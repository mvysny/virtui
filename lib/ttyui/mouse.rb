# frozen_string_literal: true

# A mouse event:
# - `button` is a {Symbol}, one of `:left`, `:middle`, `:right`, `:scroll_up`, `:scroll_down`; `nil` if not known.
# - `x` {Integer} x coordinate, 1-based.
# - `y` {Integer} y coordinate, 1-based.
class MouseEvent < Data.define(:button, :x, :y)
  # Checks whether given key is a mouse event key
  # @param key [String] key read via {Keys.getkey}
  # @return [Boolean] true if it is a mouse event
  def self.mouse_event?(key)
    key.start_with?('[M') && key.size >= 5
  end

  # @param key [String] key read via {Keys.getkey}
  # @return [MouseEvent | nil]
  def self.parse(key)
    return nil unless mouse_event?(key)

    button = $stdin.getc.ord - 32
    x = $stdin.getc.ord - 32
    y = $stdin.getc.ord - 32
    button = case button
             when 0 then :left
             when 2 then :right
             when 1 then :middle
             when 64 then :scroll_up
             when 65 then :scroll_down
             end
    MouseEvent.new(button, x, y)
  end
end
