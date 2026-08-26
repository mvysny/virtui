# frozen_string_literal: true

module Virt
  class BallooningVM
    # Votes to raise a VM's memory once the guest's own usage figure reaches a trigger. The
    # oldest of {BallooningVM}'s inputs and the only one that reads the guest's memory
    # *level* rather than a derived rate.
    #
    # Its blind spot is why the others exist: `percent_used` is
    # `(MemTotal - MemAvailable) / MemTotal`, and evicting anon pages to swap *raises*
    # `MemAvailable`, so a guest under real pressure can hold this figure still — or push it
    # down — while it pays disk I/O for the memory it lacks. See {SwapOutRaiseVoter}.
    #
    # UI-thread-confined, like its owner.
    class MemLevelRaiseVoter
      def initialize
        # Guest memory usage (omitting cache), as a percentage, at or above which this votes
        # to raise. Must stay above {MemLevelShrinkVoter}'s trigger, or the two vote at once
        # on the same sample and the VM hunts — nothing enforces that but this line.
        #
        # 65 leaves a 35% reserve, where MoM, Hyper-V and K8s VPA all use 15-20%. Do not
        # read it as `100 - vm.swappiness`, which is what it used to claim: swappiness
        # weights the anon LRU against the file LRU once reclaim has *already* been entered
        # and says nothing about when reclaim starts. A guest at 61% was measured holding
        # 2 GiB of swap — see `ideas/swap-despite-ballooning.md`.
        @trigger_at = 65

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

      # @return [String, nil] why this VM's memory should be raised, phrased to follow a
      #   colon; `nil` when the guest is comfortable
      def vote_reason
        return nil if @percent_used.nil? || @percent_used < @trigger_at

        "usage is at or over the #{@trigger_at}% trigger"
      end

      # @return [void]
      def forget
        @percent_used = nil
      end
    end
  end
end
