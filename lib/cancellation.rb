# frozen_string_literal: true

# A cancel flag shared by the thread that cancels some work and the thread doing it. Work
# that takes a while checks it between its steps:
#
#   UI::BackgroundTask.new('Reading the VMs') do |cancel|
#     vms.map { |vm| cancel.check_canceled; virt.guest_os(vm) }
#   end.run { |oses| ... }
#
# Cooperative: work that never checks runs to its end, and no check can interrupt a step
# blocked in a subprocess. Code handed one calls only {#canceled?} and {#check_canceled},
# never naming this class, so a backend call can take one without depending on where it
# lives.
#
# Thread-safe.
class Cancellation
  # Raised by {Cancellation#check_canceled}: the user canceled the work, and nothing failed.
  #
  # An `Exception`, not a `StandardError`, so a `rescue => e` between the check and whatever
  # runs the work cannot swallow the cancel; `ensure` blocks still run.
  class CanceledError < Exception # rubocop:disable Lint/InheritException
  end

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
end
