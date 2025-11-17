# frozen_string_literal: true

require 'minitest/autorun'
require 'ballooning'
require 'virt'
require 'virtcache'
require 'timecop'
require 'vm_emulator'

class TestBallooningVM < Minitest::Test
  def test_ballooning_does_nothing_on_stopped_machine
    virt = VMEmulator.new
    virt.allow_set_actual = false
    virt.add(VMEmulator::VM.simple('vm0'))
    virt_cache = VirtCache.new(virt)

    b = BallooningVM.new(virt_cache, 'vm0')
    b.update
    Timecop.freeze(Time.now + 200) do
      b.update
    end
  end

  def test_ballooning_memory_increase_in_backoff_period
    virt = VMEmulator.new
    virt.allow_set_actual = false
    vm = virt.add(VMEmulator::VM.simple('vm0'))
    vm.start
    virt_cache = VirtCache.new(virt)
    assert_equal 2 * 1024 * 1024 * 1024, vm.to_mem_stat.actual

    b = BallooningVM.new(virt_cache, 'vm0')
    b.update
    # should issue no update - the VM is just starting
    assert_equal 'only 0% memory used, but backing off for 20.0s; d=0', b.status.to_s

    virt.allow_set_actual = true
    Timecop.freeze(Time.now + 10) do
      # overshoot the used memory
      vm.memory_app = 4 * 1024 * 1024 * 1024
      virt_cache.update
      # ballooning should issue the memory_resize command immediately
      b.update

      assert_equal 'VM reports 1.9G (100%), updating actual by 30% to 2.6G; d=30', b.status.to_s
      assert_equal 2_791_728_742, vm.to_mem_stat.actual
    end
  end
end
