# frozen_string_literal: true

require_relative '../spec_helper'

module Tuile
  # The representative terminal backgrounds the derivation was measured against
  # (design/decisions.md D_tint_toward_grey): the two poles plus popular dark and light themes.
  TINT_SPEC_BACKGROUNDS = {
    'pure black' => '#000000',
    'Catppuccin Mocha' => '#1e1e2e',
    'One Dark' => '#282c34',
    'pure white' => '#ffffff',
    'Catppuccin Latte' => '#eff1f5',
    'Solarized Light' => '#fdf6e3'
  }.freeze

  describe UI::Tint do
    def lightness(color) = UI::Tint.to_hsl(color.rgb)[2]

    context('pane_bg') do
      it 'steps a dark background lighter and a light one darker — toward mid-grey' do
        dark = Color.hex('#1e1e2e')
        light = Color.hex('#eff1f5')
        assert_operator lightness(UI::Tint.pane_bg(dark)), :>, lightness(dark)
        assert_operator lightness(UI::Tint.pane_bg(light)), :<, lightness(light)
      end

      it 'still shows a tint at the poles, where a pole-directed step would be a no-op' do
        refute_equal Color.hex('#000000'), UI::Tint.pane_bg(Color.hex('#000000'))
        refute_equal Color.hex('#ffffff'), UI::Tint.pane_bg(Color.hex('#ffffff'))
      end

      it 'preserves the hue of a tinted background' do
        mocha = Color.hex('#1e1e2e').rgb
        tinted = UI::Tint.pane_bg(Color.hex('#1e1e2e')).rgb
        assert_in_delta UI::Tint.to_hsl(mocha)[0], UI::Tint.to_hsl(tinted)[0], 2.0
      end

      it 'flips away from grey when the step would drag a passing token under the floor' do
        # A background/token pair crafted to trip the guard: the token clears 4.5:1
        # against the raw background but not against the toward-grey candidate.
        background = Color.hex('#255') # dark teal — toward grey = lighter
        token = Color.hex('#c4c4c4') # ~4.8:1 on the raw background, no headroom
        assert_operator UI::Tint.contrast(token, background), :>=, UI::Tint::CONTRAST_FLOOR
        toward = Color.rgb(*UI::Tint.step(background.rgb, UI::Tint::DELTA))
        assert_operator UI::Tint.contrast(token, toward), :<, UI::Tint::CONTRAST_FLOOR

        chosen = UI::Tint.pane_bg(background, guard: [token])
        assert_operator lightness(chosen), :<, lightness(background) # flipped: darker
        assert_operator UI::Tint.contrast(token, chosen), :>=, UI::Tint::CONTRAST_FLOOR
      end

      it 'skips guard tokens with no knowable RGB rather than raising' do
        UI::Tint.pane_bg(Color.hex('#000000'), guard: [Color::GREEN, Color::RED])
      end
    end

    context('hairline') do
      it 'matches the hand-tuned floors at the poles' do
        # #333333 on black and #cccccc on white are both 0.2 of HSL lightness away —
        # HAIRLINE_DELTA reproduces them.
        assert_equal Color.rgb(51, 51, 51), UI::Tint.hairline(Color.hex('#000000'))
        assert_equal Color.rgb(204, 204, 204), UI::Tint.hairline(Color.hex('#ffffff'))
      end

      it 'stays visible on a mid-dark ground, where the fixed #333333 vanished' do
        one_dark = Color.hex('#282c34')
        assert_operator UI::Tint.contrast(UI::Tint.hairline(one_dark), one_dark), :>=, 1.5
        # the motivating regression: the fixed hex is near-invisible there
        assert_operator UI::Tint.contrast(Color.hex('#333333'), one_dark), :<, 1.2
      end
    end

    context('the guard table (UI::Theme\'s derived tokens)') do
      it 'falls back to the fixed-tint floor when no background was reported' do
        dark = UI::Theme::DARK.resolve(nil)
        assert_equal Color.hex('#121212'), dark[:pane_bg]
        assert_equal Color.hex('#333333'), dark[:frame]
        assert_equal Color.hex('#333333'), dark[:pane_frame]
        light = UI::Theme::LIGHT.resolve(nil)
        assert_equal Color.hex('#f0f0f0'), light[:pane_bg]
        assert_equal Color.hex('#cccccc'), light[:frame]
        assert_equal Color.hex('#cccccc'), light[:pane_frame]
      end

      # The spec form of the measurement that picked the direction and DELTA: across the
      # representative backgrounds, no guarded token that clears the floor against the
      # raw background may lose it against the derived tint.
      TINT_SPEC_BACKGROUNDS.each do |name, hex|
        it "keeps every passing System-pane token above the floor on #{name}" do
          background = Color.hex(hex)
          [UI::Theme::DARK, UI::Theme::LIGHT].map { _1.resolve(background) }.each do |theme|
            pane_bg = theme[:pane_bg]
            UI::Theme::GUARD_TOKENS.each do |token|
              rgb = theme[token].rgb
              next if rgb.nil? # symbolic ANSI — the terminal's scheme owns it
              next if UI::Tint.contrast(theme[token], background) < UI::Tint::CONTRAST_FLOOR

              assert_operator UI::Tint.contrast(theme[token], pane_bg), :>=, UI::Tint::CONTRAST_FLOOR,
                              "#{token} on #{name} (#{pane_bg.inspect})"
            end
          end
        end
      end

      it 'derives the hairlines from their actual grounds' do
        derived = UI::Theme::DARK.resolve(Color.hex('#282c34'))
        assert_equal UI::Tint.hairline(Color.hex('#282c34')), derived[:frame]
        assert_equal UI::Tint.hairline(derived[:pane_bg]), derived[:pane_frame]
      end
    end
  end
end
