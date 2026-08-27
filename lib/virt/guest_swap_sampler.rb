# frozen_string_literal: true

module Virt
  # Samples a guest's swap level once per poll tick, and stops asking a guest that cannot
  # answer:
  #
  #   sampler = GuestSwapSampler.new(agent: GuestAgent.new(runner: session))
  #   sampler.swap('Ubuntu')     # => #<ResourceUsage total=4GiB available=2.8GiB>, or nil
  #   sampler.forget('Ubuntu')   # it stopped running; its strikes must not greet the next boot
  #
  # An enhancement, never a dependency: every failure answers `nil`, because a guest with no
  # agent — or with `guest-file-*` among the agent's `BLOCK_RPCS`, as RHEL/Fedora ship it —
  # is a normal state, not an internal error. This is the one read path in the project that
  # swallows; the {GuestAgent} underneath raises loudly, and a caller wanting the failure
  # rather than a blank gauge asks it directly — deliberately not a decorator over it, see
  # DECISIONS.md D_swap_sampler_split.
  #
  # == Implementation details
  #
  # A guest that keeps failing is written off and then probed once a minute (see
  # {FAILURES_BEFORE_BACKOFF}); a failed poll costs up to {GuestAgent::TIMEOUT_SECONDS} of
  # the timer thread, so a guest that cannot answer has to stop being asked.
  #
  # A {GuestAgent::Unavailable} — the failure a healthy host produces on its own — stays at
  # `debug`, since every VM start passes through one while `qemu-ga` comes up; anything else
  # says so once, at `warn`, so a misconfigured agent is not swallowed with the rest. See
  # DECISIONS.md D_guest_agent_backoff.
  #
  # Timer-thread-confined: the strike counts are unguarded, and the sample under them is
  # three RPCs against a guest that may be sick — exactly the stall that must never reach
  # the UI thread.
  class GuestSwapSampler
    # How many consecutive failures write a guest off, and for how long.
    #
    # 60s because the guest this defends is a *booting* one: at a 2s poll three strikes are
    # spent 6s after libvirt calls the domain running, long before `qemu-ga` connects, so
    # every VM start writes its own guest off and waits the backoff out with a blank swap
    # gauge. The strike count then survives a lapse ({#backing_off?}), making a still-mute
    # guest cost one probe a minute rather than three. See DECISIONS.md D_guest_agent_backoff.
    FAILURES_BEFORE_BACKOFF = 3
    # @see FAILURES_BEFORE_BACKOFF
    BACKOFF_SECONDS = 60

    # @param agent [GuestAgent] the channel each sample is read through
    # @param backoff_seconds [Integer, Float] how long a written-off guest is skipped for
    #   (see {BACKOFF_SECONDS}); lowered by the specs, which would otherwise have to wait a
    #   minute to watch a write-off lapse
    def initialize(agent:, backoff_seconds: BACKOFF_SECONDS)
      @agent = agent
      @backoff_seconds = backoff_seconds
      # Hash{String => Integer} consecutive failures, and Hash{String => Cooldown} how long
      # each written-off guest stays unasked.
      @failures = {}
      @retry_at = {}
    end

    # This tick's swap level for one guest, or `nil` if it could not be had.
    #
    # @param domain [String] VM name; must be running, or the agent call fails
    # @return [ResourceUsage, nil] what the guest reports, or `nil` if it cannot answer — no
    #   agent, a blocked RPC, an undocumented reply, or the guest is currently written off
    #   (see {FAILURES_BEFORE_BACKOFF})
    def swap(domain)
      return nil if backing_off?(domain)

      level = @agent.swap(domain)
      forget(domain) # a good sample clears the strike count and any lapsed write-off alike
      level
    rescue StandardError => e
      note_failure(domain, e)
      nil
    end

    # Forgets a guest's strike count and any write-off, so its next sample starts clean.
    #
    # Call it when a VM leaves the running state: the agent goes down before libvirt calls
    # the domain stopped, so a shutdown otherwise burns strikes that greet the next boot. It
    # cannot cover a guest-induced *reboot*, which never leaves the running state — that one
    # heals by {BACKOFF_SECONDS} lapsing instead.
    #
    # @param domain [String] VM name
    # @return [void]
    def forget(domain)
      @failures.delete(domain)
      @retry_at.delete(domain)
    end

    # A lapsed write-off simply answers `false` and the next call goes through. Note what is
    # *not* touched: the strike count, which is what makes a still-mute guest re-arm on that
    # single probe instead of spending three (see {FAILURES_BEFORE_BACKOFF}).
    #
    # @param domain [String] VM name
    # @return [Boolean] whether this guest is currently written off
    private def backing_off?(domain) = @retry_at[domain]&.active? || false

    # Records one failed sample, writing the guest off on the {FAILURES_BEFORE_BACKOFF}th.
    #
    # @param domain [String] VM name
    # @param error [StandardError] why the sample failed
    # @return [void]
    private def note_failure(domain, error)
      count = @failures[domain] = (@failures[domain] || 0) + 1
      reason = error.message.lines.first&.strip
      if count < FAILURES_BEFORE_BACKOFF
        $log.debug("#{domain}: no swap level (#{count}/#{FAILURES_BEFORE_BACKOFF}): #{reason}")
      else
        @retry_at[domain] = Cooldown.of(@backoff_seconds)
        # Exactly at the write-off, so an unforeseen failure is announced once per episode:
        # earlier is a blip that may yet clear, later is a re-arm of something already said.
        unforeseen = count == FAILURES_BEFORE_BACKOFF && !error.is_a?(GuestAgent::Unavailable)
        $log.public_send(unforeseen ? :warn : :debug,
                         "#{domain}: guest agent gives no swap level (#{reason}); not asking " \
                         "again for #{@backoff_seconds}s")
      end
    end
  end
end
