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
class AppScreen < Screen
  # @param virt_cache [VirtCache]
  # @param ballooning [Ballooning]
  def initialize(virt_cache, ballooning)
    super()
    @virt_cache = virt_cache
    with_lock do
      @system = SystemWindow.new(virt_cache)
      @vms = VMWindow.new(virt_cache, ballooning)
      @log = LogWindow.new('[3]-Log')
      @log.configure_logger $log
      self.windows = { '2' => @system, '1' => @vms, '3' => @log }
      self.active_window = @vms
    end
  end

  # Call when windows need to update their contents. Must be run with screen lock held.
  def update_data
    check_locked
    @system.update
    @vms.update
    repaint
  end

  protected

  def relayout_tiled_windows
    super
    sw = size.width
    sh = size.height
    system_window_width = (sw / 2).clamp(0, 60)
    sh -= 1 # make way for the status bar
    system_height = 13
    vms_height = sh - system_height
    @system.rect = Rect.new(0, vms_height, system_window_width, system_height)
    @vms.rect = Rect.new(0, 0, sw, vms_height)
    @log.rect = Rect.new(system_window_width, vms_height, sw - system_window_width, system_height)
  end
end
