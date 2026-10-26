# frozen_string_literal: true

module UI
  class VMPane
    # The `p` menu of {VMPane}: start, graceful shutdown, force off, soft reboot and hard
    # reset of one VM, and the magic-SysRq power-off and reboot between them (see
    # {Virt::MagicSysRq}).
    #
    #   PowerPickerWindow.new(virt_cache, 'vt-ubuntu').open_in_popup
    #
    #   ┌Power─────────────────────────────────────────┐
    #   │s Start (VM not stopped)                      │
    #   │o shut dOwn gracefully                        │
    #   │u sync, remoUnt ro, power off (SysRq)         │
    #   │O force Off                                   │
    #   │…                                             │
    #
    # What the VM's state or guest rules out is disabled. The menu is a snapshot, so each
    # action checks again and logs an error if the VM changed state since.
    #
    # UI-thread-confined.
    class PowerPickerWindow < Tuile::Component::PickerWindow
      # @param virt_cache [Virt::Cache] the runtime cache to read the VM's state from and act through
      # @param vm [String] the VM's name
      def initialize(virt_cache, vm)
        @virt_cache = virt_cache
        @vm = vm
        super('Power', options) { pick(_1) }
      end

      private

      # @return [Array<Array(String, String, Hash)>] the {Tuile::Component::PickerWindow} options
      def options
        state = @virt_cache.state(@vm)
        stopped = state == :shut_off ? {} : { disabled: 'VM not stopped' }
        running = state == :running ? {} : { disabled: 'VM not running' }
        refusal = sysrq_refusal
        sysrq = refusal.nil? ? {} : { disabled: refusal }
        [['s', 'Start', stopped], ['o', 'shut dOwn gracefully', running],
         ['u', 'sync, remoUnt ro, power off (SysRq)', sysrq], ['O', 'force Off', running],
         ['r', 'reboot (soft)', running], ['b', 'sync, remount ro, reBoot (SysRq)', sysrq],
         ['R', 'Reset (hard)', running]]
      end

      # @param key [String] the picked option's key
      # @return [void]
      def pick(key)
        return sysrq_power(reboot: key == 'b') if %w[u b].include?(key)

        virt = @virt_cache.virt
        state = @virt_cache.state(@vm)
        if key == 's'
          return $log.error("'#{@vm}' is already running") unless state == :shut_off

          $log.info "Starting '#{@vm}'"
          virt.start(@vm)
          return
        end
        return $log.error("'#{@vm}' is not running") unless state == :running

        case key
        when 'o'
          $log.info "Shutting down '#{@vm}' gracefully"
          virt.shutdown(@vm)
        when 'O'
          $log.info "Force off '#{@vm}'"
          virt.force_off(@vm)
        when 'r'
          $log.info "Asking '#{@vm}' to reboot"
          virt.reboot(@vm)
        when 'R'
          $log.info "Resetting '#{@vm}' forcefully"
          virt.reset(@vm)
        end
      end

      # @return [String, nil] why the SysRq items cannot end this VM, or `nil` if they can
      def sysrq_refusal
        return 'VM not running' unless @virt_cache.running?(@vm)

        entry = @virt_cache.cache(@vm)
        Virt::MagicSysRq.refusal(entry.guest_os, entry.sysrq_mask)
      end

      # Syncs, remounts read-only and powers off or reboots the VM through magic SysRq, behind
      # a popup that cannot be canceled: a guest left after U has every filesystem read-only.
      #
      # @param reboot [Boolean] B rather than O as the last key
      # @return [void]
      def sysrq_power(reboot:)
        refusal = sysrq_refusal
        return $log.error("'#{@vm}': no SysRq #{reboot ? 'reboot' : 'power-off'}: #{refusal}") unless refusal.nil?

        virt = @virt_cache.virt
        vm = @vm
        if reboot
          BackgroundTask.new("Rebooting #{vm} through SysRq", cancelable: false) { virt.sysrq_reboot(vm) }
                        .run { $log.info "'#{vm}' synced, remounted read-only and rebooted" }
        else
          BackgroundTask.new("Powering #{vm} off through SysRq", cancelable: false) { virt.sysrq_power_off(vm) }
                        .run { $log.info "'#{vm}' synced, remounted read-only and powered off" }
        end
      end
    end
  end
end
