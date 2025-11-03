require 'tty-box'
require 'tty-cursor'
require 'pastel'

$p = Pastel.new

# A rectangle, with {Integer} `top`, `left`, `width` and `height`.
class Rect < Data.define(:top, :left, :width, :height)
  def empty?
    width <= 0 || height <= 0
  end
end

# A very simple textual window. Doesn't support overlapping with other windows.
class Window
  def initialize(caption = '')
    @rect = Rect.new(0, 0, 0, 0)
    @caption = caption
    @lines = []
  end
  
  attr_reader :caption
  
  # Sets new caption and repaints the window
  # @param new_caption [String | nil]
  def caption=(new_caption)
    @caption = new_caption
    repaint
  end
  
  attr_reader :rect
  
  # Sets new position of the window.
  # @param new_rect [Rect] new position
  def rect=(new_rect)
    raise 'invalid rect #{new_rect}' unless new_rect.is_a? Rect
    @rect = new_rect
    repaint
  end
  
  # Sets new content of the window, as an array of {String}s.
  # @param lines [Array<String>] new content
  def content=(lines)
    raise 'lines must be Array' unless lines.is_a? Array
    @lines = lines
    repaint_content
  end
  
  private def repaint
    return if @rect.empty? || @rect.top < 0 || @rect.left < 0
    print TTY::Box.frame(
      width: @rect.width, height: @rect.height, top: @rect.top, left: @rect.left,
      title: { top_left: @caption || '' }
    )
    repaint_content
  end
  
  private def repaint_content
    return if @rect.empty? || @rect.top < 0 || @rect.left < 0
    width = @rect.width - 4   # 1 character for window frame, 1 character for padding
    
    (0..(@rect.height - 3)).each do |line_no|
      line = (@lines[line_no] || '').to_s
      # strip the formatting before counting printable characters
      length = $p.strip(line).length
      line += ' ' * (width - length) if length < width

      print TTY::Cursor.move_to(@rect.left + 2, line_no + @rect.top + 1), line
    end
  end
end

