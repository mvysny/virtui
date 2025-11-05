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
    # Hash{DomainId => Symbol}
    @domains = {}
    # Hash{DomainId => MemStat}
    @mem_stats = {}
    @cpu_info = virt.hostinfo
    @sysinfo = SysInfo.new
    update
  end

  # @return [Set<DomainId>]
  def domains
    @domains.keys
  end

  # @param domain [DomainId]
  # @return [MemStat | nil] nil if domain isn't running
  def memstat(domain)
    @mem_stats[domain]
  end

  # @param domain [DomainId]
  # @return [Symbol] one of `:running`, `:shut_off`, `:paused`, `:other`
  def state(domain)
    @domains[domain] || :other
  end

  # Updates the cache
  def update_slow
    domains = @virt.domains
    @domains = domains.map { |d| [d.id, d.state] }.to_h
    @mem_stats = @domains.keys.map { |id| [id, id.running? ? @virt.memstat(id) : nil] }.to_h
    @host_mem_stat = @sysinfo.memory_stats
    @host_cpu_usage = @sysinfo.cpu_usage(@host_cpu_usage)
  end
  
  def update
    domain_data = @virt.domain_data
    domain_data = domain_data.map { |domain_name, data| [DomainId.new(data.running? ? domain_name.hash : nil, domain_name), data] }.to_h 
    @domains = domain_data.map { |did, data| [did, data.info.state] }.to_h
    @mem_stats = @domains.keys.map { |id| [id, id.running? ? domain_data[id].mem_stat : nil] }.to_h
    @host_mem_stat = @sysinfo.memory_stats
    @host_cpu_usage = @sysinfo.cpu_usage(@host_cpu_usage)
  end

  # @return [Integer] a sum of RSS usage of all running VMs
  def total_vm_rss_usage
    @mem_stats.values.sum { |mem_stat| mem_stat&.rss || 0 }
  end

  # @return [Float] recent CPU usage, 0..100%
  def host_cpu_usage
    @host_cpu_usage.usage_percent
  end
end
