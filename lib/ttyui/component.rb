# frozen_string_literal: true

# A rectangle, with {Integer} `left`, `top`, `width` and `height`, all 0-based.
class Rect < Data.define(:left, :top, :width, :height)
  def to_s = "#{left},#{top} #{width}x#{height}"

  # @return [Boolean] true if either {:width} or {:height} is zero or negative.
  def empty?
    width <= 0 || height <= 0
  end

  # @return [Rect] positioned at the new `left`/`top`.
  def at(left, top)
    Rect.new(left, top, width, height)
  end

  # Centers the rectangle - keeps {:width} and {:height} but modifies
  # {:top} and {:left} so that the rectangle is centered on a screen.
  # @param screen_width [Integer] screen width
  # @param screen_height [Integer] screen height
  # @return [Rect] moved rectangle.
  def centered(screen_width, screen_height)
    at((screen_width - width) / 2, (screen_height - height) / 2)
  end

  # Clamp both width and height and returns a rectangle.
  # @param max_width [Integer] the max width
  # @param max_height [Integer]
  # @return [Rect]
  def clamp(max_width, max_height)
    new_width = width.clamp(nil, max_width)
    new_height = height.clamp(nil, max_height)
    new_width == width && new_height == height ? self : Rect.new(left, top, new_width, new_height)
  end

  # @param x [Integer] 0-based
  # @param y [Integer] 0-based
  # @return [Boolean]
  def contains?(x, y) = x >= left && x < left + width && y >= top && y < top + height
end

# A ui component which is positioned on the screen and
# draws characters into its bounding rectangle.
#
# Component is considered invisible if {#rect} is empty or one of left/top is negative.
# The component won't draw when invisible.
class Component
  def initialize
    @rect = Rect.new(0, 0, 0, 0)
    @active = false
  end

  # @return [Rect] the rectangle the component occupies on screen.
  attr_reader :rect

  # Sets new position of the component.
  # @param new_rect [Rect] new position. Does nothing if the new rectangle is same as
  # the old one.
  def rect=(new_rect)
    raise "invalid rect #{new_rect}" unless new_rect.is_a? Rect
    return if @rect == new_rect

    prev_width = @rect.width
    @rect = new_rect
    on_width_changed if prev_width != new_rect.width
    invalidate
  end

  # @return [Screen] the screen which owns this component
  def screen = Screen.instance

  # Repaints the component. Default implementation does nothing.
  #
  # Tip: use {:clear_background} to clear component background before painting.
  def repaint; end

  # Called when a character is pressed on the keyboard and this component is focused/active.
  #
  # Default implementation does nothing and returns `false`.
  # @param key [String] a key.
  # @return [Boolean] true if the key was handled, false if not.
  def handle_key(_key)
    false
  end

  # Handles mouse event. Default impl does nothing.
  # @param event [MouseEvent]
  def handle_mouse(event); end

  # @return [Boolean] if the component is active. Active component receives keyboard input (unless there's a
  # popup window).
  def active? = @active

  # @param active [Boolean] true if active. Active component
  # receives keyboard input (unless there's another popup window).
  def active=(active)
    active = !!active
    raise 'Can not activate this component' if active && !can_activate?
    return unless @active != active

    @active = active
    invalidate
  end

  # Checks whether the component can receive keyboard input. `false`
  # by default. Passive components like {Label} can't receive input.
  # @return [Boolean] true if the component can be made active.
  def can_activate? = false

  protected

  # Called whenever the component width changes. Does nothing by default.
  def on_width_changed; end

  # Invalidates the component: {Screen} records this component as needs-repaint and
  # once all events are processed, will call {:repaint}.
  def invalidate
    screen.invalidate(self)
  end

  # Clears the background: prints spaces into all characters occupied by the component's rect.
  def clear_background
    return if rect.empty?

    spaces = ' ' * rect.width
    (rect.top..(rect.top + rect.height)).each do |row|
      screen.print TTY::Cursor.move_to(rect.left, row), spaces
    end
  end
end

class Component
  # A label which shows static text. No word-wrapping; clips long lines.
  class Label < Component
    def initialize
      super
      @lines = []
      @clipped_lines = []
    end

    # @param text [String | nil] draws this text. May contain ANSI formatting. Clipped automatically.
    def text=(text)
      @lines = text.to_s.split("\n")
      update_clipped_text
    end

    def repaint
      clear_background
      (0..(@clipped_lines.length - 1)).each do |index|
        screen.print TTY::Cursor.move_to(rect.left, rect.top + index), @clipped_lines[index]
      end
    end

    protected

    def on_width_changed
      super
      update_clipped_text
    end

    private

    def update_clipped_text
      len = rect.width.clamp(0, nil)
      clipped = @lines.map do |line|
        Strings::Truncation.truncate(line, length: len)
      end
      return if @clipped_lines == clipped

      @clipped_lines = clipped
      invalidate
    end
  end
end
