# frozen_string_literal: true

class Ballooning
  # @param virt_cache [VirtCache]
  def initialize(virt_cache)
    @virt_cache = virt_cache
    # maps {String} to {BallooningVM}
    @ballooning = {}
  end

  def update
    @ballooning = @virt_cache.domains.map do |domainid|
      [domainid, @ballooning[domainid] || BallooningVM.new(@virt_cache, domainid)]
    end.to_h
    @ballooning.values.each(&:update)
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
    # don't go below 1GB, or above max_memory
    @min_active = 1 * 1024 * 1024 * 1024
    # After Ballooning decreases active memory, it will back off for 20 seconds
    # before trying to decrease the memory again. Observation shows that
    # the effects of the memory decrease command in Linux guest isn't instant: instead it is gradual, and takes
    # some time (~15 second) to fully be applied. Let's not bother the VM with further
    # memory decrease commands until the VM fully settles in.
    @back_off_seconds = 20
  end

  # Call every 2 seconds, to control the VM
  def update
    mem_stat = @virt_cache.memstat(@vmid)
    if !@virt_cache.running?(@vmid) || mem_stat.nil?
      # VM is shut off. Don't fiddle with the memory.
      # Mark as back_off - this way we'll back off from the VM until it boots up.
      back_off
      return
    end

    # If the VM has no support for ballooning, do nothing
    return unless mem_stat.guest_data_available?

    # 0..100
    percent_used = mem_stat.guest_mem.percent_used

    # 0..100
    memory_delta = 0

    if percent_used >= 80
      # Increase memory immediately
      memory_delta = 20
    elsif percent_used <= 60
      # decrease memory if not in back_off period
      memory_delta = -10 unless backing_off?
    end

    # Return early if nothing to do
    return if memory_delta.zero?

    info = @virt_cache.info(@vmid)
    return if info.nil?

    # calculate min/max memory
    max_memory = info.max_memory
    min_memory = (max_memory * 0.25).to_i
    return if @min_active > max_memory

    min_memory = min_memory.clamp(min_memory_floor, max_memory)
    new_active = mem_stat.actual * (memory_delta + 100) / 100
    new_active = new_active.clamp(min_memory..max_memory)
    return if new_active == mem_stat.actual

    back_off
    @virt_cache.set_active(@vmid, new_active)
  end

  private

  # Back off from this VM - don't downgrade the memory for at least 10 seconds
  def back_off
    @back_off_since = Time.now
  end

  # @return [Boolean] true if we are backing off from issuing any further memory decrease commands.
  def backing_off?
    return false if @back_off_since.nil?

    Time.now - @back_off_since >= @back_off_seconds
  end
end
