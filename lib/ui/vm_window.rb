# frozen_string_literal: true

module UI
  # The VM window: a scrollable, cursor-selectable list of all VMs, each with guest-vs-host
  # CPU/RAM/disk usage bars and a ballooning-status indicator. Per-VM actions are reachable
  # via key shortcuts: power menu (`p`), launch viewer (`v`), memory menu (`m`), toggle disk
  # stats (`d`) and search (`/`).
  class VMWindow < Tuile::Component::Window
    include Tuile

    # @param virt_cache [Virt::Cache] the runtime cache to read VM data from and act through
    # @param ballooning [Virt::Ballooning] the ballooning controller toggled from the memory menu
    def initialize(virt_cache, ballooning)
      super('VMs')
      self.content = Component::List.new
      @f = Formatter.new
      @virt_cache = virt_cache
      @ballooning = ballooning
      # Array<String>: the VM name backing every rendered line, indexed by line position.
      @line_data = []
      @show_disk_stat = false
      content.cursor = Component::List::Cursor.new
      content.show_cursor_when_inactive = true
      self.scrollbar = true
    end

    # @return [Boolean] whether disk stats are shown for shut-off VMs too
    attr_reader :show_disk_stat

    # Toggles showing disk stats for shut-off VMs and re-renders.
    # @param value [Boolean] true to show disk stats for shut-off VMs
    def show_disk_stat=(value)
      @show_disk_stat = !!value
      update
    end

    # Rebuilds every VM's lines (overview + guest/host CPU, RAM and disk bars) from the
    # current cache data, and recomputes the allowed cursor positions. Paints nothing if
    # the window is too narrow.
    #
    # @return [void]
    def update
      column_width = (rect.width - 16) / 2
      return if column_width.negative? # paint nothing if window is not big enough

      theme = screen.theme
      domains = @virt_cache.domains.sort_by(&:upcase) # Array<String>
      cursor_positions = [] # allowed cursor positions
      cpus = @virt_cache.cpu_info.cpus
      host_ram = @virt_cache.host_mem_stat.ram
      content.lines do |lines|
        @line_data.clear
        domains.each do |domain_name|
          cursor_positions << lines.size
          # {Virt::Cache::VMCache}
          cache = @virt_cache.cache(domain_name)
          # {Virt::DomainData}
          data = cache.data
          lines << format_vm_overview_line(cache)
          @line_data << domain_name

          if data.running?
            cpu_usage = cache.guest_cpu_usage.to_i
            host_cpu_usage = (cache.cpu_usage / cpus).to_i
            cpuguest = progress_bar("#{cpu_usage.to_s.rjust(3)}%", "#{data.info.cpus.to_s.rjust(3)} t", column_width,
                                    cpu_usage, 100, theme[:cpu_vm])
            cpuhost = progress_bar("#{host_cpu_usage.to_s.rjust(3)}%", "#{cpus.to_s.rjust(3)} t", column_width,
                                   host_cpu_usage, 100, theme[:cpu])
            lines << "    #{theme.cpu('CPU')}:#{cpuguest} | #{cpuhost}"
            @line_data << domain_name

            guest_mem_usage = cache.data.mem_stat.guest_mem
            host_mem_usage = cache.data.mem_stat.host_mem
            memguest = usage_bar(column_width, guest_mem_usage, theme[:ram_vm])
            memhost = usage_bar(column_width, ResourceUsage.of(host_ram.total, host_mem_usage.used), theme[:ram])
            lines << "    #{theme.ram('RAM')}:#{memguest} | #{memhost}"
            @line_data << domain_name
          end
          next unless @show_disk_stat || data.running?

          data.disk_stat.each do |ds| # {Virt::DiskStat}
            name = theme.disk_label(ds.name[0..3].rjust(4))
            guest_du = usage_bar(column_width, ds.guest_usage, theme[:disk_vm])
            host_du = progress_bar_qcow2(column_width, ds)
            lines << "   #{name}:#{guest_du} | #{host_du}"
            @line_data << domain_name
          end
        end
      end
      content.cursor = if cursor_positions.empty?
                         Component::List::Cursor.new
                       else
                         Component::List::Cursor::Limited.new(cursor_positions, position: content.cursor.position)
                       end
    end

    # Handles a key press: `/` opens search; `p`/`v`/`m`/`d` act on the VM under the cursor
    # (power menu, launch viewer, memory menu, toggle disk stats).
    #
    # @param key [String] the pressed key
    # @return [Boolean] true if the key was handled
    def handle_key(key)
      return true if super
      return false if footer&.active?

      if key == '/'
        open_search
        return true
      end

      current_vm = @line_data[content.cursor.position] unless content.cursor.position.nil?
      return false if current_vm.nil?

      if key == 'p' # Power menu
        show_power_popup
        true
      elsif key == 'v' # view
        $log.info "Launching viewer for '#{current_vm}'"
        Run.async("virt-manager --connect qemu:///system --show-domain-console '#{current_vm}'")
        true
      elsif key == 'm' # memory
        show_memory_popup
        true
      elsif key == 'd'
        self.show_disk_stat = !show_disk_stat
        true
      else
        false
      end
    end

    # @return [String] the footer hint line, listing the available key shortcuts (or the
    #   search-close hint while searching)
    def keyboard_hint
      t = screen.theme
      return "ESC #{t.hint('close search')}" if footer

      "p #{t.hint('Power')}  v #{t.hint('run Viewer')}  m #{t.hint('Memory')}  " \
        "d #{t.hint('toggle Disk stat')}  / #{t.hint('Search')}"
    end

    protected

    # Re-renders when the window width changes (bar widths depend on it).
    # @return [void]
    def on_width_changed
      super
      update
    end

    # Re-renders when the theme changes, so colors follow the new palette.
    # @return [void]
    def on_theme_changed
      super
      update
    end

    # Draws the window border plus the "Guest usage"/"Host usage" column captions.
    # @return [void]
    def repaint_border
      super
      return if rect.empty?

      y = rect.top
      fourth = rect.width / 4
      theme = screen.theme
      bg = active? ? theme.active_border_color : theme[:tab_inactive]
      buf = screen.buffer
      buf.set_line(rect.left + fourth - 5, y,
                   StyledString.styled(' Guest usage ', fg: :black, bg: bg))
      buf.set_line(rect.left + (3 * fourth) - 5, y,
                   StyledString.styled(' Host usage ', fg: :black, bg: bg))
    end

    private

    # Opens an incremental-search text field in the footer, wiring its events to move the
    # list cursor to matching VMs.
    # @return [void]
    def open_search
      return if footer

      field = Component::TextField.new
      field.on_escape = method(:close_search)
      field.on_enter = method(:close_search)
      field.on_change = ->(text) { content.select_next(text, include_current: true) }
      field.on_key_down = -> { content.select_next(field.text) }
      field.on_key_up = -> { content.select_prev(field.text) }
      self.footer = field
      field.focus
    end

    # Closes the search footer.
    # @return [void]
    def close_search
      self.footer = nil
    end

    # Opens the memory menu for the selected VM: toggle auto-ballooning, or give it max
    # memory and disable ballooning. No-op (logs an error) if the VM isn't running.
    # @return [void]
    def show_memory_popup
      current_vm = @line_data[content.cursor.position] || return
      state = @virt_cache.state(current_vm)
      if state != :running
        $log.error "'#{current_vm}' is not running"
        return
      end
      opts = [['b', 'toggle autoBallooning'], ['m', 'Max memory & disable autoballooning']]
      Component::PickerWindow.open('Memory', opts) do |key|
        if key == 'b' # toggle ballooning
          $log.info "Toggling balloning for '#{current_vm}'"
          @ballooning.toggle_enable(current_vm)
        elsif key == 'm'
          max_memory = @virt_cache.info(current_vm).max_memory
          $log.info "Disabling balooning & giving max mem (#{format_byte_size(max_memory)}) to '#{current_vm}'"
          @ballooning.enabled(current_vm, false)
          @virt_cache.set_actual(current_vm, max_memory)
        end
      end
    end

    # Opens the power menu for the selected VM: start, graceful shutdown, force off, soft
    # reboot or hard reset. Each action logs an error if the VM is in the wrong state.
    # @return [void]
    def show_power_popup
      current_vm = @line_data[content.cursor.position] || return
      state = @virt_cache.state(current_vm)
      opts = [['s', 'Start'], ['o', 'shut dOwn gracefully'], ['O', 'force Off'], ['r', 'reboot (soft)'],
              ['R', 'Reset (hard)']]
      Component::PickerWindow.open('Power', opts) do |key|
        if key == 's' # start
          if state == :shut_off
            $log.info "Starting '#{current_vm}'"
            @virt_cache.virt.start(current_vm)
          else
            $log.error "'#{current_vm}' is already running"
          end
        elsif key == 'o' # shutdown gracefully
          if state == :running
            $log.info "Shutting down '#{current_vm}' gracefully"
            @virt_cache.virt.shutdown(current_vm)
          else
            $log.error "'#{current_vm}' is not running"
          end
        elsif key == 'O' # Force Off
          if state == :running
            $log.info "Force off '#{current_vm}'"
            @virt_cache.virt.force_off(current_vm)
          else
            $log.error "'#{current_vm}' is not running"
          end
        elsif key == 'r' # reboot
          if state == :running
            $log.info "Asking '#{current_vm}' to reboot"
            @virt_cache.virt.reboot(current_vm)
          else
            $log.error "'#{current_vm}' is not running"
          end
        elsif key == 'R' # reset
          if state == :running
            $log.info "Resetting '#{current_vm}' forcefully"
            @virt_cache.virt.reset(current_vm)
          else
            $log.error "'#{current_vm}' is not running"
          end
        end
      end
    end

    # Builds a VM's overview line: state glyph, name, and (when running) a balloon emoji
    # with a ballooning-direction indicator and a "stale data" turtle.
    #
    # @param cache [Virt::Cache::VMCache] the VM's cache entry
    # @return [String] the rendered overview line
    def format_vm_overview_line(cache)
      line = "#{format_domain_state(cache.data.state)} #{screen.theme.vm_name(cache.info.name)}"
      if cache.data.running?
        if cache.data.balloon?
          line += " \u{1F388}"
          balloon_status = @ballooning.status(cache.info.name)
          unless balloon_status.nil?
            sc = if !@ballooning.enabled?(cache.info.name)
                   'x'
                 elsif balloon_status.memory_delta.negative?
                   "\u{2193}"
                 elsif balloon_status.memory_delta.positive?
                   "\u{2191}"
                 else
                   '-'
                 end
            line += sc
          end
        end
        line += " \u{1F422}" if cache.stale?
      end
      header(line)
    end

    # Draws a row header: `left` caption followed by a frame rule filling the rest of the
    # window width.
    #
    # @param left [String] the caption (may contain styling)
    # @return [String] the rendered header line
    def header(left)
      left_size = StyledString.parse(left).display_width
      frame = '─' * (rect.width - left_size - 4).clamp(0, nil)
      left + screen.theme.frame(frame)
    end

    # Renders one labelled progress-bar segment: `left` caption, the bar, then `right`
    # caption, within `width` characters.
    #
    # @param left [String] left caption (padded to 11 chars unless empty)
    # @param right [String] right caption (padded to 6 chars)
    # @param width [Integer] total width of the segment, in characters
    # @param value [Numeric] current value, for drawing the progress bar
    # @param max [Numeric] max value, for drawing the progress bar
    # @param color [Tuile::Color] progress bar color
    # @return [String] the rendered segment, including ANSI color codes
    def progress_bar(left, right, width, value, max, color)
      @f.labelled_bar(width, left, right, value, max, color, screen.theme[:frame], label_width: 11)
    end

    # Renders a {ResourceUsage} as a progress-bar segment captioned with percent used and
    # the used/total byte sizes; blank space if `mem_usage` is `nil`.
    #
    # @param width [Integer] the width of the segment, in characters
    # @param mem_usage [ResourceUsage, nil] the resource usage to render
    # @param color [Tuile::Color] progress bar color
    # @return [String] the rendered segment
    def usage_bar(width, mem_usage, color)
      return ' ' * width if mem_usage.nil?

      progress_bar("#{mem_usage.percent_used.to_s.rjust(3)}% #{format_byte_size(mem_usage.used).rjust(5)}",
                   format_byte_size(mem_usage.total), width, mem_usage.used, mem_usage.total, color)
    end

    # Maps a VM state to a colored status glyph.
    #
    # @param state [Symbol] one of `:running`, `:shut_off`, `:paused`, `:other`
    # @return [String] the colored glyph for that state
    def format_domain_state(state)
      theme = screen.theme
      case state
      when :running  then theme.ok("\u{25B6}")
      when :shut_off then theme.off("\u{23F9}")
      when :paused   then theme.warn("\u{23F8}")
      else; theme.error('?')
      end
    end

    # Renders the host-side disk bar for a VM disk: the qcow2 file's usage of its host
    # disk, prefixed by a color-coded storage-overhead percentage.
    #
    # @param width [Integer] the width of the bar, in characters
    # @param ds [Virt::DiskStat] the VM disk to render
    # @return [String, nil] the rendered bar, or `nil` if the disk isn't tracked by the cache
    def progress_bar_qcow2(width, ds)
      host_du = @virt_cache.host_disk_usage(ds)
      return nil if host_du.nil?

      theme = screen.theme
      overhead_percent = ds.overhead_percent
      overhead_token = case overhead_percent
                       when ..10
                         :ok
                       when 10..20
                         :warn
                       else
                         :error
                       end
      op = theme.fg(overhead_token, overhead_percent.to_s.rjust(3))
      prefix = "#{op}% #{format_byte_size(host_du.used).rjust(5)} "
      prefix + progress_bar('', format_byte_size(host_du.total), width - 11, host_du.used, host_du.total, theme[:disk])
    end
  end
end
