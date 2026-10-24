# frozen_string_literal: true

module Virt
  # How a running guest has laid out its disks — the partitions on each and what is mounted
  # where — as the guest itself reports it through `qemu-guest-agent`:
  #
  #   vda = virsh.guest_storage('vt-ubuntu').disk('vda')
  #   vda.partitions.map(&:name)                         # => ["vda13", "vda14", "vda15", "vda1"]
  #   vda.partitions.last.filesystems.first.mountpoint   # => "/"
  #   vda.free_tail                                      # => 2147500032 after a 2 GiB image grow
  #
  # Two sources. `virsh guestinfo --filesystem --disk` names every guest block device, which
  # are partitions of which, and every mounted filesystem with its usage — and, crucially,
  # maps each guest disk to its host target (`vda`), which equal names do not promise: the
  # guest kernel names disks by probe order. What it lacks is geometry, read from guest
  # files: one `/proc/partitions` for every size, one `/sys/class/block/<part>/start` per
  # partition (design/research.md R_guestinfo, design/decisions.md D_guest_storage). Those
  # reads happen only for `/dev/…` partitions, so a guest without Linux device names is asked
  # for no Linux file.
  #
  # Values in bytes, never display strings; how they look is {UI::VMInfoWindow}'s business.
  #
  # @!attribute [r] disks
  #   @return [Array<Disk>] the guest's whole disks that map to a host target, in guestinfo's order
  class GuestStorage < Data.define(:disks)
    # The partitions' `/proc/partitions` and `/sys/…/start` count in units of this many
    # bytes, whatever the disk's own logical sector size.
    SECTOR = 512

    # The smallest {Disk#free_tail} that is room anyone left on purpose: a GPT disk always
    # keeps ~17 KiB there for its backup table, and partitioners align to 1 MiB.
    # @return [Integer] bytes
    MIN_FREE_TAIL = 1.MiB

    # One whole disk of the guest.
    # @!attribute [r] target
    #   @return [String] the host's name for it, e.g. `vda`; joins {DomainConfig::Disk#target}
    # @!attribute [r] device
    #   @return [String] the guest's name for it, e.g. `/dev/vda`
    # @!attribute [r] size
    #   @return [Integer, nil] bytes, as the guest sees it; `nil` when its geometry was not read
    # @!attribute [r] partitions
    #   @return [Array<Partition>] in disk order (by start), not by number
    # @!attribute [r] filesystems
    #   @return [Array<Filesystem>] mounted on the disk but on none of {#partitions}: a
    #     filesystem on the whole disk, or a Windows volume
    class Disk < Data.define(:target, :device, :size, :partitions, :filesystems)
      # @return [Integer, nil] bytes between the end of the last partition and the end of
      #   the disk — what growing the last partition would add; `nil` with no partitions or
      #   no geometry
      def free_tail
        return nil if size.nil? || partitions.empty? || partitions.any? { _1.start.nil? }

        size - partitions.map { _1.start + _1.size }.max
      end
    end

    # One partition of a {Disk}.
    # @!attribute [r] device
    #   @return [String] e.g. `/dev/vda1`
    # @!attribute [r] start
    #   @return [Integer, nil] its offset from the start of the disk, in bytes
    # @!attribute [r] size
    #   @return [Integer, nil] bytes; rounded down to a KiB, as `/proc/partitions` counts
    # @!attribute [r] filesystems
    #   @return [Array<Filesystem>] mounted from it: one, or several on an LVM physical volume
    class Partition < Data.define(:device, :start, :size, :filesystems)
      # @return [String] e.g. `vda1`
      def name = File.basename(device)
    end

    # One mounted filesystem.
    # @!attribute [r] name
    #   @return [String] the guest device it is mounted from, e.g. `vda1`, or `dm-0` through LVM
    # @!attribute [r] mountpoint
    #   @return [String] e.g. `/boot/efi`, `C:\`
    # @!attribute [r] fstype
    #   @return [String] e.g. `ext4`, `btrfs`, `NTFS`
    # @!attribute [r] total
    #   @return [Integer, nil] bytes available to an unprivileged user plus {#used}, as `df`
    #     counts its Use%; `nil` when the agent could not stat it
    # @!attribute [r] used
    #   @return [Integer, nil] bytes
    Filesystem = Data.define(:name, :mountpoint, :fstype, :total, :used)

    # @param target [String] a host target, e.g. `vda`
    # @return [Disk, nil] the guest disk behind it, or `nil` if the guest reported none
    def disk(target) = disks.find { _1.target == target }

    # Parses `virsh guestinfo --filesystem --disk`, reading the partition geometry it lacks
    # through the block.
    #
    # @param guestinfo [String] `virsh -q guestinfo <vm> --filesystem --disk` output
    # @yield [path] a guest file to read; called only when there are `/dev/…` partitions
    # @yieldparam path [String] an absolute path, as the guest sees it
    # @yieldreturn [String] the file's contents
    # @return [GuestStorage]
    # @raise [RuntimeError] on a line that is not `key : value`, or a geometry file that does
    #   not say what it should
    def self.parse(guestinfo, &read_file)
      values = guestinfo.lines.map(&:chomp).reject(&:empty?).to_h do |line|
        match = line.match(/\A([\w.-]+)\s*: ?(.*)\z/) or raise "unparseable guestinfo line: #{line.inspect}"
        match.captures
      end
      filesystems = filesystems(values)
      devices = (0...values['disk.count'].to_i).map { |i| device(values, "disk.#{i}") }
      wholes = devices.reject { _1[:partition] }.select { _1[:alias] }
      parts = devices.select { _1[:partition] }
      geometry = geometry(parts.map { _1[:name] }, &read_file)

      disks = wholes.map do |whole|
        partitions = parts.select { _1[:dependencies] == [whole[:name]] }.map do |part|
          name = part[:name]
          Partition.new(device: name, start: geometry.dig(name, :start), size: geometry.dig(name, :size),
                        filesystems: filesystems.select { |device, _| device == name }.map(&:last))
        end
        on_partitions = partitions.map(&:device)
        loose = filesystems.select { |device, fs_alias, _| fs_alias == whole[:alias] && !on_partitions.include?(device) }
        Disk.new(target: whole[:alias], device: whole[:name], size: geometry.dig(whole[:name], :size),
                 partitions: partitions.sort_by { [_1.start || 0, _1.device] },
                 filesystems: loose.map(&:last).uniq)
      end
      new(disks: disks)
    end

    # @param values [Hash{String => String}]
    # @param key [String] e.g. `disk.4`
    # @return [Hash{Symbol => Object}] `:name`, `:partition`, `:dependencies`, `:alias`
    private_class_method def self.device(values, key)
      { name: values["#{key}.name"], partition: values["#{key}.partition"] == 'yes',
        dependencies: (0...values["#{key}.dependency.count"].to_i).map { values["#{key}.dependency.#{_1}.name"] },
        alias: values["#{key}.alias"] }
    end

    # One triple per (filesystem, disk it lives on): a btrfs spanning two disks appears twice.
    # @param values [Hash{String => String}]
    # @return [Array<Array(String, String, Filesystem)>] the guest device, the host target, the filesystem
    private_class_method def self.filesystems(values)
      (0...values['fs.count'].to_i).flat_map do |i|
        key = "fs.#{i}"
        fs = Filesystem.new(name: values["#{key}.name"], mountpoint: values["#{key}.mountpoint"],
                            fstype: values["#{key}.fstype"], total: values["#{key}.total-bytes"]&.to_i,
                            used: values["#{key}.used-bytes"]&.to_i)
        (0...values["#{key}.disk.count"].to_i).map do |d|
          [values["#{key}.disk.#{d}.device"], values["#{key}.disk.#{d}.alias"], fs]
        end
      end
    end

    # @param partitions [Array<String>] guest partition devices, e.g. `/dev/vda1`
    # @yield [path] see {.parse}
    # @return [Hash{String => Hash{Symbol => Integer}}] `:size` per `/dev/…` device in
    #   `/proc/partitions`, whole disks included, and `:start` per partition
    # @raise [RuntimeError] if a start file is not a number
    private_class_method def self.geometry(partitions, &read_file)
      partitions = partitions.select { _1&.start_with?('/dev/') }
      return {} if partitions.empty?

      # major minor #blocks name, the size in KiB whatever the sector size.
      sizes = read_file.call('/proc/partitions').lines.filter_map do |line|
        columns = line.split
        ["/dev/#{columns[3]}", { size: columns[2].to_i * 1024 }] if columns.size == 4 && columns[2].match?(/\A\d+\z/)
      end.to_h
      partitions.each do |device|
        start = read_file.call("/sys/class/block/#{File.basename(device)}/start").strip
        raise "#{device}: start is not a sector count: #{start.inspect}" unless start.match?(/\A\d+\z/)

        (sizes[device] ||= {})[:start] = start.to_i * SECTOR
      end
      sizes
    end
  end
end
