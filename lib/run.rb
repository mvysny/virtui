# frozen_string_literal: true

# Replacement for all exec methods - fails eagerly and cleanly when the command goes wrong.
# Raises error if the command not found or fails.
module Run
  # Runs command asynchronously, logging stderr lazily once it fails.
  # The function terminates immediately.
  # @param command [String] the command to run
  # @return [Thread] executing the command. Call {Thread.join} to wait for the result.
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

  # Runs command synchronously, printing nothing to STDOUT nor STDERR.
  # If the command runs successfully (exit code 0), STDOUT is returned.
  # If the command fails to run, exception is thrown with STDERR.
  # @param command [String] the command to run
  # @return [String] stdout
  def self.sync(command)
    stdout, stderr, status = Open3.capture3(command)
    raise "Command '#{command}' failed with #{status.exitstatus}: #{stderr}" unless status.success?

    stdout
  end
end
