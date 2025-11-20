# frozen_string_literal: true

require 'rake/testtask'
require 'yard'
require 'rspec/core/rake_task'

Rake::TestTask.new

YARD::Rake::YardocTask.new do |t|
  t.options = [
    '--title', 'LazyVirt: TUI client for libvirt',
    '--main', 'README.md',
    '--markup', 'markdown'
  ]
end

RSpec::Core::RakeTask.new(:spec)
