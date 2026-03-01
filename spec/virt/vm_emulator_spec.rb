# frozen_string_literal: true

require_relative '../spec_helper'
require 'virt/vm_emulator'
require 'virt/virtcache'
require 'timecop'

describe VMEmulator::VM do
  it 'new_vm_not_running' do
    vm = VMEmulator::VM.simple('a')
    assert !vm.running?
    assert_nil vm.to_mem_stat
  end

  it 'new_vm_uptime_is_nil' do
    assert_nil VMEmulator::VM.simple('a').uptime
  end

  it 'started_vm_is_running' do
    vm = VMEmulator::VM.simple('a')
    vm.start
    assert vm.running?
  end

  it 'uptime_when_running' do
    vm = VMEmulator::VM.simple('a')
    now = Time.now
    Timecop.freeze(now) { vm.start }
    Timecop.freeze(now + 7) { assert_equal 7.0, vm.uptime }
  end

  it 'memory_usage_during_startup' do
    vm = VMEmulator::VM.simple('a')
    now = Time.now
    Timecop.freeze(now) do
      vm.start
      ms = vm.to_mem_stat
      assert_equal 'actual 2G(rss=1.1G); guest: 0/1.9G (0%) (unused=896M, disk_caches=1G)', ms.to_s
    end
    # the middle of guest OS startup
    Timecop.freeze(now + 5) do
      ms = vm.to_mem_stat
      assert_equal 'actual 2G(rss=1.6G); guest: 512M/1.9G (26%) (unused=384M, disk_caches=1G)', ms.to_s
    end
    # the end of guest OS startup
    Timecop.freeze(now + 10) do
      ms = vm.to_mem_stat
      assert_equal 'actual 2G(rss=2G); guest: 1G/1.9G (53%) (unused=0, disk_caches=896M)', ms.to_s
    end
    # guest OS is started for 5 seconds already
    Timecop.freeze(now + 15) do
      ms = vm.to_mem_stat
      assert_equal 'actual 2G(rss=2G); guest: 1G/1.9G (53%) (unused=0, disk_caches=896M)', ms.to_s
    end
  end

  it 'still_running_right_after_shutdown' do
    # shutdown takes 5 seconds
    vm = VMEmulator::VM.simple('a')
    now = Time.now
    Timecop.freeze(now) do
      vm.start
      vm.shut_down
      assert vm.running?
    end
    Timecop.freeze(now + 3) do
      assert vm.running?
    end
  end

  it 'not_running_when_fully_shutdown' do
    # shutdown takes 5 seconds
    vm = VMEmulator::VM.simple('a')
    now = Time.now
    Timecop.freeze(now) do
      vm.start
      vm.shut_down
    end
    Timecop.freeze(now + 5) do
      assert !vm.running?
    end
  end

  it 'uptime_nil_after_shutdown' do
    vm = VMEmulator::VM.simple('a')
    now = Time.now
    Timecop.freeze(now) { vm.start; vm.shut_down }
    Timecop.freeze(now + 5) { assert_nil vm.uptime }
  end

  it 'exact_shutdown_boundary' do
    # running? uses strict < so at exactly 5s the VM is no longer running
    vm = VMEmulator::VM.simple('a')
    now = Time.now
    Timecop.freeze(now) { vm.start; vm.shut_down }
    Timecop.freeze(now + 4.999) { assert vm.running? }
    Timecop.freeze(now + 5.0) { assert !vm.running? }
  end

  it 'mem_usage_during_shutdown' do
    # shutdown takes 5 seconds
    vm = VMEmulator::VM.simple('a')
    now = Time.now
    Timecop.freeze(now) do
      vm.start
    end
    Timecop.freeze(now + 20) do
      vm.shut_down
      ms = vm.to_mem_stat
      assert_equal 'actual 2G(rss=2G); guest: 1G/1.9G (53%) (unused=0, disk_caches=896M)', ms.to_s
    end
    Timecop.freeze(now + 22.5) do
      ms = vm.to_mem_stat
      assert_equal 'actual 2G(rss=1.6G); guest: 512M/1.9G (26%) (unused=384M, disk_caches=1G)', ms.to_s
    end
    Timecop.freeze(now + 25) do
      ms = vm.to_mem_stat
      assert_nil ms
    end
  end

  it 'restart_after_shutdown' do
    vm = VMEmulator::VM.simple('a')
    now = Time.now
    Timecop.freeze(now) { vm.start }
    Timecop.freeze(now + 20) { vm.shut_down }
    Timecop.freeze(now + 25) do
      assert !vm.running?
      vm.start
      assert vm.running?
    end
  end

  it 'increase_actual' do
    vm = VMEmulator::VM.simple('a')
    now = Time.now
    Timecop.freeze(now) do
      vm.start
    end
    Timecop.freeze(now + 10) do
      vm.memory_actual = 4.GiB
      assert_equal 'actual 4G(rss=2.1G); guest: 1G/3.9G (25%) (unused=1.9G, disk_caches=1G)', vm.to_mem_stat.to_s
    end
  end

  it 'decrease_actual' do
    vm = VMEmulator::VM.simple('a')
    now = Time.now
    Timecop.freeze(now) do
      vm.start
    end
    Timecop.freeze(now + 10) do
      vm.memory_actual = 1.GiB
      assert_equal 'actual 2G(rss=2G); guest: 1G/1.9G (53%) (unused=0, disk_caches=896M)', vm.to_mem_stat.to_s
    end
    # actual slowly decreases over 5 seconds
    Timecop.freeze(now + 12.5) do
      assert_equal 'actual 1.5G(rss=1.5G); guest: 1G/1.4G (72%) (unused=0, disk_caches=384M)', vm.to_mem_stat.to_s
    end
    Timecop.freeze(now + 15) do
      assert_equal 'actual 1G(rss=1G); guest: 896M/896M (100%) (unused=0, disk_caches=0)', vm.to_mem_stat.to_s
    end
  end

  it 'memory_app_set_immediately' do
    vm = VMEmulator::VM.simple('a')
    now = Time.now
    Timecop.freeze(now) { vm.start }
    Timecop.freeze(now + 10) do
      vm.memory_app = 512.MiB
      assert_equal 'actual 2G(rss=1.6G); guest: 512M/1.9G (26%) (unused=384M, disk_caches=1G)', vm.to_mem_stat.to_s
    end
  end

  it 'memory_app_excess_clamped_to_available' do
    vm = VMEmulator::VM.simple('a')
    now = Time.now
    Timecop.freeze(now) { vm.start }
    Timecop.freeze(now + 10) do
      vm.memory_app = 10.GiB  # far exceeds available (1.9G)
      assert_equal 'actual 2G(rss=2G); guest: 1.9G/1.9G (100%) (unused=0, disk_caches=0)', vm.to_mem_stat.to_s
    end
  end

  # Guard / validation tests

  it 'start_raises_when_already_running' do
    vm = VMEmulator::VM.simple('a')
    vm.start
    assert_raises(RuntimeError) { vm.start }
  end

  it 'shut_down_raises_when_stopped' do
    assert_raises(RuntimeError) { VMEmulator::VM.simple('a').shut_down }
  end

  it 'memory_actual_raises_when_stopped' do
    assert_raises(RuntimeError) { VMEmulator::VM.simple('a').memory_actual = 1.GiB }
  end

  it 'memory_app_raises_when_stopped' do
    assert_raises(RuntimeError) { VMEmulator::VM.simple('a').memory_app = 512.MiB }
  end

  it 'memory_actual_raises_below_minimum' do
    vm = VMEmulator::VM.simple('a')
    vm.start
    assert_raises(RuntimeError) { vm.memory_actual = VMEmulator::VM::MIN_ACTUAL - 1 }
  end

  it 'memory_actual_raises_above_max' do
    vm = VMEmulator::VM.simple('a', actual: 2.GiB, max_actual: 4.GiB)
    vm.start
    assert_raises(RuntimeError) { vm.memory_actual = 4.GiB + 1 }
  end

  it 'memory_app_raises_below_minimum' do
    vm = VMEmulator::VM.simple('a')
    vm.start
    assert_raises(RuntimeError) { vm.memory_app = VMEmulator::VM::MIN_APP_MEMORY - 1 }
  end

  it 'new_raises_with_small_max_memory' do
    info = DomainInfo.new('a', 1, 64.MiB)
    assert_raises(RuntimeError) { VMEmulator::VM.new(info, 2.GiB, 1.GiB) }
  end

  it 'new_raises_with_small_initial_actual' do
    info = DomainInfo.new('a', 1, 2.GiB)
    assert_raises(RuntimeError) { VMEmulator::VM.new(info, 64.MiB, 1.GiB) }
  end

  it 'new_raises_with_small_initial_apps' do
    info = DomainInfo.new('a', 1, 2.GiB)
    assert_raises(RuntimeError) { VMEmulator::VM.new(info, 2.GiB, 64.MiB) }
  end
