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
