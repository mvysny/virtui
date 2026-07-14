# frozen_string_literal: true

require_relative '../spec_helper'

describe Virt::CpuInfo do
  it 'derives the total logical CPU count' do
    assert_equal 16, Virt::CpuInfo.new('x86_64', 1, 8, 2).cpus
  end

  it 'to_s' do
    assert_equal 'x86_64: 1/8/2', Virt::CpuInfo.new('x86_64', 1, 8, 2).to_s
  end
end
