# frozen_string_literal: true

module UI
  # The "please wait" box {BackgroundTask} shows while its work runs: the caption over a
  # sliding indeterminate bar, in a centered modal popup sized to the caption.
  #
  #   popup = ProgressWindow.open("Reading web01's definition")
  #   popup.close
  #
  # ESC and `q` close the popup, as on any {Tuile::Component::Popup}; an outside click does
  # not, so a stray click cannot cancel a read the user asked for. Opened `cancelable: false`,
  # it swallows ESC and `q` instead — the popup is modal, so nothing else gets them either,
  # not even virtui's own quit key — and its footer stops offering a cancel:
  #
  #   ProgressWindow.open('Resizing vda', cancelable: false)
  #
  # UI-thread-confined.
  class ProgressWindow < Tuile::Component::Window
    include Tuile

    # The narrowest box: the bar needs room to visibly slide, and the footer has to fit.
    # @return [Integer]
    MIN_WIDTH = 40
    # Border columns plus one column of padding on each side.
    # @return [Integer]
    WIDTH_CHROME = 4
    # Border rows plus the caption row and the bar row.
    # @return [Integer]
    HEIGHT = 4

    # @param caption [String] what is being done, e.g. "Reading web01's definition"
    # @param cancelable [Boolean] whether ESC and `q` close the popup
    def initialize(caption, cancelable: true)
      super('Please wait')
      @cancelable = cancelable
      @label = Component::Label.new("#{caption}…")
      box = Component::Layout::Vertical.new(padding: Component::Layout::Insets[left: 1, right: 1])
      box.add(@label)
      box.add(Component::ProgressBar.new(indeterminate: true))
      self.content = box
      self.footer_text = cancelable ? 'ESC to cancel' : 'cannot be canceled'
    end

    # @return [Boolean] whether ESC and `q` close the popup
    def cancelable? = @cancelable

    # @param screen_size [Size] the screen to fit
    # @return [Size] wide enough for the caption, at least {MIN_WIDTH}, capped at the screen
    def measured_size(screen_size)
      # Two one-sided clamps: clamp(MIN_WIDTH, width) raises on a screen narrower than MIN_WIDTH.
      width = (@label.text.display_width + WIDTH_CHROME).clamp(MIN_WIDTH..).clamp(..screen_size.width)
      Size.new(width, HEIGHT.clamp(..screen_size.height))
    end

    # Opens the window as a modal popup.
    # @param caption [String] what is being done
    # @param cancelable [Boolean] whether ESC and `q` close it
    # @return [Tuile::Component::Popup] the opened popup
    def self.open(caption, cancelable: true) = MeasuredPopup.new(new(caption, cancelable:)).open

    # The popup {.open} wraps the window in, measured on every layout pass so a SIGWINCH
    # re-fits it.
    class MeasuredPopup < Component::Popup
      # @param window [ProgressWindow]
      def initialize(window)
        @window = window
        super(content: window, close_on_outside_click: false, close_on_key: window.cancelable?)
      end

      # @param screen_size [Size]
      # @return [Size] {ProgressWindow#measured_size}
      def declared_size_in(screen_size) = @window.measured_size(screen_size)
    end
    private_constant :MeasuredPopup
  end
end
