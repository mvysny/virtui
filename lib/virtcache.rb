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
    data(domain)&.mem_stat
  end

  # @param domain [String] domain name
  # @return [DomainData | nil]
  def data(domain)
    raise "Domain name must be String but was #{domain}" unless domain.is_a? String

    @domain_data[domain]
  end

  # @param domain [DomainId]
  # @return [Symbol] one of `:running`, `:shut_off`, `:paused`, `:other`
  def state(domain)
    data(domain).state || :other
  end

  # @param domain [DomainId]
  # @return [DomainInfo | nil]
  def info(domain)
    data(domain)&.info
  end

  # @param domain [DomainId]
  # @param new_active [Integer] the new active parameter.
  def set_active(domain, new_active)
    info = info(domain)
    raise "#{domain} not existing" if info.nil?

    # sanity check the new_active
    raise "#{new_active} must be at least 128m" if new_active < 128 * 1024 * 1024
    raise "#{new_active} can not go over max #{info.max_memory}" if new_active > info.max_memory

    @virt.set_active(domain, new_active)
  end

  # Returns the CPU usage of a VM.
  # @param domain [DomainId]
  # @return [Float] CPU usage 0..100%, 100%=full usage of all guest CPU cores.
  def cpu_usage(domain)
    (@guest_cpu[domain] || 0.0) / data(domain).info.cpus
  end

  # Updates the cache
  def update
    # guest stats
    old_domain_data = @domain_data
    @domain_data = @virt.domain_data
    @domain_data = @domain_data.map do |domain_name, data|
      [DomainId.new(data.running? ? domain_name.hash : nil, domain_name), data]
    end.to_h
    # guest CPU
    @guest_cpu = @domain_data.map { |did, data| [did, data.cpu_usage(old_domain_data[did])] }.to_h

    # host stats
    @host_mem_stat = @sysinfo.memory_stats
    @host_cpu_usage = @sysinfo.cpu_usage(@host_cpu_usage)
  end

  # @return [Integer] a sum of RSS usage of all running VMs
  def total_vm_rss_usage
    @domain_data.values.sum { |data| data.mem_stat.rss || 0 }
  end

  # Sum of all CPU usages of all VMs.
  # @return [Float] CPU usage 0..100%, 100%=full usage of all host CPU cores.
  def total_vm_cpu_usage
    @guest_cpu.values.sum { |it| it / @cpu_count }
  end

  # @return [Float] recent CPU usage, 0..100%
  def host_cpu_usage
    @host_cpu_usage.usage_percent
  end
end
