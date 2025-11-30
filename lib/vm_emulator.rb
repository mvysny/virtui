# frozen_string_literal: true

require_relative 'interpolator'
require_relative 'virt'
require_relative 'byte_prefixes'

# Emulates a bunch of VMs. API-compatible with [VirtCmd].
class VMEmulator
  # @param hostinfo [CpuInfo]
  def initialize(hostinfo: CpuInfo.new('emulator', 1, 4, 2))
    @hostinfo = hostinfo
    # Hash{String => VM}
    @vms = {}
    @allow_set_actual = true
  end

  attr_reader :hostinfo
  attr_accessor :allow_set_actual

  # A VM. When started, the memory used by guest apps slowly ramps to `started_initial_apps`. The `disk_caches` value
  # stays at around 1GB (or less, depending what makes most sense).
  class VM
    # We'll pretend that the apps need at least 128m
    MIN_APP_MEMORY = 128.MiB
    # Kernel+BIOS will need 128m of RAM. This will be the difference between
    # [MemStat.actual] and [MemStat.available].
    BIOS_KERNEL = 128.MiB
    # Min. value of [MemStat.actual].
    MIN_ACTUAL = MIN_APP_MEMORY + BIOS_KERNEL

    # Creates the VM.
    # @param info [DomainInfo]
    # @param initial_actual [Integer] the value of [MemStat.actual] when the VM is started.
    # @param started_initial_apps [Integer] when the VM is started, it pretends that its app will use this amount of
    #   memory. Once started, the VM mem usage slowly climbs to this value. You can call {:set_used} to set a new usage
    #   value.
    def initialize(info, initial_actual, started_initial_apps)
      raise "max_memory must be #{MIN_ACTUAL} or higher" if info.max_memory < 128.MiB
      raise "initial_actual must be #{MIN_ACTUAL} or higher" if initial_actual < 128.MiB
      raise "initial mem for apps must be at least #{MIN_APP_MEMORY}" if started_initial_apps < MIN_APP_MEMORY

      @info = info
      @started_initial_apps = started_initial_apps
      @initial_actual = initial_actual
      @disk_caches = 1.GiB
      @startup_seconds = 10
      @shutdown_seconds = 5
      # How many seconds it will take for the VM to decrease its active memory.
      @decrease_active_seconds = 5
    end

    # Creates a simple VM with 1 CPU, given amount of max_memory and `started_initial_usage` half of given memory.
    # @param name [String]
    # @param actual [Integer] initial value of [MemStat.actual].
    # @return [VM]
    def self.simple(name, actual: 2.GiB, max_actual: actual * 256)
      VM.new(DomainInfo.new(name, 1, max_actual), actual, actual / 2)
    end

    def name
      info.name
    end

    attr_reader :info, :started_initial_apps

    def running?
      !@started_at.nil? && (@shut_down_at.nil? || Time.now - @shut_down_at < @shutdown_seconds)
    end

    # "Starts" this VM.
    def start
      raise 'Already running' if running?

      @started_at = Time.now
      @shut_down_at = nil
      @actual = Interpolator::Const.new(@initial_actual)
      # Mem used by guest apps. This doesn't include disk_caches.
      # This can be higher than 'MemStat.available' - we pretend that the rest of the app memory
      # is swapped out.
      @mem_apps = Interpolator::Linear.from_now(0, started_initial_apps, @startup_seconds)
    end

    # @return [Integer | nil] uptime in seconds or nil if shut down.
    def uptime
      running? ? Time.now - @started_at : nil
    end

    # Initiates a shutdown
    def shut_down
      check_running

      @shut_down_at = Time.now
      @mem_apps = Interpolator::Linear.from_now(@mem_apps.value, 0, @shutdown_seconds)
    end

    def memory_app=(apps)
      raise "mem for apps must be at least #{MIN_APP_MEMORY}" if apps < MIN_APP_MEMORY

      check_running
      @mem_apps = Interpolator::Const.new(apps.to_i)
    end

    def check_running
      raise 'stopped' unless running?
    end

    # Sets the actual memory.
    # @param actual [Integer] can't be more than {DomainInfo.max_memory}.
    def memory_actual=(actual)
      raise "Must be #{MIN_ACTUAL} or bigger" if actual < MIN_ACTUAL
      raise "Must be #{info.max_memory} at most" if actual > info.max_memory

      check_running
      actual = actual.to_i
      current = @actual.value
      @actual = if current <= actual
                  Interpolator::Const.new(actual)
                else
                  Interpolator::Linear.from_now(current, actual, @decrease_active_seconds)
                end
    end

    # Returns current {MemStat} of the VM. Returns nil if not running.
    # @return [MemStat | nil]
    def to_mem_stat
      return nil unless running?

      actual = @actual.value.to_i
      available = actual - BIOS_KERNEL
      apps = @mem_apps.value.to_i.clamp(0, available)
      usable = available - apps
      disk_caches = @disk_caches.clamp(0, usable)
      rss = (apps + disk_caches).clamp(nil, available) + BIOS_KERNEL
      unused = usable - disk_caches
      MemStat.new(actual, unused, available, usable, disk_caches, rss, DomainData.millis_now / 1000)
    end
  end

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
end
