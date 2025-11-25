# frozen_string_literal: true

require_relative 'utils'

# Memory usage: `total` and `available`, in bytes, both {Integer}
class MemoryUsage < Data.define(:total, :available)
  def used
    total - available
  end

  def percent_used
    total.zero? ? 0 : used * 100 / total
  end

  def to_s
    "#{format_byte_size(used)}/#{format_byte_size(total)} (#{percent_used.round(2)}%)"
  end
end

# Memory statistics: `ram` and `swap`, both {MemoryUsage}.
class MemoryStat < Data.define(:ram, :swap)
  def to_s
    "RAM: #{ram}, SWAP: #{swap}"
  end
end

# Obtains system information from host Linux
class SysInfo
  # @return [MemoryStat] memory statistics
  def memory_stats(meminfo_file = nil)
    meminfo_file ||= File.read('/proc/meminfo')
    mem = meminfo_file.lines.map { |it| it.strip.split(':') }.to_h
    ram = MemoryUsage.new(total: mem['MemTotal'].strip.to_i * 1024,
                          available: mem['MemAvailable'].strip.to_i * 1024)
    swap = MemoryUsage.new(total: mem['SwapTotal'].strip.to_i * 1024,
                           available: mem['SwapFree'].strip.to_i * 1024)
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
  # @param qcow2_files [Array<String>] a list of qcow2 files used by VMs.
  # @return [Map{String => MemoryUsage}] maps physical disk to usage information.
  def disk_usage(qcow2_files, test_df = nil)
    files = qcow2_files.filter { !it.nil? }.map { "'{it}'" }.join ' '
    return {} if files.empty? && test_df.nil?

    df = test_df || Run.sync("df -P #{files}")
    df_lines = df.lines.map(&:strip)[1..]
    df_lines = df_lines.map(&:split)
    df_lines = df_lines.uniq { it[0] }
    df_lines.map do |line|
      name = line[0].split('/').last
      total = line[1].to_i * 1024
      available = line[3].to_i * 1024
      [name, MemoryUsage.new(total, available)]
    end.to_h
  end
end

# A representation of a single `cpu` line from `/proc/stat`. `name` is {String} `cpu`; others are {Integer}s.
class CpuStat < Data.define(:name, :user, :nice, :system, :idle, :iowait, :irq, :softirq, :steal, :guest, :guest_nice)
  def clocks_idle
    idle + iowait
  end

  def clocks_non_idle
    user + nice + system + irq + softirq + steal
  end

  def clocks_total
    clocks_idle + clocks_non_idle
  end

  # Parses `/proc/stat` file.
  # @param proc_stat_file [String | nil] test contents of /proc/stat. For testing only.
  # @return [CpuStat]
  def self.parse(proc_stat_file = nil)
    stat = proc_stat_file || File.read('/proc/stat')
    cpu_line = stat.lines.filter { |line| line.strip.start_with? 'cpu ' }.first
    # example line "cpu  1000 50 800 5000 200 0 100 0 0 0"
    # The fields are (in order): user nice system idle iowait irq softirq steal guest guest_nice
    values = cpu_line.strip.split
    CpuStat.new(values[0], values[1].to_i, values[2].to_i, values[3].to_i, values[4].to_i, values[5].to_i,
                values[6].to_i, values[7].to_i, values[8].to_i, values[9].to_i, values[10].to_i)
  end

  def to_s
    "#{name}: user=#{user} nice=#{nice} system=#{system} idle=#{idle} iowait=#{iowait} irq=#{irq} softirq=#{softirq} steal=#{steal} guest=#{guest} guest_nice=#{guest_nice}"
  end
end

# A CPU usage. `usage_percent` is {Float} 0..100% and represents a CPU usage single last sampling.
# `last_cpu_stat` is the most up-to-date representation of CPU clocks, {CpuStat}.
class CpuUsage < Data.define(:usage_percent, :last_cpu_stat)
end
