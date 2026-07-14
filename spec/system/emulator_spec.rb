# frozen_string_literal: true

require_relative '../spec_helper'

describe System::Emulator do
  let(:emu) { System::Emulator.new }

  it 'memory_stats reports fixed 32G RAM (half used) and 4G swap (free)' do
    assert_equal 'RAM: 16G/32G (50%), SWAP: 0/4G (0%)', emu.memory_stats.to_s
  end

  it 'cpu_usage is always 0%, ignoring the previous sample' do
    usage = emu.cpu_usage(nil)
    assert_equal 0.0, usage.usage_percent
    assert_nil usage.last_cpu_stat
  end

  it 'disk_usage is always empty' do
    assert_equal({}, emu.disk_usage([['/a.qcow2', 1.GiB]]))
  end

  it 'cpu_flags reports fixed virtualization flags' do
    assert_equal %w[svm npt pdpe1gb].to_set, emu.cpu_flags
  end
end
