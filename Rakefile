# frozen_string_literal: true

require 'yard'
require 'rspec/core/rake_task'
require 'rubocop/rake_task'

RuboCop::RakeTask.new

YARD::Rake::YardocTask.new do |t|
  t.options = [
    '--title', 'VirTUI: TUI client for libvirt',
    '--main', 'README.md',
    '--markup', 'markdown'
  ]
end

RSpec::Core::RakeTask.new(:spec)

# The one gate: everything CI and a pre-push check should agree on. `spec` runs first so a
# real failure surfaces before style nits.
desc 'Run the full test suite and the linter'
task check: %i[spec rubocop]

task default: :check

# XDG: create a launcher icon
require 'fileutils'
desc 'Install desktop entry (user-local)'
task :install_desktop do
  desktop_file = <<~DESKTOP
    [Desktop Entry]
    Type=Application
    Name=VirTUI
    Exec=alacritty --class virtui,virtui -e "#{Dir.getwd}/bin/virtui"
    Icon=#{Dir.getwd}/xdg/virtui-icon.svg
    Categories=Utility;
    StartupWMClass=virtui
  DESKTOP

  target_dir = File.expand_path('~/.local/share/applications')
  FileUtils.mkdir_p target_dir
  File.write(File.join(target_dir, 'virtui.desktop'), desktop_file)
end
