# frozen_string_literal: true

require 'zeitwerk'

# External / stdlib dependencies used across the lib.
require 'tuile'
require 'tty-cursor'
require 'concurrent-ruby'
require 'open3'
require 'date'

# Core extensions: monkey-patches and top-level helpers. These don't define a
# constant matching their path, so Zeitwerk can't manage them — load eagerly.
require_relative 'core_ext/numeric'
require_relative 'core_ext/format_byte_size'

loader = Zeitwerk::Loader.new
loader.push_dir(__dir__)
loader.ignore(__FILE__)               # this bootstrap defines no autoloadable constant
loader.ignore("#{__dir__}/core_ext")  # loaded manually above
# lib/virt groups the libvirt backend but is NOT a namespace: its files define
# top-level constants (VirtCmd, VirtCache, Ballooning, ...).
loader.collapse("#{__dir__}/virt")
loader.inflector.inflect(
  'vm_window' => 'VMWindow',
  'vm_emulator' => 'VMEmulator',
  'vm' => 'VM',
  'virtui_theme' => 'VirTUITheme',
  'ballooning_vm' => 'BallooningVM'
)
loader.setup
