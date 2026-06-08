# frozen_string_literal: true

module UI
  # Builds reusable styled-string fragments for the UI widgets.
  class Formatter
    # Renders a single-row progress bar as a styled string: the filled portion in `color`,
    # the remainder as dashes in `rest_color`. `value` is clamped to `0..max_value`.
    #
    # @param width [Integer] total width in characters (height is always 1)
    # @param value [Numeric] the current value
    # @param max_value [Numeric] the value corresponding to a full bar
    # @param color [Tuile::Color] color of the filled portion
    # @param rest_color [Tuile::Color] color of the unfilled portion
    # @param char [String] the character used for the filled portion
    # @return [Tuile::StyledString] the rendered bar; empty when `max_value` or `width` is zero
    # @raise [RuntimeError] if `max_value` is negative
    def progress_bar2(width, value, max_value, color, rest_color, char = '#')
      raise "#{max_value} must not be negative" if max_value.negative?
      return Tuile::StyledString::EMPTY if max_value.zero? || width.zero?

      value = value.clamp(0, max_value)
      progressbar_char_length = (value * width / max_value).to_i
      Tuile::StyledString.styled(char * progressbar_char_length, fg: color) +
        Tuile::StyledString.styled('-' * (width - progressbar_char_length), fg: rest_color)
    end
  end
end
