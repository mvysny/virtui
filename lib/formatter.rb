# frozen_string_literal: true

require 'rainbow'
require_relative 'virt'
require_relative 'sysinfo'

# Formats
class Formatter
  # Pretty-formats given object
  # @param what the object to format
  # @return [String] a Rainbow-formatted object
  def format(what)
    case what
    when CpuInfo
      format_cpu(what)
    when MemoryStat
      format_memory_stat(what)
    when MemStat
      format_mem_stat(what)
    when MemoryUsage
      format_memory_usage(what)
    when DiskStat
      format_disk_stat(what)
    else
      what.to_s
    end
  end

  # @param cpu [CpuInfo]
  def format_cpu(cpu)
    "#{Rainbow('CPU').bright.blue}: #{Rainbow(cpu.model).bright.blue}: #{Rainbow(cpu.cpus).cyan} cores"
  end

  # @param memory_stat [MemoryStat]
  def format_memory_stat(memory_stat)
    "#{Rainbow('RAM').bright.red}: #{format(memory_stat.ram)}; #{Rainbow('SWAP').bright.red}: #{format(memory_stat.swap)}"
  end

  # @param memory_usage [MemoryUsage]
  def format_memory_usage(memory_usage)
    r = "#{Rainbow(format_byte_size(memory_usage.used)).cyan}/#{Rainbow(format_byte_size(memory_usage.total)).cyan}"
    r += " (#{Rainbow(memory_usage.percent_used).cyan}%)"
    r
  end

  # @param state [Symbol] one of `:running`, `:shut_off`, `:paused`
  def format_domain_state(state)
    running = Rainbow("\u{25B6}").green
    paused = Rainbow("\u{23F8}").yellow
    off    = Rainbow("\u{23F9}").darkred
    unknown = Rainbow('?').red
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

  # @param disk_stat [DiskStat]
  def format_disk_stat(disk_stat)
    line = "#{disk_stat.name}: [#{progress_bar(20, 100, [[disk_stat.percent_used.to_i, :white]])}]"
    overhead = disk_stat.overhead_percent
    overhead_color = case overhead
                     when ..10
                       :green
                     when 10..20
                       :yellow
                     else
                       :red
                     end
    line += " #{Rainbow(format_byte_size(disk_stat.allocation)).white}/#{Rainbow(format_byte_size(disk_stat.capacity)).white}"
    line += ", host qcow2 #{Rainbow(overhead).bright.color(overhead_color)}%"
    line
  end

  # Draws pretty progress bar as one row. Supports paiting multiple values into the same row.
  # @param width the width of the progress bar, in characters. The height is always 1.
  # @param max_value [Integer] the max value
  # @param values [Array<Array<Integer, Symbol>>] maps value to the Rainbow color to draw with, e.g. `:red` or `:yellow`.
  # @return [String] Rainbow progress bar
  def progress_bar(width, max_value, values, char = '#')
    raise "#{max_value} must not be negative" if max_value.negative?
    return '' if max_value.zero? || width.zero?
    return ' ' * width if values.empty?

    values = values.sort_by { |value, _| value }
    result = ''
    length = 0
    values.each do |value, color|
      next if value <= 0

      progressbar_char_length = value.clamp(0, max_value) * width / max_value
      next unless length < progressbar_char_length

      chars = char * (progressbar_char_length - length)
      length = progressbar_char_length
      result += Rainbow(chars).fg(color)
    end
    result + ' ' * (width - length)
  end
end

# Pretty-format bytes with suffixes like k, m, g (for KiB, MiB, GiB), showing one decimal place when needed.
# @param bytes [Integer] size in bytes
# @return [String] "1.0K", "23.8M", "8.0G" and such
def format_byte_size(bytes)
  return '0' if bytes.zero?
  return "-#{format_byte_size(-bytes)}" if bytes.negative?

  units = ['', 'K', 'M', 'G', 'T', 'P']

  # Use 1024-based units (KiB, MiB, etc.)
  exp = Math.log(bytes, 1024).floor
  exp = 5 if exp > 5 # Cap at petabytes

  value = bytes.to_f / (1024**exp)

  # Show one decimal if it's not a whole number, otherwise none
  decimals = value >= 10 || value.round == value ? 0 : 1
  "#{value.round(decimals)}#{units[exp]}"
end
