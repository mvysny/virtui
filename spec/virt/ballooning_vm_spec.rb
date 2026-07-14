# frozen_string_literal: true

require_relative '../spec_helper'
require 'timecop'

# Serves BallooningVM#update exactly the fields it reads for one running VM ('vm0') and
# records every set_actual call in {#set_actuals}, so a test can assert both the decision
# (status) and whether memory was actually resized. Guest data is fresh (age 0) unless an
# explicit stale `data` snapshot is passed.
class BallooningFakeCache
  # @return [Array<Integer>] the `actual` sizes passed to set_actual, in call order
  attr_reader :set_actuals

  # @param mem [Virt::MemoryStat] the VM's guest/host memory stats
  # @param info [Virt::DomainInfo] the VM's static config (drives max_memory)
  # @param data [Virt::DomainData, nil] snapshot for the staleness check; defaults to a
  #   fresh one built from `mem`
  def initialize(mem:, info:, data: nil)
    @mem = mem
    @info = info
    @data = data || Virt::DomainData.new(info, :running, mem.last_updated * 1000, 0, mem, [])
    @set_actuals = []
  end

  def memstat(_vmid) = @mem
  def running?(_vmid) = true
  def info(_vmid) = @info
  def cache(_vmid) = Virt::Cache::VMCache.diff(nil, @data)
  def set_actual(_vmid, actual) = @set_actuals << actual
end

