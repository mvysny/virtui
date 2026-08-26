# frozen_string_literal: true

require_relative '../../spec_helper'
require 'timecop'

describe Virt::BallooningVM::SwapOutShrinkVetoer do
  # Guest-report time (epoch seconds) of the first sample below.
  def now_secs = 1_762_378_459

  # One tick's cache entry for a VM whose guest reported `rate` bytes/s of swap-out in the
  # sample taken at `at`. Built directly rather than diffed, so a test names the rate it
  # means; {Virt::Cache::VMCache.swap_out_rate} has its own specs.
  #
  # @param rate [Float, nil] derived swap-out rate; `nil` as on a first sighting or a guest
  #   whose balloon reports no swap counters
  # @param at [Integer] guest-report time, epoch seconds — the sample's identity
  # @return [Virt::Cache::VMCache]
  def sample(rate, at: now_secs)
    info = Virt::DomainInfo.new('vm0', 1, 16.GiB)
    mem = Virt::MemoryStat.new(2.GiB, 1.GiB, 2.GiB, 1.GiB, 0, 0, 0, 2.GiB, at)
    data = Virt::DomainData.new(info, :running, at * 1000, 0, mem, [])
    Virt::Cache::VMCache.new(data, 0.0, 0, rate, nil, Virt::GuestOS::UNKNOWN)
  end

  def vetoer = Virt::BallooningVM::SwapOutShrinkVetoer.new

  it 'does not object to a guest at rest' do
    v = vetoer
    v.observe sample(0.0)
    assert_nil v.veto_reason
  end

  it 'does not object before it has seen anything' do
    assert_nil vetoer.veto_reason
  end

  it 'objects for 60s once a sample crosses the noise floor' do
    v = vetoer
    start = Time.now
    # Frozen across the observe, so the deadline is exactly start + 60 and the boundary
    # below is the real one rather than a sub-millisecond miss.
    Timecop.freeze(start) { v.observe sample(20.0 * 1.MiB) }
    Timecop.freeze(start) { assert_equal 'the guest swapped recently; holding its memory for 60.0s', v.veto_reason }
    Timecop.freeze(start + 59) { assert_equal 'the guest swapped recently; holding its memory for 1.0s', v.veto_reason }
    Timecop.freeze(start + 60) { assert_nil v.veto_reason }
  end

  it 'objects at exactly the noise floor, not below it' do
    below = vetoer
    below.observe sample(1.MiB - 1)
    assert_nil below.veto_reason

    at_floor = vetoer
    at_floor.observe sample(1.MiB)
    refute_nil at_floor.veto_reason
  end

  it 'ignores an unknown rate — first sighting, or a balloon reporting no swap counters' do
    v = vetoer
    v.observe sample(nil)
    assert_nil v.veto_reason
  end

  it 'ignores a nil cache entry' do
    v = vetoer
    v.observe nil
    assert_nil v.veto_reason
  end

  it 'arms once per guest sample, however many polls re-see it' do
    v = vetoer
    start = Time.now
    swapping = sample(20.0 * 1.MiB)
    v.observe swapping
    # libvirt refreshes balloon data every ~5s while we poll every ~2s: the next two polls
    # see the same sample and must not push the deadline out.
    Timecop.freeze(start + 2) { v.observe swapping }
    Timecop.freeze(start + 4) { v.observe swapping }
    Timecop.freeze(start + 61) { assert_nil v.veto_reason }
  end

  it 're-arms on a later swapping sample' do
    v = vetoer
    start = Time.now
    v.observe sample(20.0 * 1.MiB)
    Timecop.freeze(start + 30) { v.observe sample(20.0 * 1.MiB, at: now_secs + 30) }
    Timecop.freeze(start + 61) { refute_nil v.veto_reason } # would have lapsed on the first alone
    Timecop.freeze(start + 91) { assert_nil v.veto_reason }
  end

  it 'holds the veto through quiet samples — the point of the cooldown' do
    v = vetoer
    start = Time.now
    v.observe sample(20.0 * 1.MiB)
    Timecop.freeze(start + 30) do
      v.observe sample(0.0, at: now_secs + 30) # guest went quiet, working set still on disk
      refute_nil v.veto_reason
    end
  end

  it 'forgets everything for a VM we stop watching' do
    v = vetoer
    v.observe sample(20.0 * 1.MiB)
    refute_nil v.veto_reason
    v.forget
    assert_nil v.veto_reason
    # ...and the forgotten sample can arm it again, as it would after a reboot.
    v.observe sample(20.0 * 1.MiB)
    refute_nil v.veto_reason
  end
end
