# frozen_string_literal: true

require_relative '../spec_helper'
require 'ttyui/window'
require 'tty-logger'
require 'ttyui/screen'

describe Window do
  before { Screen.fake }
  after { Screen.close }

  context 'caption' do
    it 'sets caption via constructor' do
      assert_equal '', Window.new.caption
      assert_equal 'foo', Window.new('foo').caption
    end

    it 'sets caption via setter' do
      w = Window.new
      w.caption = 'bar'
      assert_equal 'bar', w.caption
    end

    it 'invalidates on caption change' do
      w = Window.new
      Screen.instance.invalidated_clear
      w.caption = 'new'
      assert Screen.instance.invalidated?(w)
    end
  end

  context 'active' do
    it 'is not active by default' do
      assert !Window.new.active?
    end
  end

  context 'visible?' do
    it 'is false with default empty rect' do
      assert !Window.new.visible?
    end

    it 'is true with a positive rect' do
      w = Window.new
      w.rect = Rect.new(0, 0, 10, 5)
      assert w.visible?
    end

    it 'is false when left is negative' do
      w = Window.new
      w.rect = Rect.new(-1, 0, 10, 5)
      assert !w.visible?
    end

    it 'is false when top is negative' do
      w = Window.new
      w.rect = Rect.new(0, -1, 10, 5)
      assert !w.visible?
    end
  end

  context 'can_activate?' do
    it 'returns true' do
      assert Window.new.can_activate?
    end
  end

  context 'children' do
    it 'contains the content component' do
      w = Window.new
      assert_equal [w.content], w.children
    end
  end

  context 'key_shortcut=' do
    it 'stores the shortcut' do
      w = Window.new
      w.key_shortcut = 'p'
      assert_equal 'p', w.key_shortcut
    end

    it 'invalidates on change' do
      w = Window.new
      Screen.instance.invalidated_clear
      w.key_shortcut = 'p'
      assert Screen.instance.invalidated?(w)
    end
  end

  context 'content' do
    it 'defaults to a Component::List' do
      assert_instance_of Component::List, Window.new.content
    end

    it 'is set as a child of the window' do
      w = Window.new
      assert_equal w, w.content.parent
    end

    it 'content= with Array sets list content (compat mode)' do
      w = Window.new
      w.content = ['line1', 'line2']
      assert_equal ['line1', 'line2'], w.content.content
    end

    it 'content= with Component replaces content' do
      w = Window.new
      new_content = Component::List.new
      w.content = new_content
      assert_equal new_content, w.content
      assert_equal w, new_content.parent
    end
  end

  context 'layout' do
    it 'positions content inside the border (1px inset on all sides, 1px right border by default)' do
      w = Window.new
      w.rect = Rect.new(5, 3, 20, 10)
      # border_right=1 → content width = 20-1-1=18, height = 10-2=8
      assert_equal Rect.new(6, 4, 18, 8), w.content.rect
    end
  end

  context 'scrollbar=' do
    let(:w) do
      w = Window.new
      w.rect = Rect.new(0, 0, 20, 10)
      w
    end

    it 'enabling scrollbar expands content width by 1 (drops right border margin)' do
      w.scrollbar = true
      # border_right=0 → width = 20-1-0=19
      assert_equal 19, w.content.rect.width
    end

    it 'disabling scrollbar restores content width' do
      w.scrollbar = true
      w.scrollbar = false
      assert_equal 18, w.content.rect.width
    end

    it 'enabling scrollbar sets content scrollbar_visibility to :visible' do
      w.scrollbar = true
      assert_equal :visible, w.content.scrollbar_visibility
    end

    it 'disabling scrollbar sets content scrollbar_visibility to :gone' do
      w.scrollbar = true
      w.scrollbar = false
      assert_equal :gone, w.content.scrollbar_visibility
    end
  end

  context 'handle_key' do
    it 'returns false when content is not active' do
      assert !Window.new.handle_key('x')
    end

    it 'delegates to content when content is active' do
      w = Window.new
      handled = false
      w.content.define_singleton_method(:active?) { true }
      w.content.define_singleton_method(:handle_key) { |_key| handled = true; true }
      w.handle_key('x')
      assert handled
    end
  end

  context 'handle_mouse' do
    let(:w) do
      w = Window.new
      w.rect = Rect.new(0, 0, 20, 10)
      # content.rect = Rect.new(1, 1, 18, 8)
      w
    end

    it 'ignores clicks on the border (outside content rect)' do
      called = false
      w.content.define_singleton_method(:handle_mouse) { |_| called = true }
      # (1,1) → x-1=0, y-1=0: outside content rect which starts at (1,1)
      w.handle_mouse(MouseEvent.new(:left, 1, 1))
      assert !called
    end

    it 'delegates clicks inside content rect' do
      called = false
      w.content.define_singleton_method(:handle_mouse) { |_| called = true }
      # (3,3) → x-1=2, y-1=2: inside content rect (1,1,18,8)
      w.handle_mouse(MouseEvent.new(:left, 3, 3))
      assert called
    end
  end

  context 'repaint' do
    it 'smokes' do
      w = Window.new
      w.rect = Rect.new(0, 0, 20, 20)
      assert w.visible?
      assert Screen.instance.prints.empty?
      w.repaint
      assert !Screen.instance.prints.empty?
    end

    it 'does not print when not visible' do
      w = Window.new  # default rect (0,0,0,0) is empty → not visible
      w.repaint
      assert Screen.instance.prints.empty?
    end

    it 'prints green border when active' do
      Rainbow.enabled = true
      w = Window.new
      w.rect = Rect.new(0, 0, 20, 10)
      w.active = true
      w.repaint
      assert Screen.instance.prints.any? { |s| s.include?("\e[32m") }, 'expected green ANSI code in prints'
    ensure
      Rainbow.enabled = false
    end

    it 'does not print green border when inactive' do
      Rainbow.enabled = true
      w = Window.new
      w.rect = Rect.new(0, 0, 20, 10)
      w.repaint
      assert Screen.instance.prints.none? { |s| s.include?("\e[32m") }, 'expected no green ANSI code in prints'
    ensure
      Rainbow.enabled = false
    end

    it 'includes key_shortcut in the border title' do
      w = Window.new('Test')
      w.key_shortcut = 'p'
      w.rect = Rect.new(0, 0, 20, 10)
      w.repaint
      assert Screen.instance.prints.any? { |s| s.include?('[p]-Test') }
    end
  end

  context 'open?' do
    it 'is false for a plain window (not a popup)' do
      assert !Window.new.open?
    end
  end
end

describe LogWindow do
  before { Screen.fake }
  after { Screen.close }

  it 'logs to content' do
    w = LogWindow.new
    log = TTY::Logger.new do |config|
      config.level = :debug
    end
    w.configure_logger(log)
    log.error 'foo'
    log.warn 'bar'
    assert_equal ["\e[31m⨯\e[0m \e[31merror\e[0m   foo", "\e[33m⚠\e[0m \e[33mwarning\e[0m bar"], w.content.content
  end

  it 'has auto_scroll enabled' do
    assert LogWindow.new.content.auto_scroll
  end

  it 'has scrollbar visible' do
    assert_equal :visible, LogWindow.new.content.scrollbar_visibility
  end

  it 'has cursor enabled for scrolling' do
    assert !LogWindow.new.content.cursor.is_a?(Component::List::Cursor::None)
  end
end
