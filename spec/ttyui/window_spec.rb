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
      assert_equal %w[foo bar baz], w.content.content
    end
    it 'adds 3 lines at once' do
      w = Window.new
      w.add_lines %w[foo bar baz]
      w.add_lines %w[a b c]
      assert_equal %w[foo bar baz a b c], w.content.content
    end
  end

  context 'active' do
    it 'is not active by default' do
      assert !Window.new.active?
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
end
