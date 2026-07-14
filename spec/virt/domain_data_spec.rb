# frozen_string_literal: true

require_relative '../spec_helper'

describe Virt::DomainData do
  def info = Virt::DomainInfo.new('web', 4, 8.GiB)
  def mem = Virt::MemoryStat.new(8.GiB, 4.GiB, 8.GiB, 6.GiB, 1.GiB, 3.GiB, 1000)

  # info, state, sampled_at (ms), cpu_time (ms), mem_stat, disk_stat
  def running = Virt::DomainData.new(info, :running, 2000, 7000, mem, [])
  def stopped = Virt::DomainData.new(info, :shut_off, 2000, 0, nil, [])

  it 'running? reflects the state' do
    assert running.running?
    refute stopped.running?
  end

  it 'balloon? delegates to the guest memory stats' do
    assert running.balloon?
  end

  context 'cpu_usage' do
    it 'is per-core: 2000ms CPU over a 1000ms window on one snapshot pair is 200%' do
      older = Virt::DomainData.new(info, :running, 1000, 5000, mem, [])
      assert_equal 200.0, running.cpu_usage(older)
    end

    it 'is 0 when there is no earlier snapshot' do
      assert_equal 0.0, running.cpu_usage(nil)
    end

    it 'raises when the other snapshot is not actually older' do
      assert_raises(RuntimeError) { running.cpu_usage(running) }
    end
  end

  it 'millis_now returns an epoch-milliseconds Integer' do
    now = Virt::DomainData.millis_now
    assert_instance_of Integer, now
    assert now > 1_700_000_000_000, now # sometime after 2023
  end

  it 'to_s appends memory only when running' do
    assert_equal 'web: CPUs: 4, RAM: 8G; shut_off', stopped.to_s
    assert running.to_s.start_with?('web: CPUs: 4, RAM: 8G; running; actual 8G')
  end
end
