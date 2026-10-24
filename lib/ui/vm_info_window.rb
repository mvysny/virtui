# frozen_string_literal: true

module UI
  # The `i` popup of {VMPane}: what a VM is *defined* as, read-only.
  #
  #   ┌─ vt-ubuntu ──────────────────────────────────────────┐
  #   │ OS        linux — http://ubuntu.com/ubuntu/24.04     │
  #   │ Machine   x86_64, pc-q35-10.2, KVM                   │
  #   │ CPU       2 vCPUs, host-passthrough                  │
  #   │ Balloon   virtio, free page reporting                │
  #   │ Agent     no channel — no swap level for this VM     │
  #   │ Disks                                                │
  #   │   vda  virtio  qcow2  14G                            │
  #   │        /var/lib/libvirt/images/vt-ubuntu.qcow2       │
  #   │        vda13  1023M  ext4  /boot      108M / 921M  12% │
  #   │        vda14     4M                                  │
  #   │        vda15   106M  vfat  /boot/efi  6.3M / 104M   6% │
  #   │        vda1     13G  ext4  /          3.2G / 12G   26% │
  #   │        free    2.0G                                  │
  #   └───────────────────────────────────── q/ESC to close ─┘
  #
  # A section the VM has nothing for is left out, except `Balloon` and `Agent`: those are
  # virtui's own prerequisites, and when one is missing the line says what that costs. Paths
  # get a line of their own, so a long one wraps without breaking the columns.
  #
  # Under each disk, the guest's own view of it ({Virt::GuestStorage}) when there is one: the
  # partitions in disk order, the mounted filesystems, and the space after the last partition.
  #
  # A snapshot of the moment `i` was pressed: it does not follow later ticks.
  #
  # UI-thread-confined.
  class VMInfoWindow < Tuile::Component::Window
    include Tuile

    # Like {CpuFlagsWindow::SIZE}, a touch taller: a VM with many devices runs to 30 rows.
    # @return [Fraction]
    SIZE = Fraction.new(0.7, 0.8)

    # Width of the caption column, `Firmware` plus two spaces.
    CAPTION_WIDTH = 10

    # @param config [Virt::DomainConfig] what the VM is defined as
    # @param disk_stats [Array<Virt::DiskStat>] the VM's disks from the last tick, for their
    #   capacities; a disk missing here gets a blank size
    # @param guest [Virt::GuestStorage, String, nil] the guest's view of its disks; a `String`
    #   says why the guest could not tell, `nil` means it was not asked
    def initialize(config, disk_stats = [], guest = nil)
      super(config.name)
      @config = config
      @disk_stats = disk_stats
      @guest = guest
      @view = Component::TextView.new
      self.content = @view
      self.footer_text = 'q/ESC to close'
      rebuild
    end

    # Opens the window as a modal popup, sized {SIZE}.
    #
    # @param config [Virt::DomainConfig] what the VM is defined as
    # @param disk_stats [Array<Virt::DiskStat>] see {#initialize}
    # @param guest [Virt::GuestStorage, String, nil] see {#initialize}
    # @return [Tuile::Component::Popup] the opened popup
    def self.open(config, disk_stats = [], guest = nil)
      Tuile::Component::Popup.new(content: new(config, disk_stats, guest), declared_size: SIZE).open
    end

    protected

    # @return [void]
    def handle_theme_changed
      super
      rebuild
    end

    private

    # @return [void]
    def rebuild
      @theme = screen.theme
      blocks = [identity, resources, boot, devices].reject(&:empty?)
      @view.text = blocks.map { _1.join("\n") }.join("\n\n")
    end

    # @return [Array<String>]
    def identity
      c = @config
      os = c.guest_os
      [line('OS', "#{os.family} — #{os.osinfo_id || 'no osinfo declaration'}"),
       line('Machine', [c.arch, c.machine, c.hypervisor.upcase].compact.join(', ')),
       line('UUID', c.uuid)]
    end

    # @return [Array<String>]
    def resources
      c = @config
      [line('CPU', cpu),
       line('Memory', ["#{format_byte_size(c.max_memory)} max#{" (the balloon's ceiling)" if c.balloon}",
                       *c.memory_backing].join(', ')),
       line('Balloon', balloon),
       line('Agent', agent)]
    end

    # @return [String]
    def cpu
      c = @config
      text = "#{c.vcpus} vCPU#{'s' unless c.vcpus == 1}"
      text += " (#{c.vcpus_online} online)" unless c.vcpus_online == c.vcpus
      t = c.topology
      text += " — #{t.sockets} socket × #{t.cores} cores × #{t.threads} threads" if t
      cpu = c.cpu_mode == 'custom' ? c.cpu_model : c.cpu_mode
      cpu.nil? ? text : "#{text}, #{cpu}"
    end

    # @return [String]
    def balloon
      b = @config.balloon
      return 'none — virtui cannot resize this VM' if b.nil?

      [b.model, ('free page reporting' if b.free_page_reporting), ('deflate on OOM' if b.autodeflate)]
        .compact.join(', ')
    end

    # @return [String]
    def agent
      case @config.agent
      when nil then 'no channel — no swap level for this VM'
      when :connected then 'qemu-guest-agent channel, connected'
      when :disconnected then 'qemu-guest-agent channel, not connected'
      else 'qemu-guest-agent channel'
      end
    end

    # @return [Array<String>]
    def boot
      c = @config
      firmware = c.firmware == :uefi ? 'UEFI' : 'BIOS'
      firmware += ', Secure Boot' if c.secure_boot
      lines = [line('Firmware', firmware)]
      lines << line('', c.loader) if c.loader
      lines << line('NVRAM', c.nvram) if c.nvram
      lines << line('Boot', c.boot.join(', ')) unless c.boot.empty?
      lines << line('TPM', [c.tpm.version, c.tpm.backend, c.tpm.model].compact.join(', ')) if c.tpm
      lines
    end

    # @return [Array<String>]
    def devices
      c = @config
      section('Disks', disk_rows) +
        section('Shared folders', c.filesystems.map { "#{_1.driver}  #{_1.source}  as tag \"#{_1.tag}\"" }) +
        section('Network', c.interfaces.map { [_1.model, _1.type, _1.source, _1.mac].compact.join('  ') }) +
        section('Display', c.graphics.map { graphics(_1) } + c.video.map { "video #{_1}" }) +
        section('Passthrough', c.hostdevs.map { [_1.type.upcase, _1.id].compact.join(' ') }) +
        section('Other', c.other_devices.empty? ? [] : [other_devices])
    end

    # One aligned row per disk, its source on the line under it, then the guest's view of it.
    # @return [Array<String>]
    def disk_rows
      return [] if @config.disks.empty?

      cells = @config.disks.map do |disk|
        capacity = @disk_stats.find { _1.name == disk.target }&.capacity
        [disk.target, disk.bus, disk.device == 'disk' ? disk.format.to_s : disk.device,
         capacity.nil? ? '' : format_byte_size(capacity),
         [('shared' if disk.shareable), ('read-only' if disk.readonly)].compact.join(', ')]
      end
      widths = cells.transpose.map { |column| column.map(&:length).max }
      indent = ' ' * (widths.first + 2)
      cells.zip(@config.disks).flat_map do |row, disk|
        # Sizes are right-aligned, every other column left-aligned.
        aligned = row.each_with_index.map { |cell, i| i == 3 ? cell.rjust(widths[i]) : cell.ljust(widths[i]) }
        [aligned.join('  ').rstrip, "#{indent}#{disk_source(disk)}",
         *guest_rows(disk.target).map { "#{indent}#{_1}" }]
      end + guest_failure
    end

    # @param target [String] a host disk target, e.g. `vda`
    # @return [Array<String>] aligned rows: each partition with what is mounted from it, the
    #   filesystems on no partition, the free tail; empty when the guest did not say
    def guest_rows(target)
      disk = @guest.disk(target) if @guest.is_a?(Virt::GuestStorage)
      return [] if disk.nil?

      cells = disk.partitions.flat_map do |part|
        # One row per filesystem, the partition's own cells on the first.
        rows = part.filesystems.map { ['', '', *filesystem_cells(_1, part.name)] }
        rows = [['', '']] if rows.empty?
        rows.first[0, 2] = [part.name, part.size.nil? ? '' : format_byte_size(part.size)]
        rows
      end
      cells += disk.filesystems.map { ['', '', *filesystem_cells(_1, nil)] }
      tail = disk.free_tail
      cells << ['free', format_byte_size(tail)] if tail && tail >= Virt::GuestStorage::MIN_FREE_TAIL
      align(cells, right: [1, 5])
    end

    # @param filesystem [Virt::GuestStorage::Filesystem]
    # @param partition [String, nil] the partition it is mounted from
    # @return [Array<String>] type, mountpoint, `used / total`, use %, and the device it is
    #   mounted from when that is not the partition itself (`dm-0` through LVM)
    def filesystem_cells(filesystem, partition)
      total = filesystem.total
      usage = total.nil? || filesystem.used.nil? ? ['', ''] : usage_cells(filesystem.used, total)
      [filesystem.fstype, filesystem.mountpoint, *usage, (filesystem.name if partition && filesystem.name != partition).to_s]
    end

    # @param used [Integer] bytes
    # @param total [Integer] bytes
    # @return [Array<String>] `used / total`, and the use % as `df` rounds it
    def usage_cells(used, total)
      percent = total.zero? ? 0 : (used * 100.0 / total).ceil
      ["#{format_byte_size(used)} / #{format_byte_size(total)}", "#{percent}%"]
    end

    # @return [Array<String>] why the guest could not describe its disks; empty if it did,
    #   or was not asked
    def guest_failure
      @guest.is_a?(String) ? ["The guest did not say how its disks are laid out: #{@guest}"] : []
    end

    # @param cells [Array<Array<String>>] rows of cells, ragged
    # @param right [Array<Integer>] the columns to right-align
    # @return [Array<String>] each row's cells padded to the column widths, two spaces apart
    def align(cells, right:)
      columns = cells.map(&:size).max.to_i
      widths = (0...columns).map { |i| cells.map { _1[i].to_s.length }.max }
      cells.map do |row|
        row.each_with_index.map { |cell, i| right.include?(i) ? cell.rjust(widths[i]) : cell.ljust(widths[i]) }
           .join('  ').rstrip
      end
    end

    # @param disk [Virt::DomainConfig::Disk]
    # @return [String]
    def disk_source(disk)
      return '(no media)' if disk.source.nil?

      disk.type == 'volume' ? "volume #{disk.source}" : disk.source
    end

    # @param graphics [Virt::DomainConfig::Graphics]
    # @return [String]
    def graphics(graphics)
      return "#{graphics.type} on #{graphics.listen}:#{graphics.port}" if graphics.port

      [graphics.type, ("on #{graphics.listen}" if graphics.listen), '(port assigned at start)'].compact.join(' ')
    end

    # @return [String] e.g. `sound ich9, redirdev spicevmc ×2, rng virtio`
    def other_devices
      @config.other_devices.tally.map { |device, count| count == 1 ? device : "#{device} ×#{count}" }.join(', ')
    end

    # @param caption [String]
    # @param value [String]
    # @return [String] `value` behind a hint-colored caption, padded to {CAPTION_WIDTH}
    def line(caption, value)
      @theme.hint(caption.ljust(CAPTION_WIDTH)) + value.to_s
    end

    # @param heading [String]
    # @param rows [Array<String>]
    # @return [Array<String>] the bold heading over the indented rows; empty without rows
    def section(heading, rows)
      rows.empty? ? [] : [@theme.key(heading), *rows.map { "  #{_1}" }]
    end
  end
end
