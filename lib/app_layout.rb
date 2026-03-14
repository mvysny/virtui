# frozen_string_literal: true

require_relative 'virt/virt'
require_relative 'ttyui/window'
require_relative 'sysinfo'
require_relative 'virt/virtcache'
require 'tty-cursor'
require_relative 'formatter'
require_relative 'virt/ballooning'
require_relative 'virt/vm_emulator'
require 'rainbow'
require_relative 'utils'
require_relative 'ttyui/screen'
require_relative 'system_window'
require_relative 'vm_window'

# A screen, holding all windows.
class AppLayout < Component::Layout::Absolute
  # @param virt_cache [VirtCache]
  # @param ballooning [Ballooning]
  def initialize(virt_cache, ballooning)
    super()
    @virt_cache = virt_cache
    @system = SystemWindow.new(virt_cache)
    @vms = VMWindow.new(virt_cache, ballooning)
    @log = LogWindow.new
    @log.configure_logger $log
    add([@system, @vms, @log])
    @vms.key_shortcut = '1'
    @system.key_shortcut = '2'
    @log.key_shortcut = '3'
  end

  attr_reader :vms, :system, :log

  # Call when windows need to update their contents. Must be run with screen lock held.
  def update_data
    screen.check_locked
    @system.update
    @vms.update
    screen.repaint
  end

  def rect=(rect)
    super
    system_window_width = (rect.width / 2).clamp(0, 60)
    system_height = 13
    vms_height = rect.height - system_height
    @system.rect = Rect.new(rect.left, rect.top + vms_height, system_window_width, system_height)
    @vms.rect = Rect.new(rect.left, rect.top, rect.width, vms_height)
    @log.rect = Rect.new(rect.left + system_window_width, rect.top + vms_height, rect.width - system_window_width,
                         system_height)
  end
end
