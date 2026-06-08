# frozen_string_literal: true

require_relative '../spec_helper'

describe System::CpuStat do
  it 'should parse /proc/stat' do
    s = System::CpuStat.parse(File.read('spec/system/proc_stat0.txt'))
    assert_equal 'cpu: user=3222 nice=76 system=2433 idle=78684 iowait=416 irq=0 softirq=15 steal=26 guest=0 guest_nice=0',
                 s.to_s
    s = System::CpuStat.parse(File.read('spec/system/proc_stat1.txt'))
    assert_equal 'cpu: user=3394 nice=76 system=2673 idle=88408 iowait=420 irq=0 softirq=17 steal=27 guest=0 guest_nice=0',
                 s.to_s
  end
end
