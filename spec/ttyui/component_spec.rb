# frozen_string_literal: true

require_relative '../spec_helper'
require 'ttyui/component'
require 'tty-logger'

describe Rect do
  it 'moves rect with at()' do
    rect = Rect.new(0, 0, 40, 20).at(5, 10)
    assert_equal Rect.new(5, 10, 40, 20), rect
  end
  it 'centers rect' do
    rect = Rect.new(-1, -1, 40, 20)
    assert_equal Rect.new(20, 10, 40, 20), rect.centered(80, 40)
  end
  it 'clamps' do
    rect = Rect.new(0, 0, 40, 20)
    assert_equal Rect.new(0, 0, 20, 20), rect.clamp(20, 40)
    assert_equal Rect.new(0, 0, 40, 20), rect.clamp(50, 40)
    assert_equal Rect.new(0, 0, 40, 20), rect.clamp(40, 40)
    assert_equal Rect.new(0, 0, 40, 10), rect.clamp(40, 10)
  end
end

describe Component do
  before { Screen.fake }
  it 'smokes' do
    Component.new
  end
end

describe Component::Label do
  before { Screen.fake }
  it 'smokes' do
    label = Component::Label.new
    label.text = 'Test 1 2 3 4'
  end
end
