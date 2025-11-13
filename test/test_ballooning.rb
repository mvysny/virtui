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
    virt.allow_set_active = false
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
    vm = virt.add(VMEmulator::VM.simple('vm0'))
    vm.start
    virt_cache = VirtCache.new(virt)
    assert_equal 2 * 1024 * 1024 * 1024, vm.to_mem_stat.actual

    b = BallooningVM.new(virt_cache, 'vm0')
    b.update
    Timecop.freeze(Time.now + 10) do
      # overshoot the used memory
      vm.memory_apps = 4 * 1024 * 1024 * 1024
      # ballooning should issue the memory_resize command immediately
      b.update
      assert_equal 5, vm.to_mem_stat.actual
    end
  end
end
