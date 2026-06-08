# frozen_string_literal: true

module UI
  # A screen, holding all windows.
  class AppLayout < Tuile::Component::Layout::Absolute
    include Tuile

    # @param virt_cache [Virt::Cache]
    # @param ballooning [Virt::Ballooning]
    def initialize(virt_cache, ballooning)
      super()
      @virt_cache = virt_cache
      @system = SystemWindow.new(virt_cache)
      @vms = VMWindow.new(virt_cache, ballooning)
      @log = Component::LogWindow.new
      $log.remove_handler :console
      $log.add_handler [:console, { output: Component::LogWindow::IO.new(@log), enable_color: true }]
      add([@vms, @system, @log])
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
end
