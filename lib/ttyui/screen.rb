# frozen_string_literal: true

require_relative 'window'
require 'io/console'
require 'tty-cursor'
require 'tty-screen'

# The TTY screen. There is exactly one screen per app.
#
# A screen runs the event loop; call {#run_event_loop} to do that.
#
# A screen holds the screen lock; any UI modifications must run
# from {#with_lock}.
#
# A screen contains tiled windows. Tiled windows are visible at all times
# and don't overlap. Override {#relayout_tiled_windows} to reposition and redraw the windows.
#
# Moddal/popup windows are supported too, via {#add_popup}. They are centered
# (which mean that they need to provide their desired width and height) and drawn over some tiled windows.
#
# The drawing procedure is very simple: when a window needs repaint, it invalidates itself,
# but won't draw immediately. After the keyboard press event processing is done in the event loop,
# {#repaint} is called which then repaints all invalidated windows. This prevents repeated
# paintings.
class Screen
  def initialize
    # {Screen} store the singleton instance for later retrieval.
    @@instance = self
    # Every UI modification must hold this lock.
    @lock = Thread::Mutex.new
    # {Hash{Window => String}} tiled windows; maps key to a window activated by that key shortcut
    @windows = {}
    # {Array<Window>} modal popup windows, listed in order as they were opened.
    # Last popup is the topmost one and receives all key events.
    @popups = []
    @size = Size.new(self)
    # {Set<Window>} invalidated windows (need repaint)
    @invalidated_windows = Set.new
    # {Boolean} true after tty resize or when a popup is removed.
    @needs_full_repaint = true
  end

  # @return [Screen] the singleton instance
  def self.instance
    raise 'screen not initialized' if @@instance.nil?

    @@instance
  end

  # Provides access to {Size.width} and {Size.height} of the screen.
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

  # Recalculates positions of all windows, and repaints the scene. Automatically called whenever terminal size changes.
  # Call when the app starts.
  def layout
    check_locked
    @needs_full_repaint = true
    relayout_tiled_windows
    @popups.each(&:center)
    repaint
  end

  # Invalidates window: causes the window to be repainted on next call to {:repaint}
  # @param window [Window]
  def invalidate(window)
    check_locked
    raise unless window.is_a? Window

    @invalidated_windows << window
  end

  # Adds a new tiled window.
  # @param window [Window] the window to add.
  def add_window(shortcut, window)
    check_locked
    raise unless window.is_a? Window

    window.active = true if @windows.empty?
    @windows[window] = shortcut
    invalidate(window)
  end

  # @param [window] the popup to add. Will be centered and painted automatically.
  def add_popup(window)
    @popups << window
    window.center
    invalidate(window)
  end

  # @return [Set<Window>] list of tiled {Window}s.
  def windows = Set.new(*@windows.keys)

  # @param value [Hash{String => Window}] maps keybaard shortcut to a window activated by that shortcut.
  def windows=(value)
    check_locked
    @windows = {}
    value.each { |key, window| add_window(key, window) }
  end

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
    check_locked
    @windows.each_key { it.active = it == window }
  end

  # @return [Window | nil] current active tiled window.
  def active_window
    check_locked
    @windows.keys.find(&:active?)
  end

  # Removes a window and calls {:layout}. This should visually "remove" the window. The window will also no longer
  # receive keys.
  #
  # Does nothing if the window is not open on this screen.
  def remove_window(window)
    check_locked
    if @popups.delete(window)
      @needs_full_repaint = true
      return
    end
    @windows.delete(window)
    layout
  end

  # @return [Boolean] if screen contains this window.
  def has_window?(window)
    check_locked
    @popups.include?(window) || @windows.keys.include?(window)
  end

  # Testing only - creates new screen, locks the UI, and prevents any redraws,
  # so that test TTY is not painted over.
  def self.fake
    FakeScreen.new
    Screen.instance
  end

  protected

  # Repositions all tiled window.
  # Default implementation does nothing.
  def relayout_tiled_windows; end

  # Repaints the screen; tries to be as effective as possible, by only considering
  # invalidated windows.
  def repaint
    check_locked
    repaint = []
    if @needs_full_repaint
      # clear - only needed when tiled windows don't cover the screen entirely... and usually they do.
      # Don't clear - prevents blinking
      repaint = @windows.keys + @popups
    else
      repaint = @windows.keys.filter { @invalidated_windows.include? it }
      # This simple TUI framework doesn't support window clipping since
      # tiled windows are not expected to overlap. If there rarely is a popup,
      # we just repaint all windows in correct order - sure they will paint over
      # other windows, but if this is done in the right order, the final drawing will
      # look okay. Not the most effective algorithm, but very simple and very fast
      # in common cases.
      repaint += repaint.empty? ? @popups.filter { @invalidated_windows.include? it } : @popups
    end
    repaint.each(&:repaint)
    @invalidated_windows.clear
    update_status_bar
    @needs_full_repaint = false
  end

  private

  def update_status_bar
    print TTY::Cursor.move_to(0, size.height - 1), ' ' * size.width
    print TTY::Cursor.move_to(0, size.height - 1), "q #{Rainbow('quit').cadetblue}  ", active_window&.keyboard_hint
  end

  # A key has been pressed on the keyboard. Handle it, or forward to active window.
  # @param [String] key
  # @return [Boolean] true if the key was handled by some window.
  def handle_key(key)
    topmost_popup = @popups.last
    return topmost_popup.handle_key(key) unless topmost_popup.nil?

    window_to_activate = @windows.find { |_, v| v == key }
    if !window_to_activate.nil?
      self.active_window = window_to_activate[0]
      true
    else
      active_window.handle_key(key)
    end
  end

  def event_loop
    loop do
      key = Keys.getkey
      handled = with_lock { handle_key(key) }
      break if !handled && ['q', Keys::ESC].include?(key)

      with_lock { repaint }
    rescue StandardError => e
      $log.fatal('Uncaught event loop exception', e)
    end
  end

  # Tracks tty window size, the safe way. Call {#width} and {#height} to obtain
  # current TTY size.
  class Size
    # @param screen [Screen] the owner screen which gets notified of TTY size changes.
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

    # @return [Integer] the current width of the TTY terminal
    attr_reader :width
    # @return [Integer] the current height.
    attr_reader :height

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

# Testing only - a screen which doesn't paint anything and pretends that the lock is held.
# This way, the TTY running the tests is not painted over.
#
# Call {Screen.fake} to initialize the fake screen easily.
class FakeScreen < Screen
  def check_locked; end
  def clear; end

  def with_lock
    yield # no lock necessary when testing
  end

  def repaint; end
end
