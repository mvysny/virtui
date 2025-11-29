# frozen_string_literal: true

require_relative 'window'
require 'io/console'
require 'tty-cursor'
require 'tty-screen'

# The TTY screen. There is exactly one screen per app.
#
# A screen runs the event loop; call [:run_event_loop] to do that.
#
# A screen holds the screen lock; any UI modifications must run
# from [:with_lock].
#
# A screen contains tiled windows. Tiled windows are visible at all times
# and don't overlap. TODO how to reposition?
#
# Modal windows: TODO
class Screen
  def initialize
    $screen = self
    # Every UI modification must hold this lock.
    @lock = Thread::Mutex.new
    # {Hash{String => Window}} tiled windows; maps key to a window activated by that key shortcut
    @windows = {}
    @size = Size.new(self)
  end

  # @return [Screen] the singleton instance
  def self.instance
    raise 'screen not initialized' if $screen.nil?

    $screen
  end

  # Provides [:width] and [:height] of the screen.
  attr_reader :size

  # Runs block with the UI lock held.
  def with_lock(&block)
    if @lock.owned?
      block.call
    else
      @lock.synchronize(&block)
    end
  end

  # Checks that the UI lock is held and the current code runs in the 'UI thread'.
  def check_locked
    raise 'UI lock not held' unless @lock.owned?
  end

  # Clears the TTY screen
  def clear
    print TTY::Cursor.move_to(0, 0), TTY::Cursor.clear_screen
  end

  # Re-calculates all window sizes and re-positions them. Call after the screen is initialized.
  #
  # Default implementation clears the screen.
  def layout
    check_locked
    clear
  end

  # Adds a new tiled window.
  # @param window [Window] the window to add.
  def add_window(shortcut, window)
    raise unless window.is_a? Window

    window.active = true if @windows.empty?
    @windows[shortcut] = window
  end

  # {Hash{String => Window}} maps keyboard shortcut key to {Window}.
  attr_accessor :windows

  # Runs event loop - waits for keys and sends them to active window.
  # The function exits when the 'ESC' or 'q' key is pressed.
  def run_event_loop
    $stdin.echo = false
    print TTY::Cursor.hide
    $stdin.raw do
      event_loop
    end
  ensure
    print TTY::Cursor.show
    $stdin.echo = true
  end

  # Called when the active window changes.
  # @param window [Window] the new active window
  def active_window=(window)
    @windows.each_value { it.active = it == window }
  end

  # @return [Window | nil] current active window.
  def active_window
    @windows.values.find(&:active?)
  end

  private

  # A key has been pressed on the keyboard. Handle it, or forward to active window.
  # @param [String] key
  def handle_key(key)
    window_to_activate = @windows[key]
    if !window_to_activate.nil?
      self.active_window = window_to_activate
    else
      active_window.handle_key(key)
    end
  end

  def event_loop
    loop do
      key = Keys.getkey
      break if ['q', Keys::ESC].include?(key)

      with_lock do
        handle_key(key)
      end
    rescue StandardError => e
      $log.fatal('Uncaught event loop exception', e)
    end
  end

  # Tracks tty window size, the safe way. Call [:width] and [:height] to obtain
  # current TTY size.
  class Size
    def initialize(screen)
      @screen = screen
      @height, @width = TTY::Screen.size
      @winch_pipe_r, @winch_pipe_w = IO.pipe

      Thread.new do
        poll_winch_pipe
      rescue StandardError => e
        $log.fatal('winch thread failed', e)
      end
      trap_winch
    end

    attr_reader :width, :height

    private

    def poll_winch_pipe
      loop do
        @winch_pipe_r.gets # block until winch
        @screen.with_lock do
          @height, @width = TTY::Screen.size
          @screen.layout
        end
      rescue StandardError => e
        $log.fatal('winch handling failed', e)
      end
    end

    def trap_winch
      # Trap the WINCH signal (sent on terminal resize)
      trap('WINCH') do
        # signal handlers (set up with trap) run in a special "trap context" where Ruby prohibits many operations,
        # including acquiring a Mutex, Queue#pop, ConditionVariable#wait, or basically anything that might block or
        # allocate.
        # But writing a single byte is always allowed.
        # This notifies the poll thread that a WINCH occurred.
        @winch_pipe_w.puts 'a'
      rescue StandardError
        nil
      end
    end
  end
end
