# frozen_string_literal: true

require 'tty-box'
require 'rainbow'
require 'unicode/display_width'
require 'strings-truncation'
require 'tty-logger'
require_relative 'keys'
require_relative 'screen'

# A rectangle, with {Integer} `left`, `top`, `width` and `height`.
class Rect < Data.define(:left, :top, :width, :height)
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
    at((width - screen_width) / 2, (height - screen_height) / 2)
  end
end

# A window with a frame, a [:caption] and text contents. Doesn't support overlapping with other windows:
# it paints its entire contents and doesn't clip if there are other overlapping windows.
#
# The content is a list of lines painted into the window. The lines are automatically
# clipped horizontally. Vertical scrolling is supported, via [:top_line]; the window
# can also automatically scroll to the bottom if [:auto_scroll] is enabled.
#
# Cursor is supported too, call [:cursor=] to change the behavior of the cursor.
# The cursor responds to arrows and `jk` and scrolls the window contents automatically.
#
# Window is considered invisible if [:rect] is empty or one of left/top is negative.
# The window won't draw when invisible. You can use this feature: simply set left/top to -1
# to prevent window from drawing.
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
    # {Integer} zero or positive: top line to paint.
    @top_line = 0
    # {Cursor} cursor, none by default.
    @cursor = Cursor::None.new
    # {Boolean} true if window is active
    @active = false
  end

  attr_reader :caption, :rect, :p, :auto_scroll, :top_line, :cursor

  # @return [Screen] the screen which owns the window.
  def screen = Screen.instance

  # Moves window to center it on screen. Consults [Rect:width] and [Rect:height]
  # and modifies [Rect:top] and [Rect:left].
  def center
    self.rect = rect.centered(screen.size.width, screen.size.height)
  end

  # Sets the new auto_scroll. If true, immediately scrolls to the bottom.
  # @param new_auto_scroll [Boolean] if true, keep scrolled to the bottom.
  def auto_scroll=(new_auto_scroll)
    @auto_scroll = new_auto_scroll
    update_top_line_if_auto_scroll
  end

  # Sets new caption and repaints the window
  # @param new_caption [String | nil]
  def caption=(new_caption)
    @caption = new_caption
    repaint
  end

  # Sets a new cursor.
  # @param cursor [Cursor] new cursor.
  def cursor=(cursor)
    raise 'Not a Cursor' unless cursor.is_a? Cursor

    old_position = @cursor.position
    @cursor = cursor
    repaint_content if old_position != cursor.position
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

  # @return [Boolean]
  def active?
    @active
  end

  # @param active [Boolean] true if active. Active window has green border.
  def active=(active)
    active = !!active
    return unless @active != active

    @active = active
    repaint_border
  end

  # Sets new position of the window.
  # @param new_rect [Rect] new position. Does nothing if the new rectangle is same as
  # the old one.
  def rect=(new_rect)
    raise "invalid rect #{new_rect}" unless new_rect.is_a? Rect
    return if @rect == new_rect

    prev_width = @rect.width
    @rect = new_rect
    on_width_changed if prev_width != new_rect.width
    repaint
  end

  # Sets new position of the window. Always repaints, even if the new rectangle is same
  # as the old one.
  # @param new_rect [Rect] new position.
  def set_rect_and_repaint(new_rect)
    raise "invalid rect #{new_rect}" unless new_rect.is_a? Rect

    prev_width = @rect.width
    @rect = new_rect
    on_width_changed if prev_width != new_rect.width
    repaint
  end

  # Sets new content of the window, as an array of {String}s.
  # @param lines [Array<String>] new content
  def content=(lines)
    raise 'lines must be Array' unless lines.is_a? Array

    @lines = lines
    repaint_content unless update_top_line_if_auto_scroll
  end

  # Fully re-populates the contents of this window in a block:
  # ```
  # window.content do |lines|
  #   lines << 'Hello!'
  # end
  # ````
  def content
    return @lines unless block_given?

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
    # split lines by newline
    lines = lines.flat_map { it.to_s.split("\n") }
    @lines += lines.map(&:rstrip)
    # TODO: optimize - if no scrolling is done then perhaps only the new line needs to be painted.
    repaint_content unless update_top_line_if_auto_scroll
  end

  # Called when a character is pressed on the keyboard.
  # @param key [String] a key.
  def handle_key(key)
    if key == Keys::PAGE_UP
      move_top_line_by(-viewport_lines)
    elsif key == Keys::PAGE_DOWN
      move_top_line_by(viewport_lines)
    else
      return unless @cursor.handle_key(key, @lines.size, viewport_lines)
      return if move_viewport_to_cursor

      repaint_content
    end
  end

  # @return [String] formatted keyboard hint for users. Empty by default.
  def keyboard_hint
    ''
  end

  # @return [Boolean] true if [:rect] is off screen and the window won't paint.
  def visible?
    !@rect.empty? && !@rect.top.negative? && !@rect.left.negative? && open?
  end

  # Removes the window from the screen.
  def close
    screen.remove_window(self)
  end

  # @return [Boolean] true if this window is part of a screen. May not be visible.
  def open?
    screen.has_window?(self)
  end

  # Fully repaints the window: both frame and contents.
  def repaint
    repaint_border
    repaint_content
  end

  protected

  # Called whenever the window width changes. Does nothing by default.
  def on_width_changed; end

  private

  # Scrolls window viewport so that the cursor is visible. Repaints content if viewport was scrolled.
  # @return [Boolean] true if the viewport was moved and the window repainted, false if nothing was done.
  def move_viewport_to_cursor
    pos = @cursor.position
    return false unless pos >= 0

    if @top_line > pos
      self.top_line = pos
      return true
    elsif pos > @top_line + rect.height - 3
      self.top_line = pos - rect.height + 3
      return true
    end
    false
  end

  # @return [Integer] the max value of {@top_line}
  def top_line_max = (@lines.size - rect.height + 2).clamp(0, nil)

  # @return [Integer] the viewport height in lines.
  def viewport_lines = rect.height - 2

  # Scrolls window contents.
  # @param delta [Integer] negative value scrolls up, positive value scrolls down.
  def move_top_line_by(delta)
    new_top_line = (@top_line + delta).clamp(0, top_line_max)
    return if @top_line == new_top_line

    @top_line = new_top_line
    repaint_content
  end

  # If auto-scrolling, recalculate the top line and optionally repaint content
  # if top line changed.
  # @return [Boolean] true if the content was repainted, false if nothing was done
  def update_top_line_if_auto_scroll
    return false unless @auto_scroll

    new_top_line = (@lines.size - viewport_lines).clamp(0, nil)
    return false unless @top_line != new_top_line

    self.top_line = new_top_line
    true
  end

  def repaint_border
    return unless visible?

    frame = TTY::Box.frame(
      width: @rect.width, height: @rect.height, top: @rect.top, left: @rect.left,
      title: { top_left: @caption || '' }
    )
    frame = Rainbow(frame).green if @active
    print frame
  end

  def repaint_content
    return unless visible?

    width = @rect.width - 4 # 1 character for window frame, 1 character for padding, both sides

    (0..(@rect.height - 3)).each do |line_no|
      line_index = line_no + @top_line
      line = (@lines[line_index] || '').to_s
      truncated_line = Strings::Truncation.truncate(line, length: width)

      if truncated_line == line
        # nothing was truncated, perhaps we need to add whitespaces,
        # to repaint over old content.
        # strip the formatting before counting printable characters
        length = Unicode::DisplayWidth.of(Rainbow.uncolor(line))
        line += ' ' * (width - length) if length < width
      else
        line = truncated_line
      end

      print TTY::Cursor.move_to(@rect.left + 2, line_no + @rect.top + 1)
      is_cursor = line_index < @lines.size && @cursor.position == line_index
      if is_cursor
        print Rainbow(Rainbow.uncolor(line)).bg(:darkslategray)
      else
        print line
      end
    end
  end

  # Tracks window cursor as it hops over window content lines.
  class Cursor
    # @param position [Integer] the initial cursor position
    def initialize(position: 0)
      # {Integer} 0-based index of line
      @position = position
    end

    # No cursor - cursor is disabled.
    class None < Cursor
      def initialize
        super(position: -1)
        freeze
      end

      def handle_key(_key, _line_count, _viewport_lines)
        false
      end
    end

    attr_reader :position

    # @param key [String] pressed keyboard key
    # @param line_count [Integer] number of lines in owner {Window}
    # @param viewport_lines [Integer] number of lines of the window viewport.
    # @return [Boolean] true if the cursor moved and window needs repaint.
    def handle_key(key, line_count, viewport_lines)
      case key
      when *Keys::DOWN_ARROWS
        go_down_by(1, line_count)
      when *Keys::UP_ARROWS
        go_up_by(1)
      when Keys::HOME
        go_to_first
      when Keys::END_
        go_to_last(line_count)
      when Keys::CTRL_U
        go_up_by(viewport_lines / 2)
      when Keys::CTRL_D
        go_down_by(viewport_lines / 2, line_count)
      else
        false
      end
    end

    def position=(position)
      raise 'must be integer 0 or greater' if position.negative? || !position.is_a?(Integer)

      @position = position
    end

    protected

    def go(new_position)
      return false if new_position.nil?

      new_position = new_position.clamp(0, nil)
      return false if @position == new_position

      @position = new_position
      true
    end

    def go_down_by(lines, line_count)
      go((@position + lines).clamp(nil, line_count - 1))
    end

    def go_up_by(lines)
      go(@position - lines)
    end

    def go_to_first
      go(0)
    end

    def go_to_last(line_count)
      go(line_count - 1)
    end

    # Cursor which can not hop on just any line - only on allowed lines.
    # @param positions [Array<Integer>] a set of positions the cursor can visit. Can not be empty.
    # @param position [Integer] initial position
    class Limited < Cursor
      def initialize(positions, position: positions[0])
        @positions = positions.sort
        position = @positions[@positions.rindex { it < position } || 0] unless @positions.include?(position)
        super(position: position)
      end

      protected

      def go_down_by(lines, line_count)
        next_pos = @positions.find { it >= @position + lines }
        return go_to_last(line_count) if next_pos.nil?

        go(next_pos)
      end

      def go_up_by(lines)
        prev_index = @positions.rindex { it <= @position - lines }
        return go_to_first if prev_index.nil?

        go(@positions[prev_index])
      end

      def go_to_first
        go(@positions.first)
      end

      def go_to_last(_line_count)
        go(@positions.last)
      end
    end
  end
end

# Shows a log. Plug to `TTY::Logger`
# to log stuff straight from the logger: [:configure_logger].
class LogWindow < Window
  def initialize(caption = 'Log')
    super
    self.auto_scroll = true
    self.cursor = Cursor.new # allow scrolling when a long stacktrace is logged
  end

  # @param logger [TTY::Logger]
  def configure_logger(logger)
    logger.remove_handler :console
    logger.add_handler [:console, { output: LogWindow::IO.new(self), enable_color: true }]
  end

  class IO
    def initialize(window)
      @window = window
    end

    def puts(string)
      Screen.instance.with_lock do
        @window.add_line(string)
      end
    end
  end
end
