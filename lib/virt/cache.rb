# frozen_string_literal: true

module Virt
  # A cache of all VM runtime info, for fast reads from the UI thread. Each VM's entry is a
  # {VMCache} carrying its {DomainData} plus derived CPU/memory figures.
  #
  # == Thread-safety
  #
  # Thread-safe: every reader may be called from any thread and returns immutable, possibly
  # slightly-stale data, which is fine for display. The lone writer, {#update}, is the
  # exception and carries its own contract.
  class Cache
    # Guest memory-stat collection period armed on each running VM, in seconds. Matches our
    # ~2s poll so ballooning always sees the freshest data libvirt has; libvirt itself
    # refreshes only every ~5s regardless (see {VMCache#stale?}).
    STATS_PERIOD_SECONDS = 2

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
    # snapshot.
    #
    # @!attribute [r] data
    #   @return [DomainData] the latest VM snapshot
    # @!attribute [r] cpu_usage
    #   @return [Float] per-core CPU usage in percent; 100% means one core fully utilized,
    #     so a busy multi-core VM may exceed 100 (see {DomainData#cpu_usage})
    # @!attribute [r] mem_data_age_seconds
    #   @return [Integer, nil] age of the guest memory data, in seconds; `nil` if balloon
    #     data is unavailable or the VM is shut down
    # @!attribute [r] swap_out_rate
    #   @return [Float, nil] how fast the guest is writing pages to swap, in bytes per
    #     second; `nil` if the guest doesn't report swap counters (see
    #     {MemoryStat#swap_data_available?}) or this is the VM's first sample
    #
    #     The one figure here that says whether a guest is *paying* for memory pressure.
    #     `MemAvailable` can't: evicting anon pages to swap raises it, so a swapping guest
    #     and an idle one report the same `guest_mem` — see `ideas/swap-despite-ballooning.md`.
    #     Positive means reclaim is hitting the swap device right now; `0.0` is what at-rest
    #     looks like, even for a guest with gigabytes already parked in swap.
    class VMCache < Data.define(:data, :cpu_usage, :mem_data_age_seconds, :swap_out_rate)
      # Builds a cache entry by diffing the previous entry against the current snapshot
      # (for CPU usage, memory-data age and swap-out rate).
      #
      # @param prev_cache [VMCache, nil] previous entry for this VM, or `nil` on first sight
      # @param next_data [DomainData] current VM snapshot
      # @return [VMCache] the derived cache entry
      def self.diff(prev_cache, next_data)
        prev_data = prev_cache&.data
        # Age is wall-clock (sampled_at minus last_updated), never the delta between two
        # polls' last_updated — see DECISIONS.md D-wall-clock-mem-age.
        age = next_data.mem_stat.nil? ? nil : ((next_data.sampled_at / 1000) - next_data.mem_stat.last_updated)
        VMCache.new(next_data, next_data.cpu_usage(prev_data).clamp(0, nil), age,
                    swap_out_rate(prev_cache, next_data))
      end

      # Bytes-per-second at which the guest wrote to swap between the previous sample and
      # this one, or `nil` if it can't be computed.
      #
      # @param prev_cache [VMCache, nil] previous entry for this VM, or `nil` on first sight
      # @param next_data [DomainData] current VM snapshot
      # @return [Float, nil] swap-out rate in bytes per second
      def self.swap_out_rate(prev_cache, next_data)
        now = next_data.mem_stat
        prev = prev_cache&.data&.mem_stat
        return nil if now.nil? || prev.nil? || !now.swap_data_available? || !prev.swap_data_available?

        seconds = now.last_updated - prev.last_updated
        # The guest hasn't reported since the last poll: libvirt refreshes balloon data only
        # every ~5s while we poll every ~2s, so most polls see an unchanged sample. Carrying
        # the last rate forward keeps the figure readable; reporting 0 here would blink it
        # off on every other poll and hide exactly the activity we are watching for.
        return prev_cache.swap_out_rate if seconds <= 0

        delta = now.swap_out - prev.swap_out
        # The counter is per-boot, so it only ever falls by resetting to 0 on a guest
        # restart. That is a fresh baseline, not negative swapping.
        return 0.0 if delta.negative?

        delta.to_f / seconds
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

      # Whether the guest memory data is too old to trust (≥ 12s).
      #
      # 12s clears the normal lag — libvirt refreshes balloon data only every ~5s, and we
      # poll every ~2s on top, so healthy data is routinely 5–7s old; see DECISIONS.md
      # D-wall-clock-mem-age. Anything older means the guest stopped reporting.
      #
      # @return [Boolean] true if the memory data is stale
      def stale?
        !mem_data_age_seconds.nil? && mem_data_age_seconds >= 12
      end
    end

    # Refreshes every VM's data plus the host memory/CPU/disk stats, diffing against the
    # previous snapshot for derived figures. Unlike every other method here, this one must
    # run on the background timer thread, never the UI thread; `@write_lock` keeps it from
    # overlapping itself.
    #
    # @return [void]
    # @raise [RuntimeError] if reading VM or host data fails (e.g. `virsh`/`df` errors)
    def update
      @write_lock.synchronize do
        old_cache = @cache
        domain_data = @virt.domain_data
        cache = Concurrent::Map.new(options: { initial_capacity: domain_data.length })
        domain_data.each do |did, data|
          prev_data = old_cache[did]&.data
          cache[did] = VMCache.diff(old_cache[did], data)
          # A VM just (re)started: arm its guest mem-stat collection, or the balloon stats
          # stay frozen (see {Virsh#set_mem_stats_period}).
          @virt.set_mem_stats_period(did, STATS_PERIOD_SECONDS) if data.running? && !prev_data&.running?
        end
        @cache = cache

        @host_mem_stat = @sysinfo.memory_stats
        @host_cpu_usage = @sysinfo.cpu_usage(@host_cpu_usage)

        qcow2_files = domain_data.values.flat_map(&:disk_stat).filter { |it| !it.path.nil? }.map { |it| [it.path, it.physical] }
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
