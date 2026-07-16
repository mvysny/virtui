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
    def progress_bar(width, value, max_value, color, rest_color, char = '#')
      raise "#{max_value} must not be negative" if max_value.negative?
      return Tuile::StyledString::EMPTY if max_value.zero? || width.zero?

      value = value.clamp(0, max_value)
      progressbar_char_length = (value * width / max_value).to_i
      Tuile::StyledString.styled(char * progressbar_char_length, fg: color) +
        Tuile::StyledString.styled('-' * (width - progressbar_char_length), fg: rest_color)
    end

    # Renders a labelled progress-bar segment: `left` caption (left-padded to `label_width`,
    # unless empty), the {#progress_bar} filling the middle, then `right` caption
    # (right-padded to 6), all within `width` characters:
    #
    #   labelled_bar(24, "50%", "128G", 50, 100, cpu, frame, label_width: 11)
    #   # => "50%        ####----     128G"  (ANSI-colored bar in the middle)
    #
    # The bar shrinks to fit the captions and collapses to empty when there's no room.
    #
    # @param width [Integer] total segment width, in characters
    # @param left [String] left caption; left-padded to `label_width` unless empty
    # @param right [String] right caption; right-padded to 6 characters
    # @param value [Numeric] current value, for drawing the bar
    # @param max_value [Numeric] max value, for drawing the bar
    # @param color [Tuile::Color] color of the bar's filled portion
    # @param rest_color [Tuile::Color] color of the bar's unfilled portion
    # @param label_width [Integer] width the `left` caption is padded to
    # @return [String] the rendered segment, including ANSI color codes
    def labelled_bar(width, left, right, value, max_value, color, rest_color, label_width:)
      left = left.ljust(label_width) unless left.empty?
      right = right.rjust(6)
      pb_width = (width - left.size - right.size).clamp(0, nil)
      left + progress_bar(pb_width, value, max_value, color, rest_color).to_ansi + right
    end
  end
end
