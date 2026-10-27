# frozen_string_literal: true

module UI
  class VMPane
    # The `m` menu of {VMPane}: toggle one VM's automatic ballooning, or give it its maximum
    # memory and switch the ballooning off.
    #
    #   MemoryPickerDialog.new(virt_cache, ballooning, 'vt-ubuntu').open
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
    class MemoryPickerDialog < Tuile::Component::PickerDialog
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
