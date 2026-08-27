# frozen_string_literal: true

module Virt
  # Reads what only a guest itself knows — today its swap *level* — by calling the QEMU
  # guest agent (`qemu-guest-agent`) inside the VM via `virsh qemu-agent-command`:
  #
  #   agent = GuestAgent.new(runner: VirshSession.new)
  #   agent.swap('Ubuntu')   # => #<ResourceUsage total=4GiB available=2.8GiB>, or nil
  #   agent.read_file('Ubuntu', '/proc/pressure/memory')   # the raw channel
  #
  # `domstats` cannot answer this. Its `pswpin`/`pswpout` are counters that only ever climb,
  # so they give a rate and never a level (see {MemoryStat#swap_out}); the level lives in the
  # guest's own `/proc/meminfo`, and the agent is the only channel to it needing nothing
  # installed in the guest that `virt-manager` doesn't already put there.
  #
  # Pair it with a {VirshSession}. One sample is three agent calls (open/read/close), each
  # ~13 ms of libvirtd+QMP+virtio-serial round-trip *plus* ~18 ms of process spawn on
  # {VirshSpawn} — that spawn, three times per VM per tick, is what makes the swap level a
  # session-only feature. See DECISIONS.md D_guest_swap_level.
  #
  # == Implementation details
  #
  # An enhancement, never a dependency: {#swap} answers `nil` for *any* failure, because a
  # guest with no agent — or with `guest-file-*` among the agent's `BLOCK_RPCS`, as
  # RHEL/Fedora ship it — is a normal state, not an internal error. It is the one read path
  # in the project that swallows; everything under it raises loudly. A guest that keeps
  # failing is written off and then probed once a minute (see {FAILURES_BEFORE_BACKOFF}).
  # A failure a healthy host produces on its own ({EXPECTED_FAILURES}) stays at `debug` —
  # every VM start passes through one while `qemu-ga` comes up — and anything else says so
  # once, at `warn`, so a misconfigured agent is not swallowed with the rest.
  #
  # Timer-thread-confined: three RPCs against a sick guest is exactly the stall that must
  # never reach the UI thread.
  class GuestAgent
    # The guest file the swap level is read from.
    MEMINFO_PATH = '/proc/meminfo'

    # How much of a guest file to ask for in one `guest-file-read`. Comfortably over the
    # ~2 KB `/proc/meminfo` runs to, so one read gets the whole file and there is no loop: a
    # short read fails {System::MemoryStat.parse}'s key check instead of quietly reporting
    # half a file.
    READ_BYTES = 16_384

    # Seconds `virsh` waits for one agent call — ~150x the ~13 ms a healthy call takes. The
    # ceiling that matters is {VirshSession::READ_TIMEOUT_SECONDS}: staying well under it
    # means a wedged `qemu-ga` surfaces as a `virsh` error, which leaves the session alive,
    # rather than as a read timeout, which kills and respawns the child.
    TIMEOUT_SECONDS = 2

    # How many consecutive failures write a guest off, and for how long — a failed poll
    # costs up to {TIMEOUT_SECONDS} of the timer thread, so a guest that cannot answer has
    # to stop being asked.
    #
    # 60s because the guest this defends is a *booting* one: at a 2s poll three strikes are
    # spent 6s after libvirt calls the domain running, long before `qemu-ga` connects, so
    # every VM start writes its own guest off and waits the backoff out with a blank swap
    # gauge. The strike count then survives a lapse ({#backing_off?}), making a still-mute
    # guest cost one probe a minute rather than three. See DECISIONS.md D_guest_agent_backoff.
    FAILURES_BEFORE_BACKOFF = 3
    # @see FAILURES_BEFORE_BACKOFF
    BACKOFF_SECONDS = 60

    # The failures a healthy host produces on its own, matched against the error message to
    # raise {Unavailable} rather than a bare error. In order: the agent is not up (a guest
    # mid-boot or mid-shutdown, or one that never had `qemu-guest-agent`), it went away
    # mid-command, the RPC is blocked or absent (`guest-file-*` is in `BLOCK_RPCS` as
    # RHEL/Fedora ship the agent), the VM stopped between the `domstats` snapshot and this
    # read, and the guest simply has no `/proc/meminfo` — a non-Linux guest whose definition
    # never declared an OS, so {GuestOS} could not spare it this read (see {Cache#update}).
    #
    # Matching libvirt's error text is fragile on purpose-limited grounds: it picks the
    # error *class* only, never the write-off, so a miss costs one `warn` line from whoever
    # is polling and a new libvirt phrasing cannot change what virtui does. See DECISIONS.md
    # D_guest_agent_backoff.
    EXPECTED_FAILURES = ['guest agent is not responding', 'guest agent disappeared',
                         'has not been found', 'domain is not running',
                         'no such file or directory'].freeze

    # Raised when this guest was never going to answer: no agent connected, the RPC blocked,
    # the domain gone, the file absent ({EXPECTED_FAILURES}). A normal state of a healthy
    # host, so a caller may treat it as "no data" — unlike every other error out of this
    # class, each of which means the agent replied with something it does not document.
    class Unavailable < StandardError; end

    # @param runner [VirshSession, VirshSpawn] transport for the `qemu-agent-command` calls
    # @param timeout_seconds [Integer] per-call agent timeout (see {TIMEOUT_SECONDS})
    # @param backoff_seconds [Integer, Float] how long a written-off guest is skipped for
    #   (see {BACKOFF_SECONDS}); lowered by the specs, which would otherwise have to wait a
    #   minute to watch a write-off lapse
    def initialize(runner:, timeout_seconds: TIMEOUT_SECONDS, backoff_seconds: BACKOFF_SECONDS)
      @runner = runner
      @timeout_seconds = timeout_seconds
      @backoff_seconds = backoff_seconds
      # Hash{String => Integer} consecutive failures, and Hash{String => Cooldown} how long
      # each written-off guest stays unasked.
      @failures = {}
      @retry_at = {}
    end

    # The guest's swap occupancy, from its own `/proc/meminfo`.
    #
    # A level, unlike {MemoryStat#swap_out}: it falls when the guest faults pages back in or
    # frees the slots, which is what makes it the figure saying what a ballooned guest is
    # paying *now*.
    #
    # @param domain [String] VM name; must be running, or the agent call fails
    # @return [ResourceUsage, nil] `SwapTotal` with `SwapFree` available, or `nil` if this
    #   guest cannot answer — no agent, a blocked RPC, no swap configured, or the guest is
    #   currently written off (see {FAILURES_BEFORE_BACKOFF})
    def swap(domain)
      return nil if backing_off?(domain)

      level = System::MemoryStat.parse(read_file(domain, MEMINFO_PATH)).swap
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

    # Reads one file from inside the guest, in three agent calls: open, read, close.
    #
    # Deliberately not `guest-exec`: reading a world-readable file needs neither remote root
    # exec nor a process spawned in the guest, and `guest-exec` is asynchronous — its reply
    # carries only a PID, so the output takes a second `guest-exec-status` round-trip that
    # cannot be issued until the guest process has exited. See DECISIONS.md
    # D_guest_swap_level.
    #
    # @param domain [String] VM name
    # @param path [String] absolute path of the file, as the *guest* sees it
    # @param max_bytes [Integer] how much to read in the single `guest-file-read`
    # @return [String] the file's contents
    # @raise [Unavailable] if the guest was never going to answer this
    # @raise [RuntimeError] if the agent replies with something other than what it documents
    def read_file(domain, path, max_bytes: READ_BYTES)
      handle = agent_command(domain, 'guest-file-open', { path: path, mode: 'r' })
      raise "#{domain}: guest-file-open returned no handle: #{handle.inspect}" unless handle.is_a?(Integer)

      begin
        reply = agent_command(domain, 'guest-file-read', { handle: handle, count: max_bytes })
        b64 = reply.is_a?(Hash) ? reply['buf-b64'] : nil
        raise "#{domain}: guest-file-read gave no buf-b64: #{reply.inspect}" if b64.nil?

        # unpack1 over the base64 gem: core, and it tolerates the line breaks some agent
        # versions wrap a long payload in.
        b64.unpack1('m').force_encoding(Encoding::UTF_8)
      ensure
        close_quietly(domain, handle)
      end
    end

    # Closes a guest file handle, logging rather than raising if that fails.
    #
    # `qemu-ga` holds an open handle until the guest reboots and caps how many it hands out,
    # so leaking one per poll eventually stops the reads altogether — hence the `ensure`.
    # Never raises: a failed close must not mask the read error already on its way out.
    #
    # @param domain [String] VM name
    # @param handle [Integer] the handle from `guest-file-open`
    # @return [void]
    private def close_quietly(domain, handle)
      agent_command(domain, 'guest-file-close', { handle: handle })
    rescue StandardError => e
      # A guest shutting down between the open and the close leaks a handle it is about to
      # destroy anyway, and that is the common way to get here.
      reason = e.message.lines.first&.strip
      $log.public_send(e.is_a?(Unavailable) ? :debug : :warn,
                       "#{domain}: leaked guest file handle #{handle}: #{reason}")
    end

    # Runs one guest-agent command and returns its `return` member.
    #
    # @param domain [String] VM name
    # @param execute [String] the agent command, e.g. `guest-file-open`
    # @param arguments [Hash, nil] its arguments, or `nil` for a command taking none
    # @return [Object] the reply's `return` member — an Integer handle, or a Hash
    # @raise [Unavailable] if the failure is one a healthy host produces on its own
    # @raise [RuntimeError] if `virsh` failed, the reply is not JSON, or the agent answered
    #   with an `error` member
    private def agent_command(domain, execute, arguments = nil)
      command = { execute: execute }
      command[:arguments] = arguments unless arguments.nil?
      # JSON.generate, never interpolation: the payload is nothing but nested quotes, and
      # hand-escaping it is what breaks first. Both transports carry it as-is —
      # {VirshSession.quote}'s single quotes are what keep virsh's tokenizer off the
      # backslashes.
      raw = @runner.query('qemu-agent-command', domain, JSON.generate(command),
                          '--timeout', @timeout_seconds.to_s)
      reply = parse_reply(domain, execute, raw)
      # Delivery is not the guest's success: a blocked RPC or a missing file comes back as a
      # well-formed reply carrying `error`, and reading that as data is how a refusal turns
      # into a wrong number.
      raise "#{domain}: #{execute} failed: #{reply['error']}" if reply.key?('error')
      raise "#{domain}: #{execute} returned no 'return': #{raw[0, 200].inspect}" unless reply.key?('return')

      reply['return']
    rescue StandardError => e
      # Classified here, at the one place that talks to libvirt: the error text is this
      # class's business, and every caller above wants the answer as a type.
      raise Unavailable, e.message if expected?(e)

      raise
    end

    # @param domain [String] VM name, for the error message
    # @param execute [String] the agent command, for the error message
    # @param raw [String] the reply as `virsh` printed it
    # @return [Hash{String => Object}] the parsed reply
    # @raise [RuntimeError] if it is not a JSON object
    private def parse_reply(domain, execute, raw)
      reply = JSON.parse(raw)
      raise "#{domain}: #{execute} replied with #{reply.class}: #{raw[0, 200].inspect}" unless reply.is_a?(Hash)

      reply
    rescue JSON::ParserError => e
      raise "#{domain}: #{execute} gave an unparseable reply (#{e.message}): #{raw[0, 200].inspect}"
    end

    # A lapsed write-off simply answers `false` and the next call goes through. Note what is
    # *not* touched: the strike count, which is what makes a still-mute guest re-arm on that
    # single probe instead of spending three (see {FAILURES_BEFORE_BACKOFF}).
    #
    # @param domain [String] VM name
    # @return [Boolean] whether this guest is currently written off
    private def backing_off?(domain) = @retry_at[domain]&.active? || false

    # @param error [StandardError] the failure to classify
    # @return [Boolean] whether this is a failure a healthy host produces on its own (see
    #   {EXPECTED_FAILURES}), and so belongs in an {Unavailable}
    private def expected?(error)
      message = error.message.downcase
      EXPECTED_FAILURES.any? { |it| message.include?(it) }
    end

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
        unforeseen = count == FAILURES_BEFORE_BACKOFF && !error.is_a?(Unavailable)
        $log.public_send(unforeseen ? :warn : :debug,
                         "#{domain}: guest agent gives no swap level (#{reason}); not asking " \
                         "again for #{@backoff_seconds}s")
      end
    end
  end
end
