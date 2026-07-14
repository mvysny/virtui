# frozen_string_literal: true

module Virt
  # A point-in-time snapshot of one VM: its static {DomainInfo} plus the runtime state and
  # metrics sampled at {#sampled_at}.
  #
  # Two snapshots are diffed to derive CPU usage (see {#cpu_usage}).
  #
  # @!attribute [r] info
  #   @return [DomainInfo] static VM configuration
  # @!attribute [r] state
  #   @return [Symbol] one of `:running`, `:shut_off`, `:paused`, `:other`
  # @!attribute [r] sampled_at
  #   @return [Integer] milliseconds since the epoch when this snapshot was taken (see {.millis_now})
  # @!attribute [r] cpu_time
  #   @return [Integer] cumulative used CPU time (user + system) in milliseconds; diffed
  #     between snapshots to compute usage
  # @!attribute [r] mem_stat
  #   @return [MemoryStat, nil] memory stats; `nil` if the VM is not running
  # @!attribute [r] disk_stat
  #   @return [Array<DiskStat>] disk stats, one per connected disk
  class DomainData < Data.define(:info, :state, :sampled_at, :cpu_time, :mem_stat, :disk_stat)
    # @return [Boolean] true if the VM is running
    def running? = state == :running

    # @return [Boolean] true if VM has proper ballooning support.
    def balloon? = mem_stat.guest_data_available?

    # @return [Integer] now, represented as milliseconds since the epoch.
    def self.millis_now = DateTime.now.strftime('%Q').to_i

    # Average CPU usage over the interval between `older_data` and this snapshot, from the
    # delta of {#cpu_time} over the delta of {#sampled_at}.
    #
    # Unlike {System::CpuUsage}, this is *per-core*: 100% means one virtual CPU core was
    # fully utilized over the interval, so a busy multi-core VM can exceed 100%.
    #
    # @param older_data [DomainData, nil] the earlier snapshot; returns `0.0` when `nil`
    # @return [Float] CPU usage in percent; `0.0` or greater, may exceed 100
    # @raise [RuntimeError] if `older_data` is not actually older (its `sampled_at` is not
    #   before this snapshot's)
    def cpu_usage(older_data)
      return 0.0 if older_data.nil?
      raise 'data is not older' if older_data.sampled_at >= sampled_at

      time_passed_millis = sampled_at - older_data.sampled_at
      cpu_used_millis = cpu_time - older_data.cpu_time
      cpu_used_millis.to_f / time_passed_millis * 100
    end

    # @return [String] human-readable summary; appends memory stats only when running
    def to_s
      result = "#{info}; #{state}"
      result += "; #{mem_stat}" unless mem_stat.nil?
      result
    end
  end
end
