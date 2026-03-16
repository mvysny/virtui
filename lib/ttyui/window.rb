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

# A window with a frame, a {#caption} and a content Component. Doesn't support overlapping with other windows:
# it paints its entire contents and doesn't clip if there are other overlapping windows.
#
# By default {Component::List} is set as the `content` {Component}.
#
# Window is considered invisible if {#rect} is empty or one of left/top is negative.
# The window won't draw when invisible.
class Window < Component
  include Component::HasContent

  # @return [Component | nil]
  attr_reader :content

  def content=(content)
    if content.is_a?(Array)
      # TODO: for compatibility reasons, refactor/remove
      @content.content = content
      return
    end
    super
    @content = content
  end

  def initialize(caption = '')
    super()
    @border_right = 1
    # {String} Window caption, shown in the upper-left part
    @caption = caption
    # Set the default content.
    self.content = Component::List.new
  end

  # @param value [Boolean]
  def scrollbar=(value)
    content.scrollbar_visibility = value ? :visible : :gone
    @border_right = value ? 0 : 1
    invalidate
    layout(content)
  end

  # @return [String] the current caption, empty by default.
  attr_reader :caption

  # Sets new caption and repaints the window
  # @param new_caption [String]
  def caption=(new_caption)
    @caption = new_caption
    invalidate
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
    # border paints over content: invalidate the content to have it repainted.
    content&.invalidate
  end

  def key_shortcut=(key)
    super
    # the shortcut key is shown in the caption - repaint.
    invalidate
  end

  protected

  def layout(content)
    content.rect = Rect.new(rect.left + 1, rect.top + 1, rect.width - 1 - @border_right, rect.height - 2)
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
    content.auto_scroll = true
    content.cursor = Component::List::Cursor.new # allow scrolling when a long stacktrace is logged
    self.scrollbar = true
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
        @window.content.add_line(string)
      end
    end
  end
end
