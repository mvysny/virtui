# frozen_string_literal: true

require_relative 'spec_helper'

describe SysInfo do
  it 'should parse /proc/meminfo' do
    s = SysInfo.new.memory_stats File.read('spec/proc_meminfo.txt')
    assert_equal 'RAM: 5.9G/58G (10%), SWAP: 0/8.0G (0%)', s.to_s
  end

  it 'should calculate usage percent' do
    usage = SysInfo.new.cpu_usage(nil, File.read('spec/proc_stat0.txt'))
    assert_equal 0.0, usage.usage_percent
    usage = SysInfo.new.cpu_usage(usage, File.read('spec/proc_stat1.txt'))
    assert_equal 4.09, usage.usage_percent
  end

  it 'calculates disk usage' do
    disk_stats = %w['sda', 'sda', 'vda', 'vda'].map do
      ["/var/lib/libvirt/images/#{it}.qcow2", 32.GiB]
    end
    usage = SysInfo.new.disk_usage(disk_stats, File.read('spec/df_p.txt'))
    assert_equal 1, usage.size
    assert_equal ['nvme0n1p6_crypt'], usage.keys
    assert_equal ['501G/633G (79%) (128G VMs)'], usage.values.map(&:to_s)
  end
end
