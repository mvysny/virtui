# frozen_string_literal: true

require_relative '../spec_helper'

module Tuile
  describe UI::SystemWindow do
    let(:cache) { Virt::Cache.new(Virt::VMEmulator.demo, System::Emulator.new) }
    before { Screen.fake }
    after { Screen.close }
    it 'smokes' do
      UI::SystemWindow.new(cache)
    end

    it 'shows help window' do
      w = UI::SystemWindow.new(cache)
      w.handle_key 'h'
      popups = Screen.instance.popups
      assert_equal 1, popups.length
      assert_equal Component::Popup, popups[0].class
      assert_equal Component::InfoWindow, popups[0].content.class
    end
  end
end
