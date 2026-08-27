# frozen_string_literal: true

require_relative '../spec_helper'

# A {Virt::GuestAgent} stand-in that answers every domain the same way and counts the
# samples it was asked for. `reply` is writable so a test can heal a guest mid-run.
class ScriptedGuestAgent
  attr_reader :domains
  attr_accessor :reply

  # @param reply [ResourceUsage, StandardError] what {#swap} answers with, or raises
  def initialize(reply)
    @reply = reply
    @domains = []
  end

  # @param domain [String] VM name
  # @return [ResourceUsage] the scripted level
  def swap(domain)
    @domains << domain
    raise @reply if @reply.is_a?(StandardError)

    @reply
  end
end

# A healthy sample: 3 GiB of the guest's 4 GiB swap device occupied.
LEVEL = ResourceUsage.new(4.GiB, 1.GiB)
# The failure a healthy host produces on its own: a guest whose agent is not up.
MUTE = Virt::GuestAgent::Unavailable.new('error: QEMU guest agent is not connected')
# One nobody foresaw — an agent replying with something it does not document.
BROKEN = RuntimeError.new('win11: guest-file-read gave no buf-b64: {"count" => 0}')

describe Virt::GuestSwapSampler do
  before { @log = Helpers.setup_dummy_logger }

  # @param reply [ResourceUsage, StandardError] what the agent under the sampler answers
  # @param backoff_seconds [Integer] how long a write-off lasts
  # @return [Array(Virt::GuestSwapSampler, ScriptedGuestAgent)] the sampler and its agent
  def sampler_over(reply, backoff_seconds: Virt::GuestSwapSampler::BACKOFF_SECONDS)
    agent = ScriptedGuestAgent.new(reply)
    [Virt::GuestSwapSampler.new(agent: agent, backoff_seconds: backoff_seconds), agent]
  end

  it 'passes a good sample straight through' do
    sampler, agent = sampler_over(LEVEL)
    assert_equal LEVEL, sampler.swap('Ubuntu')
    assert_equal ['Ubuntu'], agent.domains
  end

  it 'stops asking a guest that cannot answer, and says so once' do
    sampler, agent = sampler_over(MUTE)
    5.times { assert_nil sampler.swap('win11') }

    assert_equal Virt::GuestSwapSampler::FAILURES_BEFORE_BACKOFF, agent.domains.size
    assert_equal 1, @log.string.scan('not asking again').size
  end

  it 'tries again once the write-off lapses' do
    sampler, agent = sampler_over(MUTE, backoff_seconds: 0)
    3.times { sampler.swap('win11') }
    assert_equal 3, agent.domains.size

    assert_nil sampler.swap('win11')
    assert_equal 4, agent.domains.size, 'a lapsed write-off must let the next poll through'
  end

  it 'waits out the shipped BACKOFF_SECONDS, not merely some write-off' do
    sampler, agent = sampler_over(MUTE) # the real 60s, not a spec's 0
    Virt::GuestSwapSampler::FAILURES_BEFORE_BACKOFF.times { sampler.swap('win11') }
    written_off_at = agent.domains.size

    Uptime.travel(Virt::GuestSwapSampler::BACKOFF_SECONDS - 1) { assert_nil sampler.swap('win11') }
    assert_equal written_off_at, agent.domains.size, 'a second before the write-off lapses, still not asked'

    Uptime.travel(Virt::GuestSwapSampler::BACKOFF_SECONDS) { assert_nil sampler.swap('win11') }
    assert_equal written_off_at + 1, agent.domains.size, 'asked once more the moment it lapses'
  end

  it 'spends one probe per lapse, not a fresh three strikes' do
    sampler, agent = sampler_over(MUTE, backoff_seconds: 0)
    10.times { assert_nil sampler.swap('win11') }

    assert_equal Virt::GuestSwapSampler::FAILURES_BEFORE_BACKOFF + 7, agent.domains.size,
                 'a still-mute guest must re-arm on its single probe, not spend three'
  end

  it 'lets a good sample clear the strikes a hiccup burned' do
    sampler, agent = sampler_over(MUTE)
    2.times { assert_nil sampler.swap('Ubuntu') }
    agent.reply = LEVEL
    assert_equal LEVEL, sampler.swap('Ubuntu')

    agent.reply = MUTE
    2.times { assert_nil sampler.swap('Ubuntu') }
    assert_equal 5, agent.domains.size, 'a guest that answered once must earn a fresh three strikes'
    refute_includes @log.string, 'not asking again'
  end

  it 'forgets a written-off guest' do
    sampler, agent = sampler_over(MUTE)
    5.times { sampler.swap('win11') }
    assert_equal Virt::GuestSwapSampler::FAILURES_BEFORE_BACKOFF, agent.domains.size

    sampler.forget('win11')
    assert_nil sampler.swap('win11'), 'the guest still cannot answer'
    assert_equal Virt::GuestSwapSampler::FAILURES_BEFORE_BACKOFF + 1, agent.domains.size,
                 'a forgotten guest must be asked again at once'
  end

  # `TTY::Logger` renders the level as a word, so 'warning' is what a warn line is spotted by.
  context 'log level' do
    # @param reply [StandardError] what every sample fails with
    # @return [String] everything logged over the polls that write the guest off
    def log_of_write_off(reply)
      sampler, = sampler_over(reply, backoff_seconds: 0)
      10.times { sampler.swap('win11') }
      @log.string
    end

    it 'keeps a guest that was never going to answer out of warn' do
      log = log_of_write_off(MUTE)
      assert_includes log, 'not asking again'
      refute_includes log, 'warning'
    end

    it 'warns once about a failure no healthy host produces' do
      log = log_of_write_off(BROKEN)
      assert_equal 1, log.scan('warning').size, 'one warn per episode, at the write-off'
      assert_includes log, 'gave no buf-b64'
    end
  end
end
