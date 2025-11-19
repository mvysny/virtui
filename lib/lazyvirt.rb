# frozen_string_literal: true

require_relative 'virt'
require_relative 'virtcache'
require 'rufus-scheduler'
require_relative 'ballooning'
require_relative 'vm_emulator'
require 'tty-logger'
require 'rainbow'
require_relative 'event_loop'
require_relative 'lazyvirt_screen'

# https://github.com/piotrmurach/tty-logger
$log = TTY::Logger.new do |config|
  config.level = :warn
end

# Don't use LibVirtClient for now: it doesn't provide all necessary data
# virt = LibVirtClient.new
virt = VirtCmd.new if VirtCmd.available?
virt ||= vm_emulator_demo
virt_cache = VirtCache.new(virt)

ballooning = Ballooning.new(virt_cache)
screen = Screen.new(virt_cache, ballooning)
screen.calculate_window_sizes

# Trap the WINCH signal (sent on terminal resize)
trap('WINCH') do
  screen.calculate_window_sizes
rescue StandardError => e
  $log.fatal('Failed to update window sizes', e)
end

scheduler = Rufus::Scheduler.new
begin
  # https://github.com/jmettraux/rufus-scheduler
  scheduler.every '2s' do
    virt_cache.update
    # Needs to go after virt_cache.update so that it reads up-to-date values
    ballooning.update
    # Needs to go last, to correctly update current ballooning status
    screen.update_data
  rescue StandardError => e
    $log.fatal('Failed to update VM data', e)
  end

  # event loop, captures keyboard keys and sends them to Screen
  event_loop do |key|
    screen.handle_key key
  rescue StandardError => e
    $log.fatal('Program failure', e)
  end
ensure
  scheduler.shutdown
  screen.clear
end