describe Virt::BallooningVM do
  # Guest-report time (epoch seconds) shared by the crafted stats below.
  def now_secs = 1_762_378_459

  # A fresh, ballooning-capable MemoryStat whose guest reports exactly `percent`% used.
  # `actual` (and the VM's configured max) drive the resize math; guest `available` is
  # `actual` minus the 128 MiB the BIOS/kernel reserve.
  #
  # @param percent [Integer] guest usage to report, 1..99
  # @param actual [Integer] the VM's currently-configured memory, in bytes
  # @return [Virt::MemoryStat]
  def mem_at(percent, actual: 2.GiB)
    available = actual - 128.MiB
    used = ((available * percent) + 99) / 100 # ceil, so percent_used == percent exactly
    usable = available - used
    Virt::MemoryStat.new(actual, usable, available, usable, 0, actual, now_secs)
  end

  # A BallooningVM over a fake cache holding `mem` for 'vm0'. `min_actual` defaults low so
  # the resize math isn't clamped; raise it to test clamping. Returns the cache too, so the
  # test can inspect {BallooningFakeCache#set_actuals}.
  #
  # @return [Array(BallooningFakeCache, Virt::BallooningVM)]
  def ballooner(mem, info: Virt::DomainInfo.new('vm0', 1, 16.GiB), min_actual: 128.MiB)
    cache = BallooningFakeCache.new(mem: mem, info: info)
    b = Virt::BallooningVM.new(cache, 'vm0')
    b.min_actual = min_actual
    [cache, b]
  end

  it 'does nothing to a stopped VM' do
    virt = Virt::VMEmulator.new
    virt.add(Virt::VMEmulator::VM.simple('vm0'))
    virt_cache = Virt::Cache.new(virt, System::Emulator.new)

    b = Virt::BallooningVM.new(virt_cache, 'vm0')
    b.update
    assert_equal 'vm stopped, doing nothing; d=0', b.status.to_s
    Timecop.freeze(Time.now + 200) { b.update }
    assert_equal 'vm stopped, doing nothing; d=0', b.status.to_s
  end

  it 'does nothing when the user has disabled ballooning' do
    cache, b = ballooner(mem_at(90)) # 90% would otherwise force an increase
    b.enabled = false
    b.update
    assert_equal 'ballooning disabled by user; d=0', b.status.to_s
    assert_equal [], cache.set_actuals
  end

  it 'does nothing when the VM lacks ballooning support' do
    mem = Virt::MemoryStat.new(2.GiB, nil, nil, nil, nil, 2.GiB, now_secs)
    cache, b = ballooner(mem)
    b.update
    assert_equal 'ballooning unsupported by the VM; d=0', b.status.to_s
    assert_equal [], cache.set_actuals
  end

  it 'does not act on stale guest data, even at high usage' do
    now_ms = 1_762_378_459_933
    info = Virt::DomainInfo.new('vm0', 2, 16.GiB)
    # 7G of 8G used (87%) would normally trigger an increase, but last-update is an hour old.
    mem = Virt::MemoryStat.new(8.GiB, 0, 8.GiB, 1.GiB, 0, 4.GiB, (now_ms / 1000) - 3600)
    data = Virt::DomainData.new(info, :running, now_ms, 0, mem, [])
    cache = BallooningFakeCache.new(mem: mem, info: info, data: data)

    b = Virt::BallooningVM.new(cache, 'vm0')
    b.update
    assert_equal 'guest memory data is stale, doing nothing; d=0', b.status.to_s
    assert_equal [], cache.set_actuals
  end

  context 'increasing memory (usage rises to the trigger)' do
    it 'increases by 30% at exactly the 65% trigger' do
      cache, b = ballooner(mem_at(65))
      b.update
      assert_equal 'VM reports 1.2G (65%), updating actual by 30% to 2.6G; d=30', b.status.to_s
      assert_equal [2_791_728_742], cache.set_actuals
    end

    it 'leaves memory alone just below the trigger (64%)' do
      cache, b = ballooner(mem_at(64))
      b.update
      assert_equal 'app memory in sweet spot (64%), doing nothing; d=0', b.status.to_s
      assert_equal [], cache.set_actuals
    end

    it 'increases immediately even while backing off' do
      virt = Virt::VMEmulator.new
      virt.allow_set_actual = false
      vm = virt.add(Virt::VMEmulator::VM.simple('vm0'))
      vm.start
      virt_cache = Virt::Cache.new(virt, System::Emulator.new)
      assert_equal 2.GiB, vm.to_mem_stat.actual

      b = Virt::BallooningVM.new(virt_cache, 'vm0')
      b.min_actual = 2.GiB
      b.update
      # should issue no update - the VM is just starting
      assert_equal 'only 0% memory used, but backing off for 20.0s; d=0', b.status.to_s

      virt.allow_set_actual = true
      Timecop.freeze(Time.now + 10) do
        # overshoot the used memory
        vm.memory_app = 4.GiB
        virt_cache.update
        # ballooning should issue the memory_resize command immediately
        b.update

        assert_equal 'VM reports 1.9G (100%), updating actual by 30% to 2.6G; d=30', b.status.to_s
        assert_equal 2_791_728_742, vm.to_mem_stat.actual
      end
    end

    it 'refuses to grow past the VM configured maximum' do
      cache, b = ballooner(mem_at(70, actual: 8.GiB), info: Virt::DomainInfo.new('vm0', 1, 8.GiB))
      b.update
      assert_equal 'I want to increase memory (current usage of 70% is over trigger 65%) ' \
                   "but can't go over configured max mem 8G; d=0", b.status.to_s
      assert_equal [], cache.set_actuals
    end

    it 'does nothing when min_actual exceeds the VM maximum' do
      cache, b = ballooner(mem_at(70), info: Virt::DomainInfo.new('vm0', 1, 4.GiB), min_actual: 8.GiB)
      b.update
      assert_equal 'VM max memory 4294967296 is below min_actual 8589934592, doing nothing; d=0', b.status.to_s
      assert_equal [], cache.set_actuals
    end
  end

  context 'sweet spot (between the decrease and increase triggers)' do
    it 'does nothing at 60% usage' do
      cache, b = ballooner(mem_at(60))
      b.update
      assert_equal 'app memory in sweet spot (60%), doing nothing; d=0', b.status.to_s
      assert_equal [], cache.set_actuals
    end

    it 'does nothing just above the decrease trigger (56%)' do
      cache, b = ballooner(mem_at(56))
      b.update
      assert_equal 'app memory in sweet spot (56%), doing nothing; d=0', b.status.to_s
      assert_equal [], cache.set_actuals
    end
  end

  context 'decreasing memory (usage falls to the trigger)' do
    it 'decreases by 10% at exactly the 55% trigger, once past back-off' do
      cache, b = ballooner(mem_at(55))
      Timecop.freeze(Time.now + 21) { b.update } # past the 20s boot back-off
      assert_equal 'VM reports 1.0G (55%), updating actual by -10% to 1.8G; d=-10', b.status.to_s
      assert_equal [1_932_735_283], cache.set_actuals
    end

    it 'holds off decreasing while backing off' do
      cache, b = ballooner(mem_at(40))
      b.update # still inside the boot back-off
      assert_equal 0, b.status.memory_delta
      assert b.status.to_s.include?('backing off'), b.status.to_s
      assert_equal [], cache.set_actuals
    end

    it 'enabled= clears back-off so a decrease acts immediately' do
      cache, b = ballooner(mem_at(40))
      b.update
      assert_equal 0, b.status.memory_delta # blocked by back-off
      b.enabled = true                      # user re-affirms; clears back-off
      b.update
      assert_equal(-10, b.status.memory_delta)
      assert_equal 1, cache.set_actuals.size
    end

    it 'does nothing when the decrease would clamp back to the current size' do
      cache, b = ballooner(mem_at(40), min_actual: 2.GiB) # floor == current actual
      Timecop.freeze(Time.now + 21) { b.update }
      assert_equal 'New actual 2G is the same as current one 2G, doing nothing; d=0', b.status.to_s
      assert_equal [], cache.set_actuals
    end
  end

  it 'skips a second update on the same guest data' do
    cache, b = ballooner(mem_at(65))
    b.update # acts on this snapshot
    assert_equal 30, b.status.memory_delta
    b.update # same last_updated -> nothing new to decide on
    assert_equal 'no new data; d=0', b.status.to_s
    assert_equal 1, cache.set_actuals.size
  end
end
