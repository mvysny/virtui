# frozen_string_literal: true

require_relative 'sysinfo'
require_relative 'virt'
require_relative 'byte_prefixes'

# Caches all VM runtime info for speedy access.
class VirtCache
  # @property [MemoryStat]
  attr_reader :host_mem_stat
  # @property [CpuInfo]
  attr_reader :cpu_info
  # @property [VirtCmd]
  attr_reader :virt

  # @property [Map{String => DiskUsage}] maps physical disk name to usage information.
  attr_reader :disks

  # @param virt [VirtCmd | LibVirtClient] virt client
  def initialize(virt)
    @virt = virt
    # {CpuInfo}
    @cpu_info = virt.hostinfo
    # {SysInfo}
    @sysinfo = SysInfo.new
    # {Integer}
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
    raise "#{new_actual} must be at least 128m" if new_actual < 128.MiB
    raise "#{new_actual} can not go over max #{info.max_memory}" if new_actual > info.max_memory

    @virt.set_actual(domain, new_actual)
  end

  # VM cached data.
  # - `data` {DomainData}
  # - `cpu_usage` {Float} CPU usage in %; 100% means one CPU core was fully utilized. 0 or greater, may be greater than
  #    100.
  # - `mem_data_age_seconds` {Float} memory data age in seconds; `nil` if balloon unavailable or VM is shot down.
  class VMCache < Data.define(:data, :cpu_usage, :mem_data_age_seconds)
    # @param prev_data [DomainData | nil] previous VM data
    # @param next_data [DomainData] current VM data
    # @return [VMCache]
    def self.diff(prev_data, next_data)
      age = if next_data.mem_stat.nil?
              nil
            elsif prev_data&.mem_stat.nil?
              0
            else
              next_data.mem_stat.last_updated - prev_data.mem_stat.last_updated
            end
      VMCache.new(next_data, next_data.cpu_usage(prev_data), age)
    end

    # @return [DomainInfo]
    def info
      data.info
    end

    # Returns the CPU usage of a VM, with respect to guest OS.
    # @param domain [String]
    # @return [Float] CPU usage 0..100%, 100%=full usage of all guest CPU cores.
    def guest_cpu_usage
      cpu_usage / info.cpus
    end

    def stale?
      # No matter what I do, virsh refreshes data once every 5 seconds.
      # Even if I use <memballoon ...><stats period="1"/></memballoon>
      # I wanted to consider data aged 3 seconds stale, but I have to go with 7 seconds instead.
      !mem_data_age_seconds.nil? && mem_data_age_seconds >= 7
    end
  end

  # Updates the cache
  def update
    old_cache = @cache
    # {Hash<String => DomainData>} domain data, maps VM name to {DomainData}
    domain_data = @virt.domain_data
    @cache = domain_data.map { |did, data| [did, VMCache.diff(old_cache[did]&.data, data)] }.to_h

    # {MemoryStat} host stats
    @host_mem_stat = @sysinfo.memory_stats
    # {CpuUsage}
    @host_cpu_usage = @sysinfo.cpu_usage(@host_cpu_usage)

    qcow2_files = domain_data.values.flat_map { it.disk_stat }.filter { !it.path.nil? }.map { [it.path, it.physical] }
    # {Map{String => DiskUsage}} maps physical disk name to usage information.
    @disks = @sysinfo.disk_usage(qcow2_files)
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
