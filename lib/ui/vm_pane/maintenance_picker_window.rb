# frozen_string_literal: true

module UI
  class VMPane
    # The `M` menu of {VMPane}: resize one VM's disk image, grow its root filesystem, or check
    # its health.
    #
    #   MaintenancePickerWindow.new(virt_cache, 'vt-ubuntu').open_in_popup
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
    class MaintenancePickerWindow < Tuile::Component::PickerWindow
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
          BackgroundTask.new("Checking #{vm}'s health") { virt.health(vm) }.run { HealthWindow.open(vm, _1) }
        elsif key == 'r' && state == :shut_off
          DiskResizeWindow.start(virt, vm)
        elsif key == 'r'
          Tuile::Component::ConfirmWindow.alert('Resize disk image', "Shut #{vm} down first: a running VM's " \
                                                                     'disk image cannot be resized.')
        elsif key == 'g' && state == :running
          grow_root_filesystem
        elsif key == 'g'
          Tuile::Component::ConfirmWindow.alert('Grow root filesystem', "Start #{vm} first: its root filesystem " \
                                                                        'is grown from inside the running guest.')
        end
      end

      # Checks how the VM's root filesystem would grow, asks the user to confirm the commands it
      # runs in the guest, then runs them behind a popup that cannot be canceled and reports the
      # new size. A guest whose layout or agent will not do gets the reason instead.
      #
      # @return [void]
      def grow_root_filesystem
        virt = @virt_cache.virt
        vm = @vm
        check = BackgroundTask.new("Checking #{vm}'s root filesystem") do
          virt.root_grow_plan(vm)
        rescue Virt::GuestRootGrow::Refused, Virt::GuestAgent::Unavailable => e
          # virsh's own `error: …` line, not the `Command '…' failed` wrapper around it.
          e.message[/error: ([^\n]*)/, 1] || e.message
        end
        check.run do |plan|
          next Tuile::Component::ConfirmWindow.alert("Cannot grow #{vm}'s root filesystem", plan) if plan.is_a?(String)

          fs = plan.filesystem
          Tuile::Component::ConfirmWindow.confirm(
            "Grow #{vm}'s root filesystem?",
            "/ (#{fs.fstype} on #{plan.partition.name}, #{format_byte_size(plan.partition.size)}) grows by " \
            "#{format_byte_size(plan.growth)}, into the free space at the end of #{plan.disk.target}. This runs " \
            "#{plan.commands.map { _1[0][0] }.join(', ')} as root inside the guest, and cannot be canceled once " \
            'it starts.',
            confirm: 'Grow'
          ) { run_root_grow(plan) }
        end
      end

      # @param plan [Virt::GuestRootGrow::Plan]
      # @return [void]
      def run_root_grow(plan)
        virt = @virt_cache.virt
        vm = @vm
        # Not cancelable: the agent runs each command to its end whatever virtui does.
        task = BackgroundTask.new("Growing #{vm}'s root filesystem", cancelable: false) do
          virt.grow_root(vm, plan)
          virt.guest_storage(vm).disk(plan.disk.target).partitions.last
        end
        task.run do |partition|
          # The partition's size, as `df` shows it; the filesystem's own total leaves out ext4's reserve.
          root = partition.filesystems.first
          Tuile::Component::ConfirmWindow.alert("#{vm}'s / is now #{format_byte_size(partition.size)}",
                                                "#{format_byte_size(root.total - root.used)} of it free.")
        end
      end
    end
  end
end
