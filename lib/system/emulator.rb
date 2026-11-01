# frozen_string_literal: true

module System
  # A {System::Info}-compatible test double that returns fixed, predictable host metrics
  # without touching `/proc` or `df`.
  #
  # Mirrors {System::Info}'s public interface (minus the fixture parameters) so the app
  # can run in demo mode. Stateless and thread-safe.
  class Emulator
    # @return [MemoryStat] fixed memory statistics (32 GiB RAM half-used, 4 GiB swap free)
    def memory_stats
      ram = ResourceUsage.new(total: 32.GiB, available: 16.GiB)
      swap = ResourceUsage.new(total: 4.GiB, available: 4.GiB)
      MemoryStat.new(ram, swap)
    end

    # @param _prev_cpu_usage [System::CpuUsage, nil] ignored; present for interface parity
    #   with {System::Info#cpu_usage}
    # @return [System::CpuUsage] always `0.0%` usage with no backing {System::CpuStat}
    def cpu_usage(_prev_cpu_usage)
      CpuUsage.new(0.0, nil)
    end

    # Puts every file on one simulated 1 TiB disk, `nvme0n1`, 400 GiB of it free.
    #
    # @param qcow2_files [Array<Array(String, Integer)>] `[path, size_in_bytes]` pairs, as
    #   {System::Info#disk_usage} takes them
    # @return [Hash{String => DiskUsage}] `nvme0n1`'s usage; empty when `qcow2_files` is
    def disk_usage(qcow2_files)
      return {} if qcow2_files.empty?

      empty = DiskUsage.new(ResourceUsage.new(total: 1024.GiB, available: 400.GiB), 0, [])
      { 'nvme0n1' => qcow2_files.reduce(empty) { |disk, (path, size)| disk.add(size, path) } }
    end

    # @return [Set<String>] fixed virtualization-capable CPU flags (`svm`, `npt`, `pdpe1gb`)
    def cpu_flags
      %w[svm npt pdpe1gb].to_set
    end
  end
end
