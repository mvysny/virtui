# frozen_string_literal: true

module Virt
  class BallooningVM
    # Votes to lower a VM's memory once the guest's own usage figure drops to a trigger —
    # the counterpart to {MemLevelRaiseVoter}, and the only voter that ever gives memory
    # back to the host.
    #
    # A vote is not a decision: this one is routinely overruled, because a comfortable
    # *reading* and a comfortable guest are not the same thing. {SwapOutShrinkVetoer} exists
    # for the case where the comfort is an artefact of the guest having just swapped.
    #
    # UI-thread-confined, like its owner.
    class MemLevelShrinkVoter
      # @param trigger_at [Integer] guest memory use, omitting cache, in percent, at or below
      #   which this votes to lower: {Config::Ballooning#shrink_at_percent}
      def initialize(trigger_at:)
        @trigger_at = trigger_at

        # {Integer | nil} the usage the latest sample reported, `nil` before the first one
        # or for a VM whose balloon reports no guest data.
        @percent_used = nil
      end

      # @param vm_cache [Cache::VMCache, nil] this tick's cache entry for the VM, or `nil`
      #   if the VM is unknown
      # @return [void]
      def observe(vm_cache)
        mem_stat = vm_cache&.data&.mem_stat
        @percent_used = mem_stat&.guest_mem&.percent_used
      end

      # @return [String, nil] why this VM's memory should be lowered, phrased to follow a
      #   colon; `nil` while the guest is using enough of it
      def vote_reason
        return nil if @percent_used.nil? || @percent_used > @trigger_at

        "usage is at or under the #{@trigger_at}% trigger"
      end

      # @return [String, nil] {#vote_reason} short enough for the VM pane's header:
      #   `"41% used"`
      def brief = vote_reason && "#{@percent_used}% used"

      # @return [void]
      def forget
        @percent_used = nil
      end
    end
  end
end
