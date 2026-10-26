# frozen_string_literal: true

module UI
  class VMPane
    # The `m` menu of {VMPane}: toggle one VM's automatic ballooning, or give it its maximum
    # memory and switch the ballooning off.
    #
    #   MemoryPickerWindow.open(virt_cache, ballooning, 'vt-ubuntu')
    #
    #   ┌Memory──────────────────────────────────┐
    #   │b toggle autoBallooning                 │
    #   │m Max memory & disable autoballooning   │
    #   └────────────────────────────────────────┘
    #
    # Both need the VM running and are disabled otherwise. The menu is a snapshot, so a pick
    # checks again and logs an error if the VM stopped since.
    #
    # UI-thread-confined.
    class MemoryPickerWindow < Tuile::Component::PickerWindow
      # @param virt_cache [Virt::Cache] the runtime cache to read the VM's state from and act through
      # @param ballooning [Virt::Ballooning] the ballooning controller to toggle
      # @param vm [String] the VM's name
      def initialize(virt_cache, ballooning, vm)
        @virt_cache = virt_cache
        @ballooning = ballooning
        @vm = vm
        running = virt_cache.running?(vm) ? {} : { disabled: 'VM not running' }
        super('Memory', [['b', 'toggle autoBallooning', running],
                         ['m', 'Max memory & disable autoballooning', running]]) { pick(_1) }
      end

      # Opens the menu as a modal popup that closes after a pick.
      #
      # @param virt_cache [Virt::Cache] see {#initialize}
      # @param ballooning [Virt::Ballooning] see {#initialize}
      # @param vm [String] see {#initialize}
      # @return [Tuile::Component::Popup] the opened popup
      def self.open(virt_cache, ballooning, vm)
        # Not PickerWindow.open, which builds a plain PickerWindow (tuile#72).
        picker = new(virt_cache, ballooning, vm)
        popup = Tuile::Component::Popup.new(content: picker)
        picker.on_pick { popup.close }
        popup.open
      end

      private

      # @param key [String] the picked option's key
      # @return [void]
      def pick(key)
        return $log.error("'#{@vm}' is not running") unless @virt_cache.running?(@vm)

        if key == 'b'
          $log.info "Toggling ballooning for '#{@vm}'"
          @ballooning.toggle_enable(@vm)
        elsif key == 'm'
          max_memory = @virt_cache.info(@vm).max_memory
          $log.info "Disabling ballooning & giving max mem (#{format_byte_size(max_memory)}) to '#{@vm}'"
          @ballooning.enabled(@vm, false)
          @virt_cache.set_actual(@vm, max_memory)
        end
      end
    end
  end
end
