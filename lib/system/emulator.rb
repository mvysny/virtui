# frozen_string_literal: true

module System
  # A [Info] compatible class which provides dummy predictable results.
  #
  # Has no state, thread-safe.
  class Emulator
    # @return [MemoryStat] memory statistics
    def memory_stats
      ram = MemoryUsage.new(total: 32.GiB, available: 16.GiB)
      swap = MemoryUsage.new(total: 4.GiB, available: 4.GiB)
      MemoryStat.new(ram, swap)
    end

    # Obtains CPU usage as a percentage 0..100, since the last call of this function.
    # @param prev_cpu_usage [CpuUsage | nil] the last sampling or `nil` if this is the first one.
    # @return [CpuUsage]
    def cpu_usage(_prev_cpu_usage)
      CpuUsage.new(0.0, nil)
    end

    # Calculates disk usage; only takes into account disks with VM qcow2 files on them.
    # @param qcow2_files [Array<Array<String,Integer>>] a list of qcow2 files and their sizes used by VMs.
    # @return [Map{String => DiskUsage}] maps physical disk to usage information.
    def disk_usage(_qcow2_files)
      {}
    end

    # @return [Set<String>] CPU flags.
    def cpu_flags
      %w[svm npt pdpe1gb].to_set
    end
  end
end
