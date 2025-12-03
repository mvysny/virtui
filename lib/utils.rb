# frozen_string_literal: true

require 'open3'

# Replacement for all exec methods. Raise error if the command not found or fails.
module Run
  # Runs command asynchronously, logging stderr lazily once it fails.
  # The function terminates immediately.
  # @param command [String] the command to run
  # @return [Thread] executing the command. Call [Thread.join] to wait for the result.
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

# Pretty-format bytes with suffixes like k, m, g (for KiB, MiB, GiB), showing one decimal place when needed.
# @param bytes [Integer] size in bytes
# @return [String] "1.0K", "23.8M", "8.0G" and such
def format_byte_size(bytes)
  return '0' if bytes.zero?
  return "-#{format_byte_size(-bytes)}" if bytes.negative?

  units = ['', 'K', 'M', 'G', 'T', 'P']

  # Use 1024-based units (KiB, MiB, etc.)
  exp = Math.log(bytes, 1024).floor
  exp = 5 if exp > 5 # Cap at petabytes

  value = bytes.to_f / (1024**exp)

  # Show one decimal if it's not a whole number, otherwise none
  decimals = value >= 10 || value.round == value ? 0 : 1
  "#{value.round(decimals)}#{units[exp]}"
end
