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
  #   │   vda  virtio  qcow2  40G                            │
  #   │        /var/lib/libvirt/images/vt-ubuntu.qcow2       │
  #   └───────────────────────────────────── q/ESC to close ─┘
  #
  # A section the VM has nothing for is left out, except `Balloon` and `Agent`: those are
  # virtui's own prerequisites, and when one is missing the line says what that costs. Paths
  # get a line of their own, so a long one wraps without breaking the columns.
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
    def initialize(config, disk_stats = [])
      super(config.name)
      @config = config
      @disk_stats = disk_stats
      @view = Component::TextView.new
      self.content = @view
      self.footer_text = 'q/ESC to close'
      rebuild
    end

    # Opens the window as a modal popup, sized {SIZE}.
    #
    # @param config [Virt::DomainConfig] what the VM is defined as
    # @param disk_stats [Array<Virt::DiskStat>] see {#initialize}
    # @return [Tuile::Component::Popup] the opened popup
    def self.open(config, disk_stats = [])
      Tuile::Component::Popup.new(content: new(config, disk_stats), declared_size: SIZE).open
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

    # One aligned row per disk, its source on the line under it.
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
        [aligned.join('  ').rstrip, "#{indent}#{disk_source(disk)}"]
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
