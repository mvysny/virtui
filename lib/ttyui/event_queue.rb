# frozen_string_literal: true

require_relative 'keys'
require 'tty-screen'

# An event queue. The idea is that all UI-related updates
# run from the thread which runs the event queue only;
# this removes any need for locking and/or need for
# thread safety mechanisms.
#
# Any events (keypress, timer, term resize - WINCH) are
# captured in background threads; instead of processing
# the events directly the events are pushed into
# the event queue: this causes the events to be processed
# centrally, by a single thread only.
class EventQueue
  def initialize
    @queue = Thread::Queue.new
  end

  # Posts event into the event queue. The event may be of any type.
  # Since the event is passed between threads, the event object
  # should be frozen.
  #
  # The function may be called from any thread.
  # @param event the event to post to the queue, should be frozen.
  def post(event)
    raise "#{event} is not frozen" unless event.frozen?

    @queue << event
  end

  # Runs the event loop and blocks. Must be run from at most one thread at the same time.
  # Blocks until some thread calls {#stop}. Calls block for all events
  # submitted via {#post}; the block is always called from the thread running
  # this function.
  #
  # Any exception raised by block is re-thrown, causing this function to terminate.
  def run(&block)
    raise 'block missing' unless block_given?

    start_key_thread
    begin
      trap_winch
      event_loop(&block)
    ensure
      Signal.trap('WINCH', 'SYSTEM_DEFAULT')
      @key_thread.kill
      @queue.clear
    end
  end

  # Stops ongoing {#run}. The stop may not be immediate:
  # {#run} may process a bunch of events before terminating.
  #
  # Can be called from any thread, including the thread which runs the event loop.
  def stop
    @queue.clear
    post(nil)
  end

  # A keypress event. `key` is {String} key code; see [Keys] for a list of keys.
  class KeyEvent < Data.define(:key)
  end

  # An error event, causes {EventQueue#run} to throw {StandardError} with {#error} as its origin.
  class ErrorEvent < Data.define(:error)
  end

  # TTY has been resized. Contains `width` and `height`, both {Integer}s,
  # which hold the current width of the TTY terminal
  class TTYSizeEvent < Data.define(:width, :height)
    # @return [TTYSizeEvent] event with current TTY size
    def self.create
      height, width = TTY::Screen.size
      TTYSizeEvent.new(width, height)
    end
  end

  private

  def event_loop
    loop do
      event = @queue.pop
      break if event.nil?

      if event.is_a? ErrorEvent
        begin
          raise event.error
        rescue StandardError
          raise 'Nested error' # fills in cause
        end
      end
      yield event
    end
  end

  # Starts listening for stdin, firing {KeyEvent} on keypress.
  def start_key_thread
    @key_thread = Thread.new do
      loop do
        key = Keys.getkey
        post KeyEvent.new(key)
      end
    rescue StandardError => e
      post ErrorEvent.new(e)
    end
  end

  # Trap the WINCH signal (TTY resize signal) and
  # fire {TTYSizeEvent}.
  def trap_winch
    Signal.trap('WINCH') do
      post TTYSizeEvent.create
    rescue StandardError => e
      post ErrorEvent.new(e)
    end
  end
end
