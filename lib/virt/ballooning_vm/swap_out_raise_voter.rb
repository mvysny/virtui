# frozen_string_literal: true

module Virt
  class BallooningVM
    # Votes to raise a VM's memory while its guest is writing pages to swap — memory it
    # wanted and did not have. One of {BallooningVM}'s inputs, not a decision-maker: it
    # answers {#vote_reason}, and {BallooningVM#update} decides how much memory that is
    # worth.
    #
    # Exists because a swapping guest cannot ask for memory through the figure
    # {BallooningVM} steers by: evicting anon pages *raises* `MemAvailable`, so the usage
    # figure falls exactly when the guest is suffering, and a guest can swap gigabytes
    # without it ever reaching the trigger. See DECISIONS.md D-swap-raise-vote.
    #
    # Independent of {SwapOutShrinkVetoer}, though both read the same counter, because they
    # ask different questions of it. The veto asks *has this guest swapped recently* and so
    # outlives the swapping by a minute; a vote to raise must ask *is it swapping now*,
    # since a hop per sample for a minute after the burst would multiply a VM several times
    # over in answer to something already finished. Each owns its own noise floor for the
    # same reason — a floor high enough to ignore a guest that trickles to swap benignly is
    # high enough to blind this vote to a real burst.
    #
    # UI-thread-confined, like its owner.
    class SwapOutRaiseVoter
      def initialize
        # Guest swap-out rate, in bytes per second, at or above which this votes to raise.
        # A noise floor rather than a tuned threshold: watched across the fleet on
        # 2026-08-21 the rate is exactly 0 unless something is genuinely happening, so
        # non-zero *is* the event. 1 MiB/s is ~256 pages/s — far above one aging pass,
        # ~1/100th of the ~125 MiB/s an IDE start-up produces. It is a separate constant
        # from {SwapOutShrinkVetoer}'s deliberately: on a guest that does trickle (zram,
        # MGLRU, a systemd `MemoryHigh=` slice) the two want to move in opposite directions.
        @noise_floor = 1.MiB

        # {Float | nil} the rate the last sample reported; `nil` before the first one, or
        # for a guest whose balloon carries no swap counters.
        @rate = nil
      end

      # Records one tick's rate. Unlike {SwapOutShrinkVetoer#observe} this needs no
      # once-per-guest-sample guard: it holds no timer to re-arm, and the rate a repeated
      # sample carries forward is the right answer to "is it swapping now" until a fresher
      # one lands. One hop per guest sample is {BallooningVM#update}'s own guard.
      #
      # @param vm_cache [Cache::VMCache, nil] this tick's cache entry for the VM, or `nil`
      #   if the VM is unknown
      # @return [void]
      def observe(vm_cache)
        @rate = vm_cache&.swap_out_rate
      end

      # @return [String, nil] why this VM's memory should be raised right now, phrased to
      #   follow a comma: `"the guest is swapping out 20M/s"`. `nil` when the guest is not
      #   swapping — the common case
      def vote_reason
        return nil if @rate.nil? || @rate < @noise_floor

        "the guest is swapping out #{format_byte_size(@rate.round)}/s"
      end

      # Drops what was observed, for a VM we are no longer watching (stopped, or ballooning
      # switched off). The guest's counters reset with it.
      #
      # @return [void]
      def forget
        @rate = nil
      end
    end
  end
end
