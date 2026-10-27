# frozen_string_literal: true

module UI
  # The "please wait" box {BackgroundTask} shows while its work runs: the caption over a
  # sliding indeterminate bar, in a centered modal dialog sized to the caption.
  #
  #   dialog = ProgressDialog.new("Reading web01's definition").open
  #   dialog.close
  #
  # ESC and `q` close the dialog, as on any {Tuile::Component::Dialog}; an outside click does
  # not, so a stray click cannot cancel a read the user asked for. Built `cancelable: false`,
  # it swallows ESC and `q` instead — the dialog is modal, so nothing else gets them either,
  # not even virtui's own quit key — and its footer stops offering a cancel:
  #
  #   ProgressDialog.new('Resizing vda', cancelable: false).open
  #
  # UI-thread-confined.
  class ProgressDialog < Tuile::Component::Dialog
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
    # @param cancelable [Boolean] whether ESC and `q` close the dialog
    def initialize(caption, cancelable: true)
      super('Please wait', close_on_outside_click: false, close_on_key: cancelable,
                           footer_text: cancelable ? 'ESC to cancel' : 'cannot be canceled')
      @label = Component::Label.new("#{caption}…")
      box = Component::Layout::Vertical.new(padding: Component::Layout::Insets[left: 1, right: 1])
      box.add(@label)
      box.add(Component::ProgressBar.new(indeterminate: true))
      self.content = box
    end

    # Measured on every layout pass, so a SIGWINCH re-fits it; {#declared_size} is ignored.
    # @param screen_size [Size] the screen to fit
    # @return [Size] wide enough for the caption, at least {MIN_WIDTH}, capped at the screen
    def declared_size_in(screen_size)
      # Two one-sided clamps: clamp(MIN_WIDTH, width) raises on a screen narrower than MIN_WIDTH.
      width = (@label.text.display_width + WIDTH_CHROME).clamp(MIN_WIDTH..).clamp(..screen_size.width)
      Size.new(width, HEIGHT.clamp(..screen_size.height))
    end
  end
end
