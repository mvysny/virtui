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

  it 'disk_usage puts every file on one simulated disk' do
    disks = emu.disk_usage([['/a.qcow2', 1.GiB], ['/b.qcow2', 2.GiB]])
    assert_equal ['nvme0n1'], disks.keys
    assert_equal '624G/1T (60%) (3G VMs)', disks['nvme0n1'].to_s
    assert_equal ['/a.qcow2', '/b.qcow2'], disks['nvme0n1'].qcow2_files
  end

  it 'disk_usage is empty without files' do
    assert_equal({}, emu.disk_usage([]))
  end

  it 'cpu_flags reports fixed virtualization flags' do
    assert_equal %w[svm npt pdpe1gb].to_set, emu.cpu_flags
  end
end
