# frozen_string_literal: true

require_relative 'spec_helper'
require 'window'
require 'tty-logger'

describe Window do
  it('smokes') do
    Window.new('foo')
    w = Window.new
    w.rect = Rect.new(-1, 0, 20, 20)
    w.content = %w[a b c]
    w.content do
      %w[a b c]
    end
    w.auto_scroll = true
    assert w.auto_scroll
  end
end
