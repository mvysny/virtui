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
      [UI::Theme::DARK, UI::Theme::LIGHT].each do |theme|
        colored = theme.public_send(token, 'hi')
        assert_kind_of String, colored
        assert colored.include?('hi'), "#{theme}.#{token} dropped the text"
      end
    end
  end
end
