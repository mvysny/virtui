# frozen_string_literal: true

# VirTUI entry point: requires external gems, loads the core extensions, and configures
# the Zeitwerk loader over `lib/`. `require 'virtui'` and everything else autoloads.

require 'zeitwerk'

# External / stdlib dependencies used across the lib.
require 'tuile'
require 'tty-cursor'
require 'concurrent-ruby'
require 'open3'
require 'date'
require 'json'

# Core extensions: monkey-patches and top-level helpers. These don't define a
# constant matching their path, so Zeitwerk can't manage them — load eagerly.
require_relative 'core_ext/bytes'

loader = Zeitwerk::Loader.new
loader.push_dir(__dir__)
loader.ignore(__FILE__)               # this bootstrap defines no autoloadable constant
loader.ignore("#{__dir__}/core_ext")  # loaded manually above
# lib/virt/ -> Virt:: (libvirt backend), lib/ui/ -> UI:: (tuile presentation).
loader.inflector.inflect(
  'ui' => 'UI',
  'vm_window' => 'VMWindow',
  'vm_emulator' => 'VMEmulator',
  'vm' => 'VM',
  'ballooning_vm' => 'BallooningVM',
  'guest_os' => 'GuestOS'
)
loader.setup
