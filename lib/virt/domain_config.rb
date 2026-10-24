# frozen_string_literal: true

require 'rexml/document'

module Virt
  # What a domain is *defined* as: the static facts of its `virsh dumpxml`, parsed.
  #
  #   config = DomainConfig.from_xml(File.read('spec/virt/dumpxml_vt-ubuntu.xml'))
  #   config.firmware                 # => :uefi
  #   config.disks.first.source       # => "/var/lib/libvirt/images/vt-ubuntu.qcow2"
  #   config.balloon.free_page_reporting   # => true
  #
  # Values (bytes, symbols, paths, libvirt's own model names), never display strings; how
  # they look is {UI::VMInfoWindow}'s business.
  #
  # A running domain's XML is the *live* one, with assigned ports and the agent channel's
  # state; a shut-off domain's is the persistent one, with neither. What libvirt prints in
  # each: design/research.md R_domain_xml.
  #
  # @!attribute [r] name
  #   @return [String]
  # @!attribute [r] uuid
  #   @return [String]
  # @!attribute [r] hypervisor
  #   @return [String] `<domain type=>`: `kvm`, or `qemu` for pure emulation
  # @!attribute [r] arch
  #   @return [String] e.g. `x86_64`
  # @!attribute [r] machine
  #   @return [String] the QEMU machine type, e.g. `pc-q35-10.2`
  # @!attribute [r] guest_os
  #   @return [GuestOS] the libosinfo declaration in `<metadata>`, read fresh, where
  #     {Cache::VMCache#guest_os} was read once at startup
  # @!attribute [r] vcpus
  #   @return [Integer] the maximum vCPU count
  # @!attribute [r] vcpus_online
  #   @return [Integer] the vCPUs present at boot (`<vcpu current=>`); equals {#vcpus} unless
  #     the domain is set up for vCPU hotplug
  # @!attribute [r] cpu_mode
  #   @return [String, nil] `host-passthrough`, `host-model` or `custom`; `nil` with no `<cpu>`
  # @!attribute [r] cpu_model
  #   @return [String, nil] the named CPU model of a `custom` mode, e.g. `Skylake-Client`
  # @!attribute [r] topology
  #   @return [Topology, nil] `nil` when the definition leaves it to libvirt
  # @!attribute [r] max_memory
  #   @return [Integer] `<memory>`, in bytes: the balloon's ceiling, the same figure as
  #     {DomainInfo#max_memory}
  # @!attribute [r] memory_backing
  #   @return [Array<String>] what `<memoryBacking>` asks for: `hugepages`, the source type
  #     (`memfd`, `file`), the access mode (`shared`), `locked`; empty when absent
  # @!attribute [r] balloon
  #   @return [Balloon, nil] `nil` with no balloon device, which virtui cannot resize
  # @!attribute [r] agent
  #   @return [Symbol, nil] the `qemu-guest-agent` channel: `:connected` or `:disconnected` in
  #     a running domain's live XML, `:unknown` in a shut-off one's; `nil` with no channel
  # @!attribute [r] firmware
  #   @return [Symbol] `:uefi` or `:bios`
  # @!attribute [r] secure_boot
  #   @return [Boolean]
  # @!attribute [r] loader
  #   @return [String, nil] the firmware image, as an explicit `<loader>` names it
  # @!attribute [r] nvram
  #   @return [String, nil] the UEFI variable store
  # @!attribute [r] boot
  #   @return [Array<String>] the boot order: `<os><boot dev=>` (`hd`, `cdrom`, `network`)
  #     or, failing that, the devices that carry a `<boot order=>` (a disk's target, else the
  #     element name such as `interface`); empty when neither is there
  # @!attribute [r] tpm
  #   @return [Tpm, nil]
  # @!attribute [r] disks
  #   @return [Array<Disk>] in document order
  # @!attribute [r] filesystems
  #   @return [Array<Filesystem>] host directories shared into the guest
  # @!attribute [r] interfaces
  #   @return [Array<Interface>]
  # @!attribute [r] graphics
  #   @return [Array<Graphics>]
  # @!attribute [r] video
  #   @return [Array<String>] each video adapter's model, e.g. `virtio`, `qxl`, `vga`
  # @!attribute [r] hostdevs
  #   @return [Array<Hostdev>] host devices passed through
  # @!attribute [r] other_devices
  #   @return [Array<String>] the remaining devices worth naming, as element and model, e.g.
  #     `rng virtio`, `watchdog itco`, `sound ich9`, `redirdev spicevmc`; one entry per device
  class DomainConfig < Data.define(:name, :uuid, :hypervisor, :arch, :machine, :guest_os, :vcpus, :vcpus_online,
                                   :cpu_mode, :cpu_model, :topology, :max_memory, :memory_backing, :balloon,
                                   :agent, :firmware, :secure_boot, :loader, :nvram, :boot, :tpm, :disks,
                                   :filesystems, :interfaces, :graphics, :video, :hostdevs, :other_devices)
    # The virtio-serial channel name `qemu-guest-agent` listens on.
    AGENT_CHANNEL = 'org.qemu.guest_agent.0'

    # The devices {#other_devices} names, by element.
    OTHER_DEVICES = %w[rng watchdog sound redirdev].freeze

    # `<cpu><topology>`.
    Topology = Data.define(:sockets, :cores, :threads)

    # `<memballoon>`.
    # @!attribute [r] model
    #   @return [String] e.g. `virtio`
    # @!attribute [r] autodeflate
    #   @return [Boolean] whether the guest may deflate the balloon itself when it runs out of memory
    # @!attribute [r] free_page_reporting
    #   @return [Boolean] whether the guest hands its free pages back to the host
    Balloon = Data.define(:model, :autodeflate, :free_page_reporting)

    # `<tpm>`.
    # @!attribute [r] model
    #   @return [String] e.g. `tpm-crb`, `tpm-tis`
    # @!attribute [r] backend
    #   @return [String] `emulator` or `passthrough`
    # @!attribute [r] version
    #   @return [String, nil] e.g. `2.0`
    Tpm = Data.define(:model, :backend, :version)

    # One `<disk>`.
    # @!attribute [r] target
    #   @return [String] the guest device name, e.g. `vda`; joins {DiskStat#name}
    # @!attribute [r] bus
    #   @return [String] e.g. `virtio`, `sata`, `scsi`
    # @!attribute [r] device
    #   @return [String] `disk`, `cdrom`, `floppy` or `lun`
    # @!attribute [r] type
    #   @return [String] where the data lives: `file`, `block`, `volume`, `network` or `dir`
    # @!attribute [r] format
    #   @return [String, nil] the image format, e.g. `qcow2`, `raw`
    # @!attribute [r] source
    #   @return [String, nil] a path for `file`, `block` and `dir`, `pool/volume` for `volume`,
    #     `protocol://host:port/name` for `network`; `nil` for an empty CD-ROM drive
    # @!attribute [r] shareable
    #   @return [Boolean] whether other domains may attach the same image
    # @!attribute [r] readonly
    #   @return [Boolean]
    Disk = Data.define(:target, :bus, :device, :type, :format, :source, :shareable, :readonly)

    # One `<filesystem>`: a host directory shared into the guest.
    # @!attribute [r] driver
    #   @return [String] `virtiofs` or `9p`
    # @!attribute [r] source
    #   @return [String] the host directory
    # @!attribute [r] tag
    #   @return [String] the mount tag the guest mounts it by
    Filesystem = Data.define(:driver, :source, :tag)

    # One `<interface>`.
    # @!attribute [r] type
    #   @return [String] e.g. `network`, `bridge`, `direct`, `user`
    # @!attribute [r] source
    #   @return [String, nil] the libvirt network, the bridge, or `dev (mode)` for `direct`
    # @!attribute [r] model
    #   @return [String, nil] e.g. `virtio`, `e1000e`
    # @!attribute [r] mac
    #   @return [String, nil]
    Interface = Data.define(:type, :source, :model, :mac)

    # One `<graphics>`.
    # @!attribute [r] type
    #   @return [String] e.g. `spice`, `vnc`
    # @!attribute [r] listen
    #   @return [String, nil] the address it listens on
    # @!attribute [r] port
    #   @return [Integer, nil] `nil` until libvirt assigns an autoport, so for a shut-off domain
    Graphics = Data.define(:type, :listen, :port)

    # One `<hostdev>`.
    # @!attribute [r] type
    #   @return [String] `pci`, `usb`, `scsi` or `mdev`
    # @!attribute [r] id
    #   @return [String, nil] `0000:01:00.0` for PCI, `vendor:product` (or `bus N device M`)
    #     for USB; `nil` for the other types
    Hostdev = Data.define(:type, :id)

    # Parses a domain definition.
    #
    # @param xml [String] what `virsh dumpxml` printed
    # @return [DomainConfig]
    # @raise [ArgumentError] if `xml` is not a well-formed `<domain>`, or holds a size in a
    #   unit other than the KiB `virsh dumpxml` always writes
    def self.from_xml(xml)
      domain = begin
        REXML::Document.new(xml).root
      rescue REXML::ParseException => e
        raise ArgumentError, "unparseable domain XML: #{e.message.lines.first&.strip}"
      end
      raise ArgumentError, "not a domain definition: #{xml[0, 100].inspect}" unless domain&.name == 'domain'

      os = domain.elements['os']
      cpu = domain.elements['cpu']
      vcpu = domain.elements['vcpu']
      devices = domain.elements['devices']
      new(name: domain.elements['name'].text,
          uuid: domain.elements['uuid']&.text,
          hypervisor: domain.attributes['type'],
          arch: os.elements['type'].attributes['arch'],
          machine: os.elements['type'].attributes['machine'],
          guest_os: guest_os(domain),
          vcpus: vcpu.text.to_i,
          vcpus_online: (vcpu.attributes['current'] || vcpu.text).to_i,
          cpu_mode: cpu&.attributes&.[]('mode'),
          cpu_model: domain.elements['cpu/model']&.text,
          topology: topology(domain.elements['cpu/topology']),
          max_memory: kib(domain.elements['memory']),
          memory_backing: memory_backing(domain.elements['memoryBacking']),
          balloon: balloon(devices.elements['memballoon']),
          agent: agent(devices),
          firmware: uefi?(os) ? :uefi : :bios,
          secure_boot: secure_boot?(os),
          loader: os.elements['loader']&.text,
          nvram: os.elements['nvram']&.text,
          boot: boot(os, devices),
          tpm: tpm(devices.elements['tpm']),
          disks: devices.get_elements('disk').map { disk(_1) },
          filesystems: devices.get_elements('filesystem').map { filesystem(_1) },
          interfaces: devices.get_elements('interface').map { interface(_1) },
          graphics: devices.get_elements('graphics').map { graphics(_1) },
          video: devices.get_elements('video/model').map { _1.attributes['type'] },
          hostdevs: devices.get_elements('hostdev').map { hostdev(_1) },
          other_devices: other_devices(devices))
    end

    class << self
      private

      # @param domain [REXML::Element]
      # @return [GuestOS]
      def guest_os(domain)
        os = REXML::XPath.first(domain, 'metadata/osinfo:libosinfo/osinfo:os', 'osinfo' => Virsh::LIBOSINFO_URI)
        GuestOS.from_osinfo_id(os&.attributes&.[]('id'))
      end

      # @param element [REXML::Element] a size element, such as `<memory unit='KiB'>`
      # @return [Integer] bytes
      # @raise [ArgumentError] for any unit but KiB, libvirt's default and the only one
      #   `dumpxml` writes
      def kib(element)
        unit = element.attributes['unit'] || 'KiB'
        raise ArgumentError, "unexpected unit in #{element}" unless unit == 'KiB'

        element.text.to_i.KiB
      end

      # @param element [REXML::Element, nil]
      # @return [Topology, nil]
      def topology(element)
        return nil if element.nil?

        Topology.new(*%w[sockets cores threads].map { element.attributes[_1].to_i })
      end

      # @param element [REXML::Element, nil] `<memoryBacking>`
      # @return [Array<String>]
      def memory_backing(element)
        return [] if element.nil?

        [element.elements['hugepages'] && 'hugepages',
         element.elements['source']&.attributes&.[]('type'),
         element.elements['access']&.attributes&.[]('mode'),
         element.elements['locked'] && 'locked'].compact
      end

      # @param element [REXML::Element, nil] `<memballoon>`
      # @return [Balloon, nil]
      def balloon(element)
        return nil if element.nil? || element.attributes['model'] == 'none'

        Balloon.new(element.attributes['model'], element.attributes['autodeflate'] == 'on',
                    element.attributes['freePageReporting'] == 'on')
      end

      # @param devices [REXML::Element]
      # @return [Symbol, nil]
      def agent(devices)
        target = devices.elements["channel/target[@name='#{AGENT_CHANNEL}']"]
        return nil if target.nil?

        target.attributes['state']&.to_sym || :unknown
      end

      # Both spellings count: `<os firmware='efi'>` auto-selects, `<loader type='pflash'>`
      # names the image; libvirt expands the first into the second, but only once it has
      # picked one.
      # @param os [REXML::Element]
      # @return [Boolean]
      def uefi?(os)
        os.attributes['firmware'] == 'efi' || os.elements['loader']&.attributes&.[]('type') == 'pflash'
      end

      # @param os [REXML::Element]
      # @return [Boolean]
      def secure_boot?(os)
        os.elements['loader']&.attributes&.[]('secure') == 'yes' ||
          os.elements["firmware/feature[@name='secure-boot']"]&.attributes&.[]('enabled') == 'yes'
      end

      # @param os [REXML::Element]
      # @param devices [REXML::Element]
      # @return [Array<String>]
      def boot(os, devices)
        by_os = os.get_elements('boot').map { _1.attributes['dev'] }
        return by_os unless by_os.empty?

        devices.get_elements('*[boot]')
               .sort_by { _1.elements['boot'].attributes['order'].to_i }
               .map { _1.name == 'disk' ? _1.elements['target'].attributes['dev'] : _1.name }
      end

      # @param element [REXML::Element, nil] `<tpm>`
      # @return [Tpm, nil]
      def tpm(element)
        return nil if element.nil?

        backend = element.elements['backend']
        Tpm.new(element.attributes['model'], backend&.attributes&.[]('type'), backend&.attributes&.[]('version'))
      end

      # @param element [REXML::Element] `<disk>`
      # @return [Disk]
      def disk(element)
        target = element.elements['target']
        Disk.new(target: target.attributes['dev'], bus: target.attributes['bus'],
                 device: element.attributes['device'] || 'disk', type: element.attributes['type'],
                 format: element.elements['driver']&.attributes&.[]('type'),
                 source: disk_source(element.attributes['type'], element.elements['source']),
                 shareable: !element.elements['shareable'].nil?, readonly: !element.elements['readonly'].nil?)
      end

      # @param type [String] `<disk type=>`
      # @param source [REXML::Element, nil] `<disk><source>`
      # @return [String, nil]
      def disk_source(type, source)
        return nil if source.nil?

        a = source.attributes
        case type
        when 'file' then a['file']
        when 'block' then a['dev']
        when 'dir' then a['dir']
        when 'volume' then "#{a['pool']}/#{a['volume']}"
        when 'network'
          host = source.elements['host']
          address = host.nil? ? '' : [host.attributes['name'], host.attributes['port']].compact.join(':')
          "#{a['protocol']}://#{address}/#{a['name']}"
        else raise ArgumentError, "unexpected disk type #{type}: #{source}"
        end
      end

      # @param element [REXML::Element] `<filesystem>`
      # @return [Filesystem]
      def filesystem(element)
        # No `<driver type=>` is QEMU's default driver, which is 9p.
        Filesystem.new(element.elements['driver']&.attributes&.[]('type') || '9p',
                       element.elements['source']&.attributes&.[]('dir'),
                       element.elements['target']&.attributes&.[]('dir'))
      end

      # @param element [REXML::Element] `<interface>`
      # @return [Interface]
      def interface(element)
        source = element.elements['source']&.attributes || {}
        # A live `type='network'` also carries the bridge libvirt put it on; the network is
        # what the definition says.
        source_text = source['network'] || source['bridge'] ||
                      (source['dev'] && [source['dev'], source['mode'] && "(#{source['mode']})"].compact.join(' '))
        Interface.new(element.attributes['type'], source_text,
                      element.elements['model']&.attributes&.[]('type'),
                      element.elements['mac']&.attributes&.[]('address'))
      end

      # @param element [REXML::Element] `<graphics>`
      # @return [Graphics]
      def graphics(element)
        listen = element.attributes['listen'] || element.elements['listen']&.attributes&.[]('address')
        port = element.attributes['port']&.to_i
        Graphics.new(element.attributes['type'], listen, port&.positive? ? port : nil)
      end

      # @param element [REXML::Element] `<hostdev>`
      # @return [Hostdev]
      def hostdev(element)
        type = element.attributes['type']
        source = element.elements['source']
        id = case type
             when 'pci'
               a = source.elements['address'].attributes
               format('%<domain>04x:%<bus>02x:%<slot>02x.%<function>x',
                      **%w[domain bus slot function].to_h { [_1.to_sym, a[_1].hex] })
             when 'usb'
               vendor = source.elements['vendor']&.attributes&.[]('id')
               if vendor.nil?
                 a = source.elements['address'].attributes
                 "bus #{a['bus']} device #{a['device']}"
               else
                 "#{vendor.delete_prefix('0x')}:#{source.elements['product'].attributes['id'].delete_prefix('0x')}"
               end
             end
        Hostdev.new(type, id)
      end

      # @param devices [REXML::Element]
      # @return [Array<String>]
      def other_devices(devices)
        devices.elements.select { OTHER_DEVICES.include?(_1.name) }.map do |element|
          # A redirdev's kind is its `type`, everything else's its `model`.
          [element.name, element.attributes['model'] || element.attributes['type']].compact.join(' ')
        end
      end
    end
  end
end
