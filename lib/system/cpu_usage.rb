# frozen_string_literal: true

module System
  # A CPU usage. `usage_percent` is {Float} 0..100% and represents a CPU usage single last sampling.
  # `last_cpu_stat` is the most up-to-date representation of CPU clocks, {CpuStat}.
  #
  # Immutable, thread-safe.
  class CpuUsage < Data.define(:usage_percent, :last_cpu_stat)
  end
end
