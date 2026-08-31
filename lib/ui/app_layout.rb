# frozen_string_literal: true

module UI
  # The top-level screen layout, orchestrating the three borderless panes: {VMPane} (VM
  # list/controls), {SystemPane} (host CPU/RAM/disk) and {LogPane}, over a one-row status
  # line. Also redirects `$log`'s console output into the log pane and owns the `1`/`2`/`3`
  # focus keys (see {#handle_key}).
  #
  # The panes carry no frames (DECISIONS.md D_panes_are_layouts); what tells them apart is
  # the background: the VM pane — the "editor", where all interaction lives — keeps the
  # terminal's default background, while the System and log panes are tinted one step
  # toward mid-grey (`:pane_bg`, see {Theme}) and separated from each other by a one-cell
  # `│` column. Focus is *labeled* instead of frame-colored: each pane's header chip plus
  # the status-line chip (DECISIONS.md D_labeled_focus_cues).
  #
  # Tuile draws no status bar and reserves no row (see its DECISIONS.md
  # `D-status-bar`), so the bottom line is ours: {#refresh_status} rebuilds it and
  # `bin/virtui` hangs it off `Tuile::Screen#on_focus_changed=`.
  #
  # UI-thread-confined.
  class AppLayout < Tuile::Component::Layout::Absolute
    include Tuile

    # @param virt_cache [Virt::Cache] the runtime cache the panes read from
    # @param ballooning [Virt::Ballooning] the ballooning controller for {VMPane}
    def initialize(virt_cache, ballooning)
      super()
      @virt_cache = virt_cache
      @system = SystemPane.new(virt_cache)
      @vms = VMPane.new(virt_cache, ballooning)
      @log = LogPane.new
      # The one-cell `│` column between the System and log panes; its text is rebuilt to
      # the row height by {#rect=}, its colors by {#on_theme_changed}.
      @separator = Component::Label.new
      @status = Component::Label.new
      $log.remove_handler :console
      $log.add_handler [:console, { output: Component::LogTextView::IO.new(@log), enable_color: true }]
      add([@vms, @system, @separator, @log, @status])
      # Tint the secondary panes; a {Theme::Ref} re-resolves on every theme swap by itself.
      # The VM pane deliberately keeps the terminal default (DECISIONS.md
      # D_tint_secondaries_only).
      @system.bg_color = Theme.ref(:pane_bg)
      @log.bg_color = Theme.ref(:pane_bg)
      @separator.bg_color = Theme.ref(:pane_bg)
      # {Hash<String, Tuile::Component>}: the focus keys {#handle_key} dispatches. Each
      # pane's chip advertises its own key; keep the two in sync.
      @focus_keys = { '1' => @vms, '2' => @system, '3' => @log }
    end

    # @return [VMPane] the VM list/controls pane
    attr_reader :vms
    # @return [SystemPane] the host CPU/RAM/disk pane
    attr_reader :system
    # @return [LogPane] the log pane
    attr_reader :log
    # @return [Tuile::Component::Label] the bottom status line
    attr_reader :status

    # Focuses the pane bound to `key`: `1` the VMs, `2` the host metrics, `3` the log.
    # As the scope root, this is the last rung of the key bubble — the focused component
    # and its ancestors get the key first, so typing `1` into the VM search field isn't
    # hijacked.
    #
    # @param key [String] the pressed key
    # @return [Boolean] true if the key was handled
    def handle_key(key)
      pane = @focus_keys[key]
      return false if pane.nil?

      pane.focus
      true
    end

    # Rebuilds the status line: the focused pane's chip, the global quit key, then that
    # pane's hint. Walking *up* from the focused component mirrors the direction a key
    # bubbles, so the row describes the keys that will actually be delivered — the focused
    # search field consumes `/` and `ESC` before {VMPane} sees them, and its hint says so.
    #
    # `keyboard_hint` (and `chip`) are virtui's own methods on virtui's own panes; Tuile
    # has no such seam, and nothing calls this but the screen's focus hook.
    #
    # @return [void]
    def refresh_status
      cursor = screen.focused
      cursor = cursor.parent until cursor.nil? || cursor.respond_to?(:keyboard_hint)
      chip = cursor.respond_to?(:chip) ? cursor.chip.to_ansi : nil
      @status.text = [chip, "q #{screen.theme.hint('quit')}", cursor&.keyboard_hint]
                     .compact.reject(&:empty?).join('  ')
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

    # Lays out the three panes within `rect`: VMs on top spanning the full width, with
    # the system pane and log side-by-side along the bottom, a one-cell separator column
    # between them.
    #
    # @param rect [Tuile::Rect] the area assigned to this layout
    def rect=(rect)
      super
      system_pane_width = (rect.width / 2).clamp(0, 60)
      system_height = 13
      # One row goes to the status line; the panes share what is left.
      body_height = [rect.height - 1, 0].max
      vms_height = [body_height - system_height, 0].max
      @vms.rect = Rect.new(rect.left, rect.top, rect.width, vms_height)
      @system.rect = Rect.new(rect.left, rect.top + vms_height, system_pane_width, system_height)
      @separator.rect = Rect.new(rect.left + system_pane_width, rect.top + vms_height, 1, system_height)
      @log.rect = Rect.new(rect.left + system_pane_width + 1, rect.top + vms_height,
                           [rect.width - system_pane_width - 1, 0].max, system_height)
      @status.rect = Rect.new(rect.left, rect.top + body_height, rect.width, 1)
      rebuild_separator
    end

    protected

    # Re-bakes the labels whose colors are flattened into their text — the separator
    # column and the status line. The panes rebuild their own headers.
    # @return [void]
    def on_theme_changed
      super
      rebuild_separator
      refresh_status
    end

    private

    # Rebuilds the separator column's text: one `:pane_frame` `│` per row of the bottom
    # pane row.
    # @return [void]
    def rebuild_separator
      bar = screen.theme.fg(:pane_frame, '│')
      @separator.text = Array.new(@separator.rect.height, bar).join("\n")
    end
  end
end
