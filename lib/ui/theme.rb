# frozen_string_literal: true

module UI
  # VirTUI's color theme: Tuile's built-in tokens plus app-specific ones, with
  # one coloring reader per custom token. Assign {THEME_DEF} to
  # `screen.theme_def=` so the screen picks the right variant for the terminal
  # background and follows OS light/dark flips.
  class Theme < Tuile::Theme
    # @!group Coloring readers, one per custom token

    # @param text [String]
    # @return [String] `text` in the host CPU accent color.
    def cpu(text) = fg(:cpu, text)

    # @param text [String]
    # @return [String] `text` in the host RAM accent color.
    def ram(text) = fg(:ram, text)

    # @param text [String]
    # @return [String] `text` in the swap accent color.
    def swap(text) = fg(:swap, text)

    # @param text [String]
    # @return [String] `text` in the disk-device-name accent color.
    def disk_label(text) = fg(:disk_label, text)

    # @param text [String]
    # @return [String] `text` in the subtle horizontal-frame color.
    def frame(text) = fg(:frame, text)

    # @param text [String]
    # @return [String] `text` in the VM name color.
    def vm_name(text) = fg(:vm_name, text)

    # @param text [String]
    # @return [String] `text` in the "all good" color (running VM, low overhead).
    def ok(text) = fg(:ok, text)

    # @param text [String]
    # @return [String] `text` in the warning color (paused VM, elevated overhead).
    def warn(text) = fg(:warn, text)

    # @param text [String]
    # @return [String] `text` in the error color (unknown VM state, high overhead).
    def error(text) = fg(:error, text)

    # @param text [String]
    # @return [String] `text` in the powered-off color.
    def off(text) = fg(:off, text)

    # @!endgroup

    # Tuned for dark terminal backgrounds: Rainbow's X11 color names, quantized
    # to the 256-color palette.
    # @return [Theme]
    DARK = new(**Tuile::Theme::DARK.to_h,
               custom: {
                 cpu: Tuile::Color::DEEP_SKY_BLUE1, # 39 — Rainbow's :dodgerblue
                 cpu_vm: Tuile::Color::CORNFLOWER_BLUE, # 69 — Rainbow's :royalblue
                 ram: Tuile::Color.palette(168), # Rainbow's :maroon (X11 #B03060; dup-named cell, no constant)
                 ram_vm: Tuile::Color::MAGENTA,
                 # A lifted tint of the #9141AC base: the base itself is only 3.6:1 against
                 # black, under the 4.5:1 needed to read as text; this is 6.3:1 at the same
                 # hue. Its light counterpart darkens instead of lifting.
                 swap: Tuile::Color.hex('#b673ce'),
                 disk: Tuile::Color::ORANGE1, # 214 — Rainbow's :goldenrod
                 disk_vm: Tuile::Color::ORANGE3, # 172 — Rainbow's :chocolate
                 disk_label: Tuile::Color::YELLOW1, # 226 — Rainbow's :gold
                 frame: Tuile::Color.hex('#333333'),
                 vm_name: Tuile::Color::WHITE,
                 ok: Tuile::Color::GREEN,
                 warn: Tuile::Color::YELLOW,
                 error: Tuile::Color::RED,
                 off: Tuile::Color::RED3, # 124 — Rainbow's :darkred
                 # Secondary-pane (System/log) background and the separator hairline on it.
                 # These are the fixed-tint *floor* — the values used when the terminal
                 # answers no OSC 11 (Screen#background_color is nil), assuming the common
                 # near-black ground; when the actual background RGB is known the derived
                 # tint replaces them (see {.derived}). Toward-grey per DECISIONS.md
                 # D_tint_toward_grey; exact floor values pending the eyeball pass
                 # (ideas/borderless-panes.md).
                 pane_bg: Tuile::Color.hex('#121212'),
                 pane_frame: Tuile::Color.hex('#333333')
               })

    # Darker counterparts legible on light terminal backgrounds. Named ANSI
    # colors (green, red, magenta) stay symbolic — the terminal's own palette
    # remaps them to light-appropriate shades.
    # @return [Theme]
    LIGHT = new(**Tuile::Theme::LIGHT.to_h,
                custom: {
                  cpu: Tuile::Color::DODGER_BLUE3, # 26
                  cpu_vm: Tuile::Color::ROYAL_BLUE1, # 63
                  ram: Tuile::Color::MEDIUM_VIOLET_RED, # 126
                  ram_vm: Tuile::Color::MAGENTA,
                  swap: Tuile::Color.hex('#7c3494'), # 7.6:1 on white; the base is 5.9:1
                  disk: Tuile::Color::DARK_ORANGE3, # 130
                  disk_vm: Tuile::Color.palette(94), # xterm Orange4 (dup-named cell, no constant)
                  disk_label: Tuile::Color::DARK_GOLDENROD, # 136
                  frame: Tuile::Color.hex('#cccccc'),
                  vm_name: Tuile::Color::BLACK,
                  ok: Tuile::Color::GREEN,
                  warn: Tuile::Color::ORANGE3, # 172 — yellow is unreadable on white
                  error: Tuile::Color::RED,
                  off: Tuile::Color::RED3,
                  # The light-variant fixed-tint floor — see the DARK counterpart's note.
                  pane_bg: Tuile::Color.hex('#f0f0f0'),
                  pane_frame: Tuile::Color.hex('#cccccc')
                })

    # The dark/light pair; assign to `screen.theme_def=`.
    # @return [Tuile::ThemeDef]
    THEME_DEF = Tuile::ThemeDef.new(dark: DARK, light: LIGHT)
  end
end
