# frozen_string_literal: true

require_relative '../spec_helper'
require 'ttyui/screen'

describe Screen do
  let(:screen) { Screen.new }

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
      assert_nil screen.active_window
    end
    it 'returns the active window' do
      w = Window.new
      screen.add_window '0', w
      assert_equal w, screen.active_window
    end
  end
end
