# frozen_string_literal: true

require_relative '../spec_helper'

VIRSH_NODEINFO = <<~EOF
  CPU model:           x86_64
  CPU(s):              16
  CPU frequency:       1397 MHz
  CPU socket(s):       1
  Core(s) per socket:  8
  Thread(s) per core:  2
  NUMA cell(s):        1
  Memory size:         29987652 KiB
EOF

describe Virt::Virsh do
  it 'hostinfo' do
    info = Virt::Virsh.new.hostinfo(VIRSH_NODEINFO)
    assert_equal 'x86_64: 1/8/2', info.to_s
  end

  it 'domain_data' do
    result = Virt::Virsh.new.domain_data(File.read('spec/virt/domstats0.txt'), 0)
    assert_equal 2, result.size
    assert_equal 'ubuntu: CPUs: 8, RAM: 12G; running; actual 12G(rss=3.4G); guest: 241M/11G (2%) (unused=11G, disk_caches=37M)',
                 result['ubuntu'].to_s
    assert_equal 'win11: CPUs: 4, RAM: 8G; shut_off', result['win11'].to_s
    assert_equal 'sda: 18G/128G (13%); physical 18G (2% overhead)', result['win11'].disk_stat.join(',')
    assert_equal 'vda: 23G/64G (36%); physical 25G (9% overhead)', result['ubuntu'].disk_stat.join(',')
  end

  it 'cpu usage' do
    millis_since_epoch = 1_762_378_459_933
    result0 = Virt::Virsh.new.domain_data(File.read('spec/virt/domstats0.txt'), millis_since_epoch)['ubuntu']
    result1 = Virt::Virsh.new.domain_data(File.read('spec/virt/domstats1.txt'), millis_since_epoch + 10 * 1000)['ubuntu']
    assert_equal 22.51, result1.cpu_usage(result0).round(2)
    result2 = Virt::Virsh.new.domain_data(File.read('spec/virt/domstats2.txt'), millis_since_epoch + 20 * 1000)['ubuntu']
    assert_equal 181.43, result2.cpu_usage(result1).round(2)
  end
end
