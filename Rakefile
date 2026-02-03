# frozen_string_literal: true

require 'rake/testtask'
require 'yard'
require 'rspec/core/rake_task'

YARD::Rake::YardocTask.new do |t|
  t.options = [
    '--title', 'LazyVirt: TUI client for libvirt',
    '--main', 'README.md',
    '--markup', 'markdown'
  ]
end

RSpec::Core::RakeTask.new(:spec)

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
