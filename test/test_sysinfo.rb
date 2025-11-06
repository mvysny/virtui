# frozen_string_literal: true

require 'minitest/autorun'
require 'sysinfo'

class TestMemoryUsage < Minitest::Test
  def test_to_s
    assert_equal '0/0 (0%)', MemoryUsage.new(0, 0).to_s
    assert_equal '24/48 (50%)', MemoryUsage.new(48, 24).to_s
    assert_equal '228 M/459 M (49%)', MemoryUsage.new(481_231_286, 242_134_623).to_s
    assert_equal '2.2 G/4.5 G (49%)', MemoryUsage.new(4_812_312_860, 2_421_346_230).to_s
  end
end

class TestSysInfo < Minitest::Test
  def test_memory_stats
    s = SysInfo.new.memory_stats PROC_MEMINFO
    assert_equal 'RAM: 5.9 G/58 G (10%), SWAP: 0/8.0 G (0%)', s.to_s
  end

  def test_cpu_usage
    usage = SysInfo.new.cpu_usage(nil, PROC_STAT0)
    assert_equal 0.0, usage.usage_percent
    usage = SysInfo.new.cpu_usage(usage, PROC_STAT1)
    assert_equal 4.09, usage.usage_percent
  end
end

class TestCpuStat < Minitest::Test
  def test_parse
    s = CpuStat.parse(PROC_STAT0)
    assert_equal 'cpu: user=3222 nice=76 system=2433 idle=78684 iowait=416 irq=0 softirq=15 steal=26 guest=0 guest_nice=0',
                 s.to_s
    s = CpuStat.parse(PROC_STAT1)
    assert_equal 'cpu: user=3394 nice=76 system=2673 idle=88408 iowait=420 irq=0 softirq=17 steal=27 guest=0 guest_nice=0',
                 s.to_s
  end
end

PROC_MEMINFO = <<~EOF
  MemTotal:       60432620 kB
  MemFree:        34851344 kB
  MemAvailable:   54292748 kB
  Buffers:           18852 kB
  Cached:         19671048 kB
  SwapCached:            0 kB
  Active:          7395780 kB
  Inactive:       16769528 kB
  Active(anon):    4268016 kB
  Inactive(anon):        0 kB
  Active(file):    3127764 kB
  Inactive(file): 16769528 kB
  Unevictable:       17916 kB
  Mlocked:           17916 kB
  SwapTotal:       8388604 kB
  SwapFree:        8388604 kB
  Zswap:                 0 kB
  Zswapped:              0 kB
  Dirty:              3364 kB
  Writeback:           148 kB
  AnonPages:       4494000 kB
  Mapped:          1524448 kB
  Shmem:            320344 kB
  KReclaimable:     213328 kB
  Slab:             651168 kB
  SReclaimable:     213328 kB
  SUnreclaim:       437840 kB
  KernelStack:       30512 kB
  PageTables:        63836 kB
  SecPageTables:      4332 kB
  NFS_Unstable:          0 kB
  Bounce:                0 kB
  WritebackTmp:          0 kB
  CommitLimit:    38604912 kB
  Committed_AS:   16070836 kB
  VmallocTotal:   34359738367 kB
  VmallocUsed:      118656 kB
  VmallocChunk:          0 kB
  Percpu:            23104 kB
  HardwareCorrupted:     0 kB
  AnonHugePages:         0 kB
  ShmemHugePages:        0 kB
  ShmemPmdMapped:        0 kB
  FileHugePages:         0 kB
  FilePmdMapped:         0 kB
  CmaTotal:              0 kB
  CmaFree:               0 kB
  Unaccepted:            0 kB
  Balloon:               0 kB
  HugePages_Total:       0
  HugePages_Free:        0
  HugePages_Rsvd:        0
  HugePages_Surp:        0
  Hugepagesize:       2048 kB
  Hugetlb:               0 kB
  DirectMap4k:      598804 kB
  DirectMap2M:    20146176 kB
  DirectMap1G:    42991616 kB
EOF

PROC_STAT0 = <<~EOF
  cpu  3222 76 2433 78684 416 0 15 26 0 0
  cpu0 243 2 249 10033 61 0 5 9 0 0
  cpu1 413 1 326 9757 106 0 3 2 0 0
  cpu2 323 0 264 9995 32 0 1 2 0 0
  cpu3 462 64 280 9778 38 0 0 1 0 0
  cpu4 511 0 395 9619 63 0 1 2 0 0
  cpu5 390 2 365 9805 42 0 0 2 0 0
  cpu6 586 4 230 9774 32 0 0 2 0 0
  cpu7 291 0 320 9919 39 0 1 2 0 0
  intr 395784 0 844 0 0 0 0 0 0 0 0 0 0 144 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 21 0 278 0 2998 5249 2554 3090 2766 2839 1845 2500 0 178 161 79 0 0 0 0 0 0 0 0 0 13 0 1 10171 246 0 0 169 524 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  ctxt 423286
  btime 1762346711
  processes 3984
  procs_running 1
  procs_blocked 0
  softirq 129964 52 16726 8 475 6684 0 797 31481 0 73741
EOF

PROC_STAT1 = <<~EOF
  cpu  3394 76 2673 88408 420 0 17 27 0 0
  cpu0 258 2 278 11251 62 0 7 9 0 0
  cpu1 436 1 361 10961 107 0 3 2 0 0
  cpu2 344 0 314 11192 32 0 1 2 0 0
  cpu3 489 64 298 11007 38 0 1 1 0 0
  cpu4 536 0 426 10839 63 0 1 3 0 0
  cpu5 411 2 388 11032 43 0 0 2 0 0
  cpu6 615 4 268 10961 32 0 0 2 0 0
  cpu7 301 0 336 11162 39 0 1 2 0 0
  intr 438014 0 894 0 0 0 0 0 0 0 0 0 0 144 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 23 0 479 0 3022 5277 2573 3092 2766 2847 1855 2501 0 185 161 79 0 0 0 0 0 0 0 0 0 13 0 1 11323 428 0 0 169 524 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  ctxt 1040440
  btime 1762346711
  processes 4075
  procs_running 3
  procs_blocked 0
  softirq 138289 52 18209 8 482 6684 0 845 35257 0 76752
EOF
