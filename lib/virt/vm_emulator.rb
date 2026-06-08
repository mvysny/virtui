# frozen_string_literal: true

# Emulates a bunch of VMs. API-compatible with [VirtCmd].
class VMEmulator
  # @param hostinfo [CpuInfo]
  def initialize(hostinfo: CpuInfo.new('emulator', 1, 4, 2))
    @hostinfo = hostinfo
    # {Hash{String => VM}}
    @vms = {}
    # {Boolean} For debugging purposes
    @allow_set_actual = true
  end

  # @return [CpuInfo]
  attr_reader :hostinfo
  attr_accessor :allow_set_actual

  # Adds a new VM.
  # @param vm [VM]
  # @return [VM]
  def add(vm)
    raise "VM with given name already present: #{vm.name}: #{@vms.keys}" if @vms.keys.include? vm.name

    @vms[vm.name] = vm
    vm
  end

  # @return [VM | nil]
  def vm(name)
    @vms[name]
  end

  # Deletes VM with given name
  # @param name [String]
  def delete(name)
    @vms.delete(name)
  end

  # @return [Hash{String => DomainData}]
  def domain_data
    @vms.map do |name, vm|
      state = vm.running? ? :running : :shut_off
      disk = DiskStat.new('vda', 64.GiB, 128.GiB, 64.GiB, nil)
      data = DomainData.new(vm.info, state, DomainData.millis_now, 0, vm.to_mem_stat, [disk])
      [name, data]
    end.to_h
  end

  # @param vmid [String]
  # @param actual [Integer]
  def set_actual(vmid, actual)
    raise 'set_actual not allowed' unless allow_set_actual

    @vms[vmid].memory_actual = actual
  end

  # Creates a bunch of VMs:
  # - BASE: shut_off
  # - Ubuntu: running
  # - win11: running
  # - Fedora: shut_off
  # @return A [VirtCmd] compatible class.
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

  def start(vm)
    @vms[vm].start
  end

  # Shuts down a VM gracefully - basically asks the VM to shut off.
  # @param domain_name [String] VM name
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
