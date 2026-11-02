# frozen_string_literal: true

source 'https://rubygems.org'
ruby '>= 3.3'

gem 'concurrent-ruby'
# Typemap::Mapper::RBSTypes reads State's types from sig/virtui.rbs through the rbs parser;
# Typemap never depends on rbs itself, so the app names it.
gem 'rbs', '~> 4.2'
# Parses `virsh dumpxml` (Virt::DomainConfig). A bundled gem since Ruby 3.0, so it needs this line.
gem 'rexml', '~> 3.4'
# Parses the user's config.toml (lib/config.rb); parse-only, as virtui never writes it.
gem 'tomlrb', '~> 3.0'
gem 'tty-cursor', '~> 0.7.1'
gem 'tty-logger'
# Unreleased tuile: FakeEventQueue's queued submit and Testing.loop (tuile#65), which the
# BackgroundTask specs need, PickerDialog's disabled options (tuile#71), which the power and
# maintenance menus use, the `@_`-prefixed framework ivars (tuile#69), which let
# DiskResizeDialog keep its own `@caption`, Dialog's `close_on_key:` (tuile#66), which
# ProgressDialog's uncancelable dialog uses, Popup/Window becoming Dialog/Panel, which
# every dialog here extends, and the wrapping Label with Layout::Auto (tuile#73), which lays out
# HealthDialog, land after 0.17.0 and have no gem yet, so this rides master until
# they do — a git source rather than `path: '../tuile'` so CI can resolve it too. To work against
# the sibling checkout: `bundle config set --local local.tuile ../tuile`.
gem 'tuile', git: 'https://github.com/mvysny/tuile.git', branch: 'master'
# Maps State to and from its JSON file (lib/state.rb) and config.toml onto Config (lib/config.rb).
gem 'typemap', '~> 0.1.0'
gem 'zeitwerk', '~> 2.7'

group :development do
  gem 'rake', '~> 13.4'
  gem 'redcarpet' # Markdown formatting for Yard
  gem 'rubocop', require: false
  gem 'sord', '~> 7.1', require: false # writes sig/virtui.rbs from the YARD tags: `rake sig:generate`
  gem 'yard', '~> 0.9.43'
end

group :test do
  gem 'minitest', '~> 6.0'
  gem 'rspec-core', '~> 3.13'
  gem 'simplecov', '~> 0.22', require: false
  gem 'timecop'
end
