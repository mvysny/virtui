# frozen_string_literal: true

module Virt
  # Auto-scales the memory of a single VM based on its guest memory usage. Asymmetric on
  # purpose: {#update} grows the VM at once when the guest is running short, and shrinks it
  # slowly and rate-limited when the guest is comfortable — a VM that needs RAM needs it
  # now, a VM that has spare RAM can give it back at leisure.
  #
  # A third state sits between the two: while the guest is seen writing to swap, decreases
  # are vetoed outright. Swapping *lowers* the usage figure this class steers by, so
  # without the veto a swapping guest reads as a comfortable one and gets shrunk — see
  # DECISIONS.md D-swap-shrink-veto.
  #
  # Does nothing if the VM lacks ballooning support, is shut off, reports stale data, or
  # the user has disabled it. Memory never drops below {#min_actual} nor rises above the
  # VM's configured maximum. Every threshold and rate is an ivar set in the constructor,
  # documented next to its value; `README.md` states the resulting behaviour for users.
  #
  # UI-thread-confined.
  class BallooningVM
    # @param virt_cache [Cache] the runtime cache to read VM data from and act through
    # @param vmid [String] the VM name
    def initialize(virt_cache, vmid)
      @virt_cache = virt_cache
      @vmid = vmid
      # 8 GiB: a healthy minimum for a desktop guest. See {#min_actual}.
      @min_actual = 8.GiB
      # How long to leave a VM alone after decreasing its memory, in seconds. A Linux guest
      # applies a decrease gradually, over 5..15 seconds depending on how big it is;
      # stacking another decrease on top before it settles would compound blindly. 10s is
      # enough because we only ever decrease by 10%, which lands at the fast end.
      @back_off_seconds = 10

      # Grace period after a VM starts, in seconds — booting takes ~15s, and the guest's
      # memory figures mean nothing until it's up.
      @boot_back_off_seconds = 20

      # When the guest mem usage (omitting cache) is above this value, increase guest memory.
      # To prevent client swapping, set this lower than `100 - guest vm.swappiness`
      @trigger_increase_at = 65

      # When increasing memory, increase by how much.
      # A percentage value; 30 means that the actual will be increased to 130%.
      @increase_memory_by = 30

      # When the guest mem usage (omitting cache) is below this, start decreasing guest memory
      @trigger_decrease_at = 55

      # When decreasing memory, decrease by how much.
      # A percentage value; 10 means that the actual will be decreased to 90%.
      @decrease_memory_by = 10

      # Guest swap-out rate, in bytes per second, above which a sample counts as "this
      # guest is swapping" and vetoes a decrease. A noise floor, not a tuned threshold:
      # watched across the fleet on 2026-08-21 the rate is exactly 0 unless something is
      # genuinely happening, so anything between a handful of pages and a fraction of a
      # balloon block per second behaves identically. 1 MiB/s is ~256 pages/s — far above
      # one aging pass, ~1/100th of the ~125 MiB/s an IDE start-up produces.
      @swap_out_noise_floor = 1.MiB

      # How long one over-floor sample vetoes decreases for, in seconds. Not "while the
      # rate is non-zero": a guest that just swapped and went quiet is the one that least
      # wants shrinking, because it has not yet faulted its working set back. 60s covers
      # ~12 guest samples and 2-3x the ~10-25s burst measured on 2026-08-26, and is
      # deliberately finite — swap *level* is a high-water scar, so "still holding swap"
      # would veto forever. See DECISIONS.md D-swap-shrink-veto.
      @swap_veto_seconds = 60

      # start by backing off. We don't know what state the VM is in - it could have been
      # just started seconds ago.
      back_off duration_seconds: @boot_back_off_seconds

      # {Boolean} if the VM was running during the last ballooning update
      @was_running = false

      # {Integer | nil} {MemoryStat#last_updated} of the data the last decision was made
      # on; guards against acting twice on the same guest sample.
      @last_update_at = nil

      # {Time | nil} until when decreases are vetoed because the guest was seen swapping;
      # {Integer | nil} the sample that armed it, so one sample arms it once.
      @swapping_until = nil
      @last_swap_sample_at = nil

      # {Boolean} the user can manually disable ballooning for a VM.
      @enabled = true

      # {Status}
      @status = Status.new('', 0)
    end

    # @return [Integer] floor for the VM's `actual` memory, in bytes; QEMU's own overhead
    #   means the guest OS sees somewhat less
    attr_accessor :min_actual

    # The outcome of one ballooning {#update} for a VM: a human-readable explanation and
    # the percentage change applied.
    #
    # @!attribute [r] text
    #   @return [String] human-readable description of the decision, for debug logging
    # @!attribute [r] memory_delta
    #   @return [Integer] percentage change applied: `0` for no change, positive for an
    #     increase, negative for a decrease
    class Status < Data.define(:text, :memory_delta)
      # @return [String] `text; d=memory_delta`
      def to_s = "#{text}; d=#{memory_delta}"
    end

    # @return [Status] the status of this ballooner.
    attr_reader :status

    # @return [Boolean] true if automatic ballooning is enabled.
    def enabled? = @enabled

    # @return [Boolean] if the VM was running during the last ballooning update
    def was_running? = @was_running

    # Enables or disables automatic ballooning for this VM. Clears any active back-off so
    # the user's manual change takes effect on the next {#update}.
    #
    # @param enabled [Boolean] `true` to enable, `false` to disable
    def enabled=(enabled)
      @enabled = !!enabled
      @back_off_until = nil # This is user manual action, user wants to see effects now.
    end

    # Runs one control step: reads the VM's current memory stats and increases, decreases,
    # or leaves its memory unchanged, recording the decision in {#status}. Call every ~2s.
    #
    # @return [void]
    # @raise [RuntimeError] if the VM is running but its {DomainInfo} can't be found
    def update
      unless @enabled
        @status = Status.new('ballooning disabled by user', 0)
        @back_off_until = nil
        @last_update_at = nil
        @was_running = false
        forget_swapping
        return
      end

      mem_stat = @virt_cache.memstat(@vmid)
      if mem_stat.nil? || !@virt_cache.running?(@vmid)
        # VM is shut off. Don't fiddle with the memory.
        # Mark as back_off - this way we'll back off from the VM until it boots up.
        back_off duration_seconds: @boot_back_off_seconds
        @status = Status.new('vm stopped, doing nothing', 0)
        @was_running = false
        @last_update_at = nil
        # The counters reset with the guest, so nothing observed before the stop applies
        # to the next boot.
        forget_swapping
        return
      end

      @was_running = true

      # If the VM has no support for ballooning, do nothing
      unless mem_stat.guest_data_available?
        @status = Status.new('ballooning unsupported by the VM', 0)
        return
      end

      # Don't act on stale guest data — e.g. just after the VM started, before it
      # completes its first stats collection cycle, the numbers still reflect a nearly-empty
      # boot-time guest. Resizing on those would wrongly shrink a VM that's actually busy.
      if @virt_cache.cache(@vmid)&.stale?
        @status = Status.new('guest memory data is stale, doing nothing', 0)
        return
      end

      # Ahead of every branch: the veto's clock must advance on each guest sample, not
      # only on the samples whose decision happens to reach the decrease branch.
      note_swapping mem_stat

      # Check whether we already did some action (mem increase/decrease) on
      # this VM data.
      if @last_update_at == mem_stat.last_updated
        @status = Status.new('no new data', 0)
        return
      end

      # 0..100
      percent_used = mem_stat.guest_mem.percent_used
      used_mem = mem_stat.guest_mem.used

      # delta percent by which we'll modify the memory available to the VM.
      # -10% means we'll decrease by 10%, +30% will increase by 30%.
      memory_delta = 0

      if percent_used >= @trigger_increase_at
        # No back-off on the way up: we sample every 2s at best, so by the time a demand
        # spike shows up here the guest may already be swapping.
        memory_delta = @increase_memory_by
      elsif percent_used <= @trigger_decrease_at
        # A guest that has been swapping is the last one that should have memory taken
        # away — and it is precisely the guest that asks for it, since evicting anon pages
        # raises MemAvailable and so *lowers* percent_used. Shrinking here would cement the
        # swapping instead of undoing it. See DECISIONS.md D-swap-shrink-veto.
        if swapping?
          @status = Status.new(
            "only #{percent_used}% memory used, but the guest swapped recently; holding its " \
            "memory for #{(@swapping_until - Time.now).round(1)}s", 0
          )
          return
        end
        # decrease memory slowly. We use back_off period to slow down memory decrease.
        if backing_off?
          @status = Status.new(
            "only #{percent_used}% memory used, but backing off for #{(@back_off_until - Time.now).round(1)}s", 0
          )
          return
        end
        memory_delta = -@decrease_memory_by
      end

      # Return early if nothing to do
      if memory_delta.zero?
        @status = Status.new("app memory in sweet spot (#{percent_used}%), doing nothing", 0)
        return
      end

      info = @virt_cache.info(@vmid)
      raise 'unexpected: info is nil' if info.nil?

      # calculate min/max memory
      max_memory = info.max_memory
      if @min_actual > max_memory
        @status = Status.new("VM max memory #{max_memory} is below min_actual #{@min_actual}, doing nothing", 0)
        return
      end

      min_memory = @min_actual.clamp(nil, max_memory)
      new_actual = mem_stat.actual * (memory_delta + 100) / 100
      new_actual = new_actual.clamp(min_memory..max_memory)
      if new_actual == mem_stat.actual
        @status = if memory_delta.positive?
                    Status.new(
                      "I want to increase memory (current usage of #{percent_used}% is over " \
                      "trigger #{@trigger_increase_at}%) but can't go over configured max mem " \
                      "#{format_byte_size(new_actual)}", 0
                    )
                  else
                    Status.new(
                      "New actual #{format_byte_size(new_actual)} is the same as current one " \
                      "#{format_byte_size(mem_stat.actual)}, doing nothing", 0
                    )
                  end
        return
      end

      back_off

      @status = Status.new(
        "VM reports #{format_byte_size(used_mem)} (#{percent_used}%), updating actual by " \
        "#{memory_delta}% to #{format_byte_size(new_actual)}", memory_delta
      )
      @last_update_at = mem_stat.last_updated
      @virt_cache.set_actual(@vmid, new_actual)
    end

    private

    # Suppresses memory *decreases* until `duration_seconds` from now; extends an active
    # back-off, never shortens it.
    #
    # @param duration_seconds [Integer] how long to stay off this VM
    # @return [void]
    def back_off(duration_seconds: @back_off_seconds)
      back_off_until = Time.now + duration_seconds
      @back_off_until = back_off_until if @back_off_until.nil? || @back_off_until < back_off_until
    end

    # @return [Boolean] true if we are backing off from issuing any further memory decrease commands.
    def backing_off?
      !@back_off_until.nil? && Time.now < @back_off_until
    end

    # Re-arms the shrink veto if this sample caught the guest writing to swap. A no-op for
    # a sample already seen, so the veto measures guest time rather than poll count, and
    # for a guest whose balloon reports no swap counters (see
    # {MemoryStat#swap_data_available?}) — such a VM balloons exactly as before.
    #
    # @param mem_stat [MemoryStat] this tick's guest memory stats
    # @return [void]
    def note_swapping(mem_stat)
      return if @last_swap_sample_at == mem_stat.last_updated

      @last_swap_sample_at = mem_stat.last_updated
      rate = @virt_cache.cache(@vmid)&.swap_out_rate
      @swapping_until = Time.now + @swap_veto_seconds if !rate.nil? && rate >= @swap_out_noise_floor
    end

    # Drops the veto and the sample it was armed from, for a VM whose guest we are no
    # longer watching.
    #
    # @return [void]
    def forget_swapping
      @swapping_until = nil
      @last_swap_sample_at = nil
    end

    # @return [Boolean] true while decreases are vetoed because the guest was seen writing
    #   to swap within the last `@swap_veto_seconds`
    def swapping?
      !@swapping_until.nil? && Time.now < @swapping_until
    end
  end
end
