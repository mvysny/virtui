require_relative 'window'

# A popup window, adds {open} function which opens
# the window; the window closes automatically when 'q' or ESC
# is pressed.
#
# The window also sets its size automatically, based on the contents set.
# {#max_height} is consulted.
class PopupWindow < Window
  # Opens the popup window.
  def open
    screen.add_popup(self)
  end

  # Moves window to center it on screen. Consults {Rect.width} and {Rect.height}
  # and modifies {Rect.top} and {Rect.left}.
  def center
    self.rect = rect.centered(screen.size.width, screen.size.height)
  end

  # The max height of the window, defaults to 12 (10 rows + 2 chars border).
  # The window automatically enables cursor + scrolling when there are more items.
  def max_height = 12

  def content=(lines)
    super
    # Re-center the popup window after its contents have been updated.
    update_rect
  end

  def handle_key(key)
    return true if super

    if [Keys::ESC, 'q'].include?(key)
      close
      true
    else
      false
    end
  end

  private

  # Recalculates window width/height and recenters the window if it's open. Called after
  # the window content is changed.
  def update_rect
    width = content.map { Unicode::DisplayWidth.of(Rainbow.uncolor(it)) }.max + 4
    height = (content.length + 2).clamp(..max_height)
    # clamp it to 80% of screen width/height
    self.rect = Rect.new(-1, -1, width, height).clamp(screen.size.width * 4 / 5, screen.size.height * 4 / 5)
    center if open?
    # If we need to scroll since there's just too much stuff to show, enable cursor.
    self.cursor = Cursor.new if content.length > max_height
  end
end

# Shows a bunch of lines as a helpful info. Call {#open}
# to quickly open the window.
class InfoPopupWindow < PopupWindow
  # Opens the info window
  # @param caption [String]
  # @param lines [Array<String>] the content, may contain formatting.
  def self.open(caption, lines)
    w = InfoPopupWindow.new(caption)
    w.content = lines
    w.open
  end
end
