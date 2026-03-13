# frozen_string_literal: true

require_relative '../spec_helper'
require 'ttyui/screen'
require 'strings-truncation'

describe Rect do
  describe '#at' do
    it 'changes left and top' do
      assert_equal Rect.new(5, 10, 40, 20), Rect.new(0, 0, 40, 20).at(5, 10)
    end

    it 'preserves width and height' do
      rect = Rect.new(3, 7, 40, 20).at(99, 99)
      assert_equal 40, rect.width
      assert_equal 20, rect.height
    end

    it 'accepts zero coordinates' do
      assert_equal Rect.new(0, 0, 10, 5), Rect.new(3, 7, 10, 5).at(0, 0)
    end

    it 'accepts negative coordinates' do
      assert_equal Rect.new(-1, -2, 10, 5), Rect.new(0, 0, 10, 5).at(-1, -2)
    end
  end

  describe '#empty?' do
    it 'returns false when both dimensions are positive' do
      assert !Rect.new(0, 0, 1, 1).empty?
    end

    it 'returns true when width is zero' do
      assert Rect.new(0, 0, 0, 10).empty?
    end

    it 'returns true when height is zero' do
      assert Rect.new(0, 0, 10, 0).empty?
    end

    it 'returns true when width is negative' do
      assert Rect.new(0, 0, -1, 10).empty?
    end

    it 'returns true when height is negative' do
      assert Rect.new(0, 0, 10, -1).empty?
    end

    it 'returns true when both dimensions are zero' do
      assert Rect.new(0, 0, 0, 0).empty?
    end
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

  describe '#contains?' do
    # Rect occupies x: 10..29, y: 5..14  (right/bottom edges are exclusive)
    let(:rect) { Rect.new(10, 5, 20, 10) }

    it 'returns true for a point clearly inside' do
      assert rect.contains?(20, 9)
    end

    it 'returns true on the left edge' do
      assert rect.contains?(10, 9)
    end

    it 'returns false just outside the left edge' do
      assert !rect.contains?(9, 9)
    end

    it 'returns true on the last column (right edge is exclusive)' do
      assert rect.contains?(29, 9)
    end

    it 'returns false on the right edge (exclusive)' do
      assert !rect.contains?(30, 9)
    end

    it 'returns true on the top edge' do
      assert rect.contains?(20, 5)
    end

    it 'returns false just above the top edge' do
      assert !rect.contains?(20, 4)
    end

    it 'returns true on the last row (bottom edge is exclusive)' do
      assert rect.contains?(20, 14)
    end

    it 'returns false on the bottom edge (exclusive)' do
      assert !rect.contains?(20, 15)
    end

    it 'returns true on the top-left corner' do
      assert rect.contains?(10, 5)
    end

    it 'returns false on the top-right corner (x is exclusive)' do
      assert !rect.contains?(30, 5)
    end

    it 'returns false on the bottom-left corner (y is exclusive)' do
      assert !rect.contains?(10, 15)
    end

    it 'returns false for an empty rect' do
      assert !Rect.new(10, 5, 0, 10).contains?(10, 5)
      assert !Rect.new(10, 5, 10, 0).contains?(10, 5)
    end
  end
end

describe Component do
  before { Screen.fake }
  after { Screen.close }

  it 'smokes' do
    Component.new
  end

  context 'rect=' do
    it 'raises on non-Rect argument' do
      assert_raises(RuntimeError) { Component.new.rect = 'not a rect' }
    end

    it 'is no-op when set to the same rect' do
      c = Component.new
      c.rect = Rect.new(0, 0, 10, 5)
      Screen.instance.invalidated_clear
      c.rect = Rect.new(0, 0, 10, 5)
      assert !Screen.instance.invalidated?(c)
    end

    it 'invalidates when rect changes' do
      c = Component.new
      c.rect = Rect.new(0, 0, 10, 5)
      assert Screen.instance.invalidated?(c)
    end

    it 'calls on_width_changed when width changes' do
      width_changed = false
      klass = Class.new(Component) { define_method(:on_width_changed) { width_changed = true } }
      c = klass.new
      c.rect = Rect.new(0, 0, 20, 5)
      assert width_changed
    end

    it 'does not call on_width_changed when only height changes' do
      width_changed = false
      klass = Class.new(Component) { define_method(:on_width_changed) { width_changed = true } }
      c = klass.new
      c.rect = Rect.new(0, 0, 10, 5)
      width_changed = false
      c.rect = Rect.new(0, 0, 10, 10)
      assert !width_changed
    end
  end

  context 'active' do
    it 'is false by default' do
      assert !Component.new.active?
    end

    it 'raises when trying to activate a non-activatable component' do
      assert_raises(RuntimeError) { Component.new.active = true }
    end

    it 'setting false when already false is a no-op' do
      c = Component.new
      assert !Screen.instance.invalidated?(c)
      c.active = false
      assert !Screen.instance.invalidated?(c)
    end
  end

  context 'root' do
    it 'returns self when component has no parent' do
      c = Component.new
      assert_equal c, c.root
    end

    it 'returns parent when parent has no parent' do
      parent = Component.new
      child = Component.new
      child.send(:parent=, parent)
      assert_equal parent, child.root
    end

    it 'returns the top-most ancestor in a deeper hierarchy' do
      root = Component.new
      middle = Component.new
      leaf = Component.new
      middle.send(:parent=, root)
      leaf.send(:parent=, middle)
      assert_equal root, leaf.root
    end
  end

  it 'can_activate? is false by default' do
    assert !Component.new.can_activate?
  end

  it 'handle_key returns false' do
    assert_equal false, Component.new.handle_key('a')
  end

  it 'handle_mouse returns nil' do
    assert_nil Component.new.handle_mouse(nil)
  end

  context 'clear_background' do
    it 'skips when rect is empty' do
      c = Component.new
      c.send(:clear_background)
      assert_equal [], Screen.instance.prints
    end

    it 'prints spaces for each row of the rect' do
      c = Component.new
      c.rect = Rect.new(2, 3, 5, 2)
      Screen.instance.prints.clear
      c.send(:clear_background)
      assert_equal [TTY::Cursor.move_to(2, 3), '     ',
                    TTY::Cursor.move_to(2, 4), '     '], Screen.instance.prints
    end
  end

  it 'invalidate adds component to screen invalidated set' do
    c = Component.new
    Screen.instance.invalidated_clear
    c.send(:invalidate)
    assert Screen.instance.invalidated?(c)
  end
