# frozen_string_literal: true

module UI
  # The top-level screen layout, orchestrating the three windows: {VMWindow} (VM
  # list/controls), {SystemWindow} (host CPU/RAM/disk) and a log window. Also redirects
  # `$log`'s console output into the log window and assigns the `1`/`2`/`3` focus
  # shortcuts.
  #
  # UI-thread-confined.
  class AppLayout < Tuile::Component::Layout::Absolute
    include Tuile

    # @param virt_cache [Virt::Cache] the runtime cache the windows read from
    # @param ballooning [Virt::Ballooning] the ballooning controller for {VMWindow}
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

    # @return [VMWindow] the VM list/controls window
    attr_reader :vms
    # @return [SystemWindow] the host CPU/RAM/disk window
    attr_reader :system
    # @return [Tuile::Component::LogWindow] the log window
    attr_reader :log

    # Refreshes every window's contents from the cache and repaints. Call when new data is
    # available; must run with the screen lock held (on the UI thread).
    #
    # @return [void]
    def update_data
      screen.check_locked
      @system.update
      @vms.update
      screen.repaint
    end

    # Lays out the three windows within `rect`: VMs on top spanning the full width, with
    # the system window and log side-by-side along the bottom.
    #
    # @param rect [Tuile::Rect] the area assigned to this layout
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
