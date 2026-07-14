# frozen_string_literal: true

require_relative '../spec_helper'

describe System::MemoryStat do
  it 'to_s' do
    ram = ResourceUsage.new(32.GiB, 16.GiB)
    swap = ResourceUsage.new(4.GiB, 4.GiB)
    assert_equal 'RAM: 16G/32G (50%), SWAP: 0/4G (0%)', System::MemoryStat.new(ram, swap).to_s
  end
end
