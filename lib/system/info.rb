# frozen_string_literal: true

module System
  # Obtains system information from host Linux.
  #
  # Thread-safe, has no state.
  class Info
    # @return [MemoryStat] memory statistics
    def memory_stats(meminfo_file = nil)
      meminfo_file ||= File.read('/proc/meminfo')
      mem = meminfo_file.lines.map { |it| it.strip.split(':') }.to_h
      ram = MemoryUsage.new(total: mem['MemTotal'].strip.to_i.KiB,
                            available: mem['MemAvailable'].strip.to_i.KiB)
      swap = MemoryUsage.new(total: mem['SwapTotal'].strip.to_i.KiB,
                             available: mem['SwapFree'].strip.to_i.KiB)
      MemoryStat.new(ram, swap)
    end

    # Obtains CPU usage as a percentage 0..100, since the last call of this function.
    # @param prev_cpu_usage [CpuUsage | nil] the last sampling or `nil` if this is the first one.
    # @param proc_stat_file [String | nil] testing purposes only
    # @return [CpuUsage]
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

    # Calculates disk usage; only takes into account disks with VM qcow2 files on them.
    # @param qcow2_files [Array<Array<String,Integer>>] a list of qcow2 files and their sizes used by VMs.
    # @return [Map{String => DiskUsage}] maps physical disk to usage information.
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
                         DiskUsage.new(MemoryUsage.new(total, available), vm_usage, [qcow2_file])
                       else
                         result[name].add(vm_usage, qcow2_file)
                       end
      end
      result
    end

    # @return [Set<String>] CPU flags.
    def cpu_flags
      l = File.read('/proc/cpuinfo').lines
      l = l.filter { it.start_with? 'flags' }
      l = l.flat_map(&:split).to_set
      l.subtract(['flags', ':'])
      l
    end
  end
end
