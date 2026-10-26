# frozen_string_literal: true

module Virt
  # Samples what a guest reports through its agent — its swap level, how full its disks are,
  # its SysRq mask — and stops asking a guest that cannot answer:
  #
  #   sampler = GuestSampler.new(agent: GuestAgent.new(runner: session))
  #   sampler.swap('Ubuntu')       # => #<ResourceUsage total=4GiB available=2.8GiB>, or nil
  #   sampler.fs_usage('Ubuntu')   # => {"vda" => #<ResourceUsage 3.4G/15G (23%)>}, or nil
  #   sampler.sysrq_mask('Ubuntu') # => 176, or nil
  #   sampler.revive('Ubuntu')     # every tick: its agent just connected, so ask again now
  #   sampler.forget('Ubuntu')     # it stopped running; its strikes must not greet the next boot
  #
  # An enhancement, never a dependency: every failure answers `nil`, because a guest with no
  # agent — or with `guest-file-*` among the agent's `BLOCK_RPCS`, as RHEL/Fedora ship it —
  # is a normal state, not an internal error. This is the one read path in the project that
  # swallows; the {GuestAgent} underneath raises loudly, and a caller wanting the failure
  # rather than a blank gauge asks it directly — deliberately not a decorator over it, see
  # design/decisions.md D_swap_sampler_split.
  #
  # == Implementation details
  #
  # Each read keeps its own strikes, since one can be blocked while the other answers (the
  # RHEL agent refuses the swap level's `guest-file-*`, not `guest-get-fsinfo`). A read that
  # keeps failing is written off and then probed once a minute (see
  # {FAILURES_BEFORE_BACKOFF}); a failed poll costs up to {GuestAgent::TIMEOUT_SECONDS} of
  # the timer thread, so a guest that cannot answer has to stop being asked. A write-off
  # made while the agent was down ends early, when {#revive} sees it connect.
  #
  # A {GuestAgent::Unavailable} — the failure a healthy host produces on its own — stays at
  # `debug`, since every VM start passes through one while `qemu-ga` comes up; anything else
  # says so once, at `warn`, so a misconfigured agent is not swallowed with the rest. See
  # design/decisions.md D_guest_agent_backoff.
  #
  # Timer-thread-confined: the strike counts are unguarded, and the sample under them is
  # RPCs against a guest that may be sick — exactly the stall that must never reach the UI
  # thread.
  class GuestSampler
    # How many consecutive failures write a read off, and for how long.
    #
    # 60s because the guest this defends is a *booting* one: at a 2s poll three strikes are
    # spent 6s after libvirt calls the domain running, long before `qemu-ga` connects, so
    # every VM start writes its own guest off and waits the backoff out with a blank swap
    # gauge. The strike count then survives a lapse ({#backing_off?}), making a still-mute
    # guest cost one probe a minute rather than three. See design/decisions.md D_guest_agent_backoff.
    FAILURES_BEFORE_BACKOFF = 3
    # @see FAILURES_BEFORE_BACKOFF
    BACKOFF_SECONDS = 60

    # @param agent [GuestAgent] the channel each sample is read through
    # @param backoff_seconds [Integer, Float] how long a written-off read is skipped for
    #   (see {BACKOFF_SECONDS}); lowered by the specs, which would otherwise have to wait a
    #   minute to watch a write-off lapse
    def initialize(agent:, backoff_seconds: BACKOFF_SECONDS)
      @agent = agent
      @backoff_seconds = backoff_seconds
      # Hash{Array(String, String) => Integer} consecutive failures, and
      # Hash{Array(String, String) => Cooldown} how long each written-off read stays unasked;
      # both keyed by (domain, read).
      @failures = {}
      @retry_at = {}
      # Hash{String => Symbol}: each domain with a write-off whose agent {#revive} still
      # watches — `:unchecked`, or `:down` once its channel was seen disconnected.
      @agent_watch = {}
    end

    # @param domain [String] VM name; must be running, or the agent call fails
    # @return [ResourceUsage, nil] the guest's swap level (see {GuestAgent#swap}), or `nil`
    #   if it cannot answer — no agent, a blocked RPC, an undocumented reply, or the read is
    #   currently written off (see {FAILURES_BEFORE_BACKOFF})
    def swap(domain) = sample(domain, 'swap level') { @agent.swap(domain) }

    # @param domain [String] VM name; must be running, or the agent call fails
    # @return [Hash{String => ResourceUsage}, nil] how full each disk is (see
    #   {GuestAgent#fs_usage}), or `nil` for the reasons {#swap} gives
    def fs_usage(domain) = sample(domain, 'filesystem usage') { @agent.fs_usage(domain) }

    # @param domain [String] VM name; must be running, or the agent call fails
    # @return [Integer, nil] the guest's `kernel.sysrq` (see {GuestAgent#sysrq_mask}), or `nil`
    #   for the reasons {#swap} gives
    def sysrq_mask(domain) = sample(domain, 'SysRq mask') { @agent.sysrq_mask(domain) }

    # Forgets a guest's strike counts and any write-off, so its next samples start clean.
    #
    # Call it when a VM leaves the running state: the agent goes down before libvirt calls
    # the domain stopped, so a shutdown otherwise burns strikes that greet the next boot. A
    # guest-induced *reboot* never leaves the running state; {#revive} covers that one.
    #
    # @param domain [String] VM name
    # @return [void]
    def forget(domain)
      @failures.delete_if { |(d, _), _| d == domain }
      @retry_at.delete_if { |(d, _), _| d == domain }
      @agent_watch.delete(domain)
    end

    # Lifts a guest's write-offs the moment its agent connects, so a booting or rebooting
    # guest is read on the next tick instead of after {BACKOFF_SECONDS}.
    #
    # Call it every tick for every running VM, after its samples. Only a disconnected →
    # connected edge lifts: an agent connected at the write-off is wedged or refusing the
    # RPC, and waits out its time. Costs one libvirtd read per tick while a written-off
    # guest's agent stays down, and none otherwise. See design/decisions.md D_guest_agent_backoff.
    #
    # @param domain [String] VM name
    # @return [void]
    # @raise [RuntimeError] if libvirt cannot say whether the agent is connected
    def revive(domain)
      return unless @agent_watch.key?(domain)

      if !@agent.connected?(domain)
        @agent_watch[domain] = :down
      elsif @agent_watch[domain] == :down
        $log.debug("#{domain}: guest agent connected; asking again")
        forget(domain)
      else
        @agent_watch.delete(domain)
      end
    end

    # One sample of one read, or `nil` if it could not be had.
    #
    # @param domain [String] VM name
    # @param read [String] what is sampled, for the strike key and the log, e.g. `swap level`
    # @yieldreturn [Object] the sample, from the agent
    # @return [Object, nil] the block's answer, or `nil` if it raised or is written off
    private def sample(domain, read)
      key = [domain, read]
      return nil if backing_off?(key)

      value = yield
      # A good sample clears the strike count and any lapsed write-off alike.
      @failures.delete(key)
      @retry_at.delete(key)
      value
    rescue StandardError => e
      note_failure(key, e)
      nil
    end

    # A lapsed write-off simply answers `false` and the next call goes through. Note what is
    # *not* touched: the strike count, which is what makes a still-mute guest re-arm on that
    # single probe instead of spending three (see {FAILURES_BEFORE_BACKOFF}).
    #
    # @param key [Array(String, String)] the domain and the read
    # @return [Boolean] whether this read is currently written off
    private def backing_off?(key) = @retry_at[key]&.active? || false

    # Records one failed sample, writing the read off on the {FAILURES_BEFORE_BACKOFF}th.
    #
    # @param key [Array(String, String)] the domain and the read
    # @param error [StandardError] why the sample failed
    # @return [void]
    private def note_failure(key, error)
      domain, read = key
      count = @failures[key] = (@failures[key] || 0) + 1
      reason = error.message.lines.first&.strip
      if count < FAILURES_BEFORE_BACKOFF
        $log.debug("#{domain}: no #{read} (#{count}/#{FAILURES_BEFORE_BACKOFF}): #{reason}")
      else
        @retry_at[key] = Cooldown.of(@backoff_seconds)
        @agent_watch[domain] ||= :unchecked
        # Exactly at the write-off, so an unforeseen failure is announced once per episode:
        # earlier is a blip that may yet clear, later is a re-arm of something already said.
        unforeseen = count == FAILURES_BEFORE_BACKOFF && !error.is_a?(GuestAgent::Unavailable)
        $log.public_send(unforeseen ? :warn : :debug,
                         "#{domain}: guest agent gives no #{read} (#{reason}); not asking " \
                         "again for #{@backoff_seconds}s")
      end
    end
  end
end
