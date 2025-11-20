# frozen_string_literal: true

require 'minitest/autorun'
require 'window'
require 'tty-logger'

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
