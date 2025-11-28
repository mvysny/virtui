# frozen_string_literal: true

require 'rainbow'
require_relative 'virt'
require_relative 'sysinfo'
require_relative 'utils'

# Formats
class Formatter
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

  # Draws pretty progress bar as one row. Supports paiting multiple values into the same row.
  # @param width the width of the progress bar, in characters. The height is always 1.
  # @param value [Integer] the value
  # @param max_value [Integer] the max value
  # @param color [Symbol | String] color
  # @return [String] Rainbow progress bar
  def progress_bar2(width, value, max_value, color, char = '#')
    raise "#{max_value} must not be negative" if max_value.negative?
    return '' if max_value.zero? || width.zero?
    raise "non-integer value: #{value}" unless value.is_a? Integer

    value = value.clamp(0, max_value)
    progressbar_char_length = value * width / max_value
    pb = char * progressbar_char_length
    Rainbow(pb).fg(color) + Rainbow('-' * (width - progressbar_char_length)).fg('#333333')
  end
end
