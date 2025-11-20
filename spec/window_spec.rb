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

describe LogWindow do
  it 'smokes' do
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
