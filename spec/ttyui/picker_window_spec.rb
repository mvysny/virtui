# frozen_string_literal: true

require_relative '../spec_helper'
require 'ttyui/picker_window'

describe PickerWindow do
  before { Screen.new }
  it 'smokes' do
    w = PickerWindow.new('foo', [PickerWindow::Option.new('a', 'all')]) {}
    w.close
  end
  it 'doesnt call block if closed' do
    w = PickerWindow.new('foo', [PickerWindow::Option.new('a', 'all')]) { raise 'should not be called' }
    w.handle_key('q')
  end
end
