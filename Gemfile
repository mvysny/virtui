# frozen_string_literal: true

source 'https://rubygems.org'
ruby '>= 3.3'

gem 'concurrent-ruby'
gem 'tty-cursor', '~> 0.7.1'
gem 'tty-logger'
# Swapped to the local checkout for co-development of the 0.12.0 List changes
# (items + renderer, the lines/appender cleanup). Restore `gem 'tuile',
# '>= 0.12.0'` once 0.12.0 is released.
gem 'tuile', path: '../tuile'
gem 'zeitwerk', '~> 2.7'

group :development do
  gem 'rake', '~> 13.4'
  gem 'redcarpet' # Markdown formatting for Yard
  gem 'rubocop', require: false
  gem 'yard', '~> 0.9.43'
end

group :test do
  gem 'minitest', '~> 6.0'
  gem 'rspec-core', '~> 3.13'
  gem 'simplecov', '~> 0.22', require: false
  gem 'timecop'
end
