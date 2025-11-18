# frozen_string_literal: true

require 'minitest/autorun'
require 'window'
require 'tty-logger'

class TestWindow < Minitest::Test
  def test_smoke
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

class TestLogWindow < Minitest::Test
  def test_smoke
    w = LogWindow.new
    log = TTY::Logger.new do |config|
      config.level = :debug
    end
    w.configure_logger(log)
    log.error 'foo'
    log.warn 'bar'
  end
end
