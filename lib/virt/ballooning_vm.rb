# frozen_string_literal: true

module Virt
  # Auto-scales the memory of a single VM based on its guest memory usage. Asymmetric on
  # purpose: {#update} grows the VM at once when the guest is running short, and shrinks it
  # slowly and rate-limited when the guest is comfortable — a VM that needs RAM needs it
  # now, a VM that has spare RAM can give it back at leisure.
  #
  # A third state sits between the two: while {SwapOutShrinkVetoer} objects, decreases are
  # off the table entirely. Every threshold and rate that decision needs lives on the
  # vetoer, not here — it is the first of what will be several such inputs, so a new veto
  # or hint arrives as its own class under `lib/virt/ballooning_vm/` rather than as more
  # ivars on this one.
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

      # start by backing off. We don't know what state the VM is in - it could have been
      # just started seconds ago.
      back_off duration_seconds: @boot_back_off_seconds

      # {Boolean} if the VM was running during the last ballooning update
      @was_running = false

      # {Integer | nil} {MemoryStat#last_updated} of the data the last decision was made
      # on; guards against acting twice on the same guest sample.
      @last_update_at = nil

      # {SwapOutShrinkVetoer} the sole thing standing between a swapping guest and a
      # shrink; owns its own thresholds and state.
      @shrink_vetoer = SwapOutShrinkVetoer.new

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
        @shrink_vetoer.forget
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
        @shrink_vetoer.forget
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

      # Ahead of every branch — see {SwapOutShrinkVetoer#observe}.
      @shrink_vetoer.observe @virt_cache.cache(@vmid)

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
        # raises MemAvailable and so *lowers* percent_used ({SwapOutShrinkVetoer}).
        veto = @shrink_vetoer.veto_reason
        unless veto.nil?
          @status = Status.new("only #{percent_used}% memory used, but #{veto}", 0)
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
  end
end
