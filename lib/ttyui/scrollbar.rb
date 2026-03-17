# frozen_string_literal: true

# A vertical scrollbar that computes which character to draw at each row.
#
# For height == 1, every row shows '|'.
# For height == 2, row 0 shows '▲' and row 1 shows '▼'.
# For height > 2, row 0 is '▲', the last row is '▼', and the middle track
# uses a handle (█) against a background (░); handle geometry is precomputed
# in the constructor as {#handle_height}, {#handle_start}, and {#handle_end}.
class VerticalScrollBar
  # @return [Integer] number of track rows the handle occupies (height > 2 only).
  attr_reader :handle_height
  # @return [Integer] 0-based track-row where the handle starts (height > 2 only).
  attr_reader :handle_start
  # @return [Integer] 0-based track-row where the handle ends (height > 2 only).
  attr_reader :handle_end

  # @param height [Integer] number of rows in the scrollbar (== viewport height).
  # @param line_count [Integer] total number of content lines.
  # @param top_line [Integer] index of the first visible content line.
  def initialize(height, line_count:, top_line:)
    @height = height
    @line_count = line_count

    return unless height > 2

    track_size = height - 2
    if line_count <= height
      @handle_height = track_size
      @handle_start  = 0
      @handle_end    = track_size - 1
    else
      @handle_height = [(track_size * height / line_count.to_f).ceil, track_size].min
      @handle_height = [@handle_height, 1].max
      @handle_start  = (track_size * top_line / line_count.to_f).floor
      @handle_end    = @handle_start + @handle_height - 1
    end
  end

  # Returns the scrollbar character for the given viewport row.
  # @param row_in_viewport [Integer] 0-based row index within the viewport.
  # @return [String] single scrollbar character.
  def scrollbar_char(row_in_viewport)
    h = @height
    return '|' if h <= 1
    return row_in_viewport == 0 ? '▲' : '▼' if h == 2

    return '▲' if row_in_viewport == 0
    return '▼' if row_in_viewport == h - 1

    track_row = row_in_viewport - 1
    track_row >= @handle_start && track_row <= @handle_end ? '█' : '░'
  end
end
