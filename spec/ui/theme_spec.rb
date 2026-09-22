# frozen_string_literal: true

require_relative '../spec_helper'

describe UI::Theme do
  it 'THEME_DEF pairs a dark and light Tuile theme' do
    assert_instance_of Tuile::ThemeDef, UI::Theme::THEME_DEF
    assert UI::Theme::DARK.is_a?(Tuile::Theme)
    assert UI::Theme::LIGHT.is_a?(Tuile::Theme)
  end

  it 'every custom coloring reader wraps but preserves the text' do
    %i[cpu ram disk_label frame vm_name ok warn error off].each do |token|
      [UI::Theme::DARK, UI::Theme::LIGHT].map { _1.resolve(nil) }.each do |theme|
        colored = theme.public_send(token, 'hi')
        assert_kind_of String, colored
        assert colored.include?('hi'), "#{theme}.#{token} dropped the text"
      end
    end
  end

  # Chrome carries no hue, so a hint can't be misread as a metric.
  it 'hints are grey and keys are bold in the terminal foreground, in both variants' do
    assert_equal Tuile::Color::GREY58, UI::Theme::DARK[:hint]
    assert_equal Tuile::Color::GREY42, UI::Theme::LIGHT[:hint]
    [UI::Theme::DARK, UI::Theme::LIGHT].each do |theme|
      assert_equal "\e[1mp\e[0m", theme.key('p')
    end
  end
end
