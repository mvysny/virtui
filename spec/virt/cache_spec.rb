# frozen_string_literal: true

require_relative '../spec_helper'
require 'timecop'

# A VMEmulator that records every set_mem_stats_period call instead of no-op'ing it.
class RecordingEmulator < Virt::VMEmulator
  def period_calls = @period_calls ||= []
  def set_mem_stats_period(vmid, period_seconds) = period_calls << [vmid, period_seconds]
end

describe Virt::Cache do
  it 'smokes' do
    Virt::Cache.new(Virt::VMEmulator.new, System::Emulator.new)
  end

  context 'total_vm_rss_usage' do
    it 'is 0 for no VMs' do
      assert_equal 0, Virt::Cache.new(Virt::VMEmulator.new, System::Emulator.new).total_vm_rss_usage
    end

    it 'is calculated properly' do
      Timecop.freeze(Time.now) do
        assert_equal 2_415_919_104, Virt::Cache.new(Virt::VMEmulator.demo, System::Emulator.new).total_vm_rss_usage
      end
    end
  end

  context 'running?' do
    it 'works on demo data' do
      c = Virt::Cache.new(Virt::VMEmulator.demo, System::Emulator.new)
      assert c.running?('Ubuntu')
      assert c.running?('win11')
      assert !c.running?('BASE')
      assert !c.running?('non-existing-cm')
    end
  end

  context 'VMCache#stale?' do
    # Reference sample time (millis since epoch) for the crafted snapshots below.
    def now_millis = 1_762_378_459_933

    # @param last_updated [Integer] guest report time, epoch seconds
    def running_data(last_updated)
      info = Virt::DomainInfo.new('vm', 2, 8.GiB)
      mem = Virt::MemoryStat.new(8.GiB, 1.GiB, 8.GiB, 4.GiB, 0, 0, 0, 4.GiB, last_updated)
      Virt::DomainData.new(info, :running, now_millis, 0, mem, [])
    end

    it 'is false when the guest just reported' do
      vc = Virt::Cache::VMCache.diff(nil, running_data(now_millis / 1000))
      refute vc.stale?
    end

    it 'is false within the normal ~5s refresh lag' do
      vc = Virt::Cache::VMCache.diff(nil, running_data((now_millis / 1000) - 6))
      refute vc.stale?
    end

    # Regression: with a frozen last-update (collection period unset), the old delta-based
    # age was always 0 between consecutive polls, so stale? never tripped and no 🐢 showed.
    it 'is true when last-update is frozen far in the past' do
      vc = Virt::Cache::VMCache.diff(nil, running_data((now_millis / 1000) - 3600))
      assert vc.stale?
    end

    it 'is false (nil age) for a shut-off VM with no memory data' do
      data = Virt::DomainData.new(Virt::DomainInfo.new('vm', 2, 8.GiB), :shut_off, now_millis, 0, nil, [])
      vc = Virt::Cache::VMCache.diff(nil, data)
      assert_nil vc.mem_data_age_seconds
      refute vc.stale?
    end
  end

  context 'VMCache#swap_out_rate' do
    def now_millis = 1_762_378_459_933

    # @param swap_out [Integer, nil] the guest's cumulative swap-out counter, in bytes
    # @param last_updated [Integer] guest report time, epoch seconds
    # @param poll [Integer] which poll this is; our own polls advance even when the guest's
    #   `last_updated` doesn't, which is the normal case
    def data(swap_out, last_updated, poll)
      info = Virt::DomainInfo.new('vm', 2, 8.GiB)
      mem = Virt::MemoryStat.new(8.GiB, 1.GiB, 8.GiB, 4.GiB, 0, 0, swap_out, 4.GiB, last_updated)
      Virt::DomainData.new(info, :running, now_millis + (poll * 2000), 0, mem, [])
    end

    # Chains snapshots through diff the way Cache#update does, and returns the last entry.
    # @param samples [Array<Array(Integer, Integer)>] `[swap_out, last_updated]` pairs
    def rate_after(*samples)
      samples.each_with_index
             .reduce(nil) { |prev, ((out, at), i)| Virt::Cache::VMCache.diff(prev, data(out, at, i)) }
             .swap_out_rate
    end

    it 'is nil on the first sample — a counter needs two reads' do
      assert_nil rate_after([0, 1000])
    end

    it 'is the counter delta over the guest-reported interval' do
      assert_equal 2.MiB, rate_after([0, 1000], [10.MiB, 1005]) # 10 MiB over 5s
    end

    it 'is 0.0 for a guest that is not swapping' do
      assert_equal 0.0, rate_after([5.MiB, 1000], [5.MiB, 1005])
    end

    # libvirt refreshes balloon data only every ~5s while we poll every ~2s, so most polls
    # see an unchanged sample. Reporting 0 there would blink the rate off every other poll.
    it 'carries the last rate forward while the guest sample is unchanged' do
      assert_equal 2.MiB, rate_after([0, 1000], [10.MiB, 1005], [10.MiB, 1005])
    end

    it 'reads a counter reset as a guest reboot, not as negative swapping' do
      assert_equal 0.0, rate_after([0, 1000], [10.MiB, 1005], [0, 1010])
    end

    it 'is nil when the guest does not report swap counters' do
      assert_nil rate_after([nil, 1000], [nil, 1005])
    end

    it 'is nil for a shut-off VM with no memory data' do
      stopped = Virt::DomainData.new(Virt::DomainInfo.new('vm', 2, 8.GiB), :shut_off, now_millis + 2000, 0, nil, [])
      vc = Virt::Cache::VMCache.diff(Virt::Cache::VMCache.diff(nil, data(0, 1000, 0)), stopped)
      assert_nil vc.swap_out_rate
    end
  end

  context 'arming guest mem-stat collection' do
    it 'arms a running VM once, on the not-running -> running transition' do
      e = RecordingEmulator.new
      e.add(Virt::VMEmulator::VM.simple('Ubuntu', actual: 8.GiB, max_actual: 16.GiB))
      e.add(Virt::VMEmulator::VM.simple('BASE', actual: 8.GiB, max_actual: 8.GiB))
      e.vm('Ubuntu').start

      Timecop.freeze(Time.now) do
        cache = Virt::Cache.new(e, System::Emulator.new) # constructor runs update once
        assert_equal [['Ubuntu', Virt::Cache::STATS_PERIOD_SECONDS]], e.period_calls

        Timecop.travel(Time.now + 2) # next poll, 2s later
        cache.update # already-running VM must not be re-armed
        assert_equal [['Ubuntu', Virt::Cache::STATS_PERIOD_SECONDS]], e.period_calls

        e.vm('BASE').start
        Timecop.travel(Time.now + 2)
        cache.update # newly-started VM gets armed
        assert_equal [['Ubuntu', Virt::Cache::STATS_PERIOD_SECONDS], ['BASE', Virt::Cache::STATS_PERIOD_SECONDS]],
                     e.period_calls
      end
    end
  end
end
