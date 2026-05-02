# frozen_string_literal: true

require_relative 'spec_helper'
require 'system_window'
require 'virt/vm_emulator'
require 'virt/virtcache'

module Tuile
  describe SystemWindow do
    let(:cache) { VirtCache.new(VMEmulator.demo, PcEmulator.new) }
    before { Screen.fake }
    after { Screen.close }
    it 'smokes' do
      SystemWindow.new(cache)
    end

    it 'shows help window' do
      w = SystemWindow.new(cache)
      w.handle_key 'h'
      popups = Screen.instance.popups
      assert_equal 1, popups.length
      assert_equal Component::Popup, popups[0].class
      assert_equal Component::InfoWindow, popups[0].content.class
    end
  end
end
