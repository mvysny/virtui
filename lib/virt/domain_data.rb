# frozen_string_literal: true

module Virt
  # A VM information
  #
  # - `info` {DomainInfo} info
  # - `state` {Symbol} one of `:running`, `:shut_off`, `:paused`, `:other`
  # - `sampled_at` {Integer} milliseconds since the epoch; you can use [:millis_now]
  # - `cpu_time` {Integer} milliseconds of used CPU time (user + system) since last sampling.
  #   Used to calculate CPU usage.
  # - `mem_stat` {MemStat} memory stats, `nil` if not running.
  # - `disk_stat` {Array<DiskStat>} disk stats, one per every connected disk
  class DomainData < Data.define(:info, :state, :sampled_at, :cpu_time, :mem_stat, :disk_stat)
    def running? = state == :running

    # @return [Boolean] true if VM has proper ballooning support.
    def balloon? = mem_stat.guest_data_available?

    # @return [Integer] now, represented as milliseconds since the epoch.
    def self.millis_now = DateTime.now.strftime('%Q').to_i

    # Calculates average CPU usage in the time period between older data and this data.
    # @param older_data [DomainData | nil]
    # @return [Float] CPU usage in %; 100% means one CPU core was fully utilized. 0 or greater, may be greater than 100.
    def cpu_usage(older_data)
      return 0.0 if older_data.nil?
      raise 'data is not older' if older_data.sampled_at >= sampled_at

      time_passed_millis = sampled_at - older_data.sampled_at
      cpu_used_millis = cpu_time - older_data.cpu_time
      cpu_used_millis.to_f / time_passed_millis * 100
    end

    def to_s
      result = "#{info}; #{state}"
      result += "; #{mem_stat}" unless mem_stat.nil?
      result
    end
  end
end
