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
class Window
  def initialize(caption = '')
    @rect = Rect.new(0, 0, 0, 0)
    @caption = caption
    @lines = []
    @auto_scroll = false
    @p = Pastel.new
  end

  attr_reader :caption, :rect, :p

  # Sets new caption and repaints the window
  # @param new_caption [String | nil]
  def caption=(new_caption)
    @caption = new_caption
    repaint
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

  def content
    lines = []
    yield lines
    self.content = lines
  end

  private def repaint
    return if @rect.empty? || @rect.top.negative? || @rect.left.negative?

    print TTY::Box.frame(
      width: @rect.width, height: @rect.height, top: @rect.top, left: @rect.left,
      title: { top_left: @caption || '' }
    )
    repaint_content
  end

  private

  def repaint_content
    return if @rect.empty? || @rect.top.negative? || @rect.left.negative?

    width = @rect.width - 4 # 1 character for window frame, 1 character for padding

    (0..(@rect.height - 3)).each do |line_no|
      line = (@lines[line_no] || '').to_s
      truncated_line = Strings::Truncation.truncate(line, omission: '', length: width)

      if truncated_line == line
        # nothing was truncated, perhaps we need to add whitespaces.
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
    @log_lines = []
    self.log_level = 'W'
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

  private def ellipsize(str, max_length)
    str.length <= max_length ? str : "#{str[0...(max_length - 2)]}.."
  end

  private def log(level, text, exception)
    text = "#{Time.now.strftime('%H:%M:%S')} #{level} #{text}"
    text_lines = text.lines(chomp: true)
    unless exception.nil?
      text_lines << exception.message
      text_lines += exception.backtrace.first(3) unless exception.backtrace.nil?
    end
    @log_lines += text_lines
    @log_lines = @log_lines.last((rect.height - 2).clamp(0..100))
    content_width = rect.width - 4
    if content_width.negative?
      self.content = []
    else
      @log_lines.map! { |it| ellipsize(it, content_width) }
      self.content = @log_lines
    end
  end
end
