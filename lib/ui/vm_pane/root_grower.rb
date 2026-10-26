# frozen_string_literal: true

module UI
  class VMPane
    # Grows a running VM's root filesystem into the free space after it, the flow behind
    # `M` → Grow root filesystem and the health check's Fix button:
    #
    #   RootGrower.new(virt_cache.virt, 'vt-ubuntu').start
    #
    # Checks how the root would grow, asks the user to confirm the commands it runs in the
    # guest, then runs them behind a popup that cannot be canceled and reports the new size.
    # A guest whose layout or agent will not do gets the reason instead.
    #
    # UI-thread-confined.
    class RootGrower
      # @param virt [Virt::Virsh, Virt::VMEmulator] the backend
      # @param vm [String] the VM's name
      def initialize(virt, vm)
        @virt = virt
        @vm = vm
      end

      # Opens the first popup of the flow and returns; the rest follows on the user's answers.
      # @return [void]
      def start
        virt = @virt
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
          ) { grow(plan) }
        end
      end

      private

      # @param plan [Virt::GuestRootGrow::Plan]
      # @return [void]
      def grow(plan)
        virt = @virt
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
