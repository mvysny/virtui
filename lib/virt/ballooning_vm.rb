# frozen_string_literal: true

module Virt
  # Auto-scales the memory of a single VM by polling a set of *inputs* and acting on what
  # they say. Call {#update} every ~2s.
  #
  # == The inputs
  #
  # Each input is a small object under `lib/virt/ballooning_vm/`, fed this tick's
  # {Cache::VMCache} via `observe` and asked one question, which it answers with a `String`
  # reason or `nil` for "no opinion". There are two kinds:
  #
  # - a **voter** (`vote_reason`) asks for a change — {MemLevelRaiseVoter},
  #   {SwapOutRaiseVoter} on the raise side, {MemLevelShrinkVoter} on the lower side;
  # - a **vetoer** (`veto_reason`) blocks one — {SwapOutShrinkVetoer},
  #   {BackOffShrinkVetoer}, both against lowering.
  #
  # The division of labour: **an input decides *whether* and says *why*; this class decides
  # *how much*.** So every threshold lives on the input that reads it and every rate lives
  # here, and a new consideration arrives as another class in one of the lists rather than
  # as another branch in {#update}.
  #
  # == The rules
  #
  # 1. Any raise vote wins outright — a VM that needs RAM needs it now, and nothing vetoes
  #    a raise.
  # 2. Otherwise a lower needs a voter for it *and* no vetoer against it.
  # 3. Otherwise nothing happens.
  #
  # Asymmetric on purpose, and rule 1 is where the asymmetry lives: raises are immediate and
  # unopposed, lowering is voted, vetoable and rate-limited.
  #
  # Does nothing at all if the VM lacks ballooning support, is shut off, reports stale data,
  # or the user has disabled it. Memory never drops below {#min_actual} nor rises above the
  # VM's configured maximum. `README.md` states the resulting behaviour for users.
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

      # How much to raise by, as a percentage: 30 means the actual goes to 130%. No
      # back-off gates it, so this is also a velocity — one hop per new guest sample, i.e.
      # roughly one per 5s. See DECISIONS.md D-swap-raise-vote for what that costs.
      @increase_memory_by = 30

      # How much to lower by, as a percentage: 10 means the actual goes to 90%. Deliberately
      # a third of the raise, and gated by {BackOffShrinkVetoer} on top.
      @decrease_memory_by = 10

      # How long to veto lowering after we change a VM's memory, in seconds. A Linux guest
      # applies a decrease gradually, over 5..15 seconds depending on how big it is;
      # stacking another decrease on top before it settles would compound blindly. 10s is
      # enough because we only ever decrease by 10%, which lands at the fast end.
      @back_off_seconds = 10

      # Same, after a VM starts — booting takes ~15s, and the guest's memory figures mean
      # nothing until it's up.
      @boot_back_off_seconds = 20

      @back_off = BackOffShrinkVetoer.new
      @raise_voters = [MemLevelRaiseVoter.new, SwapOutRaiseVoter.new]
      @shrink_voters = [MemLevelShrinkVoter.new]
      # The guest's own objection first: it says more than "we just did something".
      @shrink_vetoers = [SwapOutShrinkVetoer.new, @back_off]
      @inputs = @raise_voters + @shrink_voters + @shrink_vetoers

      # We don't know what state the VM is in — it could have been started seconds ago.
      @back_off.arm @boot_back_off_seconds

      # {Boolean} if the VM was running during the last ballooning update
      @was_running = false

      # {Integer | nil} {MemoryStat#last_updated} of the data the last decision was made
      # on; guards against acting twice on the same guest sample.
      @last_update_at = nil

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

    # Enables or disables automatic ballooning for this VM. Clears the back-off so the
    # user's manual change takes effect on the next {#update}.
    #
    # @param enabled [Boolean] `true` to enable, `false` to disable
    def enabled=(enabled)
      @enabled = !!enabled
      @back_off.forget # This is user manual action, user wants to see effects now.
    end

    # Runs one control step: feeds every input this tick's data, applies the rules above,
    # and records what happened in {#status}.
    #
    # @return [void]
    # @raise [RuntimeError] if the VM is running but its {DomainInfo} can't be found
    def update
      unless @enabled
        @status = Status.new('ballooning disabled by user', 0)
        reset
        return
      end

      mem_stat = @virt_cache.memstat(@vmid)
      if mem_stat.nil? || !@virt_cache.running?(@vmid)
        # VM is shut off. Don't fiddle with the memory. Back off until it boots up.
        @status = Status.new('vm stopped, doing nothing', 0)
        reset
        @back_off.arm @boot_back_off_seconds
        return
      end

      @was_running = true

      # If the VM has no support for ballooning, do nothing
      unless mem_stat.guest_data_available?
        @status = Status.new('ballooning unsupported by the VM', 0)
        return
      end

      # Don't act on stale guest data — e.g. just after the VM started, before it completes
      # its first stats collection cycle, the numbers still reflect a nearly-empty boot-time
      # guest. Resizing on those would wrongly shrink a VM that's actually busy.
      vm_cache = @virt_cache.cache(@vmid)
      if vm_cache&.stale?
        @status = Status.new('guest memory data is stale, doing nothing', 0)
        return
      end

      # Ahead of the guards below: an input's clock must advance on every sample, not only
      # on the ones whose decision reaches it.
      @inputs.each { |it| it.observe vm_cache }

      # Check whether we already did some action (mem increase/decrease) on this VM data.
      if @last_update_at == mem_stat.last_updated
        @status = Status.new('no new data', 0)
        return
      end

      decide mem_stat
    end

    private

    # Polls the inputs, applies the three rules and carries out whatever they call for.
    #
    # @param mem_stat [MemoryStat] this tick's guest memory stats
    # @return [void]
    # @raise [RuntimeError] if the VM's {DomainInfo} can't be found
    def decide(mem_stat)
      report = "VM reports #{format_byte_size(mem_stat.guest_mem.used)} (#{mem_stat.guest_mem.percent_used}%)"

      raises = @raise_voters.filter_map(&:vote_reason)
      # Only asked when nothing wants a raise, and the vetoers only when something wants a
      # lower: a reason nobody acts on has no business in the status line.
      lowers = raises.empty? ? @shrink_voters.filter_map(&:vote_reason) : []
      veto = lowers.empty? ? nil : @shrink_vetoers.filter_map(&:veto_reason).first

      if !raises.empty?
        resize mem_stat, @increase_memory_by, report, raises
      elsif !veto.nil?
        @status = Status.new("#{report}, not lowering memory: #{veto}", 0)
      elsif !lowers.empty?
        resize mem_stat, -@decrease_memory_by, report, lowers
      else
        @status = Status.new("#{report}, nothing to do", 0)
      end
    end

    # Applies one change of `memory_delta` percent, or explains why it can't be applied.
    #
    # @param mem_stat [MemoryStat] this tick's guest memory stats
    # @param memory_delta [Integer] percentage change: positive raises, negative lowers
    # @param report [String] what the guest reported, for the status line
    # @param because [Array<String>] the reasons the voters gave
    # @return [void]
    # @raise [RuntimeError] if the VM's {DomainInfo} can't be found
    def resize(mem_stat, memory_delta, report, because)
      info = @virt_cache.info(@vmid)
      raise 'unexpected: info is nil' if info.nil?

      max_memory = info.max_memory
      if @min_actual > max_memory
        @status = Status.new("VM max memory #{max_memory} is below min_actual #{@min_actual}, doing nothing", 0)
        return
      end

      new_actual = (mem_stat.actual * (memory_delta + 100) / 100).clamp(@min_actual.clamp(nil, max_memory)..max_memory)
      if new_actual == mem_stat.actual
        @status = if memory_delta.positive?
                    Status.new("#{report}, want to raise memory (#{because.join(', ')}) but can't go over " \
                               "configured max mem #{format_byte_size(new_actual)}", 0)
                  else
                    Status.new("New actual #{format_byte_size(new_actual)} is the same as current one " \
                               "#{format_byte_size(mem_stat.actual)}, doing nothing", 0)
                  end
        return
      end

      @back_off.arm @back_off_seconds
      @status = Status.new(
        "#{report}, #{memory_delta.positive? ? 'raising' : 'lowering'} memory by #{memory_delta.abs}% to " \
        "#{format_byte_size(new_actual)}: #{because.join(', ')}", memory_delta
      )
      @last_update_at = mem_stat.last_updated
      @virt_cache.set_actual(@vmid, new_actual)
    end

    # Forgets everything observed about a VM we are no longer steering — it is stopped, or
    # the user switched ballooning off. Its guest's counters reset with it, so nothing seen
    # before applies to the next boot.
    #
    # @return [void]
    def reset
      @inputs.each(&:forget)
      @last_update_at = nil
      @was_running = false
    end
  end
end
