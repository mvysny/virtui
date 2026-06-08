# frozen_string_literal: true

module UI
  # Formats
  class Formatter
    # Draws pretty progress bar as one row.
    # @param width [Integer] the width of the progress bar, in characters. The height is always 1.
    # @param value [Integer] the value
    # @param max_value [Integer] the max value
    # @param color [Tuile::Color] color of the filled portion
    # @param rest_color [Tuile::Color] color of the unfilled portion
    # @return [Tuile::StyledString] progress bar
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
