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
# never naming this class or {CanceledError}, so a backend call can take one without
# depending on where it lives.
#
# Thread-safe.
class Cancellation
  def initialize
    @lock = Mutex.new
    @canceled = false
  end

  # Marks the work canceled, for good. Idempotent.
  # @return [void]
  def cancel = @lock.synchronize { @canceled = true }

  # @return [Boolean] whether {#cancel} has been called
  def canceled? = @lock.synchronize { @canceled }

  # Raises once the work has been canceled; a no-op until then.
  # @raise [CanceledError] after {#cancel}
  # @return [void]
  def check_canceled
    raise CanceledError, 'canceled' if canceled?
  end
end
