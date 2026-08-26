# frozen_string_literal: true

require_relative 'spec_helper'
require 'timecop'

describe Cooldown do
  it 'ELAPSED is over and stays over' do
    refute Cooldown::ELAPSED.active?
    assert_equal 0.0, Cooldown::ELAPSED.remaining
    Uptime.travel(10_000) { refute Cooldown::ELAPSED.active? }
  end

  it 'is active up to its deadline, and not past it' do
    c = Cooldown.of(60)
    assert c.active?
    Uptime.travel(59) { assert c.active? }
    Uptime.travel(60) { refute c.active? }
  end

  it 'counts down, and floors at zero' do
    c = Cooldown.of(60)
    Uptime.travel(20) { assert_equal 40.0, c.remaining.round(1) }
    Uptime.travel(999) { assert_equal 0.0, c.remaining }
  end

  it 'counts uptime, not wall time' do
    c = Cooldown.of(60)
    Timecop.freeze(Time.now + 3600) do
      assert c.active?, 'an hour of wall clock is not an hour of uptime'
      assert_equal 60.0, c.remaining.round(1)
    end
  end

  it 'extends an elapsed cooldown' do
    c = Cooldown::ELAPSED.extended_by(10)
    assert c.active?
    assert_equal 10.0, c.remaining.round(1)
  end

  it 'never shortens: a smaller extension leaves the longer one running' do
    long = Cooldown.of(60)
    Uptime.travel(10) do
      assert_equal long, long.extended_by(5) # 15s from now is less than the 50s still to run
      assert_equal 50.0, long.extended_by(5).remaining.round(1)
    end
  end

  it 'extends when the new deadline is further out' do
    short = Cooldown.of(10)
    Uptime.travel(5) { assert_equal 60.0, short.extended_by(60).remaining.round(1) }
  end

  it 'refuses a deadline that is not seconds — a Time being the likely mistake' do
    err = assert_raises(RuntimeError) { Cooldown.new(Time.now) }
    assert_includes err.message, 'deadline must be seconds on the uptime clock'
  end
end
