# frozen_string_literal: true

source 'https://rubygems.org'
ruby '>= 3.3'

gem 'concurrent-ruby'
gem 'tty-cursor', '~> 0.7.1'
gem 'tty-logger'
# Unreleased tuile: the relative-rect, Canvas, deferred-relayout and Listeners rework that
# lands after 0.16.0 has no gem yet, so this rides master until it does — a git source rather
# than `path: '../tuile'` so CI can resolve it too. To work against the sibling checkout:
# `bundle config set --local local.tuile ../tuile`.
gem 'tuile', git: 'https://github.com/mvysny/tuile.git', branch: 'master'
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
