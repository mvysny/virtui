# frozen_string_literal: true

# Controls memory of all VMs via the ballooning virt support. The VM must
# have ballooning support installed and enabled, see README for instructions.
#
# Must be called from UI only.
class Ballooning
  # @param virt_cache [VirtCache]
  def initialize(virt_cache)
    @virt_cache = virt_cache
    # maps {String} to {BallooningVM}
    @ballooning = {}
  end

  # Polls new data from {VirtCache} and controls the VMs.
  def update
    @ballooning = @virt_cache.domains.map do |domainid|
      [domainid, @ballooning[domainid] || BallooningVM.new(@virt_cache, domainid)]
    end.to_h
    @ballooning.each_value(&:update)
    log_statuses
  end

  # debug-logs statuses
  def log_statuses
    $log.debug do
      statuses = @ballooning.filter do |_vmid, ballooning|
        ballooning.was_running?
      end
      statuses = statuses.map { |vmid, ballooning| "#{vmid}: #{ballooning.status.text}" }.join "\n"
      "Ballooning: #{statuses}"
    end
  end

  # @param vm_name [String] vm name
  # @return [Status | nil] the VM ballooning status
  def status(vm_name)
    @ballooning[vm_name]&.status
  end

  # User can enable/disable ballooning per VM manually.
  # @param vm_name [String] vm name
  # @return [Boolean]
  def enabled?(vm_name)
    @ballooning[vm_name]&.enabled? || false
  end

  # @param vm_name [String]
  # @param enabled [Boolean]
  def enabled(vm_name, enabled)
    @ballooning[vm_name].enabled = !!enabled
  end

  def toggle_enable(vm_name)
    enabled(vm_name, !enabled?(vm_name))
  end
end
