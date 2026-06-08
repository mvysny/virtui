# frozen_string_literal: true

module System
  # A CPU usage sample: the busy percentage over the last interval, plus the raw
  # {System::CpuStat} it was derived from.
  #
  # `last_cpu_stat` is retained so the next sample can diff against it (CPU usage is the
  # delta of busy clocks between two `/proc/stat` readings). Immutable and thread-safe
  # (a frozen {Data} value object).
  #
  # @!attribute [r] usage_percent
  #   @return [Float] busy percentage of the *whole* CPU over the last sampling interval,
  #     `0.0..100.0`. This is normalized across all cores, not per-core: an 8-core host
  #     with every core saturated reads `100.0`, not `800.0` (it is derived from the
  #     aggregate `cpu` line of `/proc/stat`, which already sums all cores).
  # @!attribute [r] last_cpu_stat
  #   @return [System::CpuStat] the most recent raw clock counters this sample used
  class CpuUsage < Data.define(:usage_percent, :last_cpu_stat)
  end
end
