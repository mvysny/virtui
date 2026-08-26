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
      def initialize
        # Guest memory usage (omitting cache), as a percentage, at or below which this votes
        # to lower. Must stay below {MemLevelRaiseVoter}'s trigger, or the two vote at once
        # on the same sample and the VM hunts — nothing enforces that but this line.
        #
        # The 10-point gap to that trigger is a deadband, and it is narrower than it looks:
        # raising by 30% takes a guest reading 65% straight down to 50%, five points *under*
        # this trigger, so a raise is followed by a shrink as soon as the back-off lapses.
        # See `ideas/swap-despite-ballooning.md` for the arithmetic.
        @trigger_at = 55

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

      # @return [void]
      def forget
        @percent_used = nil
      end
    end
  end
end
