# frozen_string_literal: true

require_relative '../spec_helper'
require 'ttyui/screen'
require 'ttyui/popup_window'

describe Screen do
  let(:screen) { Screen.fake }

  it 'provides singleton instance' do
    assert_equal screen, Screen.instance
  end

  it 'with_lock is reentrant' do
    foo = 'foo'
    screen.with_lock do
      screen.with_lock do
        foo = 'bar'
      end
    end
    assert_equal 'bar', foo
  end

  context 'active_window' do
    it 'is nil when no windows' do
      screen.with_lock { assert_nil screen.active_window }
    end
    it 'returns the active window' do
      screen.with_lock do
        w = Window.new
        screen.add_window '0', w
        assert_equal w, screen.active_window
      end
    end
  end

  it 'removes window' do
    screen.with_lock do
      w = Window.new
      screen.add_window '1', w
      screen.remove_window(w)
      assert !screen.has_window?(w)
    end
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
