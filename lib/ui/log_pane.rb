# frozen_string_literal: true

module UI
  # The log pane: `$log`'s console output, word-wrapped and auto-scrolled. A borderless
  # `Layout::Vertical` (see DECISIONS.md D_panes_are_layouts): a one-row header carrying
  # the focus chip, over a {Tuile::Component::LogTextView} — deliberately a text view and
  # not a list, so long lines (stacktraces, wide log records) wrap rather than ellipsize.
  # Point a logger at a `LogTextView::IO` wrapping this pane; {#log} is any-thread safe
  # (the view self-marshals).
  #
  # UI-thread-confined (except {#log}).
  class LogPane < Tuile::Component::Layout::Vertical
    include Tuile

    def initialize
      super
      @header = Component::Label.new
      @view = Component::LogTextView.new
      add(@header, Fixed[1])
      add(@view, Expand[1])
      rebuild_header
    end

    # @return [Tuile::Component::LogTextView] the log view — the pane's focus target
    attr_reader :view

    # Focuses the log view. The pane itself is passive layout; the view is what owns
    # scrolling and the keyboard.
    # @return [void]
    def focus
      @view.focus
    end

    # Appends the given line to the log. Safe to call from any thread — delegates to
    # {Tuile::Component::LogTextView#log}, which self-marshals onto the UI thread.
    # @param string [String, nil] the line (or multiple lines) to log; `nil` is a no-op
    # @return [void]
    def log(string)
      @view.log(string)
    end

    # @return [Tuile::StyledString] the pane's focus chip, inverted iff the pane owns the
    #   keyboard. `[3]` mirrors {AppLayout}'s focus-key map.
    def chip
      Formatter.chip('3', 'Log', focused: active?, theme: screen.theme)
    end

    # @return [String] empty — the log pane has no key shortcuts to advertise. It answers
    #   {AppLayout#refresh_status}'s probe anyway, so that the empty status line is this
    #   pane's deliberate silence rather than a method nobody remembered to write.
    def keyboard_hint
      ''
    end

    # Rebuilds the header when the pane enters or leaves the focus chain — the chip's
    # inverted/dim state is baked into the header label's text.
    # @param value [Boolean]
    # @return [void]
    def active=(value)
      super
      rebuild_header
    end

    protected

    # Re-renders the header when the theme changes, so the chip follows the new palette.
    # @return [void]
    def on_theme_changed
      super
      rebuild_header
    end

    private

    # Rebuilds the header row — the focus chip.
    # @return [void]
    def rebuild_header
      @header.text = chip
    end
  end
end
