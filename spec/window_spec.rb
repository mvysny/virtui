# frozen_string_literal: true

require_relative 'spec_helper'
require 'window'
require 'tty-logger'

describe Window do
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
  end

  context 'content' do
    it 'sets empty contents via setter' do
      w = Window.new
      w.content = []
      assert_equal [], w.content
    end
    it 'sets simple contents via setter' do
      w = Window.new
      w.content = %w[a b c]
      assert_equal %w[a b c], w.content
    end
    it 'sets empty contents via block' do
      w = Window.new
      w.content {}
      assert_equal [], w.content
    end
    it 'sets simple contents via block' do
      w = Window.new
      w.content do |lines|
        lines << 'foo'
        lines << 'bar'
        lines << 'baz'
      end
      assert_equal %w[foo bar baz], w.content
    end
  end

  context 'auto_scroll' do
    it 'is false by default' do
      assert !Window.new.auto_scroll
    end
    it 'sets auto_scroll to true' do
      w = Window.new
      w.auto_scroll = true
      assert w.auto_scroll
    end
    it 'scrolls the contents automatically' do
      w = Window.new
      w.rect = Rect.new(-1, -1, 20, 4) # two lines of content
      w.content = %w[a b c]
      w.auto_scroll = true
      assert_equal 1, w.top_line
    end
    it 'scrolls the contents automatically 2' do
      w = Window.new
      w.rect = Rect.new(-1, -1, 20, 4) # two lines of content
      w.auto_scroll = true
      w.content = %w[a b c]
      assert_equal 1, w.top_line
    end
    it 'autoscrolls on add_lines' do
      w = Window.new
      w.auto_scroll = true
      w.rect = Rect.new(-1, -1, 20, 4)
      w.add_lines %w[foo bar baz a b c]
      assert_equal 4, w.top_line
    end
    it 'autoscrolls on add_line' do
      w = Window.new
      w.auto_scroll = true
      w.rect = Rect.new(-1, -1, 20, 4)
      w.add_line 'foo'
      assert_equal 0, w.top_line
      w.add_line 'bar'
      assert_equal 0, w.top_line
      w.add_line 'baz'
      assert_equal 1, w.top_line
    end
  end

  context 'add lines' do
    it 'adds 3 lines' do
      w = Window.new
      w.add_line 'foo'
      w.add_line 'bar'
      w.add_line 'baz'
      assert_equal %w[foo bar baz], w.content
    end
    it 'adds 3 lines at once' do
      w = Window.new
      w.add_lines %w[foo bar baz]
      w.add_lines %w[a b c]
      assert_equal %w[foo bar baz a b c], w.content
    end
  end

  context 'active' do
    it 'is not active by default' do
      assert !Window.new.active?
    end
  end
end

describe LogWindow do
  it 'logs to content' do
    w = LogWindow.new
    log = TTY::Logger.new do |config|
      config.level = :debug
    end
    w.configure_logger(log)
    log.error 'foo'
    log.warn 'bar'
    assert_equal ["\e[31m⨯\e[0m \e[31merror\e[0m   foo", "\e[33m⚠\e[0m \e[33mwarning\e[0m bar"], w.content
  end
end

describe Window::Cursor do
  it 'has correct default position' do
    assert_equal 0, Window::Cursor.new.position
  end
  it 'moves down on down arrow' do
    c = Window::Cursor.new
    assert c.handle_key("\e[B", 20)
    assert_equal 1, c.position
  end
  it 'wont move down if there are no more lines' do
    c = Window::Cursor.new
    assert !c.handle_key("\e[B", 1)
    assert_equal 0, c.position
  end
  it 'moves up on up arrow' do
    c = Window::Cursor.new(position: 10)
    assert c.handle_key("\e[A", 20)
    assert_equal 9, c.position
  end
  it 'wont move up when at the top' do
    c = Window::Cursor.new
    assert !c.handle_key("\e[A", 20)
    assert_equal 0, c.position
  end
end

describe Window::Cursor::None do
  let(:c) { Window::Cursor::None.new }
  it 'has default position of -1' do
    assert_equal(-1, c.position)
  end
  it 'doesnt move' do
    assert !c.handle_key('j', 20)
    assert !c.handle_key('k', 20)
  end
  it 'cant move position' do
    assert_raises(StandardError) { c.position = 1 }
  end
end

describe Window::Cursor::Limited do
  let(:cursor) { Window::Cursor::Limited.new([0, 2, 4, 8]) }
  it 'moves cursor down correctly' do
    assert_equal 0, cursor.position
    # first VM is stopped and takes 2 lines
    cursor.handle_key("\e[B", 10)
    assert_equal 2, cursor.position
    # second VM is running and takes 3 lines
    cursor.handle_key("\e[B", 10)
    assert_equal 4, cursor.position
    # third VM is running and takes 3 lines
    cursor.handle_key("\e[B", 10)
    assert_equal 8, cursor.position
    # no more VMs
    cursor.handle_key("\e[B", 10)
    assert_equal 8, cursor.position
  end
  it 'moves cursor up correctly' do
    cursor.position = 8
    assert_equal 8, cursor.position
    cursor.handle_key("\e[A", 10)
    assert_equal 4, cursor.position
    cursor.handle_key("\e[A", 10)
    assert_equal 2, cursor.position
    cursor.handle_key("\e[A", 10)
    assert_equal 0, cursor.position
    cursor.handle_key("\e[A", 10)
    assert_equal 0, cursor.position
  end
  it 'keeps position if allowed' do
    assert_equal 0, cursor.position
    cursor = Window::Cursor::Limited.new([0, 2, 4, 8], position: 4)
    assert_equal 4, cursor.position
  end
  it 'adjusts the position if needed' do
    cursor = Window::Cursor::Limited.new([0, 2, 4, 8], position: 1)
    assert_equal 0, cursor.position
    cursor = Window::Cursor::Limited.new([0, 2, 4, 8], position: 7)
    assert_equal 4, cursor.position
  end
end
