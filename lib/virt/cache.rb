# frozen_string_literal: true

module Virt
  # A thread-safe cache of all VM runtime info, for fast reads from the UI thread.
  #
  # {#update} runs on the background timer thread (guarded by `@write_lock`, never run it
  # from the UI thread); readers return immutable, possibly slightly-stale data, which is
  # fine for display. Each VM's entry is a {VMCache} carrying its {DomainData} plus
  # derived CPU/memory figures.
  class Cache
    # @return [System::MemoryStat] host memory statistics, refreshed by {#update}
    attr_reader :host_mem_stat
    # @return [CpuInfo] static host CPU topology
    attr_reader :cpu_info
    # @return [Virsh] the libvirt client backing this cache
    attr_reader :virt

    # @return [Hash{String => System::DiskUsage}] maps physical disk name to its usage
    attr_reader :disks

    # @return [Set<String>] host CPU flags such as `npt`, `nx` etc. — not just virtualization-related
    attr_reader :cpu_flags

    # Builds the cache and performs an initial {#update}.
    #
    # @param virt [Virsh] libvirt client used to read VM data
    # @param sysinfo [System::Info] host-metrics reader (or {System::Emulator})
    def initialize(virt, sysinfo)
      @virt = virt
      @cpu_info = virt.hostinfo
      @cpu_flags = sysinfo.cpu_flags
      @sysinfo = sysinfo
      @cpu_count = @cpu_info.cpus
      @cache = Concurrent::Map.new
      # So that {#update} won't be run concurrently.
      @write_lock = Thread::Mutex.new
      update
    end

    # @return [Integer] how many VMs are currently running
    def up
      @cache.values.count { |it| it.data.state == :running }
    end

    # @return [Array<String>] names of all known VMs
    def domains
      @cache.keys
    end

    # @param domain [String] domain name
    # @return [MemoryStat, nil] memory stats, or `nil` if the VM isn't running
    def memstat(domain)
      data(domain)&.mem_stat
    end

    # @param domain [String] domain name
    # @return [VMCache, nil] cached entry, or `nil` if no such VM is known
    # @raise [RuntimeError] if `domain` is not a {String}
    def cache(domain)
      raise "Domain name must be String but was #{domain}" unless domain.is_a? String

      @cache[domain]
    end

    # @param domain [String] domain name
    # @return [DomainData, nil] latest snapshot, or `nil` if no such VM is known
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
    # @return [DomainInfo, nil] static VM config, or `nil` if no such VM is known
    def info(domain)
      cache(domain)&.info
    end

    # Validates the requested size against the VM's limits, then delegates to {Virsh#set_actual}.
    #
    # @param domain [String] domain name
    # @param new_actual [Integer] the new `actual` memory size, in bytes
    # @raise [RuntimeError] if the VM is unknown, or `new_actual` is below 128 MiB or
    #   above the VM's `max_memory`
    def set_actual(domain, new_actual)
      info = info(domain)
      raise "#{domain} not existing" if info.nil?

      # sanity check the new_active
      raise "#{new_actual} must be at least 128m" if new_actual < 128.MiB
      raise "#{new_actual} can not go over max #{info.max_memory}" if new_actual > info.max_memory

      @virt.set_actual(domain, new_actual)
    end

    # One VM's cached snapshot plus the figures derived by diffing it against the previous
    # snapshot. Immutable and thread-safe (a frozen {Data} value object).
    #
    # @!attribute [r] data
    #   @return [DomainData] the latest VM snapshot
    # @!attribute [r] cpu_usage
    #   @return [Float] per-core CPU usage in percent; 100% means one core fully utilized,
    #     so a busy multi-core VM may exceed 100 (see {DomainData#cpu_usage})
    # @!attribute [r] mem_data_age_seconds
    #   @return [Integer, nil] age of the guest memory data, in seconds; `nil` if balloon
    #     data is unavailable or the VM is shut down
    class VMCache < Data.define(:data, :cpu_usage, :mem_data_age_seconds)
      # Builds a cache entry by diffing the previous snapshot against the current one
      # (for CPU usage and memory-data age).
      #
      # @param prev_data [DomainData, nil] previous VM snapshot, or `nil` on first sight
      # @param next_data [DomainData] current VM snapshot
      # @return [VMCache] the derived cache entry
      def self.diff(prev_data, next_data)
        age = if next_data.mem_stat.nil?
                nil
              elsif prev_data&.mem_stat.nil?
                0
              else
                next_data.mem_stat.last_updated - prev_data.mem_stat.last_updated
              end
        VMCache.new(next_data, next_data.cpu_usage(prev_data).clamp(0, nil), age)
      end

      # @return [DomainInfo] the VM's static config
      def info
        data.info
      end

      # CPU usage normalized to the guest's own core count, so 100% means every guest core
      # is fully utilized (unlike the per-core {#cpu_usage}).
      #
      # @return [Float] guest CPU usage, `0..100%`
      def guest_cpu_usage
        cpu_usage / info.cpus
      end

      # Whether the guest memory data is too old to trust (≥ 7s).
      #
      # virsh refreshes balloon data only every ~5s regardless of the configured stats
      # period, so the threshold is 7s rather than the 3s we'd prefer.
      #
      # @return [Boolean] true if the memory data is stale
      def stale?
        !mem_data_age_seconds.nil? && mem_data_age_seconds >= 7
      end
    end

    # Refreshes every VM's data plus the host memory/CPU/disk stats, diffing against the
    # previous snapshot for derived figures.
    #
    # Guarded by `@write_lock` so it never runs concurrently with itself. Runs on the
    # background timer thread — must not be called from the UI thread.
    #
    # @return [void]
    # @raise [RuntimeError] if reading VM or host data fails (e.g. `virsh`/`df` errors)
    def update
      @write_lock.synchronize do
        old_cache = @cache
        domain_data = @virt.domain_data
        cache = Concurrent::Map.new(options: { initial_capacity: domain_data.length })
        domain_data.each { |did, data| cache[did] = VMCache.diff(old_cache[did]&.data, data) }
        @cache = cache

        @host_mem_stat = @sysinfo.memory_stats
        @host_cpu_usage = @sysinfo.cpu_usage(@host_cpu_usage)

        qcow2_files = domain_data.values.flat_map { |it| it.disk_stat }.filter { |it| !it.path.nil? }.map { |it| [it.path, it.physical] }
        @disks = @sysinfo.disk_usage(qcow2_files)
      end
    end

    # How much host disk space a VM disk's qcow2 file occupies, against that disk's total.
    #
    # @param disk_stat [DiskStat] the VM disk whose backing file to locate
    # @return [ResourceUsage, nil] `physical` size out of the disk's total, or `nil` if the
    #   file isn't found on any tracked disk
    def host_disk_usage(disk_stat)
      du = @disks.values.find { |it| it.qcow2_files.include?(disk_stat.path) }
      return nil if du.nil?

      ResourceUsage.of(du.usage.total, disk_stat.physical)
    end

    # @return [Integer] sum of the RSS (host memory) of all VMs, in bytes
    def total_vm_rss_usage
      @cache.values.sum { |cache| cache.data.mem_stat&.rss || 0 }
    end

    # Combined CPU usage of all VMs, normalized to the host core count so that 100% means
    # all host cores are fully utilized.
    #
    # @return [Float] total VM CPU usage, `0..100%`
    def total_vm_cpu_usage
      @cache.values.sum { |it| it.cpu_usage / @cpu_count }
    end

    # @return [Float] most recent whole-host CPU usage, `0..100%` (see {System::CpuUsage})
    def host_cpu_usage
      @host_cpu_usage.usage_percent
    end
  end
end
