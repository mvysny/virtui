# frozen_string_literal: true

# Subprocess helpers that fail eagerly and loudly — the project's replacement for
# `system`/backticks/`exec`. Wraps Open3 so a missing or failing command never passes
# silently: {.sync} raises with stderr, {.async} logs the failure via `$log`.
#
# **Pass one argument per word.** Both methods take a splat, and that is the whole
# defence against quoting bugs:
#
#   Run.sync('df', '-P', path)      # argv — no shell, so `path` needs no escaping
#   Run.sync("df -P #{path}")       # one string — /bin/sh parses it, and a path
#                                   # containing a quote or a space breaks it
#
# Ruby hands a lone string to `/bin/sh`, so interpolating a VM name or a file path into
# one means hand-escaping it correctly forever — see DECISIONS.md D_argv_not_shell. The
# single-string form is kept only for literal commands with no interpolation.
module Run
  # Runs `command` in the background, logging its combined output only if it fails.
  #
  # Returns immediately; the command keeps running on the returned thread. Success is
  # logged at debug level, failure at error level, and an unexpected exception at fatal —
  # all via `$log`. Output is read on the thread, so this never blocks the caller.
  #
  # @param command [Array<String>] the command and its arguments, one per element
  # @return [Thread] the thread executing the command; call {Thread#join} to await it
  def self.async(*command)
    printable = command.join(' ')
    _stdin, combined_output, wait_thr = Open3.popen2e(*command)

    Thread.new do
      status = wait_thr.value
      output = combined_output.read

      if status.success?
        $log.debug("'#{printable}': OK")
      else
        $log.error("'#{printable}' failed with #{status.exitstatus}: #{output}")
      end
    rescue StandardError => e
      $log.fatal("Fatal error running '#{printable}'", e)
    ensure
      combined_output.close
    end
  end

  # Runs `command` synchronously and returns its stdout, printing nothing itself.
  #
  # @param command [Array<String>] the command and its arguments, one per element
  # @return [String] the command's stdout, on exit code 0
  # @raise [RuntimeError] if the command exits non-zero; the message includes the exit
  #   status and the captured stderr
  def self.sync(*command)
    stdout, stderr, status = Open3.capture3(*command)
    printable = command.join(' ')
    raise "Command '#{printable}' failed with #{status.exitstatus}: #{stderr}" unless status.success?

    stdout
  end
end
