# frozen_string_literal: true

require_relative '../../spec_helper'

describe Virt::BallooningVM::MemLevelRaiseVoter do
  # One tick's cache entry for a VM whose guest reports exactly `percent`% used.
  #
  # @param percent [Integer, nil] usage to report; `nil` for a VM whose balloon carries no
  #   guest data at all
  # @return [Virt::Cache::VMCache]
  def sample(percent)
    info = Virt::DomainInfo.new('vm0', 1, 16.GiB)
    mem = if percent.nil?
            Virt::MemoryStat.new(2.GiB, nil, nil, nil, nil, nil, nil, 2.GiB, 1_762_378_459)
          else
            total = 2.GiB
            used = ((total * percent) + 99) / 100 # ceil, so percent_used == percent exactly
            Virt::MemoryStat.new(2.GiB, total - used, total, total - used, 0, 0, 0, 2.GiB, 1_762_378_459)
          end
    Virt::Cache::VMCache.new(Virt::DomainData.new(info, :running, 1_762_378_459_000, 0, mem, []),
                             0.0, 0, nil, nil, Virt::GuestOS::UNKNOWN)
  end

  def voter = Virt::BallooningVM::MemLevelRaiseVoter.new

  it 'does not vote before it has seen anything' do
    assert_nil voter.vote_reason
  end

  it 'votes at exactly the trigger' do
    v = voter
    v.observe sample(65)
    assert_equal 'usage is at or over the 65% trigger', v.vote_reason
  end

  it 'stays silent one point below it' do
    v = voter
    v.observe sample(64)
    assert_nil v.vote_reason
  end

  it 'votes for a guest that is full' do
    v = voter
    v.observe sample(100)
    refute_nil v.vote_reason
  end

  it 'stays silent for a VM whose balloon reports no guest data' do
    v = voter
    v.observe sample(nil)
    assert_nil v.vote_reason
  end

  it 'stays silent for a nil cache entry' do
    v = voter
    v.observe nil
    assert_nil v.vote_reason
  end

  it 'forgets what it saw for a VM we stop watching' do
    v = voter
    v.observe sample(80)
    v.forget
    assert_nil v.vote_reason
  end
end
