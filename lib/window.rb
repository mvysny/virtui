# frozen_string_literal: true

require 'tty-box'
require 'tty-cursor'
require 'rainbow'
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
    # {Integer} zero or positive: top line to paint.
    @top_line = 0
    # {Cursor} cursor, none by default.
    @cursor = Cursor::None.new
    # {Boolean} true if window is active
    @active = false
  end

  attr_reader :caption, :rect, :p, :auto_scroll, :top_line, :cursor

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
    @active = !!active
    repaint_border
  end

  # Sets new position of the window.
  # @param new_rect [Rect] new position
  def rect=(new_rect)
    raise "invalid rect #{new_rect}" unless new_rect.is_a? Rect
    return if @rect == new_rect

    @rect = new_rect
    repaint
  end

  def set_rect_and_repaint(new_rect)
    raise "invalid rect #{new_rect}" unless new_rect.is_a? Rect

    @rect = new_rect
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
    # TODO: optimize
    repaint_content unless update_top_line_if_auto_scroll
  end

  # Called when a character is pressed on the keyboard
  def handle_key(key)
    return unless active?

    repaint_content if @cursor.handle_key(key, @lines.size)
  end

  # @return [String] formatted keyboard hint for users. Empty by default.
  def keyboard_hint
    ''
  end

  private

  # If auto-scrolling, recalculate the top line and optionally repaint content
  # if top line changed.
  # @return [Boolean] true if the content was repainted, false if nothing was done
  def update_top_line_if_auto_scroll
    return false unless @auto_scroll

    new_top_line = (@lines.size - rect.height + 2).clamp(0, nil)
    return false unless @top_line != new_top_line

    self.top_line = new_top_line
    true
  end

  def rect_off_screen?
    @rect.empty? || @rect.top.negative? || @rect.left.negative?
  end

  # Fully repaints the window: both frame and Contents
  def repaint
    repaint_border
    repaint_content
  end

  def repaint_border
    return if rect_off_screen?

    frame = TTY::Box.frame(
      width: @rect.width, height: @rect.height, top: @rect.top, left: @rect.left,
      title: { top_left: @caption || '' }
    )
    frame = Rainbow(frame).green if @active
    print frame
  end

  def repaint_content
    return if rect_off_screen?

    width = @rect.width - 4 # 1 character for window frame, 1 character for padding

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

      def handle_key(_key, _line_count)
        false
      end

      def position=(_position)
        raise 'no cursor'
      end
    end

    attr_reader :position

    # @param key [String] pressed keyboard key
    # @param line_count [Integer] number of lines in owner {Window}
    # @return [Boolean] true if the cursor moved and window needs repaint.
    def handle_key(key, line_count)
      if ["\e[B", 'j'].include?(key) # down arrow
        return go_down(line_count)
      elsif ["\e[A", 'k'].include?(key) # up arrow
        return go_up
      end

      false
    end

    def position=(position)
      raise 'must be integer 0 or greater' if position.negative? || !position.is_a?(Integer)

      @position = position
    end

    protected

    def go_down(line_count)
      return false if @position >= line_count - 1

      @position += 1
      true
    end

    def go_up
      return false if @position <= 0

      @position -= 1
      true
    end

    # Cursor which can not hop on just any line - only on allowed lines.
    # @param positions [Array<Integer>] a set of positions the cursor can visit.
    # @param position [Integer] initial position
    class Limited < Cursor
      def initialize(positions, position: positions[0])
        @positions = positions.sort
        super(position: position)
      end

      protected

      def go_down(_line_count)
        next_position = @positions.find { it > @position }
        return false if next_position.nil?

        @position = next_position
        true
      end

      def go_up
        prev_index = @positions.rindex { it < @position }
        return false if prev_index.nil?

        @position = @positions[prev_index]
        true
      end
    end
  end
end

# Shows a log. Plug to `TTY::Logger`
# to log stuff.
class LogWindow < Window
  def initialize
    super('Log')
    self.auto_scroll = true
    @lock = Mutex.new # multiple threads may log at the same time
  end

  def add_line(line)
    @lock.synchronize { super }
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
      @window.add_line(string)
    end
  end
end
