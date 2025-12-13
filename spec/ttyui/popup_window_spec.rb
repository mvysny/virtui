# frozen_string_literal: true

require_relative '../spec_helper'
require 'ttyui/popup_window'
require 'ttyui/keys'

describe PopupWindow do
  before { Screen.fake }

  it 'smokes' do
    w = PopupWindow.new('foo')
    w.open
    assert w.open?
    w.close
    assert !w.open?
  end

  it 'closes on q' do
    w = PopupWindow.new('foo')
    w.open
    w.handle_key 'q'
    assert !w.open?
  end

  it 'closes on ESC' do
    w = PopupWindow.new('foo')
    w.open
    w.handle_key Keys::ESC
    assert !w.open?
  end
end
