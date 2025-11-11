# frozen_string_literal: true

require 'minitest/autorun'
require 'virt'

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

class TestVirt < Minitest::Test
  def initialize(arg)
    super(arg)
    @dummy_domain = Domain.new(DomainId.new(5, 'dummy'), :running)
  end

  def test_hostinfo
    info = VirtCmd.new.hostinfo(VIRSH_NODEINFO)
    assert_equal 'x86_64: 1/8/2', info.to_s
  end

  def test_domain_data_parse
    result = VirtCmd.new.domain_data(File.read('test/domstats0.txt'), 0)
    assert_equal 2, result.size
    assert_equal 'running, CPUs: 8, RAM: 12G; actual 12G(rss=3.4G); guest: 241M/11G (2%) (unused=11G, disk_caches=37M)',
                 result['ubuntu'].to_s
    assert_equal 'shut_off, CPUs: 4, RAM: 8G; actual 8G(rss=0)', result['win11'].to_s
    assert_equal 'sda: 18G/128G (13.99%); physical 18G (2.88% overhead)', result['win11'].disk_stat.join(',')
    assert_equal 'vda: 23G/64G (36.02%); physical 25G (9.31% overhead)', result['ubuntu'].disk_stat.join(',')
  end

  def test_domain_data_cpu_usage
    millis_since_epoch = 1_762_378_459_933
    result0 = VirtCmd.new.domain_data(File.read('test/domstats0.txt'), millis_since_epoch)['ubuntu']
    result1 = VirtCmd.new.domain_data(File.read('test/domstats1.txt'), millis_since_epoch + 10 * 1000)['ubuntu']
    assert_equal 22.51, result1.cpu_usage(result0).round(2)
    result2 = VirtCmd.new.domain_data(File.read('test/domstats2.txt'), millis_since_epoch + 20 * 1000)['ubuntu']
    assert_equal 181.43, result2.cpu_usage(result1).round(2)
  end
end

class TestDiskStat < Minitest::Test
  def test_to_s
    ds = DiskStat.new('vda', 20_348_669_952, 68_719_476_736, 20_452_605_952)
    assert_equal 'vda: 19G/64G (29.61%); physical 19G (0.51% overhead)', ds.to_s
    ds = DiskStat.new('sda', 18_022_993_920, 137_438_953_472, 23_508_287_488)
    assert_equal 'sda: 17G/128G (13.11%); physical 22G (30.43% overhead)', ds.to_s
  end
end

class TestVirtFakeClient < Minitest::Test
  def test_hostinfo_smoke
    assert_equal 'x86_fake: 1/8/2', FakeVirtClient.new.hostinfo.to_s
  end
end
