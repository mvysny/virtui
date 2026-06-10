# frozen_string_literal: true

module Virt
  # Auto-scales the memory of every VM via libvirt ballooning, delegating per-VM decisions
  # to one {BallooningVM} each. Each VM must have ballooning support installed and enabled
  # (see README).
  #
  # Reads from {Cache} and issues memory changes through it; must be called from the UI
  # thread only (never the background timer thread).
  class Ballooning
    # @param virt_cache [Cache] the runtime cache to read VM data from and act through
    def initialize(virt_cache)
      @virt_cache = virt_cache
      # Hash{String => BallooningVM}, keyed by VM name
      @ballooning = {}
    end

    # Refreshes the per-VM ballooners from {Cache} (adding any new VMs), runs one control
    # step on each, then debug-logs the outcome. Call every ~2 seconds.
    #
    # @return [void]
    def update
      @ballooning = @virt_cache.domains.to_h do |domainid|
        [domainid, @ballooning[domainid] || BallooningVM.new(@virt_cache, domainid)]
      end
      @ballooning.each_value(&:update)
      log_statuses
    end

    # Debug-logs the status of every running VM's ballooner.
    # @return [void]
    def log_statuses
      $log.debug do
        statuses = @ballooning.filter do |_vmid, ballooning|
          ballooning.was_running?
        end
        statuses = statuses.map { |vmid, ballooning| "#{vmid}: #{ballooning.status.text}" }.join "\n"
        "Ballooning: #{statuses}"
      end
    end

    # @param vm_name [String] VM name
    # @return [BallooningVM::Status, nil] the VM's latest ballooning status, or `nil` if
    #   the VM is unknown
    def status(vm_name)
      @ballooning[vm_name]&.status
    end

    # @param vm_name [String] VM name
    # @return [Boolean] whether automatic ballooning is currently enabled for the VM
    #   (`false` if the VM is unknown)
    def enabled?(vm_name)
      @ballooning[vm_name]&.enabled? || false
    end

    # Manually enables or disables automatic ballooning for one VM.
    #
    # @param vm_name [String] VM name
    # @param enabled [Boolean] `true` to enable, `false` to disable
    # @return [void]
    def enabled(vm_name, enabled)
      @ballooning[vm_name].enabled = !!enabled
    end

    # Flips the enabled state of one VM's ballooning.
    # @param vm_name [String] VM name
    # @return [void]
    def toggle_enable(vm_name)
      enabled(vm_name, !enabled?(vm_name))
    end
  end
end
