# frozen_string_literal: true

require_relative 'window'
require_relative 'popup_window'
require_relative 'event_queue'
require_relative 'component'
require_relative 'layout'
require 'io/console'
require 'tty-cursor'
require 'tty-screen'

# The TTY screen. There is exactly one screen per app.
#
# A screen runs the event loop; call {#run_event_loop} to do that.
#
# A screen holds the screen lock; any UI modifications must be called from the event queue.
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
    # {EventQueue} Event queue
    @event_queue = EventQueue.new
    # {Array<Window>} modal popup windows, listed in order as they were opened.
    # Last popup is the topmost one and receives all key events.
    @popups = []
    # {Hash<PopupWindow, Component>} per-popup snapshot of {#focused} taken just
    # before the popup was added. Restored when the popup closes so focus
    # returns to where the user was, instead of falling through to @content
    # and getting cascaded to the first activatable child.
    @popup_prior_focus = {}
    @size = EventQueue::TTYSizeEvent.create
    # {Set<Component>} invalidated components (need repaint)
    @invalidated = Set.new
    # {Set<Component>} components being repainted right now. A component
    # may invalidate its children during its repaint phase; this prevents double-draw
    @repainting = Set.new
    # Until the event loop is run, we pretend we're in the UI thread.
    # This allows AppScreen to initialize.
    @pretend_ui_lock = true
    # Bottom status bar
    @status_bar = Component::Label.new
  end

  # @return [Screen] the singleton instance
  def self.instance
    raise 'screen not initialized' if @@instance.nil?

    @@instance
  end

  # @return [Component | nil]
  attr_reader :content

  def content=(content)
    raise unless content.is_a? Component

    self.focused = nil
    @content = content
    layout
  end

  # Provides access to {:width} and {:height} of the screen.
  attr_reader :size
  # @return [Array<Window>] currently active popup windows. The array must not be modified!
  attr_reader :popups
  # @return [EventQueue] the event queue
  attr_reader :event_queue

  # Checks that the UI lock is held and the current code runs in the 'UI thread'.
  def check_locked
    raise 'UI lock not held' unless @pretend_ui_lock || @event_queue.has_lock?
  end

  # Clears the TTY screen
  def clear
    print TTY::Cursor.move_to(0, 0), TTY::Cursor.clear_screen
  end

  # Invalidates a component: causes the component to be repainted on next call to {:repaint}
  # @param component [Component]
  def invalidate(component)
    check_locked
    raise unless component.is_a? Component

    @invalidated << component unless @repainting.include? component
  end

  # @return [Component | nil] currently focused component
  attr_reader :focused

  # Sets the focused {Component}. Focused component receives keyboard events.
  # @param focused [Component | nil] the new component to be focused.
  def focused=(focused)
    raise unless focused.nil? || focused.is_a?(Component)

    check_locked
    if @popups.include?(focused)
      @focused = focused
      focused.on_tree { it.active = true if it.can_activate? }
      focused.on_focus
      return
    elsif @popups.include?(focused&.root)
      @focused = focused
      focused.active = true
      return
    end

    if focused.nil?
      @focused = nil
      @content&.on_tree { it.active = false }
    else
      root = focused.root
      raise if root != @content || @popups.include?(root)

      @focused = focused
      active = [focused]
      active << active.last.parent until active.last.parent.nil?
      active = active.to_set
      @content.on_tree { it.active = active.include?(it) if it.can_activate? }
      @focused.on_focus
    end
    @status_bar.text = "q #{Rainbow('quit').cadetblue}  #{active_window&.keyboard_hint}".strip
  end

  # @param window [PopupWindow] the popup to add. Will be centered and painted automatically.
  def add_popup(window)
    raise unless window.is_a? PopupWindow

    @popup_prior_focus[window] = @focused
    @popups << window
    window.center
    self.focused = window
    invalidate(window)
    # no need to fully repaint the scene: PopupWindow simply paints over current screen contents.
  end

  # Runs event loop - waits for keys and sends them to active window.
  # The function exits when the 'ESC' or 'q' key is pressed.
  def run_event_loop
    @pretend_ui_lock = false
    $stdin.echo = false
    print MouseEvent.start_tracking
    $stdin.raw do
      event_loop
    end
  ensure
    print MouseEvent.stop_tracking
    print TTY::Cursor.show
    $stdin.echo = true
  end

  # @return [Component | nil] current active tiled component.
  def active_window
    check_locked
    result = nil
    @content&.on_tree { result = it if it.is_a?(Window) && it.active? }
    result
  end

  # Removes a popup. Repaints the whole scene, which should visually "remove" the window. The window will also no longer
  # receive keys.
  #
  # Does nothing if the window is not open on this screen.
  def remove_popup(window)
    check_locked
    raise 'window is not a popup' unless @popups.delete(window)

    prior = @popup_prior_focus.delete(window)
    # If any other popup recorded its prior focus inside the popup we're
    # removing, forward it to *our* prior so chained closures still climb
    # back to the original owner instead of stopping at a detached component.
    @popup_prior_focus.transform_values! { |p| p && p.root == window ? prior : p }

    if @focused && @focused.root == window
      fallback = @popups.last
      fallback ||= prior if prior && prior.attached?
      fallback ||= @content
      self.focused = fallback
    end
    needs_full_repaint
  end

  # @return [Boolean] if screen contains this window.
  def has_popup?(window)
    check_locked
    @popups.include?(window)
  end

  # Testing only - creates new screen, locks the UI, and prevents any redraws,
  # so that test TTY is not painted over.
  # @return [FakeScreen]
  def self.fake
    FakeScreen.new
    Screen.instance
  end

  def close
    clear
    @content = nil
    @@instance = nil
  end

  def self.close
    @@instance&.close
  end

  # Prints given strings
  # @param args [Array<String>] stuff to print.
  def print(*args)
    Kernel.print(*args)
  end

  # Repaints the screen; tries to be as effective as possible, by only considering
  # invalidated windows.
  def repaint
    check_locked
    # This simple TUI framework doesn't support window clipping since
    # tiled windows are not expected to overlap. If there rarely is a popup,
    # we just repaint all windows in correct order - sure they will paint over
    # other windows, but if this is done in the right order, the final drawing will
    # look okay. Not the most effective algorithm, but very simple and very fast
    # in common cases.

    did_paint = false
    until @invalidated.empty?
      did_paint = true
      # Figure out repaint order of @content first.
      repaint = @invalidated.to_a.delete_if { @popups.include? it }
      # Repaint parents before children, so that
      # children won't paint over parents.
      repaint.sort_by!(&:depth)

      # If some @content needs repaint, it may draw over popups.
      # In such case repaint all popups.
      repaint += repaint.empty? ? @popups.filter { @invalidated.include? it } : @popups
      @repainting = repaint.to_set
      @invalidated.clear

      # Don't call {:clear} before repaint - causes flickering, and only needed when @content
      # doesn't cover the entire screen.
      repaint.each(&:repaint)

      # Repaint done, mark all components as up-to-date
      @repainting.clear
    end
    position_cursor if did_paint
  end

  # Returns the absolute screen coordinates where the hardware cursor should sit,
  # or nil if it should be hidden. Only the {#focused} component owns the cursor:
  # there can be multiple active components (the focus path), but only one focused.
  # @return [Point | nil]
  def cursor_position = @focused&.cursor_position

  private

  # Hides or moves the hardware cursor based on the current focus state.
  def position_cursor
    pos = cursor_position
    if pos.nil?
      print TTY::Cursor.hide
    else
      print TTY::Cursor.move_to(pos.x, pos.y), TTY::Cursor.show
    end
  end

  # Recalculates positions of all windows, and repaints the scene. Automatically called whenever terminal size changes.
  # Call when the app starts. {:size} provides correct size of the terminal.
  def layout
    check_locked
    needs_full_repaint
    @content.rect = Rect.new(0, 0, size.width, size.height - 1)
    @popups.each(&:center)
    @status_bar.rect = Rect.new(0, size.height - 1, size.width, 1)
    repaint
  end

  # Called after a popup is closed. Since a popup can cover any window, top-level component
  # or other popups, we need to redraw everything.
  def needs_full_repaint
    @content&.on_tree { invalidate it }
    @popups.each { invalidate it }
    invalidate @status_bar
  end

  # A key has been pressed on the keyboard. Handle it, or forward to active window.
  # @param [String] key
  # @return [Boolean] true if the key was handled by some window.
  def handle_key(key)
    topmost_popup = @popups.last
    return topmost_popup.handle_key(key) unless topmost_popup.nil?
    return @content.handle_key(key) unless @content.nil?

    false
  end

  # Finds target window and calls {Window.handle_mouse}
  # @param event [MouseEvent]
  def handle_mouse(event)
    x = event.x - 1
    y = event.y - 1
    clicked = @popups.rfind { it.rect.contains?(x, y) }
    clicked = @content if clicked.nil? && @popups.empty?
    clicked&.handle_mouse(event)
  end

  def event_loop
    @event_queue.run_loop do |event|
      if event.is_a? EventQueue::KeyEvent
        key = event.key
        handled = handle_key(key)
        @event_queue.stop if !handled && ['q', Keys::ESC].include?(key)
      elsif event.is_a? MouseEvent
        handle_mouse(event)
      elsif event.is_a? EventQueue::TTYSizeEvent
        @size = event
        layout
      elsif event.is_a? EventQueue::EmptyQueueEvent
        repaint
      end
    rescue StandardError => e
      $log.fatal('Uncaught event loop exception', e)
    end
  end
end

# Testing only - a screen which doesn't paint anything and pretends that the lock is held.
# This way, the TTY running the tests is not painted over.
#
# Call {Screen.fake} to initialize the fake screen easily.
class FakeScreen < Screen
  def initialize
    super
    @event_queue = FakeEventQueue.new
    @size = EventQueue::TTYSizeEvent.new(160, 50)
    @prints = []
  end
  # @return [Array<String>] whatever {#print} printed so far.
  attr_reader :prints

  def check_locked; end

  def clear
    @prints.clear
  end

  # Doesn't print anything: collects all strings in {#prints}
  def print(*args)
    @prints += args
  end

  # @param component [Component] the component to check
  # @return [Boolean]
  def invalidated?(component) = @invalidated.include?(component)

  def invalidated_clear
    @invalidated.clear
  end
end
