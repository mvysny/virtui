# frozen_string_literal: true

require_relative '../spec_helper'
require 'ttyui/screen'
require 'ttyui/popup_window'

describe Screen do
  let(:screen) { Screen.fake }

  it 'provides singleton instance' do
    assert_equal screen, Screen.instance
  end

  context 'active_window' do
    it 'is nil when no windows' do
      assert_nil screen.active_window
    end
    it 'returns the active window' do
      w = Window.new
      screen.add_window '0', w
      assert_equal w, screen.active_window
    end
  end

  it 'removes window' do
    w = Window.new
    screen.add_window '1', w
    screen.remove_window(w)
    assert !screen.has_window?(w)
  end

  context 'popups' do
    it 'adds popup' do
      w = PopupWindow.new
      screen.add_popup w
      assert screen.has_window? w
    end
    it 'close removes popup' do
      w = PopupWindow.new
      screen.add_popup w
      screen.remove_window w
      assert !screen.has_window?(w)
    end
  end
end
