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
    @system = SystemWindow.new(virt_cache)
    @vms = VMWindow.new(virt_cache, ballooning)
    @log = LogWindow.new('[3]-Log')
    @log.configure_logger $log
    with_lock do
      self.windows = { '2' => @system, '1' => @vms, '3' => @log }
      self.active_window = @vms
    end
  end

  # Call when windows need to update their contents. Must be run with screen lock held.
  def update_data
    check_locked
    @system.update
    @vms.update
  end

  def active_window=(window)
    super
    update_status_bar
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
    @system.set_rect_and_repaint(Rect.new(0, vms_height, system_window_width, system_height))
    @vms.set_rect_and_repaint(Rect.new(0, 0, sw, vms_height))
    @log.set_rect_and_repaint(Rect.new(system_window_width, vms_height, sw - system_window_width, system_height))
    update_status_bar
  end

  private

  def update_status_bar
    print TTY::Cursor.move_to(0, size.height - 1), ' ' * size.width
    print TTY::Cursor.move_to(0, size.height - 1), "q #{Rainbow('quit').cadetblue}  ", active_window&.keyboard_hint
  end
end
