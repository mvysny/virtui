# frozen_string_literal: true

require_relative 'spec_helper'
require 'timecop'

describe Cooldown do
  it 'ELAPSED is over and stays over' do
    refute Cooldown::ELAPSED.active?
    assert_equal 0.0, Cooldown::ELAPSED.remaining
    Timecop.freeze(Time.now + 10_000) { refute Cooldown::ELAPSED.active? }
  end

  it 'is active until its deadline, and not after' do
    start = Time.now
    c = Timecop.freeze(start) { Cooldown.of(60) }
    Timecop.freeze(start) { assert c.active? }
    Timecop.freeze(start + 59.9) { assert c.active? }
    Timecop.freeze(start + 60) { refute c.active? }
  end

  it 'counts down, and floors at zero' do
    start = Time.now
    c = Timecop.freeze(start) { Cooldown.of(60) }
    Timecop.freeze(start + 20) { assert_equal 40.0, c.remaining }
    Timecop.freeze(start + 999) { assert_equal 0.0, c.remaining }
  end

  it 'extends an elapsed cooldown' do
    c = Cooldown::ELAPSED.extended_by(10)
    assert c.active?
    assert_equal 10.0, c.remaining.round(1)
  end

  it 'never shortens: a smaller extension leaves the longer one running' do
    start = Time.now
    long = Timecop.freeze(start) { Cooldown.of(60) }
    Timecop.freeze(start + 10) do
      assert_equal long, long.extended_by(5) # 15s < the 50s still to run
      assert_equal 50.0, long.extended_by(5).remaining
    end
  end

  it 'extends when the new deadline is further out' do
    start = Time.now
    short = Timecop.freeze(start) { Cooldown.of(10) }
    Timecop.freeze(start + 5) { assert_equal 60.0, short.extended_by(60).remaining }
  end

  it 'refuses a deadline that is not a Time' do
    err = assert_raises(RuntimeError) { Cooldown.new(60) }
    assert_equal 'deadline must be a Time but was 60', err.message
  end
end
