# frozen_string_literal: true

# A cancel flag shared by the thread that cancels some work and the thread doing it. Work
# that takes a while checks it between its steps:
#
#   UI::BackgroundTask.new('Reading the VMs') do |cancel|
#     vms.map { |vm| cancel.check_canceled; virt.guest_os(vm) }
#   end.run { |oses| ... }
#
# A wait the work blocks in has a cancelable twin here, raising the moment the work is
# canceled; the next one the work needs belongs here too:
#
#   cancel.sleep(2)            # Kernel#sleep
#   cancel.join(wait_thr)      # Thread#join
#
# Cooperative: work that neither checks nor waits here runs to its end. Code handed one only
# calls its methods, never naming this class, so a backend call can take one without
# depending on where it lives.
#
# Thread-safe.
class Cancellation
  # Raised by {Cancellation#check_canceled}: the user canceled the work, and nothing failed.
  #
  # An `Exception`, not a `StandardError`, so a `rescue => e` between the check and whatever
  # runs the work cannot swallow the cancel; `ensure` blocks still run.
  class CanceledError < Exception # rubocop:disable Lint/InheritException
  end

  # How often {#join} looks at the flag: a cancel feels instant under about 100 ms, and a
  # look this often costs nothing.
  # @return [Float] seconds
  POLL_INTERVAL = 0.1

  def initialize
    # An Event, not an AtomicBoolean: a cancelable wait can block on it and wake the moment
    # it is set, where a boolean would have to be polled.
    @event = Concurrent::Event.new
  end

  # Marks the work canceled, for good. Idempotent.
  # @return [void]
  def cancel = @event.set

  # @return [Boolean] whether {#cancel} has been called
  def canceled? = @event.set?

  # Raises once the work has been canceled; a no-op until then.
  # @raise [CanceledError] after {#cancel}
  # @return [void]
  def check_canceled
    raise CanceledError, 'canceled' if canceled?
  end

  # `Kernel#sleep` that wakes and raises the moment the work is canceled.
  #
  #   cancel.sleep(2)   # pause before a retry, unless the user gives up meanwhile
  #
  # @param seconds [Numeric] how long to sleep
  # @raise [CanceledError] once canceled, at once rather than when `seconds` are up
  # @return [void]
  def sleep(seconds)
    @event.wait(seconds)
    check_canceled
  end

  # `Thread#join` that raises once the work is canceled.
  #
  #   status = cancel.join(wait_thr).value
  #
  # **It stops the waiting, not the thread**: after a cancel, `thread` runs on, and whoever
  # started it stops it. A cancel shows within {POLL_INTERVAL}, since nothing reports the end
  # of an arbitrary thread.
  #
  # @param thread [Thread] the thread to wait for
  # @raise [CanceledError] once canceled, with `thread` possibly still running
  # @raise [Exception] whatever `thread` died of, re-raised as `Thread#join` does
  # @return [Thread] `thread`, ended
  def join(thread)
    check_canceled
    check_canceled until thread.join(POLL_INTERVAL)
    thread
  end
end
