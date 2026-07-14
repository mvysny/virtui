# frozen_string_literal: true

# Start coverage before requiring the library, so its load is measured. Set COVERAGE=0
# to skip (e.g. when running a single file and the sub-100% summary would just be noise).
unless ENV['COVERAGE'] == '0'
  require 'simplecov'
  SimpleCov.start do
    enable_coverage :branch
    add_filter '/spec/'
    # Namespace-only modules and the entry point hold no branches worth covering.
    add_filter %r{/lib/(virtui|ui|virt|system|interpolator)\.rb$}
  end
end

require 'tty-logger'
require 'virtui'

RSpec.configure do |config|
  config.expect_with :minitest
end

# Every Screen.fake starts with VirTUI's theme, so components can read custom tokens.
Tuile::ThemeDef.default = UI::Theme::THEME_DEF

module Helpers
  # Sets a logger to `$log` and returns a {StringIO} which captures logged stuff.
  # @return [StringIO] use {StringIO.string} to get logged stuff
  def self.setup_dummy_logger
    result = StringIO.new
    $log = TTY::Logger.new { |it| it.level = :debug }
    $log.remove_handler :console
    $log.add_handler [:console, { output: result, enable_color: false }]
    result
  end
end
