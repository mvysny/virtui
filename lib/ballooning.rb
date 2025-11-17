# frozen_string_literal: true

require_relative 'byte_prefixes'

# Controls all VMs.
class Ballooning
  # @param virt_cache [VirtCache]
  def initialize(virt_cache)
    @virt_cache = virt_cache
    # maps {String} to {BallooningVM}
    @ballooning = {}
  end

  # Polls new data from {VirtCache} and controls the VMs.
  def update
    @ballooning = @virt_cache.domains.map do |domainid|
      [domainid, @ballooning[domainid] || BallooningVM.new(@virt_cache, domainid)]
    end.to_h
    @ballooning.each_value(&:update)
    log_statuses
  end

  # debug-logs statuses
  def log_statuses
    $log.debug do
      statuses = @ballooning.filter do |_vmid, ballooning|
        ballooning.was_running?
      end
      statuses = statuses.map { |vmid, ballooning| "#{vmid}: #{ballooning.status.text}" }.join "\n"
      "Ballooning: #{statuses}"
    end
  end

  # @param vm_name [String] vm name
  # @return [Status | nil] the VM ballooning status
  def status(vm_name)
    @ballooning[vm_name]&.status
  end
end

# Controls the memory for one VM. The VM must support ballooning otherwise nothing is done.
# The memory upgrade is instant, but the memory downgrade happens only once awhile.
class BallooningVM
  # @param virt_cache [VirtCache]
  # @param vmid [String]
  def initialize(virt_cache, vmid)
    @virt_cache = virt_cache
    @vmid = vmid
    # don't go below 1GB
    @min_active = 1.GiB
    # After Ballooning decreases active memory, it will back off for 20 seconds
    # before trying to decrease the memory again. Observation shows that
    # the effects of the memory decrease command in Linux guest isn't instant: instead it is gradual, and takes
    # some time (5..15 seconds, depending on the difference in memory) to fully be applied. Let's not bother the VM with further
    # memory decrease commands until the VM fully settles in.
    #
    # 20 seconds is a safe bet, but we can use 10 seconds since we decrease memory gently, by 10% tops, which is fast.
    @back_off_seconds = 10

    # It takes ~15 seconds for a VM to start.
    @boot_back_off_seconds = 15

    # When the guest mem usage (ommitting cache) is above this value, increase guest memory
    @trigger_increase_at = 70

    # When increasing memory, increase by how much
    @increase_memory_by = 30

    # When the guest mem usage (ommitting cache) is below this, start decreasing guest memory
    @trigger_decrease_at = 60

    # When decreasing memory, decrease by how much
    @decrease_memory_by = 10

    # start by backing off. We don't know what state the VM is in - it could have been
    # just started seconds ago.
    back_off duration_seconds: @boot_back_off_seconds

    # {Boolean} if the VM was running during the last ballooning update
    @was_running = false

    # {Integer | nil} the value of {MemStat.last_updated} or nil
    @last_update_at = nil
  end

  # - `text` [String] textual representation of the change, useful for debug purposes.
  # - `memory_delta` [Integer] no change applied to memory if zero; memory increased if positive; memory decreased if negative.
  class Status < Data.define(:text, :memory_delta)
    def to_s
      "#{text}; d=#{memory_delta}"
    end
  end

  # @return [Status | nil]
  attr_reader :status

  def was_running?
    @was_running
  end

  # Call every 2 seconds, to control the VM
  def update
    mem_stat = @virt_cache.memstat(@vmid)
    if mem_stat.nil? || !@virt_cache.running?(@vmid)
      # VM is shut off. Don't fiddle with the memory.
      # Mark as back_off - this way we'll back off from the VM until it boots up.
      back_off duration_seconds: @boot_back_off_seconds
      @status = Status.new('vm stopped, doing nothing', 0)
      @was_running = false
      @last_update_at = nil
      return
    end

    @was_running = true
    if @last_update_at == mem_stat.last_updated
      @status = Status.new('no new data', 0)
      return
    end
    @last_update_at = mem_stat.last_updated

    # If the VM has no support for ballooning, do nothing
    unless mem_stat.guest_data_available?
      @status = Status.new('ballooning unsupported by the VM', 0)
      return
    end

    # 0..100
    percent_used = mem_stat.guest_mem.percent_used
    used_mem = mem_stat.guest_mem.used

    # 0..100
    memory_delta = 0

    if percent_used >= @trigger_increase_at
      # Increase memory immediately
      memory_delta = @increase_memory_by
    elsif percent_used <= @trigger_decrease_at
      # decrease memory if not in back_off period
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
    if @min_active > max_memory
      @status = Status.new("VM max memory #{max_memory} is below min_active #{@min_active}, doing nothing", 0)
      return
    end

    min_memory = @min_active.clamp(nil, max_memory)
    new_actual = mem_stat.actual * (memory_delta + 100) / 100
    new_actual = new_actual.clamp(min_memory..max_memory)
    if new_actual == mem_stat.actual
      @status = if memory_delta > 0
                  Status.new(
                    "I want to increase memory (current usage of #{percent_used}% is over trigger #{@trigger_increase_at}%) but can't go over configured max mem #{format_byte_size(new_actual)}", 0
                  )
                else
                  Status.new(
                    "New actual #{format_byte_size(new_actual)} is the same as current one #{format_byte_size(mem_stat.actual)}, doing nothing", 0
                  )
                end
      return
    end

    back_off

    @status = Status.new(
      "VM reports #{format_byte_size(used_mem)} (#{percent_used}%), updating actual by #{memory_delta}% to #{format_byte_size(new_actual)}", memory_delta
    )
    @virt_cache.set_actual(@vmid, new_actual)
  end

  private

  # Back off from this VM - don't downgrade the memory for at least 10 seconds
  def back_off(duration_seconds: @back_off_seconds)
    back_off_until = Time.now + duration_seconds
    @back_off_until = back_off_until if @back_off_until.nil? || @back_off_until < back_off_until
  end

  # @return [Boolean] true if we are backing off from issuing any further memory decrease commands.
  def backing_off?
    Time.now < @back_off_until
  end
end
