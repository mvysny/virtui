# frozen_string_literal: true

require 'tty-logger'

RSpec.configure do |config|
  config.expect_with :minitest
end

module Helpers
  # Sets a logger to `$log` and returns a {StringIO} which captures logged stuff.
  # @return [StringIO] use {StringIO.string} to get logged stuff
  def self.setup_dummy_logger
    result = StringIO.new
    $log = TTY::Logger.new { it.level = :debug }
    $log.remove_handler :console
    $log.add_handler [:console, { output: result, enable_color: false }]
    result
  end
end
