# frozen_string_literal: true

module Virt
  # An in-memory fleet of simulated VMs, API-compatible with {Virsh}, for demo/test mode
  # without libvirt. Each VM is a {VMEmulator::VM}; see {.demo} for a ready-made fleet.
  class VMEmulator
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
      @vms.map do |name, vm|
        state = vm.running? ? :running : :shut_off
        disk = DiskStat.new('vda', 64.GiB, 128.GiB, 64.GiB, nil)
        data = DomainData.new(vm.info, state, DomainData.millis_now, 0, vm.to_mem_stat, [disk])
        [name, data]
      end.to_h
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

    # Builds a ready-made demo fleet: BASE (shut off), Ubuntu (running), win11 (running),
    # Fedora (shut off).
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
