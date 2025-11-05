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
    # Hash{DomainId => DomainData}
    @domain_data = {}
    update
  end

  # @return [Set<DomainId>]
  def domains
    @domain_data.keys
  end

  # @param domain [DomainId]
  # @return [MemStat | nil] nil if domain isn't running
  def memstat(domain)
    @domain_data[domain].mem_stat
  end

  # @param domain [DomainId]
  # @return [Symbol] one of `:running`, `:shut_off`, `:paused`, `:other`
  def state(domain)
    @domain_data[domain].info.state || :other
  end

  # @param domain [DomainId]
  # @return [Float] CPU usage 0..100%, 100%=full usage of all host CPU cores.
  def cpu_usage(domain)
    @guest_cpu[domain] || 0.0
  end

  # Updates the cache
  def update
    # guest stats
    domain_data = @virt.domain_data
    domain_data = domain_data.map { |domain_name, data| [DomainId.new(data.running? ? domain_name.hash : nil, domain_name), data] }.to_h
    # guest CPU
    @guest_cpu = domain_data.map { |did, data| [did, data.cpu_usage(@domain_data[did]) / @cpu_count] } .to_h
    @domain_data = domain_data
    
    # host stats
    @host_mem_stat = @sysinfo.memory_stats
    @host_cpu_usage = @sysinfo.cpu_usage(@host_cpu_usage)
  end

  # @return [Integer] a sum of RSS usage of all running VMs
  def total_vm_rss_usage
    @domain_data.values.sum { |data| data.mem_stat.rss || 0 }
  end

  # @return [Float] recent CPU usage, 0..100%
  def host_cpu_usage
    @host_cpu_usage.usage_percent
  end
end
