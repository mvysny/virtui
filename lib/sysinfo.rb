# Memory usage: `total` and `available`, in bytes, both {Integer}
class MemoryUsage < Data.define(:total, :available)
  def used
    total - available
  end
  def percent_used
    total.zero? ? 0 : used * 100 / total
  end
  def to_s
    "#{format_byte_size(used)}/#{format_byte_size(total)} (#{percent_used}%)"
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
    meminfo_file = meminfo_file || File.read('/proc/meminfo')
    mem = meminfo_file.lines.map { |it| it.strip.split(':') } .to_h
    ram = MemoryUsage.new(total: mem['MemTotal'].strip.to_i * 1024,
      available: mem['MemAvailable'].strip.to_i * 1024)
    swap = MemoryUsage.new(total: mem['SwapTotal'].strip.to_i * 1024,
      available: mem['SwapFree'].strip.to_i * 1024)
    MemoryStat.new(ram, swap)
  end
end

