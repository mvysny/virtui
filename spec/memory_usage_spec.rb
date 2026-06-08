# frozen_string_literal: true

require_relative 'spec_helper'

describe MemoryUsage do
  it 'should produce good to_s' do
    assert_equal '0/0 (0%)', MemoryUsage.new(0, 0).to_s
    assert_equal '24/48 (50%)', MemoryUsage.new(48, 24).to_s
    assert_equal '228M/459M (49%)', MemoryUsage.new(481_231_286, 242_134_623).to_s
    assert_equal '2.2G/4.5G (49%)', MemoryUsage.new(4_812_312_860, 2_421_346_230).to_s
  end
end
