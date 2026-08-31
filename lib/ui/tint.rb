# frozen_string_literal: true

module UI
  # Derives the borderless-pane colors from the terminal's reported background RGB
  # (`Screen#background_color`, tuile#7): the secondary panes' background tint and the
  # `─`/`│` hairline colors. Stateless; called by {Theme.derived} whenever the reported
  # background changes, and unit-tested from canned backgrounds.
  #
  # The derivation preserves hue — popular terminal themes are rarely neutral (Catppuccin
  # Mocha `#1e1e2e` is purple-blue) and a neutral-grey sidebar next to a tinted primary
  # pane looks dirty — so every step is an HSL round-trip moving only lightness, **toward
  # mid-grey**: a dark background lightens, a light one darkens. Toward-grey rather than
  # toward-the-pole because the pole rule dies exactly at `#000`/`#fff`, the two most
  # common terminal backgrounds, where toward-grey's failure case (a mid-grey terminal)
  # exists on no real terminal; the measured contrast cost at {DELTA} never pushes a
  # passing token under the floor. See DECISIONS.md D_tint_toward_grey for the ratios.
  module Tint
    module_function

    # How far the pane background steps toward mid-grey, in HSL lightness. Measured safe
    # across `#000`/Mocha/One Dark/`#fff`/Latte/Solarized Light: the binding token (the
    # LIGHT theme's `:cpu`, 5.8:1 on white) still clears {CONTRAST_FLOOR} at 0.04 and
    # sits on the line at 0.05 (DECISIONS.md D_tint_toward_grey). Perceptibility on
    # washed-out displays is the open eyeball item (ideas/borderless-panes.md).
    DELTA = 0.04

    # How far a hairline (`:frame` / `:pane_frame`) steps from the ground it rules on.
    # Matches the hand-tuned floors — `#333333` on black and `#cccccc` on white are both
    # 0.2 of HSL lightness from their grounds (~1.6:1) — and, being derived, stays that
    # distance on mid grounds like One Dark `#282c34`, where the fixed `#333333` was a
    # near-invisible 1.1:1.
    HAIRLINE_DELTA = 0.2

    # The WCAG text contrast floor the {#pane_bg} guard defends. Guarded tokens are only
    # those that clear it against the *raw* background — several bar colors are tuned
    # below 4.5:1 by design (bars are non-text, where 3:1 is the WCAG line) and no tint
    # direction could satisfy them.
    CONTRAST_FLOOR = 4.5

    # The secondary-pane background: `background` stepped {DELTA} toward mid-grey, unless
    # that would drag a guarded foreground token under {CONTRAST_FLOOR} — then the step
    # flips away from grey instead. The flip is expected dead on every real terminal
    # (see DECISIONS.md D_tint_toward_grey); it protects the backgrounds never measured.
    #
    # @param background [Tuile::Color] the terminal background; must carry RGB
    # @param guard [Array<Tuile::Color>] foreground tokens rendered on the pane; entries
    #   without a knowable RGB (symbolic ANSI colors, remapped by the terminal) are skipped
    # @return [Tuile::Color] the pane background, 24-bit RGB
    # @raise [ArgumentError] when `background` has no knowable RGB
    def pane_bg(background, guard: [])
      bg = rgb_of(background)
      raise ArgumentError, "background must carry RGB, got #{background.inspect}" if bg.nil?

      toward = step(bg, direction(bg) * DELTA)
      guarded = guard.filter_map { |color| rgb_of(color) }
                     .select { |fg| contrast(fg, bg) >= CONTRAST_FLOOR }
      safe = guarded.all? { |fg| contrast(fg, toward) >= CONTRAST_FLOOR }
      Tuile::Color.rgb(*(safe ? toward : step(bg, -direction(bg) * DELTA)))
    end

    # A hairline color for rules drawn on `ground`: the ground stepped
    # {HAIRLINE_DELTA} toward mid-grey — always the same perceptual distance away,
    # whatever the terminal's background.
    #
    # @param ground [Tuile::Color] the background the hairline sits on; must carry RGB
    # @return [Tuile::Color] the hairline color, 24-bit RGB
    # @raise [ArgumentError] when `ground` has no knowable RGB
    def hairline(ground)
      rgb = rgb_of(ground)
      raise ArgumentError, "ground must carry RGB, got #{ground.inspect}" if rgb.nil?

      Tuile::Color.rgb(*step(rgb, direction(rgb) * HAIRLINE_DELTA))
    end

    # WCAG 2.x contrast ratio between two colors.
    #
    # @param first [Tuile::Color, Array<Integer>] a color or RGB triple
    # @param second [Tuile::Color, Array<Integer>] a color or RGB triple
    # @return [Float] the ratio, 1.0..21.0
    # @raise [ArgumentError] when either color has no knowable RGB
    def contrast(first, second)
      a, b = [first, second].map do |color|
        rgb = color.is_a?(Array) ? color : rgb_of(color)
        raise ArgumentError, "color must carry RGB, got #{color.inspect}" if rgb.nil?

        luminance(rgb)
      end
      a, b = b, a if a < b
      (a + 0.05) / (b + 0.05)
    end

    # The RGB triple behind `color`, when one is knowable: RGB colors as-is, 256-palette
    # indices via the xterm cube/grey-ramp formulas. Symbolic ANSI colors (and the 16
    # low palette indices aliasing them) return nil — the terminal's own scheme decides
    # what they look like, so no contrast can honestly be computed for them.
    #
    # @param color [Tuile::Color]
    # @return [Array<Integer>, nil] red, green, blue (each 0..255), or nil
    def rgb_of(color)
      value = color.value
      case value
      when Array then value
      when Integer
        return nil if value < 16
        return [8 + (10 * (value - 232))] * 3 if value >= 232

        cube = value - 16
        [CUBE_LEVELS[cube / 36], CUBE_LEVELS[(cube / 6) % 6], CUBE_LEVELS[cube % 6]]
      end
    end

    # The xterm 6×6×6 color-cube channel levels (palette indices 16..231).
    # @return [Array<Integer>]
    CUBE_LEVELS = [0, 95, 135, 175, 215, 255].freeze

    # Which way mid-grey lies from `rgb`, on the HSL lightness axis.
    #
    # @param rgb [Array<Integer>]
    # @return [Integer] +1 (lighten) below mid-lightness, else -1 (darken)
    def direction(rgb)
      to_hsl(rgb)[2] < 0.5 ? 1 : -1
    end

    # `rgb` with its HSL lightness moved by `delta` (clamped to 0..1), hue and
    # saturation held.
    #
    # @param rgb [Array<Integer>]
    # @param delta [Float] signed lightness delta
    # @return [Array<Integer>] the stepped RGB triple
    def step(rgb, delta)
      h, s, l = to_hsl(rgb)
      from_hsl(h, s, (l + delta).clamp(0.0, 1.0))
    end

    # WCAG relative luminance of an RGB triple.
    #
    # @param rgb [Array<Integer>]
    # @return [Float] 0.0..1.0
    def luminance(rgb)
      r, g, b = rgb.map do |channel|
        c = channel / 255.0
        c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4
      end
      (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
    end

    # RGB → HSL.
    #
    # @param rgb [Array<Integer>] channels 0..255
    # @return [Array(Float, Float, Float)] hue in degrees, saturation 0..1, lightness 0..1
    def to_hsl(rgb)
      r, g, b = rgb.map { |channel| channel / 255.0 }
      max = [r, g, b].max
      min = [r, g, b].min
      l = (max + min) / 2
      return [0.0, 0.0, l] if max == min

      d = max - min
      s = l > 0.5 ? d / (2.0 - max - min) : d / (max + min)
      h = case max
          when r then ((g - b) / d) % 6
          when g then ((b - r) / d) + 2
          else ((r - g) / d) + 4
          end
      [h * 60, s, l]
    end

    # HSL → RGB.
    #
    # @param hue [Float] hue in degrees
    # @param sat [Float] saturation 0..1
    # @param light [Float] lightness 0..1
    # @return [Array<Integer>] channels 0..255
    def from_hsl(hue, sat, light)
      c = (1 - ((2 * light) - 1).abs) * sat
      x = c * (1 - (((hue / 60.0) % 2) - 1).abs)
      m = light - (c / 2)
      rgb = case hue
            when 0...60 then [c, x, 0]
            when 60...120 then [x, c, 0]
            when 120...180 then [0, c, x]
            when 180...240 then [0, x, c]
            when 240...300 then [x, 0, c]
            else [c, 0, x]
            end
      rgb.map { |channel| ((channel + m) * 255).round.clamp(0, 255) }
    end
  end
end