end

describe VMEmulator do
  it 'new_empty' do
    assert VMEmulator.new.domain_data.empty?
    assert !VMEmulator.new.hostinfo.nil?
  end

  it 'smoke_virtcache' do
    VirtCache.new(VMEmulator.new, PcEmulator.new)
  end

  it 'virtcache_with_some_vms' do
    e = VMEmulator.new
    e.add(VMEmulator::VM.simple('vm0')).start
    e.add(VMEmulator::VM.simple('vm1'))
    assert_equal 2, e.domain_data.size
    c = VirtCache.new(e, PcEmulator.new)
    assert_equal %w[vm0 vm1], c.domains
  end

  it 'set_active_on_running_vm' do
    e = VMEmulator.new
    e.add(VMEmulator::VM.simple('vm0')).start
    e.set_actual 'vm0', 3.GiB
    assert_equal 3.GiB, e.vm('vm0').to_mem_stat.actual
  end

  it 'add_raises_on_duplicate_name' do
    e = VMEmulator.new
    e.add(VMEmulator::VM.simple('vm0'))
    assert_raises(RuntimeError) { e.add(VMEmulator::VM.simple('vm0')) }
  end

  it 'delete_removes_vm' do
    e = VMEmulator.new
    e.add(VMEmulator::VM.simple('vm0'))
    e.delete('vm0')
    assert e.domain_data.empty?
  end

  it 'vm_returns_nil_for_unknown_name' do
    assert_nil VMEmulator.new.vm('unknown')
  end

  it 'set_actual_raises_when_disabled' do
    e = VMEmulator.new
    e.allow_set_actual = false
    e.add(VMEmulator::VM.simple('vm0')).start
    assert_raises(RuntimeError) { e.set_actual('vm0', 3.GiB) }
  end

  it 'domain_data_reflects_running_state' do
    e = VMEmulator.new
    e.add(VMEmulator::VM.simple('vm0')).start
    e.add(VMEmulator::VM.simple('vm1'))
    dd = e.domain_data
    assert_equal :running, dd['vm0'].state
    assert_equal :shut_off, dd['vm1'].state
    assert !dd['vm0'].mem_stat.nil?
    assert_nil dd['vm1'].mem_stat
  end

  it 'domain_data_disk_stat' do
    e = VMEmulator.new
    e.add(VMEmulator::VM.simple('vm0')).start
    disk = e.domain_data['vm0'].disk_stat.first
    assert_equal 'vda', disk.name
    assert_equal 64.GiB, disk.allocation
    assert_equal 128.GiB, disk.capacity
  end

  it 'demo_creates_correct_vm_states' do
    dd = VMEmulator.demo.domain_data
    assert_equal 4, dd.size
    assert_equal :running, dd['Ubuntu'].state
    assert_equal :running, dd['win11'].state
    assert_equal :shut_off, dd['BASE'].state
    assert_equal :shut_off, dd['Fedora'].state
  end
end
