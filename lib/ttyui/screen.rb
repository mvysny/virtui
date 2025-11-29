# frozen_string_literal: true

require_relative 'window'
require 'io/console'

# The TTY screen. There is exactly one screen per app.
# It holds the screen lock; any UI modifications must run
# from [:with_lock].
#
# A screen contains tiled windows. Tiled windows are visible at all times
# and don't overlap. TODO how to reposition?
#
# Modal windows: TODO
class Screen
  def initialize
    # Every UI modification must hold this lock.
    @lock = Thread::Mutex.new
    # {Array<Window>} tiled windows.
    @windows = []
  end

  # Runs block with the UI lock held.
  def with_lock(&block)
    @lock.synchronize(&block)
  end

  # Clears the TTY screen
  def clear
    print TTY::Cursor.move_to(0, 0), TTY::Cursor.clear_screen
  end

  # Adds a new tiled window.
  # @param window [Window] the window to add.
  def add_window(window)
    raise unless window.is_a? Window

    window.active = true if @windows.empty?
    @windows << window
  end

  # Runs event loop - waits for keys and sends them to active window.
  # The event loop is terminated on ESC or `q`.
  def run_event_loop
    $stdin.echo = false
    $stdin.raw do
      loop do
        char = $stdin.getch
        break if char == 'q'

        char << $stdin.read_nonblock(3) if char == "\e"
        active_window.handle_key(char)
      end
    end
  ensure
    $stdin.echo = true
  end

  private

  # @return [Window] active window.
  def active_window
    @windows.find(&:active?)
  end
end
