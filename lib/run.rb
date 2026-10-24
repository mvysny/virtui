# frozen_string_literal: true

# Subprocess helpers that fail eagerly and loudly — the project's replacement for
# `system`/backticks/`exec`. Wraps Open3 so a missing or failing command never passes
# silently: {.sync} raises with stderr, {.async} runs it on a thread and logs the failure
# via `$log`.
#
# **Pass one argument per word.** Both methods take a splat, and that is the whole
# defence against quoting bugs:
#
#   Run.sync('df', '-P', path)      # argv — no shell, so `path` needs no escaping
#   Run.sync("df -P #{path}")       # one string — /bin/sh parses it, and a path
#                                   # containing a quote or a space breaks it
#
# Ruby hands a lone string to `/bin/sh`, so interpolating a VM name or a file path into
# one means hand-escaping it correctly forever — see design/decisions.md D_argv_not_shell. The
# single-string form is kept only for literal commands with no interpolation.
module Run
  # {.sync} on a thread of its own: returns at once, and logs the outcome via `$log`
  # instead of returning or raising it. Success is logged at debug level; a failure —
  # a non-zero exit with its stderr, or a command that cannot even start — at error.
  #
  # @param command [Array<String>] the command and its arguments, one per element
  # @return [Thread] the thread executing the command; call {Thread#join} to await it
  def self.async(*command)
    Thread.new do
      sync(*command)
      $log.debug("'#{command.join(' ')}': OK")
    rescue StandardError => e
      $log.error(e.message)
    end
  end

  # Runs `command` synchronously and returns its stdout, printing nothing itself.
  #
  # With a `cancellation:`, a cancel stops the command with `TERM`, reaps it, and raises
  # within {Cancellation::POLL_INTERVAL}; one canceled already spawns nothing:
  #
  #   Run.sync('virsh', '-q', 'dumpxml', vm, cancellation: cancel)
  #
  # @param command [Array<String>] the command and its arguments, one per element
  # @param cancellation [Cancellation, nil] stops the command once canceled
  # @return [String] the command's stdout, on exit code 0
  # @raise [RuntimeError] if the command exits non-zero; the message includes the exit
  #   status and the captured stderr
  # @raise [Cancellation::CanceledError] once `cancellation` is canceled
  def self.sync(*command, cancellation: nil)
    cancellation&.check_canceled
    stdout, stderr, status = Open3.popen3(*command) do |stdin, out, err, wait_thr|
      stdin.close
      # Drained while the child runs, as capture3 does: a child filling a pipe nobody reads
      # blocks for ever.
      readers = [out, err].map { |io| Thread.new { io.read } }
      wait(wait_thr, readers, cancellation)
      [*readers.map(&:value), wait_thr.value]
    end
    raise "Command '#{command.join(' ')}' failed with #{status.exitstatus}: #{stderr}" unless status.success?

    stdout
  end

  # Waits for the child, stopping it when the wait ends any other way — a cancel, or an
  # exception thrown into this thread.
  # @param wait_thr [Process::Waiter] the child's waiter, from popen3
  # @param readers [Array<Thread>] the threads draining its stdout and stderr
  # @param cancellation [Cancellation, nil]
  # @return [void]
  private_class_method def self.wait(wait_thr, readers, cancellation)
    cancellation ? cancellation.join(wait_thr) : wait_thr.join
  ensure
    if wait_thr.alive?
      begin
        Process.kill('TERM', wait_thr.pid)
      rescue Errno::ESRCH
        nil # exited between alive? and kill
      end
      wait_thr.join
      # EOF now that the child is gone; joined before popen3 closes the pipes under them.
      readers.each(&:join)
    end
  end
end
