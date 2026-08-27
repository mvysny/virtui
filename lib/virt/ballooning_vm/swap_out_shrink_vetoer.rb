# frozen_string_literal: true

module Virt
  class BallooningVM
    # Vetoes memory *decreases* for a VM whose guest was recently seen writing to swap.
    # One of {BallooningVM}'s inputs, not a decision-maker: it answers {#veto_reason} and
    # {BallooningVM#update} decides what to do with the answer.
    #
    # Exists because swapping is invisible to the figure {BallooningVM} steers by. Evicting
    # anon pages *raises* `MemAvailable`, so a guest paying disk I/O for the memory it lacks
    # reads as one with memory to spare — and gets shrunk. See DECISIONS.md
    # D_swap_shrink_veto for why the veto keys on the swap-out *rate* rather than on how
    # full the guest's swap device is, and why it outlives the swapping by a minute.
    #
    # Stateful across calls: feed it every guest sample via {#observe}, in order.
    # UI-thread-confined, like its owner.
    class SwapOutShrinkVetoer
      def initialize
        # Guest swap-out rate, in bytes per second, at or above which a sample counts as
        # "this guest is swapping". A noise floor, not a tuned threshold: watched across the
        # fleet on 2026-08-21 the rate is exactly 0 unless something is genuinely happening,
        # so any value between a handful of pages and a fraction of a balloon block per
        # second behaves identically. 1 MiB/s is ~256 pages/s — far above one aging pass,
        # ~1/100th of the ~125 MiB/s an IDE start-up produces.
        @noise_floor = 1.MiB

        # How long one over-floor sample vetoes decreases for, in seconds. Not "while the
        # rate is non-zero": a guest that just swapped and went quiet is the one that least
        # wants shrinking, because it has not yet faulted its working set back. 60s covers
        # ~12 guest samples and 2-3x the ~10-25s burst measured on 2026-08-26, and is
        # deliberately finite — swap *level* is a high-water scar, so "still holding swap"
        # would veto forever.
        @veto_seconds = 60

        # {Cooldown} how long decreases stay vetoed;
        # {Integer | nil} {MemoryStat#last_updated} of the sample that armed it, so one
        # guest sample arms the veto once however many polls see it.
        @veto = Cooldown::ELAPSED
        @last_sample_at = nil
      end

      # Records one tick's evidence, re-arming the veto if this sample caught the guest
      # writing to swap. A no-op for a sample already seen — libvirt refreshes balloon data
      # every ~5s while we poll every ~2s, so most polls re-see the previous sample and must
      # not extend the veto — and for a guest whose balloon reports no swap counters
      # (see {MemoryStat#swap_data_available?}), which therefore balloons unaffected.
      #
      # Call on every tick, before any decision is taken: the veto's clock has to advance on
      # each sample, not only on the ticks whose decision reaches the shrink branch.
      #
      # @param vm_cache [Cache::VMCache, nil] this tick's cache entry for the VM, or `nil`
      #   if the VM is unknown
      # @return [void]
      def observe(vm_cache)
        mem_stat = vm_cache&.data&.mem_stat
        return if mem_stat.nil? || mem_stat.last_updated == @last_sample_at

        @last_sample_at = mem_stat.last_updated
        rate = vm_cache.swap_out_rate
        @veto = Cooldown.of(@veto_seconds) if !rate.nil? && rate >= @noise_floor
      end

      # @return [String, nil] why this VM's memory must not be decreased right now, phrased
      #   to follow a "but": `"the guest swapped recently; holding its memory for 58.3s"`.
      #   `nil` when there is no objection — the common case
      def veto_reason
        return nil unless @veto.active?

        "the guest swapped recently; holding its memory for #{@veto.remaining.round(1)}s"
      end

      # Drops the veto and the sample it was armed from, for a VM we are no longer watching
      # (stopped, or ballooning switched off). The guest's counters reset with it, so
      # nothing observed before applies to the next boot.
      #
      # @return [void]
      def forget
        @veto = Cooldown::ELAPSED
        @last_sample_at = nil
      end
    end
  end
end
