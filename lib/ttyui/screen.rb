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
    # Every UI modification must hold this lock.
    @lock = Thread::Mutex.new
    # {Array<Window>} tiled windows.
    @windows = []
    @size = Size.new(self)
  end

  # Provides [:width] and [:height] of the screen.
  attr_reader :size

  # Runs block with the UI lock held.
  def with_lock(&block)
    @lock.synchronize(&block)
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
  def add_window(window)
    raise unless window.is_a? Window

    window.active = true if @windows.empty?
    @windows << window
  end

  # {Array<Window>}
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

  private

  # @return [Window] active window.
  def active_window
    @windows.find(&:active?)
  end

  def event_loop
    loop do
      char = $stdin.getch
      break if char == 'q'

      if char == "\e"
        # Escape sequence. Try to read more data.
        begin
          char << $stdin.read_nonblock(3)
        rescue IO::EAGAINWaitReadable
          # The 'ESC' key pressed => only the \e char is emitted. Exit the event loop.
          break
        end
      end
      with_lock do
        active_window.handle_key(char)
      end
    rescue StandardError => e
      $log.fatal('Uncaught event loop exception', e)
    end
  end

  # Tracks tty window size, the safe way.
  class Size
    def initialize(screen)
      @screen = screen
      @height, @width = TTY::Screen.size

      # Trap the WINCH signal (sent on terminal resize)
      @rd, @wr = IO.pipe
      trap('WINCH') do
        # signal handlers (set up with trap) run in a special "trap context" where Ruby prohibits many operations,
        # including acquiring a Mutex, Queue#pop, ConditionVariable#wait, or basically anything that might block or
        # allocate.
        # But writing a single byte is always allowed.
        @wr.puts 'a'
      rescue StandardError
        nil
      end

      Thread.new do
        loop do
          @rd.gets # block until winch
          screen.with_lock do
            @height, @width = TTY::Screen.size
            screen.layout
          rescue e
            $log.fatal('winch handling failed', e)
          end
        rescue e
          $log.fatal('winch thread failed', e)
        end
      end
    end

    attr_reader :width, :height
  end
end
