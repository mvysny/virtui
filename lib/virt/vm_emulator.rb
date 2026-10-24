# frozen_string_literal: true

module Virt
  # An in-memory fleet of simulated VMs, API-compatible with {Virsh}, for demo/test mode
  # without libvirt. Each VM is a {VMEmulator::VM}; see {.demo} for a ready-made fleet.
  class VMEmulator
    # What a simulated VM declares unless told otherwise (see {VMEmulator::VM#guest_os}).
    LINUX = GuestOS.from_osinfo_id('http://ubuntu.com/ubuntu/25.10')

    # A ready-made non-Linux declaration, for a fleet that needs one — {.demo} gives it to
    # win11 so the UI's guest-OS marker has more than one family to draw.
    WINDOWS = GuestOS.from_osinfo_id('http://microsoft.com/win/11')

    # A simulated VM's one disk, `vda`, until {#resize_volume} grows it.
    DISK_CAPACITY = 128.GiB

    # The simulated `default` pool's free space.
    POOL_AVAILABLE = 400.GiB

    # @param hostinfo [CpuInfo] the host CPU topology to report
    def initialize(hostinfo: CpuInfo.new('emulator', 1, 4, 2))
      @hostinfo = hostinfo
      @vms = {}
      @allow_set_actual = true
    end

    # @return [CpuInfo] the simulated host CPU topology
    attr_reader :hostinfo
    # @return [Boolean] whether {#set_actual} is honored; set `false` to simulate a host
    #   that rejects memory changes (for debugging)
    attr_accessor :allow_set_actual

    # Adds a VM to the fleet.
    #
    # @param vm [VMEmulator::VM] the VM to add
    # @return [VMEmulator::VM] the same VM
    # @raise [RuntimeError] if a VM with the same name already exists
    def add(vm)
      raise "VM with given name already present: #{vm.name}: #{@vms.keys}" if @vms.keys.include? vm.name

      @vms[vm.name] = vm
      vm
    end

    # @param name [String] VM name
    # @return [VMEmulator::VM, nil] the VM, or `nil` if no such VM exists
    def vm(name)
      @vms[name]
    end

    # Deletes the VM with the given name.
    # @param name [String] VM name
    # @return [VMEmulator::VM, nil] the deleted VM, or `nil` if none existed
    def delete(name)
      @vms.delete(name)
    end

    # @return [Hash{String => DomainData}] a snapshot of every VM, keyed by name
    def domain_data
      @vms.to_h do |name, vm|
        state = vm.running? ? :running : :shut_off
        disk = DiskStat.new('vda', 64.GiB, vm.disk_capacity, 64.GiB, vm.disk_path)
        data = DomainData.new(vm.info, state, DomainData.millis_now, 0, vm.to_mem_stat, [disk])
        [name, data]
      end
    end

    # @param name [String] VM name
    # @return [ResourceUsage, nil] the simulated guest's swap level (see {VMEmulator::VM#swap}),
    #   or `nil` for an unknown, stopped, or agent-less VM
    def guest_swap(name) = @vms[name]&.swap

    # @param name [String] VM name
    # @return [String, nil] the simulated VM's address (see {VMEmulator::VM#ip_address}), or
    #   `nil` for an unknown or stopped VM
    def ip_address(name) = @vms[name]&.ip_address

    # What the VM declares — {LINUX} unless its {VMEmulator::VM#guest_os} was set. Mirrors
    # {Virsh#guest_os} so {Cache} can call it backend-agnostically, including the part where
    # a domain that declares nothing answers {GuestOS::UNKNOWN} rather than `nil`.
    #
    # @param name [String] VM name
    # @return [GuestOS] the declaration; {GuestOS::UNKNOWN} for an unknown VM
    def guest_os(name) = @vms[name]&.guest_os || GuestOS::UNKNOWN

    # A small definition built from the simulated VM and run through the same
    # {DomainConfig.from_xml} as {Virsh#domain_config}, so demo mode exercises the parser.
    #
    # Its declared OS chooses the rest: Windows gets UEFI, Secure Boot and a TPM, Linux gets
    # UEFI, and an undeclared OS gets BIOS and no agent channel.
    #
    # @param name [String] VM name
    # @return [DomainConfig]
    # @raise [RuntimeError] for an unknown VM, as `virsh dumpxml` does
    def domain_config(name)
      vm = @vms[name] || raise("failed to get domain '#{name}'")
      DomainConfig.from_xml(vm.to_domain_xml)
    end

    # The guest's disk layout, run through the same {GuestStorage.parse} as
    # {Virsh#guest_storage}. A Linux guest is the easy case: an EFI partition, then `/` as the
    # last partition, with whatever the disk holds beyond 100 GiB left after it — 28 GiB until
    # {#resize_volume} grows the disk. A Windows guest reports one
    # `C:\` volume and no partitions, as its agent does.
    #
    # @param name [String] VM name
    # @return [GuestStorage]
    # @raise [GuestAgent::Unavailable] for an unknown or stopped VM, or one that declares no OS
    #   and so has no agent channel (see {#domain_config})
    def guest_storage(name)
      vm = @vms[name]
      raise GuestAgent::Unavailable, "domain '#{name}' is not running" unless vm&.running?
      raise GuestAgent::Unavailable, 'QEMU guest agent is not configured' if vm.guest_os.family == :unknown

      return GuestStorage.parse(<<~WINDOWS) if vm.guest_os.windows?
        fs.count : 1
        fs.0.name : \\\\?\\Volume{0f2c}\\
        fs.0.mountpoint : C:\\
        fs.0.fstype : NTFS
        fs.0.total-bytes : #{vm.disk_capacity - 1.GiB}
        fs.0.used-bytes : #{31.GiB}
        fs.0.disk.count : 1
        fs.0.disk.0.alias : vda
        disk.count : 1
        disk.0.name : \\\\.\\PhysicalDrive0
        disk.0.partition : no
        disk.0.alias : vda
      WINDOWS

      efi_start = 1.MiB
      efi = 106.MiB
      root_start = efi_start + efi
      root = 100.GiB
      guestinfo = <<~LINUX
        fs.count : 2
        fs.0.name : vda1
        fs.0.mountpoint : /
        fs.0.fstype : ext4
        fs.0.total-bytes : #{root - 5.GiB}
        fs.0.used-bytes : #{9.4.GiB.to_i}
        fs.0.disk.count : 1
        fs.0.disk.0.alias : vda
        fs.0.disk.0.device : /dev/vda1
        fs.1.name : vda15
        fs.1.mountpoint : /boot/efi
        fs.1.fstype : vfat
        fs.1.total-bytes : #{efi}
        fs.1.used-bytes : #{6.MiB}
        fs.1.disk.count : 1
        fs.1.disk.0.alias : vda
        fs.1.disk.0.device : /dev/vda15
        disk.count : 3
        disk.0.name : /dev/vda1
        disk.0.partition : yes
        disk.0.dependency.count : 1
        disk.0.dependency.0.name : /dev/vda
        disk.1.name : /dev/vda15
        disk.1.partition : yes
        disk.1.dependency.count : 1
        disk.1.dependency.0.name : /dev/vda
        disk.2.name : /dev/vda
        disk.2.partition : no
        disk.2.alias : vda
      LINUX
      files = {
        '/proc/partitions' => <<~PARTITIONS,
          major minor  #blocks  name

           253        0 #{vm.disk_capacity / 1024} vda
           253        1 #{root / 1024} vda1
           253       15 #{efi / 1024} vda15
        PARTITIONS
        '/sys/class/block/vda1/start' => "#{root_start / GuestStorage::SECTOR}\n",
        '/sys/class/block/vda15/start' => "#{efi_start / GuestStorage::SECTOR}\n"
      }
      GuestStorage.parse(guestinfo) { files.fetch(_1) }
    end

    # Mirrors {Virsh#volume}: every simulated VM's image is in the `default` pool.
    #
    # @param path [String] the image, as {VMEmulator::VM#disk_path} names it
    # @return [Volume, nil] `nil` for a path no simulated VM has
    def volume(path)
      vm = @vms.values.find { _1.disk_path == path } || return
      Volume.new(path: path, pool: 'default', capacity: vm.disk_capacity, allocation: 64.GiB,
                 pool_available: POOL_AVAILABLE)
    end

    # Mirrors {Virsh#resize_volume}, refusing what libvirt refuses.
    #
    # @param path [String] the image (see {#volume})
    # @param capacity [Integer] the new size, in bytes
    # @return [void]
    # @raise [RuntimeError] for an unknown image, a running VM's, or a capacity below the
    #   current one
    def resize_volume(path, capacity)
      vm = @vms.values.find { _1.disk_path == path } || raise("no storage vol with matching path '#{path}'")
      raise "qemu-img: Could not open '#{path}': Failed to get \"write\" lock" if vm.running?
      raise "Can't shrink capacity below current capacity" if capacity < vm.disk_capacity

      vm.disk_capacity = capacity
    end

    # Sets a VM's current memory, unless {#allow_set_actual} is `false`.
    #
    # @param vmid [String] VM name
    # @param actual [Integer] new memory size, in bytes
    # @raise [RuntimeError] if {#allow_set_actual} is `false`, or the size is out of range
    #   (see {VMEmulator::VM#memory_actual=})
    def set_actual(vmid, actual)
      raise 'set_actual not allowed' unless allow_set_actual

      @vms[vmid].memory_actual = actual
    end

    # No-op: the emulator always reports fresh stats, so there's no collection period to
    # arm. Mirrors {Virsh#set_mem_stats_period} so {Cache} can call it backend-agnostically.
    #
    # @param vmid [String] VM name
    # @param period_seconds [Integer] ignored
    # @return [void]
    def set_mem_stats_period(vmid, period_seconds); end

    # No-op: the emulator's guests always answer, so there is no failure state to forget.
    # Mirrors {Virsh#forget_guest} so {Cache} can call it backend-agnostically.
    #
    # @param name [String] VM name
    # @return [void]
    def forget_guest(name); end

    # Builds a ready-made demo fleet: BASE (shut off), Ubuntu (running), win11 (running),
    # Fedora (shut off). Three OS declarations between them, so the guest-OS marker has a
    # penguin, a window and an undeclared `?` to draw.
    #
    # @return [VMEmulator] a {Virsh}-compatible emulator pre-populated with four VMs
    def self.demo
      e = VMEmulator.new
      e.add(VMEmulator::VM.simple('BASE', actual: 8.GiB, max_actual: 8.GiB))
      e.add(VMEmulator::VM.simple('Ubuntu', actual: 8.GiB, max_actual: 16.GiB))
      e.add(VMEmulator::VM.simple('win11', actual: 8.GiB, max_actual: 16.GiB))
      e.add(VMEmulator::VM.simple('Fedora', actual: 20.GiB, max_actual: 40.GiB))
      e.vm('Ubuntu').start
      e.vm('win11').start
      # Ubuntu swaps, win11 doesn't, so the demo shows both halves of the swap indicator.
      e.vm('Ubuntu').swap_out_rate = 3.MiB
      # And win11 reports no level at all — the guest-agent read is the half that plenty of
      # real guests cannot answer, so the demo has to show that state too. Declaring it
      # Windows is the same state arrived at one step earlier: {Cache} won't even ask.
      e.vm('win11').swap_total = nil
      e.vm('win11').guest_os = WINDOWS
      # BASE is the hand-written definition that names no OS at all.
      e.vm('BASE').guest_os = GuestOS::UNKNOWN
      e.vm('Ubuntu').address = '192.168.122.84'
      e.vm('win11').address = '192.168.122.23'
      e
    end

    # Starts a stopped VM.
    # @param vm [String] VM name
    def start(vm)
      @vms[vm].start
    end

    # Shuts down a VM gracefully - basically asks the VM to shut off.
    # @param vm [String] VM name
    def shutdown(vm)
      @vms[vm].shut_down
    end

    # Asks the VM to reboot itself gracefully.
    # @param domain_name [String] VM name
    def reboot(domain_name)
      @vms[domain_name].force_reboot
    end

    # Resets the VM forcefully.
    # @param domain_name [String] VM name
    def reset(domain_name)
      @vms[domain_name].force_reboot
    end

    # Forces the VM off.
    # @param domain_name [String] VM name
    def force_off(domain_name)
      @vms[domain_name].force_off
    end
  end
end
