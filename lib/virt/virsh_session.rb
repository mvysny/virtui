# frozen_string_literal: true

module Virt
  # A `virsh` transport that keeps one long-lived interactive `virsh` child and talks to
  # it over pipes, instead of spawning a process per command. Drop-in for {VirshSpawn}:
  #
  #   runner = VirshSession.new
  #   Virsh.new(runner: runner)      # reads now cost ~0.1ms instead of ~8ms
  #   runner.query('domstats')       # one argument per word; {.quote} handles the rest
  #   runner.close                   # always; otherwise the child outlives the process
  #
  # Only {#query} uses the session. {#sync} and {#async} delegate to a {VirshSpawn},
  # because one `virsh` child runs commands strictly one at a time: a `virsh start` would
  # block every read behind it for ~800ms, and mutating commands additionally want the
  # exit status that only a dedicated process has.
  #
  # The default transport in `bin/virtui`; {VirshSpawn} is the fallback you get by editing
  # that file. Why a session at all, and why the obvious framings do not work:
  # DECISIONS.md D-virsh-session.
  #
  # == Implementation details
  #
  # `virsh` drives GNU readline even when stdin is a pipe, so the reply stream carries a
  # prompt and an echo of the line just sent. Both {CHILD_ENV} entries are load-bearing
  # (see the constant), and the echo is not noise — {#query} asserts on it, which is what
  # turns a stale reply into an exception instead of one VM's numbers silently reported
  # as another's.
  #
  # Command completeness is decided by *ordering*, never by a timeout: `virsh` runs one
  # command at a time, so a sentinel `echo` sent after the real command cannot produce
  # output until the real command's output is finished. Seeing the sentinel proves the
  # reply is whole. The read deadline only detects a wedged child.
  #
  # Failures split in two, and conflating them would break a host with no libvirtd —
  # there `virsh` sits happily in its REPL and fails every command, so respawning would
  # churn forever:
  #
  # - a *command* failure (`error:` on stderr) raises and leaves the session alone;
  # - a *transport* failure ({Desync}, {Timeout}, EOF) kills and respawns the child once,
  #   then gives up and degrades permanently to {VirshSpawn}. The saving is an
  #   optimisation, so losing it must never be worse than not having tried.
  #
  # == Thread-safety
  #
  # Thread-safe: one mutex serialises every call, which is required rather than defensive
  # — two callers interleaved on one pipe would read each other's replies. Reads normally
  # come from the timer thread, but {Cache#initialize} calls {Virsh#hostinfo} on the main
  # thread.
  class VirshSession
    # Both entries defend against GNU readline, which `virsh` uses even on a pipe.
    # `TERM=dumb` stops it emitting ANSI redisplay escapes into the reply, and `COLUMNS`
    # caps the length of a command line that survives intact — readline re-wraps (and
    # re-emits, non-deterministically) anything it thinks is wider than the terminal, so
    # this is a line-length limit and not merely a cosmetic hint.
    #
    # Not replaceable by a `virsh` flag, which is the first thing a reader tidying this up
    # will look for: `-q` silences the banner but not the prompt or the echo, and 12.0.0
    # has no `-f`/`--file` clean-stream mode at all.
    CHILD_ENV = { 'TERM' => 'dumb', 'COLUMNS' => '1000000' }.freeze

    # Bytes {.quote} refuses, because readline acts on them instead of passing them along.
    CONTROL_BYTES = /[\x00-\x1f\x7f]/

    # How long to wait for one reply. Generously above the 2s poll: a read still
    # outstanding after this many ticks means the child is wedged, not slow, and killing
    # it beats pinning the timer thread forever the way {Run.sync} would.
    READ_TIMEOUT_SECONDS = 10.0

    # How long the child gets to print its first prompt before the session is written off
    # as unusable.
    STARTUP_TIMEOUT_SECONDS = 5.0

    # The prompt is read from the child rather than hardcoded, so it can only be this
    # long; `virsh # ` is 8 bytes.
    MAX_PROMPT_BYTES = 32

    # Raised when the child is unusable: the reply stream no longer lines up, or it went
    # away, or it stopped answering. Always recovered from by respawning, never by
    # retrying on the same child.
    class TransportError < StandardError; end

    # Raised when the reply stream no longer corresponds to the commands sent — a stale
    # reply from an abandoned call, most likely. Never swallowed: the whole point is that
    # a desynchronised session must not report VM A's data as VM B's.
    class Desync < TransportError; end

    # Raised when a reply does not arrive within the configured read timeout.
    class Timeout < TransportError; end

    # @param uri [String, nil] a libvirt connection URI for `virsh -c`, or `nil` for the
    #   default. `test:///default` is libvirt's in-process driver and needs no daemon,
    #   which is how the specs exercise a real `virsh`
    # @param spawn [VirshSpawn] transport for the calls a session must not serve, and the
    #   fallback once the session is written off
    # @param read_timeout [Float] seconds to wait for one reply; lowered by the specs,
    #   which deliberately wedge a session and would otherwise wait
    #   {READ_TIMEOUT_SECONDS} to find out
    # @raise [TransportError] if the child never printed a usable prompt
    def initialize(uri: nil, spawn: VirshSpawn.new, read_timeout: READ_TIMEOUT_SECONDS)
      @uri = uri
      @spawn = spawn
      @read_timeout = read_timeout
      @mutex = Mutex.new
      @degraded = false
      start
    end

    # @return [Boolean] whether the session was written off and reads now spawn a process
    #   each, exactly as {VirshSpawn} would
    def degraded? = @degraded

    # A read served from the persistent child, byte-identical to what {VirshSpawn#query}
    # would have returned.
    #
    # Recovers from a broken child by respawning and retrying once, then by degrading for
    # good. A failure *reported by* `virsh` is not a broken child and propagates
    # untouched.
    #
    # @param args [Array<String>] a `virsh` subcommand and its arguments, one per element
    # @return [String] the command's stdout, with stderr excluded
    # @raise [RuntimeError] if `virsh` reported an error for this command
    def query(*args)
      line = args.map { |it| self.class.quote(it) }.join(' ')
      @mutex.synchronize do
        next @spawn.query(*args) if @degraded

        begin
          call(line)
        rescue TransportError => e
          $log.warn("virsh session: #{e.message}; respawning")
          begin
            restart
            call(line)
          rescue TransportError => e2
            degrade(e2)
            @spawn.query(*args)
          end
        end
      end
    end

    # Quotes one argument for `virsh`'s own tokenizer, which is not the shell's.
    #
    # Single quotes, never double: inside `'…'` `virsh` takes every byte literally, while
    # inside `"…"` it treats backslash as an escape and would eat the ones JSON puts
    # there. An embedded quote closes, escapes and reopens, exactly as POSIX sh needs —
    # `virsh echo --shell` emits this same form, which is a handy oracle.
    #
    #   quote("it's")   # => "'it'\\''s'"
    #
    # Quoting cannot rescue a *control* byte, so one raises here instead of being wrapped:
    # readline reads the child's stdin (see {CHILD_ENV}) and acts on C0 and DEL as editing
    # keys — TAB completes, `\x15` kills the line — before the tokenizer ever sees them,
    # which corrupts the command and hands every later reply to the wrong call. Nothing
    # feeds one in today (`JSON.generate` escapes every C0 byte, though notably *not* DEL,
    # and the guest paths are literals), so this guards the next payload, not a live bug.
    #
    # @param str [String] one argument, as the caller means it to arrive
    # @return [String] the argument wrapped so the tokenizer reproduces it byte for byte
    # @raise [RuntimeError] if the argument contains a C0 byte or DEL
    def self.quote(str)
      raise "cannot pass #{str.inspect} to virsh: readline reads a control byte as a key" if str.match?(CONTROL_BYTES)

      "'#{str.gsub("'") { "'\\''" }}'"
    end

    # @param args [Array<String>] a `virsh` subcommand and its arguments, one per element
    # @return [String] the command's stdout
    # @raise [RuntimeError] if the command fails (via {Run.sync})
    def sync(*args) = @spawn.sync(*args)

    # @param args [Array<String>] a `virsh` subcommand and its arguments, one per element
    # @return [Thread] the thread running the command (see {Run.async})
    def async(*args) = @spawn.async(*args)

    # Shuts the child down, killing it if it will not leave politely. Safe to call twice;
    # after it, {#query} degrades to spawning.
    #
    # @return [void]
    def close
      @mutex.synchronize do
        @degraded = true
        stop
      end
    end

    # Starts the child and learns its prompt.
    #
    # The prompt is whatever the child prints first, rather than a hardcoded `virsh # `:
    # it is cosmetic, unversioned string, and reading it costs nothing. Waiting for
    # quiescence is safe *here only* — at startup there is no earlier reply that a
    # premature read could steal.
    #
    # @return [void]
    # @raise [TransportError] if nothing prompt-shaped arrived in time
    private def start
      args = @uri ? ['-c', @uri] : []
      @stdin, @stdout, @stderr, @wait = Open3.popen3(CHILD_ENV, 'virsh', '-q', *args)

      banner = read_quiescent(@stdout, STARTUP_TIMEOUT_SECONDS)
      # A failed connection prints errors first, but `virsh` stays in the REPL and
      # connects lazily, so the prompt is still the last thing on the line.
      newline = banner.rindex("\n")
      @prompt = newline ? banner[(newline + 1)..] : banner
      return if !@prompt.empty? && @prompt.bytesize <= MAX_PROMPT_BYTES

      stop
      raise TransportError, "virsh printed no usable prompt: #{banner[0, 200].inspect}"
    end

    # @return [void]
    private def stop
      @stdin&.write("quit\n")
      @stdin&.flush
    rescue StandardError
      nil # the child is already gone; the kill below is what matters
    ensure
      [@stdin, @stdout, @stderr].each { |io| io&.close unless io&.closed? }
      kill_child
      @stdin = @stdout = @stderr = @wait = nil
    end

    # @return [void]
    private def kill_child
      return unless @wait&.alive?

      Process.kill('KILL', @wait.pid)
      @wait.value
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    # @return [void]
    private def restart
      stop
      start
    end

    # @param error [TransportError] why the session was written off
    # @return [void]
    private def degrade(error)
      @degraded = true
      stop
      $log.warn("virsh session unusable (#{error.message}); falling back to one virsh " \
                'process per read for the rest of this run')
    end

    # Sends one command plus a sentinel and returns the command's stdout.
    #
    # @param line [String] the command line to send, arguments already quoted by {.quote}
    # @return [String] the command's stdout
    # @raise [TransportError] if the child is unusable
    # @raise [RuntimeError] if `virsh` reported an error for this command
    private def call(line)
      nonce = "VT#{SecureRandom.hex(6)}"
      # Splitting the nonce with a quote that virsh's tokenizer removes means the echoed
      # command line cannot contain the bytes we search for — so a payload that happens
      # to include the marker, or the prompt, can't terminate the read early.
      sentinel = "echo '#{nonce[0, 4]}'#{nonce[4..]}"
      write_line("#{line}\n#{sentinel}\n")

      raw = read_until(@stdout, "#{nonce}#{@prompt}")
      raise Desync, "expected an echo of #{line.inspect}" unless raw.start_with?("#{line}\n")

      body = raw[(line.bytesize + 1)..]
      tail = "#{@prompt}#{sentinel}\n#{nonce}#{@prompt}"
      cut = body.rindex(tail)
      raise Desync, 'sentinel did not close the reply' if cut.nil?

      check_stderr(line)
      body[0, cut]
    end

    # @param text [String] bytes to send, newline included
    # @return [void]
    # @raise [TransportError] if the child has gone away
    private def write_line(text)
      @stdin.write(text)
      @stdin.flush
    rescue IOError, Errno::EPIPE => e
      raise TransportError, "cannot write to virsh: #{e.message}"
    end

    # Raises if `virsh` reported an error for the command just read.
    #
    # Sound without any waiting: `virsh` wrote stderr before the sentinel's stdout, and
    # the sentinel has already been read, so anything stderr holds is already there.
    #
    # Stderr is the only failure signal there is: empty *stdout* is not one, because a host
    # with no VMs returns an empty `domstats` legitimately.
    #
    # Only `error:` lines fail the call. libvirt's own log output also lands on stderr and
    # a warning must not turn a good read into an exception, so the remainder is logged —
    # at `warn` rather than `debug`, because classifying stderr without an exit status is
    # this design's weakest joint and misreading it must not be quiet.
    #
    # @param line [String] the command just run, for the message
    # @return [void]
    # @raise [RuntimeError] if `virsh` printed an `error:` line
    private def check_stderr(line)
      text = read_available(@stderr)
      return if text.empty?

      errors, chatter = text.lines.partition { |it| it.start_with?('error:') }
      $log.warn("virsh session: '#{line}' wrote #{chatter.join.strip}") unless chatter.empty?
      raise "Command 'virsh #{line}' failed: #{errors.join.strip}" unless errors.empty?
    end

    # @param io [IO] stream to read
    # @param pattern [String] bytes that end the reply
    # @return [String] everything read, including `pattern`
    # @raise [TransportError] on timeout or if the child closed the stream
    private def read_until(io, pattern)
      buf = +''
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @read_timeout
      loop do
        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Timeout, "no reply within #{@read_timeout}s" if left <= 0 || !io.wait_readable(left)

        begin
          buf << io.read_nonblock(65_536)
        rescue IO::WaitReadable
          next
        rescue IOError # EOFError included: the child is gone
          raise TransportError, 'virsh closed its output'
        end
        return buf if buf.include?(pattern)
      end
    end

    # @param io [IO] stream to read
    # @param timeout [Float] seconds to wait for the first byte
    # @return [String] everything readable once the stream falls quiet
    private def read_quiescent(io, timeout)
      buf = +''
      while io.wait_readable(buf.empty? ? timeout : 0.1)
        begin
          buf << io.read_nonblock(65_536)
        rescue IOError, IO::WaitReadable
          break
        end
      end
      buf
    end

    # @param io [IO] stream to read
    # @return [String] whatever is buffered right now, without waiting
    private def read_available(io)
      buf = +''
      while io.wait_readable(0)
        begin
          buf << io.read_nonblock(65_536)
        rescue IOError, IO::WaitReadable
          break
        end
      end
      buf
    end
  end
end
