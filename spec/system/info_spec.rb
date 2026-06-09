# frozen_string_literal: true

require_relative '../spec_helper'

describe System::Info do
  it 'should parse /proc/meminfo' do
    s = System::Info.new.memory_stats File.read('spec/system/proc_meminfo.txt')
    assert_equal 'RAM: 5.9G/58G (10%), SWAP: 0/8.0G (0%)', s.to_s
  end

  it 'should calculate usage percent' do
    usage = System::Info.new.cpu_usage(nil, File.read('spec/system/proc_stat0.txt'))
    assert_equal 0.0, usage.usage_percent
    usage = System::Info.new.cpu_usage(usage, File.read('spec/system/proc_stat1.txt'))
    assert_equal 4.09, usage.usage_percent
  end

  it 'calculates disk usage' do
    disk_stats = %w['sda', 'sda', 'vda', 'vda'].map do |it|
      ["/var/lib/libvirt/images/#{it}.qcow2", 32.GiB]
    end
    usage = System::Info.new.disk_usage(disk_stats, File.read('spec/system/df_p.txt'))
    assert_equal 1, usage.size
    assert_equal ['nvme0n1p6_crypt'], usage.keys
    assert_equal ['501G/633G (79%) (128G VMs)'], usage.values.map(&:to_s)
  end
end
