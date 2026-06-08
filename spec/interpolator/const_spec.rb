# frozen_string_literal: true

require_relative '../spec_helper'

describe Interpolator::Const do
  it 'provides given value' do
    assert_equal 2, Interpolator::Const.new(2).value
    assert_equal 'q', Interpolator::Const.new('q').value
  end
end
