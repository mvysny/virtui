# frozen_string_literal: true

require_relative '../spec_helper'
require 'ttyui/picker_window'
require 'ttyui/keys'

describe PickerWindow do
  let(:screen) { Screen.fake }
  it 'smokes' do
    w = PickerWindow.new('foo', [PickerWindow::Option.new('a', 'all')]) {}
    screen.add_window '1', w
    w.close
  end
  it 'opens as popup' do
    w = PickerWindow.open('foo', [PickerWindow::Option.new('a', 'all')]) {}
    assert w.open?
    w.close
  end
  it 'doesnt call block if closed' do
    w = PickerWindow.new('foo', [PickerWindow::Option.new('a', 'all')]) { raise 'should not be called' }
    screen.add_window '1', w
    w.handle_key('q')
    assert !w.open?
  end
  it 'selects first option on enter' do
    selected = nil
    w = PickerWindow.new('foo', [PickerWindow::Option.new('a', 'all')]) { selected = it }
    screen.add_window '1', w
    w.handle_key(Keys::ENTER)
    assert_equal 'a', selected
    assert !w.open?
  end
  it 'selects correct option' do
    selected = nil
    w = PickerWindow.new('foo', [PickerWindow::Option.new('a', 'all')]) { selected = it }
    screen.add_window '1', w
    w.handle_key('a')
    assert_equal 'a', selected
    assert !w.open?
  end
  it 'does nothing if unlisted key is pressed' do
    selected = nil
    w = PickerWindow.new('foo', [PickerWindow::Option.new('a', 'all')]) { selected = it }
    screen.add_window '1', w
    w.handle_key('b')
    assert_nil selected
    assert w.open?
  end
end
