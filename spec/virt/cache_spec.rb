# frozen_string_literal: true

require_relative '../spec_helper'
require 'timecop'

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
    NOW_MILLIS = 1_762_378_459_933

    # @param last_updated [Integer] guest report time, epoch seconds
    def running_data(last_updated)
      info = Virt::DomainInfo.new('vm', 2, 8.GiB)
      mem = Virt::MemoryStat.new(8.GiB, 1.GiB, 8.GiB, 4.GiB, 0, 4.GiB, last_updated)
      Virt::DomainData.new(info, :running, NOW_MILLIS, 0, mem, [])
    end

    it 'is false when the guest just reported' do
      vc = Virt::Cache::VMCache.diff(nil, running_data(NOW_MILLIS / 1000))
      refute vc.stale?
    end

    it 'is false within the normal ~5s refresh lag' do
      vc = Virt::Cache::VMCache.diff(nil, running_data(NOW_MILLIS / 1000 - 6))
      refute vc.stale?
    end

    # Regression: with a frozen last-update (collection period unset), the old delta-based
    # age was always 0 between consecutive polls, so stale? never tripped and no 🐢 showed.
    it 'is true when last-update is frozen far in the past' do
      vc = Virt::Cache::VMCache.diff(nil, running_data(NOW_MILLIS / 1000 - 3600))
      assert vc.stale?
    end

    it 'is false (nil age) for a shut-off VM with no memory data' do
      data = Virt::DomainData.new(Virt::DomainInfo.new('vm', 2, 8.GiB), :shut_off, NOW_MILLIS, 0, nil, [])
      vc = Virt::Cache::VMCache.diff(nil, data)
      assert_nil vc.mem_data_age_seconds
      refute vc.stale?
    end
  end

  context 'arming guest mem-stat collection' do
    # A VMEmulator that records every set_mem_stats_period call instead of no-op'ing it.
    class RecordingEmulator < Virt::VMEmulator
      def period_calls = @period_calls ||= []
      def set_mem_stats_period(vmid, period_seconds) = period_calls << [vmid, period_seconds]
    end

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
