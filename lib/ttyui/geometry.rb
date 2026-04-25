# frozen_string_literal: true

# A point with {Integer} `x` and `y`, both 0-based.
class Point < Data.define(:x, :y)
  def to_s = "#{x},#{y}"
end

# A size with {Integer} `width` and `height`.
class Size < Data.define(:width, :height)
  def to_s = "#{width}x#{height}"

  # @return [Boolean] true if either {:width} or {:height} is zero or negative.
  def empty?
    width <= 0 || height <= 0
  end

  # @param width [Integer]
  # @param height [Integer]
  # @return [Size]
  def plus(width, height) = Size.new(self.width + width, self.height + height)

  # Clamp both width and height and returns a size.
  # @param max_width [Integer] the max width
  # @param max_height [Integer] the max height
  # @return [Size]
  def clamp(max_width, max_height)
    new_width = width.clamp(nil, max_width)
    new_height = height.clamp(nil, max_height)
    new_width == width && new_height == height ? self : Size.new(new_width, new_height)
  end

  # Clamp height and returns a size.
  # @param max_height [Integer] the max height
  # @return [Size]
  def clamp_height(max_height) = clamp(width, max_height)
end

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

  # @return [Size]
  def size = Size.new(width, height)
end
