# frozen_string_literal: true

require_relative '../../spec_helper'

describe Virt::BallooningVM::SwapOutRaiseVoter do
  # One tick's cache entry for a VM whose guest reported `rate` bytes/s of swap-out. Built
  # directly rather than diffed, so a test names the rate it means;
  # {Virt::Cache::VMCache.swap_out_rate} has its own specs.
  #
  # @param rate [Float, nil] derived swap-out rate; `nil` as on a first sighting or a guest
  #   whose balloon reports no swap counters
  # @return [Virt::Cache::VMCache]
  def sample(rate)
    info = Virt::DomainInfo.new('vm0', 1, 16.GiB)
    mem = Virt::MemoryStat.new(2.GiB, 1.GiB, 2.GiB, 1.GiB, 0, 0, 0, 2.GiB, 1_762_378_459)
    data = Virt::DomainData.new(info, :running, 1_762_378_459_000, 0, mem, [])
    Virt::Cache::VMCache.new(data, 0.0, 0, rate, nil, Virt::GuestOS::UNKNOWN)
  end

  def voter = Virt::BallooningVM::SwapOutRaiseVoter.new

  it 'does not vote before it has seen anything' do
    assert_nil voter.vote_reason
  end

  it 'does not vote for a guest at rest' do
    v = voter
    v.observe sample(0.0)
    assert_nil v.vote_reason
  end

  it 'votes while the guest is swapping, and says how fast' do
    v = voter
    v.observe sample(20.0 * 1.MiB)
    assert_equal 'the guest is swapping out 20M/s', v.vote_reason
  end

  it 'votes at exactly the noise floor, not below it' do
    below = voter
    below.observe sample(1.MiB - 1)
    assert_nil below.vote_reason

    at_floor = voter
    at_floor.observe sample(1.MiB)
    refute_nil at_floor.vote_reason
  end

  it 'stops voting the moment the guest stops — it holds no cooldown' do
    v = voter
    v.observe sample(20.0 * 1.MiB)
    refute_nil v.vote_reason
    v.observe sample(0.0)
    assert_nil v.vote_reason, 'a raise answers what the guest is doing now, not what it did'
  end

  it 'ignores an unknown rate — first sighting, or a balloon reporting no swap counters' do
    v = voter
    v.observe sample(nil)
    assert_nil v.vote_reason
  end

  it 'ignores a nil cache entry' do
    v = voter
    v.observe nil
    assert_nil v.vote_reason
  end

  it 'forgets what it saw for a VM we stop watching' do
    v = voter
    v.observe sample(20.0 * 1.MiB)
    v.forget
    assert_nil v.vote_reason
  end
end
