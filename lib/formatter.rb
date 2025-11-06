require 'pastel'
require_relative 'virt'
require_relative 'sysinfo'

# Formats
class Formatter
  def initialize
    @p = Pastel.new
  end

  # Pretty-formats given object
  # @param what the object to format
  # @return [String] a Pastel-formatted object
  def format(what)
    return format_cpu(what) if what.is_a? CpuInfo
    return format_memory_stat(what) if what.is_a? MemoryStat
    return format_mem_stat(what) if what.is_a? MemStat
    return format_memory_usage(what) if what.is_a? MemoryUsage

    what.to_s # Fallback to :to_s
  end

  # @param cpu [CpuInfo]
  def format_cpu(cpu)
    "#{@p.bright_blue('CPU')}: #{@p.bright_blue(cpu.model)}: #{@p.cyan(cpu.cpus)} cores"
  end

  # @param memory_stat [MemoryStat]
  def format_memory_stat(memory_stat)
    "#{@p.bright_red('RAM')}: #{format(memory_stat.ram)}; #{@p.bright_red('SWAP')}: #{format(memory_stat.swap)}"
  end

  # @param memory_usage [MemoryUsage]
  def format_memory_usage(memory_usage)
    r = "#{@p.cyan(format_byte_size(memory_usage.used))}/#{@p.cyan(format_byte_size(memory_usage.total))}"
    r += " (#{@p.cyan(memory_usage.percent_used)}%)"
    r
  end

  # @param state [Symbol] one of `:running`, `:shut_off`, `:paused`
  def format_domain_state(state)
    running = "\u{1F7E2}"        # 🟢 LARGE GREEN CIRCLE
    paused = "\u{1F7E1}"        # 🟡
    off    = "\u{1F534}"        # 🔴
    unknown = "\u{26AA}"        # ⚪ MEDIUM WHITE CIRCLE
    case state
      when :running then running
      when :shut_off then off
      when :paused then paused
      else; unknown
    end
  end

  # @param mem_stat [MemStat]
  def format_mem_stat(mem_stat)
    result = "Host:#{format(mem_stat.host_mem)}"
    result += " Guest:#{format(mem_stat.guest_mem)}" unless mem_stat.guest_mem.nil?
    result
  end

  # Draws pretty progress bar as one row. Supports paiting multiple values into the same row.
  # @param width the width of the progress bar, in characters. The height is always 1.
  # @param max_value [Integer] the max value
  # @param values [Array<Array<Integer, Symbol>>] maps value to the Pastel color to draw with, e.g. `:red` or `:bright_yellow`.
  # @return [String] Pastel progress bar
  def progress_bar(width, max_value, values, char = '#')
    raise '#{max_value} must not be negative' if max_value.negative?
    return '' if max_value.zero? || width.zero?
    return ' ' * width if values.empty?

    values = values.sort_by { |value, color| value }
    result = ''
    length = 0
    values.each do |value, color|
      next if value <= 0

      progressbar_char_length = value.clamp(0, max_value) * width / max_value
      next unless length < progressbar_char_length

      chars = char * (progressbar_char_length - length)
      length = progressbar_char_length
      result += @p.lookup(color) + chars
    end
    result + ' ' * (width - length) + (length > 0 ? @p.lookup(:reset) : '')
  end
end

# Pretty-format bytes with suffixes like k, m, g (for KiB, MiB, GiB), showing one decimal place when needed.
# @param bytes [Integer] size in bytes
# @return [String] "1.0K", "23.8M", "8.0G" and such
def format_byte_size(bytes)
  return '0' if bytes.zero?
  return '-' + format_byte_size(-bytes) if bytes.negative?
  
  units = ['', 'K', 'M', 'G', 'T', 'P']

  # Use 1024-based units (KiB, MiB, etc.)
  exp = (Math.log(bytes, 1024)).floor
  exp = 5 if exp > 5 # Cap at petabytes

  value = bytes.to_f / (1024 ** exp)
  
  # Show one decimal if it's not a whole number, otherwise none
  formatted = if value >= 10 || value.truncate == value
                value.round.to_s
              else
                value.round(1)
              end

  "#{formatted} #{units[exp]}".strip
end

