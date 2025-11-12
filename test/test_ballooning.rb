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
end
