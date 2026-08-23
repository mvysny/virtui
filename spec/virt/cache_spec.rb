# frozen_string_literal: true

require_relative '../spec_helper'
require 'timecop'

# A transport for a Virsh with no guest agent behind it: real domstats, so the cache has
# VMs to sample, and an empty reply to everything else.
class NoAgentRunner
  def query(*args) = args.first == 'domstats' ? File.read('spec/virt/domstats0.txt') : ''
  def sync(*_args) = ''
  def async(*_args) = nil
end

# A VMEmulator that records the calls {Virt::Cache} makes on the VM-state edges, instead of
# no-op'ing them.
class RecordingEmulator < Virt::VMEmulator
  def period_calls = @period_calls ||= []
  def set_mem_stats_period(vmid, period_seconds) = period_calls << [vmid, period_seconds]
  def forget_calls = @forget_calls ||= []
  def forget_guest(name) = forget_calls << name
end

# A VMEmulator that declares win11 as Windows, and records what {Virt::Cache} asked about
# whom -- so the gate on the guest-agent read is observable.
class DeclaringEmulator < Virt::VMEmulator
  WINDOWS = Virt::GuestOS.from_osinfo_id('http://microsoft.com/win/11')

  def swap_asked = @swap_asked ||= []
  def os_asked = @os_asked ||= []

  def guest_swap(name)
    swap_asked << name
    super
  end

  def guest_os(name)
    os_asked << name
    name == 'win11' ? WINDOWS : super
  end
end

describe Virt::Cache do
  it 'smokes' do
    Virt::Cache.new(Virt::VMEmulator.new, System::Emulator.new)
  end

  context 'guest_os' do
    # Two running VMs, identical but for what they declare.
    def two_guests
      virt = DeclaringEmulator.new
      virt.add(Virt::VMEmulator::VM.simple('Ubuntu', actual: 8.GiB, max_actual: 16.GiB)).start
      virt.add(Virt::VMEmulator::VM.simple('win11', actual: 8.GiB, max_actual: 16.GiB)).start
      virt
    end

    it 'does not ask a non-Linux guest for a swap level' do
      virt = two_guests
      Virt::Cache.new(virt, System::Emulator.new)

      # Both are running; only the one declaring Linux is worth three agent RPCs.
      assert_includes virt.swap_asked, 'Ubuntu'
      refute_includes virt.swap_asked, 'win11'
    end

    it 'asks each domain once, however many ticks pass' do
      virt = two_guests
      start = Time.now
      cache = Timecop.freeze(start) { Virt::Cache.new(virt, System::Emulator.new) }
      # Each tick needs its own instant, or DomainData#cpu_usage refuses to diff.
      (1..3).each { |i| Timecop.freeze(start + (i * 2)) { cache.update } }

      assert_equal %w[Ubuntu win11], virt.os_asked.sort
    end

    it 'is carried on the cache entry, including for a stopped VM' do
      cache = Virt::Cache.new(Virt::VMEmulator.demo, System::Emulator.new)

      assert cache.cache('Ubuntu').guest_os.linux?
      # The whole reason the declaration beats asking the guest: Fedora is shut off.
      assert_equal :shut_off, cache.state('Fedora')
      assert cache.cache('Fedora').guest_os.linux?
    end
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

  context 'guest swap level' do
    it 'is sampled per running VM and carried on the entry' do
      Timecop.freeze(Time.now) do
        c = Virt::Cache.new(Virt::VMEmulator.demo, System::Emulator.new)
        assert_equal '0/4G (0%)', c.cache('Ubuntu').guest_swap.to_s
        # win11 simulates a guest that cannot report a level, BASE is shut off — neither is
        # a failure, and both must read as "no level" rather than as zero.
        assert_nil c.cache('win11').guest_swap
        assert_nil c.cache('BASE').guest_swap
      end
    end

    it 'is nil for every VM when the backend has no guest agent' do
      c = Virt::Cache.new(Virt::Virsh.new(runner: NoAgentRunner.new), System::Emulator.new)
      assert_equal %w[ubuntu win11], c.domains
      levels = c.domains.map { |it| c.cache(it).guest_swap }
      assert_equal [nil, nil], levels
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

  context 'forgetting a stopped guest' do
    it 'forgets every VM that is not running, so its next boot starts clean' do
      e = RecordingEmulator.new
      e.add(Virt::VMEmulator::VM.simple('Ubuntu', actual: 8.GiB, max_actual: 16.GiB))
      e.add(Virt::VMEmulator::VM.simple('BASE', actual: 8.GiB, max_actual: 8.GiB))
      e.vm('Ubuntu').start

      Timecop.freeze(Time.now) do
        cache = Virt::Cache.new(e, System::Emulator.new) # constructor runs update once
        assert_equal ['BASE'], e.forget_calls, 'the running VM must be sampled, not forgotten'

        e.vm('Ubuntu').force_off
        Timecop.travel(Time.now + 2)
        cache.update
        assert_equal %w[BASE Ubuntu BASE].sort, e.forget_calls.sort
      end
    end
  end
end
