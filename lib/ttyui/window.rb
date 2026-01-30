# frozen_string_literal: true

require 'tty-box'
require 'rainbow'
require 'unicode/display_width'
require 'strings-truncation'
require 'tty-logger'
require_relative 'keys'
require_relative 'screen'

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

# A window with a frame, a {#caption} and text contents. Doesn't support overlapping with other windows:
# it paints its entire contents and doesn't clip if there are other overlapping windows.
#
# The content is a list of lines painted into the window. The lines are automatically
# clipped horizontally. Vertical scrolling is supported, via {#top_line}; the window
# can also automatically scroll to the bottom if {#auto_scroll} is enabled.
#
# Cursor is supported too, call {#cursor=} to change the behavior of the cursor.
# The cursor responds to arrows and `jk` and scrolls the window contents automatically.
#
# Window is considered invisible if {#rect} is empty or one of left/top is negative.
# The window won't draw when invisible.
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

  # @return [String] the current caption, empty by default.
  attr_reader :caption

  # @return [Rect] the rectangle the windows occupies on screen.
  attr_reader :rect

  # @return [Rect] the rectangle of the window viewport on screen.
  def viewport_rect = Rect.new(@rect.left + 1, @rect.top + 1, @rect.width - 2, @rect.height - 2)

  # @return [Boolean] if true and a line is added or a new content is set, auto-scrolls to the bottom
  attr_reader :auto_scroll

  # @return [Integer] top line of the window viewport. 0 or positive.
  attr_reader :top_line

  # @return [Cursor] the window's cursor.
  attr_reader :cursor

  # @return [Screen] the screen which owns the window.
  def screen = Screen.instance

  # Sets the new auto_scroll. If true, immediately scrolls to the bottom.
  # @param new_auto_scroll [Boolean] if true, keep scrolled to the bottom.
  def auto_scroll=(new_auto_scroll)
    @auto_scroll = new_auto_scroll
    update_top_line_if_auto_scroll
  end

  # Sets new caption and repaints the window
  # @param new_caption [String]
  def caption=(new_caption)
    @caption = new_caption
    invalidate
  end

  # Sets a new cursor.
  # @param cursor [Cursor] new cursor.
  def cursor=(cursor)
    raise 'Not a Cursor' unless cursor.is_a? Cursor

    old_position = @cursor.position
    @cursor = cursor
    invalidate if old_position != cursor.position
  end

  # Scrolls the window contents by setting the new top line
  # @new_top_line [Integer] 0 or greater
  def top_line=(new_top_line)
    raise 'Not an Integer' unless new_top_line.is_a? Integer
    raise "#{new_top_line} must not be negative" if new_top_line.negative?
    return unless @top_line != new_top_line

    @top_line = new_top_line
    invalidate
  end

  # @return [Boolean] if the window is active. Active window has green border and
  # usually receives keyboard input (unless there's another popup window).
  def active? = @active

  # @param active [Boolean] true if active. Active window has green border and
  # usually receives keyboard input (unless there's another popup window).
  def active=(active)
    active = !!active
    return unless @active != active

    @active = active
    invalidate
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
    invalidate
  end

  # Sets new content of the window, as an array of {String}s.
  # @param lines [Array<String>] new content
  def content=(lines)
    raise 'lines must be Array' unless lines.is_a? Array

    @lines = lines
    update_top_line_if_auto_scroll
    invalidate
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
    screen.check_locked
    # split lines by newline
    lines = lines.flat_map { it.to_s.split("\n") }
    @lines += lines.map(&:rstrip)
    # TODO: optimize - if no scrolling is done then perhaps only the new line needs to be painted.
    update_top_line_if_auto_scroll
    invalidate
  end

  # Called when a character is pressed on the keyboard.
  # @param key [String] a key.
  # @return [Boolean] true if the key was handled, false if not.
  def handle_key(key)
    if key == Keys::PAGE_UP
      move_top_line_by(-viewport_lines)
      true
    elsif key == Keys::PAGE_DOWN
      move_top_line_by(viewport_lines)
      true
    elsif @cursor.handle_key(key, @lines.size, viewport_lines)
      move_viewport_to_cursor
      invalidate # the cursor has been moved, repaint
      true
    else
      false
    end
  end

  # @param event [MouseEvent]
  def handle_mouse(event)
    vp = viewport_rect
    return unless vp.contains?(event.x - 1, event.y - 1)

    line = event.y - 1 - vp.top + top_line
    invalidate if @cursor.handle_mouse(line, event, @lines.size)
  end

  # @return [String] formatted keyboard hint for users. Empty by default.
  # Example: `p #{Rainbow('Power').cadetblue}`. If the window responds to keys,
  # override {#handle_key}
  def keyboard_hint
    ''
  end

  # @return [Boolean] true if {#rect} is off screen and the window won't paint.
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

  # Invalidates window: causes the window to be repainted by {Screen} later on.
  def invalidate
    screen.invalidate(self)
  end

  # Paints the window border.
  def repaint_border
    return unless visible?

    frame = TTY::Box.frame(
      width: @rect.width, height: @rect.height, top: @rect.top, left: @rect.left,
      title: { top_left: @caption || '' }
    )
    frame = Rainbow(frame).green if @active
    screen.print frame
  end

  private

  # Scrolls window viewport so that the cursor is visible. Repaints content if viewport was scrolled.
  def move_viewport_to_cursor
    pos = @cursor.position
    return unless pos >= 0

    if @top_line > pos
      self.top_line = pos
    elsif pos > @top_line + rect.height - 3
      self.top_line = pos - rect.height + 3
    end
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
    invalidate
  end

  # If auto-scrolling, recalculate the top line and optionally repaint content
  # if top line changed.
  def update_top_line_if_auto_scroll
    return unless @auto_scroll

    new_top_line = (@lines.size - viewport_lines).clamp(0, nil)
    return unless @top_line != new_top_line

    self.top_line = new_top_line
  end

  # Trims string exactly to [width] columns.
  # @return [String] trimmed string
  def trim_to(str, width)
    return ' ' * width if str.empty? # optimization

    # truncate() takes ANSI sequences into account.
    truncated_line = Strings::Truncation.truncate(str, length: width)
    return truncated_line unless truncated_line == str

    # nothing was truncated, perhaps we need to add whitespaces,
    # to repaint over old content.
    # strip the formatting before counting printable characters
    length = Unicode::DisplayWidth.of(Rainbow.uncolor(str))
    str += ' ' * (width - length) if length < width
    str
  end

  # @param index [Integer] 0-based index to {@lines}
  # @param width [Integer] number of columns for String to exactly occupy.
  # @return [String] paintable line {width} columns wide; shows cursor if needed.
  def paintable_line(index, width)
    line = (@lines[index] || '').to_s
    line = trim_to(line, width - 2)
    line = " #{line} "
    is_cursor = index < @lines.size && @cursor.position == index
    if is_cursor
      Rainbow(Rainbow.uncolor(line)).bg(:darkslategray)
    else
      line
    end
  end

  # Repaints window contents.
  def repaint_content
    return unless visible?

    width = @rect.width - 2

    (0..(@rect.height - 3)).each do |line_no|
      line_index = line_no + @top_line
      line = paintable_line(line_index, width)
      screen.print TTY::Cursor.move_to(@rect.left + 1, line_no + @rect.top + 1), line
    end
  end

  # Tracks window cursor as it hops over window content lines.
  class Cursor
    # @param position [Integer] the initial cursor position
    def initialize(position: 0)
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

      def handle_mouse(_line, _event, _line_count)
        false
      end
    end

    # @return [Integer] 0-based line index of the current cursor position
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

    # Handles mouse event.
    # @param line [Integer] cursor is hovering over this line
    # @param event [MouseEvent] the event
    # @param line_count [Integer] number of lines in owner {Window}
    def handle_mouse(_line, event, line_count)
      case event.button
      when :scroll_down then go_down_by(4, line_count)
      when :scroll_up then go_up_by(4)
      else false
      end
    end

    # Moves the cursor to the new position. Public only because of testing - don't call directly from outside of this class!
    # @param new_position [Integer] new 0-based cursor position.
    # @return [Boolean] true if the cursor position changed.
    def go(new_position)
      new_position = new_position.clamp(0, nil)
      return false if @position == new_position

      @position = new_position
      true
    end

    protected

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
        prev_pos = @positions.reverse_each.find { it <= @position - lines }
        return go_to_first if prev_pos.nil?

        go(prev_pos)
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

# Shows a log. Plug to {TTY::Logger}
# to log stuff straight from the logger: call {#configure_logger}.
class LogWindow < Window
  def initialize(caption = 'Log')
    super
    self.auto_scroll = true
    self.cursor = Cursor.new # allow scrolling when a long stacktrace is logged
  end

  # Reconfigures given logger to log to this window instead.
  # @param logger [TTY::Logger]
  def configure_logger(logger)
    logger.remove_handler :console
    logger.add_handler [:console, { output: LogWindow::IO.new(self), enable_color: true }]
  end

  # Helper class to handle logs from the logger and redirect it to
  # owner {LogWindow}.
  class IO
    def initialize(window)
      @window = window
    end

    def puts(string)
      @window.screen.event_queue.submit do
        @window.add_line(string)
      end
    end
  end
end
