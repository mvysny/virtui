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
    # don't go below 1GB
    @min_active = 1 * 1024 * 1024 * 1024
    # After Ballooning decreases active memory, it will back off for 20 seconds
    # before trying to decrease the memory again. Observation shows that
    # the effects of the memory decrease command in Linux guest isn't instant: instead it is gradual, and takes
    # some time (~15 second) to fully be applied. Let's not bother the VM with further
    # memory decrease commands until the VM fully settles in.
    @back_off_seconds = 20

    # start by backing off. We don't know what state the VM is in - it could have been
    # just started seconds ago.
    back_off
  end

  attr_reader :status

  # Call every 2 seconds, to control the VM
  def update
    mem_stat = @virt_cache.memstat(@vmid)
    if mem_stat.nil? || !@virt_cache.running?(@vmid)
      # VM is shut off. Don't fiddle with the memory.
      # Mark as back_off - this way we'll back off from the VM until it boots up.
      back_off
      @status = 'vm stopped, doing nothing'
      return
    end

    # If the VM has no support for ballooning, do nothing
    unless mem_stat.guest_data_available?
      @status = 'ballooning unsupported by the VM'
      return
    end

    # 0..100
    percent_used = mem_stat.guest_mem.percent_used

    # 0..100
    memory_delta = 0

    if percent_used >= 80
      # Increase memory immediately
      memory_delta = 20
    elsif percent_used <= 60
      # decrease memory if not in back_off period
      if backing_off?
        @status = "only #{percent_used}% memory used, but backing off at the moment"
        return
      end
      memory_delta = -10
    end

    # Return early if nothing to do
    if memory_delta.zero?
      @status = "app memory in sweet spot (#{percent_used}), doing nothing"
      return
    end

    info = @virt_cache.info(@vmid)
    raise 'unexpected: info is nil' if info.nil?

    # calculate min/max memory
    max_memory = info.max_memory
    if @min_active > max_memory
      @status = "VM max memory #{max_memory} is below min_active #{@min_active}, doing nothing"
      return
    end

    min_memory = @min_active.clamp(nil, max_memory)
    new_actual = mem_stat.actual * (memory_delta + 100) / 100
    new_actual = new_actual.clamp(min_memory..max_memory)
    if new_actual == mem_stat.actual
      @status = "New actual #{new_actual} is the same as current one #{mem_stat.actual}, doing nothing"
      return
    end

    back_off

    @status = "Setting actual to #{new_actual}"
    puts min_memory, mem_stat, new_actual, max_memory, memory_delta
    @virt_cache.set_actual(@vmid, new_actual)
  end

  private

  # Back off from this VM - don't downgrade the memory for at least 10 seconds
  def back_off
    @back_off_since = Time.now
  end

  # @return [Boolean] true if we are backing off from issuing any further memory decrease commands.
  def backing_off?
    return false if @back_off_since.nil?

    Time.now - @back_off_since < @back_off_seconds
  end
end
