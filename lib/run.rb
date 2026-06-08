# frozen_string_literal: true

# Subprocess helpers that fail eagerly and loudly — the project's replacement for
# `system`/backticks/`exec`. Wraps Open3 so a missing or failing command never passes
# silently: {.sync} raises with stderr, {.async} logs the failure via `$log`.
module Run
  # Runs `command` in the background, logging its combined output only if it fails.
  #
  # Returns immediately; the command keeps running on the returned thread. Success is
  # logged at debug level, failure at error level, and an unexpected exception at fatal —
  # all via `$log`. Output is read on the thread, so this never blocks the caller.
  #
  # @param command [String] the command to run
  # @return [Thread] the thread executing the command; call {Thread#join} to await it
  def self.async(command)
    _stdin, combined_output, wait_thr = Open3.popen2e(command)

    Thread.new do
      status = wait_thr.value
      output = combined_output.read

      if status.success?
        $log.debug("'#{command}': OK")
      else
        $log.error("'#{command}' failed with #{status.exitstatus}: #{output}")
      end
    rescue StandardError => e
      $log.fatal("Fatal error running '#{command}'", e)
    ensure
      combined_output.close
    end
  end

  # Runs `command` synchronously and returns its stdout, printing nothing itself.
  #
  # @param command [String] the command to run
  # @return [String] the command's stdout, on exit code 0
  # @raise [RuntimeError] if the command exits non-zero; the message includes the exit
  #   status and the captured stderr
  def self.sync(command)
    stdout, stderr, status = Open3.capture3(command)
    raise "Command '#{command}' failed with #{status.exitstatus}: #{stderr}" unless status.success?

    stdout
  end
end
