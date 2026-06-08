# frozen_string_literal: true

module System
  # Reads host metrics from a Linux system: memory from `/proc/meminfo`, CPU from
  # `/proc/stat` and `/proc/cpuinfo`, disk from `df`.
  #
  # Stateless and thread-safe — callers thread the previous sample back in themselves
  # (see {#cpu_usage}). Runs on the background timer thread. {System::Emulator} is the
  # test double with the same interface.
  #
  # Each reader takes an optional fixture-content parameter used only by specs; in
  # production they read the real files/commands.
  class Info
    # Reads physical RAM and swap usage from `/proc/meminfo`.
    #
    # @param meminfo_file [String, nil] contents of `/proc/meminfo`; reads the real file
    #   when `nil`. Pass a fixture string for testing
    # @return [MemoryStat] memory statistics
    def memory_stats(meminfo_file = nil)
      meminfo_file ||= File.read('/proc/meminfo')
      mem = meminfo_file.lines.map { |it| it.strip.split(':') }.to_h
      ram = ResourceUsage.new(total: mem['MemTotal'].strip.to_i.KiB,
                            available: mem['MemAvailable'].strip.to_i.KiB)
      swap = ResourceUsage.new(total: mem['SwapTotal'].strip.to_i.KiB,
                             available: mem['SwapFree'].strip.to_i.KiB)
      MemoryStat.new(ram, swap)
    end

    # Computes whole-CPU usage over the interval since `prev_cpu_usage` was sampled, by
    # diffing `/proc/stat` clock counters.
    #
    # The result is normalized across all cores (`0.0..100.0`; 8 saturated cores read
    # `100.0`, not `800.0`) — see {System::CpuUsage}. The first call has no previous
    # sample to diff against and returns `0.0`.
    #
    # @param prev_cpu_usage [System::CpuUsage, nil] the previous sample, or `nil` on the
    #   first call
    # @param proc_stat_file [String, nil] contents of `/proc/stat`; reads the real file
    #   when `nil`. Pass a fixture string for testing
    # @return [System::CpuUsage] the new sample, carrying the raw {System::CpuStat} for
    #   the next diff
    def cpu_usage(prev_cpu_usage, proc_stat_file = nil)
      stat = CpuStat.parse(proc_stat_file)
      if prev_cpu_usage.nil?
        CpuUsage.new(0.0, stat)
      else
        prev_stat = prev_cpu_usage.last_cpu_stat
        total_diff = stat.clocks_total - prev_stat.clocks_total
        idle_diff = stat.clocks_idle - prev_stat.clocks_idle
        cpu_usage = (total_diff.positive? ? 100.0 * (1.0 - idle_diff.to_f / total_diff) : 0.0).round(2)
        CpuUsage.new(cpu_usage, stat)
      end
    end

    # Calculates per-disk usage, but only for the filesystems that hold VM qcow2 files.
    #
    # Runs `df` on the given files and groups the results by physical disk, folding each
    # file's size into that disk's {DiskUsage}. Returns an empty hash when `qcow2_files`
    # is empty.
    #
    # @param qcow2_files [Array<Array(String, Integer)>] `[path, size_in_bytes]` pairs for
    #   the qcow2 files used by VMs
    # @param test_df [String, nil] canned `df -P` output for testing; runs the real `df`
    #   when `nil`
    # @return [Hash{String => DiskUsage}] physical disk name => its usage
    # @raise [RuntimeError] if the underlying `df` command fails (via {Run.sync})
    def disk_usage(qcow2_files, test_df = nil)
      return {} if qcow2_files.empty?

      files = qcow2_files.map { "'#{it[0]}'" }.join ' '
      df = test_df || Run.sync("df -P #{files}")
      df_lines = df.lines.map(&:strip)[1..]
      # each line is an Array: 0=>physical disk name, 1=>total size in kb, 3=>available space in kb.
      df_lines = df_lines.map(&:split)

      # {Map{String => DiskUsage}}
      result = {}
      # Array<Array<String,DiskUsage>>: String physical disk name to DiskUsage. One Physical disk name may have repeated entries.
      df_lines.map.with_index do |line, idx|
        name = line[0].split('/').last
        total = line[1].to_i * 1024
        available = line[3].to_i * 1024
        vm_usage = qcow2_files[idx][1]
        qcow2_file = qcow2_files[idx][0]
        result[name] = if result[name].nil?
                         DiskUsage.new(ResourceUsage.new(total, available), vm_usage, [qcow2_file])
                       else
                         result[name].add(vm_usage, qcow2_file)
                       end
      end
      result
    end

    # Reads the host CPU feature flags from `/proc/cpuinfo` (e.g. `svm`/`vmx` for
    # virtualization support).
    #
    # @return [Set<String>] the CPU flags
    def cpu_flags
      l = File.read('/proc/cpuinfo').lines
      l = l.filter { it.start_with? 'flags' }
      l = l.flat_map(&:split).to_set
      l.subtract(['flags', ':'])
      l
    end
  end
end
