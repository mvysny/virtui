# frozen_string_literal: true

module UI
  class VMPane
    # The `M` menu of {VMPane}: resize one VM's disk image, grow its root filesystem, or check
    # its health.
    #
    #   MaintenancePickerDialog.new(virt_cache, 'vt-ubuntu').open
    #
    #   ┌Maintenance──────────────────────────────────────────┐
    #   │r Resize disk image… (shut the VM down first)        │
    #   │g Grow root filesystem…                              │
    #   │h Health check… (full scan: VM running)              │
    #   └─────────────────────────────────────────────────────┘
    #
    # Resizing needs the VM shut off and growing needs it running, so the one the state rules
    # out is disabled. The health check never is: a stopped VM is judged by its definition
    # alone. The menu is a snapshot, so a VM that changed state since gets an alert instead.
    #
    # UI-thread-confined.
    class MaintenancePickerDialog < Tuile::Component::PickerDialog
      # @param virt_cache [Virt::Cache] the runtime cache to read the VM's state from
      # @param vm [String] the VM's name
      def initialize(virt_cache, vm)
        @virt_cache = virt_cache
        @vm = vm
        state = virt_cache.state(vm)
        super('Maintenance',
              [['r', 'Resize disk image…', state == :shut_off ? {} : { disabled: 'shut the VM down first' }],
               ['g', 'Grow root filesystem…', state == :running ? {} : { disabled: 'start the VM first' }],
               ['h', 'Health check… (full scan: VM running)', {}]]) { pick(_1) }
      end

      private

      # @param key [String] the picked option's key
      # @return [void]
      def pick(key)
        virt = @virt_cache.virt
        vm = @vm
        state = @virt_cache.state(vm)
        if key == 'h'
          BackgroundTask.new("Checking #{vm}'s health") { virt.health(vm) }.run { HealthDialog.new(virt, vm, _1).open }
        elsif key == 'r' && state == :shut_off
          DiskResizeDialog.start(virt, vm)
        elsif key == 'r'
          Tuile::Component::ConfirmDialog.alert('Resize disk image', "Shut #{vm} down first: a running VM's " \
                                                                     'disk image cannot be resized.')
        elsif key == 'g' && state == :running
          RootGrower.new(virt, vm).start
        elsif key == 'g'
          Tuile::Component::ConfirmDialog.alert('Grow root filesystem', "Start #{vm} first: its root filesystem " \
                                                                        'is grown from inside the running guest.')
        end
      end
    end
  end
end
