# frozen_string_literal: true

require 'rainbow'
require_relative 'sysinfo'
require_relative 'utils'

# Formats
class Formatter
  # Draws pretty progress bar as one row.
  # @param width [Integer] the width of the progress bar, in characters. The height is always 1.
  # @param value [Integer] the value
  # @param max_value [Integer] the max value
  # @param color [Symbol | String] color
  # @return [String] Rainbow progress bar
  def progress_bar2(width, value, max_value, color, char = '#')
    raise "#{max_value} must not be negative" if max_value.negative?
    return '' if max_value.zero? || width.zero?

    value = value.clamp(0, max_value)
    progressbar_char_length = (value * width / max_value).to_i
    pb = char * progressbar_char_length
    Rainbow(pb).fg(color) + Rainbow('-' * (width - progressbar_char_length)).fg('#333333')
  end
end
