# frozen_string_literal: true

require 'minitest/autorun'
require 'vm_emulator'
require 'timecop'

class TestVM < Minitest::Test
  def test_new_vm_not_running
    vm = VMEmulator::VM.simple('a')
    assert !vm.running?
    assert_nil vm.to_mem_stat
  end

  def test_started_vm_is_running
    vm = VMEmulator::VM.simple('a')
    vm.start
    assert vm.running?
  end

  def test_memory_usage_during_startup
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

  def test_still_running_right_after_shutdown
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

  def test_not_running_when_fully_shutdown
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

  def test_mem_usage_during_shutdown
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

  def test_increase_actual
    vm = VMEmulator::VM.simple('a')
    now = Time.now
    Timecop.freeze(now) do
      vm.start
    end
    Timecop.freeze(now + 10) do
      vm.memory_actual = 4 * 1024 * 1024 * 1024
      assert_equal 'actual 4G(rss=2.1G); guest: 1G/3.9G (25%) (unused=1.9G, disk_caches=1G)', vm.to_mem_stat.to_s
    end
  end

  def test_decrease_actual
    vm = VMEmulator::VM.simple('a')
    now = Time.now
    Timecop.freeze(now) do
      vm.start
    end
    Timecop.freeze(now + 10) do
      vm.memory_actual = 1 * 1024 * 1024 * 1024
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
end

class TestVMEmulator < Minitest::Test
  def test_new_empty
    assert VMEmulator.new.domain_data.empty?
    assert !VMEmulator.new.hostinfo.nil?
  end

  def test_smoke_virtcache
    VirtCache.new(VMEmulator.new)
  end

  def test_virtcache_with_some_vms
    e = VMEmulator.new
    e.add(VMEmulator::VM.simple('vm0')).start
    e.add(VMEmulator::VM.simple('vm1'))
    assert_equal 2, e.domain_data.size
    c = VirtCache.new(e)
    assert_equal %w[vm0 vm1], c.domains
  end

  def test_set_active_on_running_vm
    e = VMEmulator.new
    e.add(VMEmulator::VM.simple('vm0')).start
    e.set_actual 'vm0', 3 * 1024 * 1024 * 1024
    assert_equal 3 * 1024 * 1024 * 1024, e.vm('vm0').to_mem_stat.actual
  end
end
