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

# The uptime-clock counterpart to Timecop, for specs that need a {Cooldown} to lapse.
# Cooldowns are measured on {Cooldown.now} — uptime, deliberately not wall time (see
# DECISIONS.md D_cooldown_monotonic) — which is exactly the clock Timecop does not move.
module Uptime
  # Runs `block` with {Cooldown}'s clock `seconds` further on, and puts it back afterwards
  # even if the block raises, so a failing example cannot leak the shift into the next one.
  # Nests: an inner travel is measured from the outer one.
  #
  # Single-threaded only. The clock is process-global, so travelling while another thread
  # holds a live {Cooldown} moves that one too — {Virt::VirshSession}'s read deadline being
  # the one in this tree that runs off the calling thread. Those specs wait out a real
  # short `read_timeout` instead, which is what a blocking `wait_readable` needs anyway.
  #
  # @param seconds [Numeric] how far ahead to jump
  # @return [Object] whatever `block` returns
  def self.travel(seconds)
    real = Cooldown.clock
    Cooldown.clock = -> { real.call + seconds }
    yield
  ensure
    Cooldown.clock = real
  end
end

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
