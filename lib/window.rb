# frozen_string_literal: true

require 'tty-box'
require 'tty-cursor'
require 'pastel'
require 'unicode/display_width'
require 'strings-truncation'

# A rectangle, with {Integer} `left`, `top`, `width` and `height`.
class Rect < Data.define(:left, :top, :width, :height)
  def empty?
    width <= 0 || height <= 0
  end
end

# A very simple textual window. Doesn't support overlapping with other windows.
# The content is a list of lines painted into the window. The lines are automatically
# clipped both vertically and horizontally so that the text contents won't overflow
# the window.
class Window
  def initialize(caption = '')
    # {Rect} absolute coordinates of the window.
    @rect = Rect.new(0, 0, 0, 0)
    # {String} Window caption, shown in the upper-left part
    @caption = caption
    # {Array<String>} Contents of the window.
    @lines = []
    # {Boolean} if true and a line is added or a new content is set, auto-scrolls to the bottom
    @auto_scroll = false
    # {Pastel} use this to draw colors
    @p = Pastel.new
    # {Integer} zero or positive: top line to paint.
    @top_line = 0
  end

  attr_reader :caption, :rect, :p, :auto_scroll, :top_line

  # Sets the new auto_scroll. If true, immediately scrolls to the bottom.
  # @param new_auto_scroll [Boolean] if true, keep scrolled to the bottom.
  def auto_scroll=(new_auto_scroll)
    @auto_scroll = auto_scroll
    update_top_line_if_auto_scroll
  end

  # Sets new caption and repaints the window
  # @param new_caption [String | nil]
  def caption=(new_caption)
    @caption = new_caption
    repaint
  end

  # Scrolls the window contents by setting the new top line
  # @new_top_line [Integer] 0 or greater
  def top_line=(new_top_line)
    raise 'Not an Integer' unless new_top_line.is_a? Integer
    raise "#{new_top_line} must not be negative" if new_top_line.negative?
    return unless @top_line != new_top_line

    @top_line = new_top_line
    repaint_content
  end

  # Sets new position of the window.
  # @param new_rect [Rect] new position
  def rect=(new_rect)
    raise "invalid rect #{new_rect}" unless new_rect.is_a? Rect

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

  # Fully re-populates the contents of this window in a block:
  # ```
  # window.content do |lines|
  #   lines << 'Hello!'
  # end
  # ````
  def content
    lines = []
    yield lines
    self.content = lines
  end

  # Adds a line to the list of lines.
  # @oaram line [String]
  def add_line(line)
    add_lines [line]
  end

  # Appends given lines.
  # @param lines [Array<String>]
  def add_lines(lines)
    @lines += lines
    # TODO: optimize
    repaint_content unless update_top_line_if_auto_scroll
  end

  private

  # If auto-scrolling, recalculate the top line and optionally repaint content
  # if top line changed.
  # @return [Boolean] true if the content was repainted, false if nothing was done
  def update_top_line_if_auto_scroll
    return false unless @auto_scroll

    new_top_line = (@lines.size - rect.width).clamp(0, nil)
    return false unless @top_line != new_top_line

    self.top_line = new_top_line
    true
  end

  # Fully repaints the window: both frame and Contents
  def repaint
    return if @rect.empty? || @rect.top.negative? || @rect.left.negative?

    print TTY::Box.frame(
      width: @rect.width, height: @rect.height, top: @rect.top, left: @rect.left,
      title: { top_left: @caption || '' }
    )
    repaint_content
  end

  def repaint_content
    return if @rect.empty? || @rect.top.negative? || @rect.left.negative?

    width = @rect.width - 4 # 1 character for window frame, 1 character for padding

    (0..(@rect.height - 3)).each do |line_no|
      line = (@lines[@top_line + line_no] || '').to_s
      truncated_line = Strings::Truncation.truncate(line, length: width)

      if truncated_line == line
        # nothing was truncated, perhaps we need to add whitespaces,
        # to repaint over old content.
        # strip the formatting before counting printable characters
        length = Unicode::DisplayWidth.of(@p.strip(line))
        line += ' ' * (width - length) if length < width
      else
        line = truncated_line
      end

      print TTY::Cursor.move_to(@rect.left + 2, line_no + @rect.top + 1), line
    end
  end
end

# Shows a log. Call one of [:error], [:warning], [:info], [:debug]
# to log stuff.
class LogWindow < Window
  def initialize
    super('Log')
    self.log_level = 'W'
    self.auto_scroll = true
  end

  # @param new_log_level [String] one of 'D', 'I', 'W', 'E'.
  def log_level=(new_log_level)
    @log_level = 'DIWE'.index new_log_level || 3
  end

  def debug_enabled?
    @log_level <= 0
  end

  def info_enabled?
    @log_level <= 1
  end

  def warning_enabled?
    @log_level <= 2
  end

  def error(text, exception: nil)
    log 'E', text, exception
  end

  def warning(text, exception: nil)
    log 'W', text, exception if warning_enabled?
  end

  def info(text, exception: nil)
    log 'I', text, exception if info_enabled?
  end

  def debug(text, exception: nil)
    log 'D', text, exception if debug_enabled?
  end

  private

  def log(level, text, exception)
    text = "#{Time.now.strftime('%H:%M:%S')} #{level} #{text}"
    text_lines = text.lines(chomp: true)
    unless exception.nil?
      text_lines << exception.message
      text_lines += exception.backtrace.first(3) unless exception.backtrace.nil?
    end
    add_lines text_lines
  end
end
