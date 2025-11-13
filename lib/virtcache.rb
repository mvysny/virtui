# frozen_string_literal: true

require_relative 'sysinfo'
require_relative 'virt'

# Caches all VM runtime info for speedy access.
class VirtCache
  # @property [MemoryStat]
  attr_reader :host_mem_stat
  # @property [CpuInfo]
  attr_reader :cpu_info

  # @param virt [VirtCmd | LibVirtClient] virt client
  def initialize(virt)
    @virt = virt
    @cpu_info = virt.hostinfo
    @sysinfo = SysInfo.new
    @cpu_count = @cpu_info.cpus
    # Hash{String => VMCache}
    @cache = {}
    update
  end

  # @return [Set<String>]
  def domains
    @cache.keys
  end

  # @param domain [String] domain name
  # @return [MemStat | nil] nil if domain isn't running
  def memstat(domain)
    data(domain)&.mem_stat
  end

  # @param domain [String]
  # @return [VMCache | nil]
  def cache(domain)
    raise "Domain name must be String but was #{domain}" unless domain.is_a? String

    @cache[domain]
  end

  # @param domain [String] domain name
  # @return [DomainData | nil]
  def data(domain)
    cache(domain)&.data
  end

  # @param domain [String] domain name
  # @return [Symbol] one of `:running`, `:shut_off`, `:paused`, `:other`
  def state(domain)
    data(domain)&.state || :other
  end

  # @param domain [String] domain name
  # @return [Boolean] `true` if running
  def running?(domain)
    state(domain) == :running
  end

  # @param domain [String] domain name
  # @return [DomainInfo | nil]
  def info(domain)
    cache(domain)&.info
  end

  # @param domain [String]
  # @param new_actual [Integer] the new `actual` memory parameter.
  def set_actual(domain, new_actual)
    info = info(domain)
    raise "#{domain} not existing" if info.nil?

    # sanity check the new_active
    raise "#{new_actual} must be at least 128m" if new_actual < 128 * 1024 * 1024
    raise "#{new_actual} can not go over max #{info.max_memory}" if new_actual > info.max_memory

    @virt.set_actual(domain, new_actual)
  end

  # Returns the CPU usage of a VM, with respect to host OS.
  # @param domain [String]
  # @return [Float] CPU usage 0..100%, 100%=full usage of all guest CPU cores.
  def cpu_usage(domain)
    c = cache(domain)
    c.cpu_usage / c.info.cpus
  end

  # VM cached data.
  # - `data` {DomainData}
  # - `cpu_usage` [Float] CPU usage in %; 100% means one CPU core was fully utilized. 0 or greater, may be greater than 100.
  class VMCache < Data.define(:data, :cpu_usage)
    # @param prev_data [DomainData | nil] previous VM data
    # @param next_data [DomainData] current VM data
    # @return [VMCache]
    def self.diff(prev_data, next_data)
      VMCache.new(next_data, next_data.cpu_usage(prev_data))
    end

    # @return [DomainInfo]
    def info
      data.info
    end
  end

  # Updates the cache
  def update
    old_cache = @cache
    domain_data = @virt.domain_data
    @cache = domain_data.map { |did, data| [did, VMCache.diff(old_cache[did]&.data, data)] }.to_h

    # host stats
    @host_mem_stat = @sysinfo.memory_stats
    @host_cpu_usage = @sysinfo.cpu_usage(@host_cpu_usage)
  end

  # @return [Integer] a sum of RSS usage of all running VMs
  def total_vm_rss_usage
    @cache.values.sum { |cache| cache.data.mem_stat&.rss || 0 }
  end

  # Sum of all CPU usages of all VMs.
  # @return [Float] CPU usage 0..100%, 100%=full usage of all host CPU cores.
  def total_vm_cpu_usage
    @cache.values.sum { |it| it.cpu_usage / @cpu_count }
  end

  # @return [Float] recent CPU usage, 0..100%
  def host_cpu_usage
    @host_cpu_usage.usage_percent
  end
end
