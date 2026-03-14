# frozen_string_literal: true

require 'tty-box'
require 'rainbow'
require 'unicode/display_width'
require 'strings-truncation'
require 'tty-logger'
require_relative 'keys'
require_relative 'component'
require_relative 'layout'
require_relative 'list'

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
class Window < Component
  include Component::HasContent

  # @return [Component | nil]
  attr_reader :content

  def content=(content)
    super
    @content = content
    content&.rect = Rect.new(rect.left + 1, rect.top + 1, rect.width - 2, rect.height - 2)
  end

  def initialize(caption = '')
    super()
    # {String} Window caption, shown in the upper-left part
    @caption = caption
    # Set the default content.
    self.content = Component::List.new
  end

  # @return [String] the current caption, empty by default.
  attr_reader :caption

  def auto_scroll = content.auto_scroll
  def top_line = content.top_line
  def cursor = content.cursor

  def auto_scroll=(new_auto_scroll)
    content.auto_scroll = new_auto_scroll
  end

  # Sets new caption and repaints the window
  # @param new_caption [String]
  def caption=(new_caption)
    @caption = new_caption
    invalidate
  end

  def cursor=(cursor)
    content.cursor = cursor
  end

  def top_line=(new_top_line)
    content.top_line = new_top_line
  end

  def add_line(line)
    content.add_line(line)
  end

  def add_lines(lines)
    content.add_lines(lines)
  end

  # @return [String] formatted keyboard hint for users. Empty by default.
  # Example: `p #{Rainbow('Power').cadetblue}`. If the window responds to keys,
  # override {#handle_key}
  def keyboard_hint
    ''
  end

  # @return [Boolean] true if {#rect} is off screen and the window won't paint.
  def visible?
    !@rect.empty? && !@rect.top.negative? && !@rect.left.negative?
  end

  # Removes the window from the screen.
  def close
    screen.remove_popup(self)
  end

  # @return [Boolean] true if this window is part of a screen. May not be visible.
  def open?
    screen.has_popup?(self)
  end

  # Fully repaints the window: both frame and contents.
  def repaint
    super
    repaint_border
  end

  def key_shortcut=(key)
    super
    invalidate
  end

  def invalidate
    super
    # repainting this component paints over content: repaint content as well.
    content&.invalidate
  end

  protected

  def layout(content)
    content.rect = Rect.new(rect.left + 1, rect.top + 1, rect.width - 2, rect.height - 2)
  end

  # Paints the window border.
  def repaint_border
    return unless visible?

    caption = @caption || ''
    caption = "[#{key_shortcut}]-#{caption}" unless key_shortcut.nil?
    frame = TTY::Box.frame(
      width: @rect.width, height: @rect.height, top: @rect.top, left: @rect.left,
      title: { top_left: caption }
    )
    frame = Rainbow(frame).green if active?
    screen.print frame
  end
end

# Shows a log. Plug to {TTY::Logger}
# to log stuff straight from the logger: call {#configure_logger}.
class LogWindow < Window
  def initialize(caption = 'Log')
    super
    self.auto_scroll = true
    self.cursor = Component::List::Cursor.new # allow scrolling when a long stacktrace is logged
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
