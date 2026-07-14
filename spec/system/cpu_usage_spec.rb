# frozen_string_literal: true

require_relative '../spec_helper'

describe System::CpuUsage do
  it 'carries the busy percentage and the raw stat it was derived from' do
    stat = System::CpuStat.parse(File.read('spec/system/proc_stat0.txt'))
    usage = System::CpuUsage.new(12.5, stat)
    assert_equal 12.5, usage.usage_percent
    assert_same stat, usage.last_cpu_stat
  end
end
