# frozen_string_literal: true

module UI
  # The top-level screen layout, orchestrating the three borderless panes: {VMPane} (VM
  # list/controls), {SystemPane} (host CPU/RAM/disk) and {LogPane}, over a one-row status
  # line. Also redirects `$log`'s console output into the log pane and owns the `1`/`2`/`3`
  # focus keys and the {HIDE_KEY} (see {#handle_key?}).
  #
  # The System and log panes can be hidden: {HIDE_KEY} hides the focused one, and its digit
  # brings it back. A hidden pane's chip moves to the right end of the status line, so the
  # way back stays on screen:
  #
  #   q quit  p Power  v run Viewer  …                            [2]-System  [3]-Log
  #
  # The panes carry no frames (design/decisions.md D_panes_are_layouts); what tells them apart is
  # the background: the VM pane — the "editor", where all interaction lives — keeps the
  # terminal's default background, while the System and log panes are tinted one step
  # toward mid-grey (`:pane_bg`, see {Theme}) and separated from each other by a one-cell
  # `│` column. Focus is *labeled* instead of frame-colored: the pane's own header chip,
  # once, and the list cursor — absolute cues, where a background lift is a relative one
  # that needs the resting shade remembered.
  #
  # Tuile draws no status bar and reserves no row (see its design/decisions.md
  # `D-status-bar`), so the bottom line is ours: {#refresh_status} rebuilds it and
  # `bin/virtui` hangs it off `Tuile::Screen#on_focus_changed`.
  #
  # A `Layout::Vertical`: the VM pane takes what is left over a {BOTTOM_HEIGHT}-row
  # `Horizontal` of System │ log, over the status line.
  #
  # UI-thread-confined.
  class AppLayout < Tuile::Component::Layout::Vertical
    include Tuile

    # Rows of the System │ log strip: exactly the System pane's content — the chip header,
    # the CPU, RAM and disk sections — so the VM pane gets every other row.
    BOTTOM_HEIGHT = 13

    # The System pane's share of the width, capped: its bars read fine at 60 columns, and
    # on a wide terminal every column past that is one taken from the log beside it.
    SYSTEM_WIDTH = Percent[50].clamp(..60)

    # Hides the focused System or log pane. `x`, not a Shift+digit: a terminal sends the
    # character typed, and on a Czech or Slovak layout Shift+2 *is* `2`.
    HIDE_KEY = 'x'

    # @param virt_cache [Virt::Cache] the runtime cache the panes read from
    # @param ballooning [Virt::Ballooning] the ballooning controller for {VMPane}
    def initialize(virt_cache, ballooning)
      super()
      @virt_cache = virt_cache
      @system = SystemPane.new(virt_cache)
      @vms = VMPane.new(virt_cache, ballooning)
      @log = LogPane.new
      # The one-cell `│` column between the System and log panes.
      @separator = Component::Fill.new('│', color: Theme.ref(:pane_frame))
      @status = Component::Label.new
      @hidden_chips = Component::Label.new
      $log.remove_handler :console
      $log.add_handler [:console, { output: Component::LogTextView::IO.new(@log), enable_color: true }]
      @bottom = Component::Layout::Horizontal.new
      @bottom.add(@system, SYSTEM_WIDTH)
      @bottom.add(@separator, Fixed[1])
      @bottom.add(@log, Expand[1])
      @status_row = Component::Layout::Horizontal.new
      @status_row.add(@status, Expand[1])
      @status_row.add(@hidden_chips, Fixed[0])
      add(@vms, Expand[1])
      add(@bottom, Fixed[BOTTOM_HEIGHT])
      add(@status_row, Fixed[1])
      # Tint the secondary panes; a {Theme::Ref} re-resolves on every theme swap by itself.
      # The VM pane deliberately keeps the terminal default: painting every background would
      # make virtui own every contrast pairing (including the LIGHT theme's symbolic ANSI
      # colors, which only the terminal can place) and kill terminal transparency. A VM
      # dashboard is furniture in the terminal, not a destination app that owns its ground.
      @system.bg_color = Theme.ref(:pane_bg)
      @log.bg_color = Theme.ref(:pane_bg)
      @separator.bg_color = Theme.ref(:pane_bg)
      # {Hash<String, Tuile::Component>}: the focus keys {#handle_key?} dispatches. Each
      # pane's chip advertises its own key; keep the two in sync.
      @focus_keys = { '1' => @vms, '2' => @system, '3' => @log }
      # The panes {HIDE_KEY} can hide; the VM pane is where all interaction lives, so it stays.
      @hideable = [@system, @log]
    end

    # @return [VMPane] the VM list/controls pane
    attr_reader :vms
    # @return [SystemPane] the host CPU/RAM/disk pane
    attr_reader :system
    # @return [LogPane] the log pane
    attr_reader :log
    # @return [Tuile::Component::Label] the bottom status line's key hints
    attr_reader :status
    # @return [Tuile::Component::Label] the hidden panes' chips, right-aligned on the status line
    attr_reader :hidden_chips

    # Focuses the pane bound to `key` — `1` the VMs, `2` the host metrics, `3` the log —
    # showing it first if it was hidden; {HIDE_KEY} hides the focused System or log pane.
    # As the scope root, this is the last rung of the key bubble — the focused component
    # and its ancestors get the key first, so typing `1` into the VM search field isn't
    # hijacked.
    #
    # @param key [String] the pressed key
    # @return [Boolean] true if the key was handled
    def handle_key?(key)
      return hide_focused_pane? if key == HIDE_KEY

      pane = @focus_keys[key]
      return false if pane.nil?

      unless pane.visible?
        pane.visible = true
        rearrange_bottom
      end
      pane.focus
      true
    end

    # Rebuilds the status line: the global quit key, then the focused pane's hint, then
    # {HIDE_KEY} for a hideable pane; the hidden panes' chips go right-aligned after. Keys
    # only on the left — the row does not repeat the focused pane's chip, which its own header
    # already carries; don't re-add it here to attribute the hints — two inverted blocks answer
    # one question twice. Walking *up* from the focused component
    # mirrors the direction a key bubbles, so the row describes the keys that will actually
    # be delivered — the focused search field consumes `/` and `ESC` before {VMPane} sees
    # them, and its hint says so.
    #
    # `keyboard_hint` is virtui's own method on virtui's own panes; Tuile has no such seam,
    # and nothing calls this but the screen's focus hook.
    #
    # @return [void]
    def refresh_status
      theme = screen.theme
      cursor = screen.focused
      cursor = cursor.parent until cursor.nil? || cursor.respond_to?(:keyboard_hint)
      hide = "#{theme.key(HIDE_KEY)} #{theme.hint('hide')}" if @hideable.include?(cursor)
      @status.text = ["#{theme.key('q')} #{theme.hint('quit')}", cursor&.keyboard_hint, hide]
                     .compact.reject(&:empty?).join('  ')
      chips = @hideable.reject(&:visible?).map(&:chip)
      @hidden_chips.text = chips.map(&:to_ansi).join(' ')
      @status_row.constrain(@hidden_chips, Fixed[chips.sum(&:display_width) + [chips.size - 1, 0].max])
    end

    # Refreshes every pane's contents from the cache and repaints. Call when new data is
    # available; must run with the screen lock held (on the UI thread).
    #
    # @return [void]
    def update_data
      screen.check_locked
      @system.update
      @vms.update
      screen.repaint
    end

    protected

    # Re-bakes the status line, whose colors are flattened into its text. (The panes
    # rebuild their own headers.)
    # @return [void]
    def handle_theme_changed
      super
      refresh_status
    end

    private

    # Hides the System or log pane holding focus, handing focus to the VMs.
    # @return [Boolean] false when the focus is in neither, so the key goes unhandled
    def hide_focused_pane?
      pane = @hideable.find(&:active?)
      return false if pane.nil?

      # Ahead of the hide: tuile's own focus repair parks focus on the bottom strip, a layout
      # that takes no keys.
      @vms.focus
      pane.visible = false
      rearrange_bottom
      true
    end

    # Fits the bottom strip to whichever of the System and log panes are visible: the
    # separator only between two, the strip gone with neither, and a lone System pane
    # across the whole width — its {SYSTEM_WIDTH} cap only ever spared the log.
    # @return [void]
    def rearrange_bottom
      @separator.visible = @system.visible? && @log.visible?
      @bottom.visible = @system.visible? || @log.visible?
      @bottom.constrain(@system, @log.visible? ? SYSTEM_WIDTH : Expand[1])
      refresh_status
    end
  end
end