end

describe Component::Label do
  before { Screen.fake }
  after { Screen.close }

  it 'smokes' do
    label = Component::Label.new
    label.text = 'Test 1 2 3 4'
  end

  it 'can repaint on unset text' do
    label = Component::Label.new
    label.repaint
    assert_equal [], Screen.instance.prints
  end

  it 'clears background when text is empty' do
    label = Component::Label.new
    label.rect = Rect.new(0, 0, 5, 1)
    label.repaint
    assert_equal ["\e[1;1H", '     '], Screen.instance.prints
  end

  it 'prints only first line when height is 1' do
    label = Component::Label.new
    label.rect = Rect.new(0, 0, 5, 1)
    label.text = "1\n2\n3"
    label.repaint
    assert_equal ["\e[1;1H", '     ', "\e[1;1H", '1'], Screen.instance.prints
  end

  it 'prints multiple lines within rect height' do
    label = Component::Label.new
    label.rect = Rect.new(0, 0, 10, 3)
    label.text = "foo\nbar\nbaz"
    label.repaint
    assert_equal [TTY::Cursor.move_to(0, 0), '          ',
                  TTY::Cursor.move_to(0, 1), '          ',
                  TTY::Cursor.move_to(0, 2), '          ',
                  TTY::Cursor.move_to(0, 0), 'foo',
                  TTY::Cursor.move_to(0, 1), 'bar',
                  TTY::Cursor.move_to(0, 2), 'baz'], Screen.instance.prints
  end

  it 'clips lines vertically when text has more lines than height' do
    label = Component::Label.new
    label.rect = Rect.new(0, 0, 10, 2)
    label.text = "one\ntwo\nthree"
    label.repaint
    assert_equal [TTY::Cursor.move_to(0, 0), '          ',
                  TTY::Cursor.move_to(0, 1), '          ',
                  TTY::Cursor.move_to(0, 0), 'one',
                  TTY::Cursor.move_to(0, 1), 'two'], Screen.instance.prints
  end

  it 'truncates lines longer than rect width' do
    label = Component::Label.new
    label.rect = Rect.new(0, 0, 5, 1)
    label.text = 'hello world'
    label.repaint
    truncated = Strings::Truncation.truncate('hello world', length: 5)
    assert_equal [TTY::Cursor.move_to(0, 0), '     ',
                  TTY::Cursor.move_to(0, 0), truncated], Screen.instance.prints
  end

  it 'handles nil text gracefully' do
    label = Component::Label.new
    label.rect = Rect.new(0, 0, 5, 1)
    label.text = nil
    label.repaint
    assert_equal [TTY::Cursor.move_to(0, 0), '     '], Screen.instance.prints
  end

  it 're-clips text when width changes' do
    label = Component::Label.new
    label.rect = Rect.new(0, 0, 3, 1)
    label.text = 'hello world'
    label.rect = Rect.new(0, 0, 5, 1)
    label.repaint
    assert_equal [TTY::Cursor.move_to(0, 0), '     ',
                  TTY::Cursor.move_to(0, 0), Strings::Truncation.truncate('hello world', length: 5)],
                 Screen.instance.prints
  end

  it 'on_tree calls block on itself' do
    label = Component::Label.new
    visited = []
    label.on_tree { visited << it }
    assert_equal [label], visited
  end

  it 'does not invalidate when text is set to the same value again' do
    label = Component::Label.new
    label.rect = Rect.new(0, 0, 5, 1)
    label.text = 'hi'
    invalidated = Screen.instance.instance_variable_get(:@invalidated)
    invalidated.clear
    label.text = 'hi'
    assert !invalidated.include?(label)
  end
end
