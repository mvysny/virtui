# frozen_string_literal: true

require_relative '../../spec_helper'

describe Virt::BallooningVM::BackOffShrinkVetoer do
  def vetoer = Virt::BallooningVM::BackOffShrinkVetoer.new

  it 'does not object until it is armed' do
    v = vetoer
    v.observe nil
    assert_nil v.veto_reason
  end

  it 'objects for as long as it was armed for, and says how much is left' do
    v = vetoer
    v.arm 10
    assert_equal 'backing off for 10.0s', v.veto_reason
    Uptime.travel(9) { assert_equal 'backing off for 1.0s', v.veto_reason }
    Uptime.travel(10) { assert_nil v.veto_reason }
  end

  it 'extends an active back-off but never cuts one short' do
    v = vetoer
    v.arm 60
    Uptime.travel(10) do
      v.arm 5 # 5s from now is less than the 50s still to run
      assert_equal 'backing off for 50.0s', v.veto_reason
      v.arm 90
      assert_equal 'backing off for 90.0s', v.veto_reason
    end
  end

  it 'ignores the guest entirely — it remembers our own actions, not the VM' do
    v = vetoer
    v.arm 10
    v.observe nil
    refute_nil v.veto_reason, 'observing must not disturb the back-off'
  end

  it 'is dropped when the user asks for their change to take effect now' do
    v = vetoer
    v.arm 60
    v.forget
    assert_nil v.veto_reason
  end
end
