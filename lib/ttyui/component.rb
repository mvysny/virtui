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
  def repaint; end

  protected

  # Called whenever the component width changes. Does nothing by default.
  def on_width_changed; end

  # Invalidates the component: {Screen} records this component as needs-repaint and
  # once all events are processed, will call {:repaint}.
  def invalidate
    screen.invalidate(self)
  end
end
