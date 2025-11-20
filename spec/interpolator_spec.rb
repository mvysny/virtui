# frozen_string_literal: true

require_relative 'spec_helper'
require 'interpolator'
require 'timecop'

describe Interpolator::Const do
  it 'provides given value' do
    assert_equal 2, Interpolator::Const.new(2).value
    assert_equal 'q', Interpolator::Const.new('q').value
  end
end

describe Interpolator::Linear do
  it 'provides limit value if time outside range' do
    assert_equal 2.0, Interpolator::Linear.new(2.0, 10.0, Time.now + 5, Time.now + 10).value
    assert_equal 10.0, Interpolator::Linear.new(2.0, 10.0, Time.now - 10, Time.now - 5).value
  end
  it 'provides linearly interpolated value' do
    now = Time.now
    # Fix `Time.now` during the duration of the test
    Timecop.freeze(now) do
      assert_equal 6.0, Interpolator::Linear.new(2.0, 10.0, now - 5, now + 5).value.round(2)
      assert_equal 12.0, Interpolator::Linear.new(10.0, 20.0, now - 2, now + 8).value.round(2)
      assert_equal 0.0, Interpolator::Linear.new(2.0, -2.0, now - 5, now + 5).value.round(2)
    end
  end
end
