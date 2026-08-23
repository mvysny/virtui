# frozen_string_literal: true

module UI
  # The VM window: a scrollable, cursor-selectable list of all VMs, each with guest-vs-host
  # CPU/RAM/disk usage bars and a ballooning-status indicator. Per-VM actions are reachable
  # via key shortcuts: power menu (`p`), launch viewer (`v`), memory menu (`m`), toggle disk
  # stats (`d`) and search (`/`).
  #
  # UI-thread-confined.
  class VMWindow < Tuile::Component::Window
    include Tuile

    # Separates a row's guest half from its host half. The same vertical bar tuile draws the
    # window border with, so the two columns read as framed rather than piped apart.
    COLUMN_SEPARATOR = '│'

    # Width of the caption cell every row opens its column with, bar rows and the swap row
    # alike — what keeps their figures in one column.
    LABEL_WIDTH = 11

    # The rate that fills the swap-out gauge. A rate has no natural 100%, so this is a chosen
    # alarm scale and not a ratio: it is set high enough that a guest thrashing hard still has
    # bar left to grow into, which costs sensitivity at the bottom — on a ~100-column terminal
    # the gauge's first character lights at ~0.8 MiB/s, so a trickle below that reads as an
    # empty bar and only the warn-colored label reports it. See DECISIONS.md
    # D-swap-rate-full-scale for the self-scaling alternatives this rejects.
    SWAP_RATE_FULL_SCALE = 20.MiB

    # Width of the swap row's `↕traffic` tail — the arrow plus a 5-char byte size. Fixed, so
    # every VM's gauge is the same length and the bars stay comparable down the list.
    SWAP_TOTALS_WIDTH = 6

    # The guest-OS marker drawn between a VM's state glyph and its name, keyed by
    # {Virt::GuestOS#family}. Emoji, because the overview line is already read by its glyphs
    # (▶/⏹/🎈/🐢), and a family with no entry here — `:unknown` — falls through to the
    # dim `?` {#format_guest_os} draws instead. See DECISIONS.md D-guest-os-glyph.
    #
    # One entry per {Virt::GuestOS::FAMILIES} key, so every declaration osinfo-db can express
    # draws something. Where a project has a mascot the mascot wins (🐧 Tux, 😈 Beastie,
    # 🐡 Puffy, 🚩 NetBSD's flag, 🍎 Apple, 🌞 Sun, 🍃 Haiku's leaf); the rest are the
    # nearest recognisable stand-in, because Unicode has no dragonfly and no gnu. Every glyph
    # here measures {GUEST_OS_WIDTH} — checked against `unicode/display_width`, not assumed:
    # the obvious ☀️ for Solaris and 🕸️ for NetWare measure **1**, being variation sequences,
    # and are why those two rows are 🌞 and 🌐.
    GUEST_OS_GLYPHS = {
      linux: "\u{1F427}",        # 🐧 Tux
      windows: "\u{1FA9F}",      # 🪟
      freebsd: "\u{1F608}",      # 😈 Beastie, the BSD daemon
      openbsd: "\u{1F421}",      # 🐡 Puffy the pufferfish
      netbsd: "\u{1F6A9}",       # 🚩 the flag of its logo
      dragonflybsd: "\u{1F409}", # 🐉 no dragonfly in Unicode; the dragon is the near miss
      macos: "\u{1F34E}",        # 🍎
      solaris: "\u{1F31E}",      # 🌞 Sun Microsystems
      illumos: "\u{1F4A1}",      # 💡 *illuminare*, which is where the name comes from
      haiku: "\u{1F343}",        # 🍃 the leaf of its logo
      dos: "\u{1F4BE}",          # 💾
      netware: "\u{1F310}"       # 🌐 Novell's networking-first pitch
    }.freeze

    # Display width every guest-OS marker is padded to. All of {GUEST_OS_GLYPHS} measure 2
    # (tuile sizes rows via `unicode/display_width`), so a narrower marker — or a blank one —
    # would pull that row's VM name a column left and cost the list its name column.
    GUEST_OS_WIDTH = 2

    # @param virt_cache [Virt::Cache] the runtime cache to read VM data from and act through
    # @param ballooning [Virt::Ballooning] the ballooning controller toggled from the memory menu
    def initialize(virt_cache, ballooning)
      super('VMs')
      self.content = Component::List.new
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
      content.build_lines do |lines|
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
            lines << "    #{theme.cpu('CPU')}:#{cpuguest} #{COLUMN_SEPARATOR} #{cpuhost}"
            @line_data << domain_name

            guest_mem_usage = cache.data.mem_stat.guest_mem
            host_mem_usage = cache.data.mem_stat.host_mem
            memguest = usage_bar(column_width, guest_mem_usage, theme[:ram_vm])
            memhost = usage_bar(column_width, ResourceUsage.of(host_ram.total, host_mem_usage.used), theme[:ram])
            lines << "    #{theme.ram('RAM')}:#{memguest} #{COLUMN_SEPARATOR} #{memhost}"
            @line_data << domain_name

            swap = format_swap_line(cache, column_width)
            unless swap.nil?
              lines << swap
              @line_data << domain_name
            end
          end
          next unless @show_disk_stat || data.running?

          data.disk_stat.each do |ds| # {Virt::DiskStat}
            name = theme.disk_label(ds.name[0..3].rjust(4))
            guest_du = usage_bar(column_width, ds.guest_usage, theme[:disk_vm])
            host_du = progress_bar_qcow2(column_width, ds)
            lines << "   #{name}:#{guest_du} #{COLUMN_SEPARATOR} #{host_du}"
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
        Run.async('virt-manager', '--connect', 'qemu:///system',
                  '--show-domain-console', current_vm)
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
      draw_text(rect.left + fourth - 5, y,
                StyledString.styled(' Guest usage ', fg: :black, bg: bg))
      draw_text(rect.left + (3 * fourth) - 5, y,
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

    # Builds a VM's overview line: state glyph, guest-OS marker, name, and (when running) a
    # balloon emoji with a ballooning-direction indicator and a "stale data" turtle.
    #
    #     ▶ 🐧 Ubuntu 🎈↑────
    #     ⏹ ?  BASE───────
    #
    # What sits on which side of the name is the rule to keep: left of it goes what the VM
    # *is* — facts that hold still while the user reads — and right of it what it is *doing*
    # right now. A live indicator on the left would shift the name column on every tick.
    #
    # @param cache [Virt::Cache::VMCache] the VM's cache entry
    # @return [String] the rendered overview line
    def format_vm_overview_line(cache)
      line = "#{format_domain_state(cache.data.state)} #{format_guest_os(cache.guest_os)} " \
             "#{screen.theme.vm_name(cache.info.name)}"
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

    # The guest-OS marker for a VM's overview line: what the VM's definition declares, as one
    # {GUEST_OS_GLYPHS} emoji padded to {GUEST_OS_WIDTH} cells.
    #
    # An undeclared OS draws a dim `?` rather than blank space, because `:unknown` is not a
    # neutral state here: {Virt::GuestOS#no_proc_meminfo?} is `!linux?`, so such a VM is never
    # asked for its swap level and quietly loses the guest half of its SWAP row — this marker
    # is the only thing on screen that says why. Same argument as {#swap_level_bar}'s dashes:
    # blank reads as *nothing there* when it means *nobody asked*.
    #
    # @param guest_os [Virt::GuestOS] what this VM's definition declares
    # @return [String] the marker, {GUEST_OS_WIDTH} cells wide, styling not counted
    def format_guest_os(guest_os)
      glyph = GUEST_OS_GLYPHS[guest_os.family] || screen.theme.frame('?')
      glyph + (' ' * (GUEST_OS_WIDTH - StyledString.parse(glyph).display_width).clamp(0, nil))
    end

    # The swap row, one per running VM that reports swap counters. Two cells, two questions:
    # the guest half is *occupancy*, drawn exactly like the RAM row above it so the two read
    # against each other; the host half is *I/O*, because guest swap writes land on the host's
    # disk.
    #
    #     RAM: 50%    4G ########---------  7.9G │  16%  5.1G ##---------------   32G
    #    SWAP: 43%  1.8G #######----------    4G │       3M/s ##-------------- ↕ 1.8G
    #    SWAP:  -        -----------------       │        0/s ---------------- ↕    0
    #          ^level, or unknown                        ^rate now      traffic since boot^
    #
    # Why the rate sits on the host side rather than beside the level: {#swap_io_bar}. Why an
    # unknown level is dashes rather than blank: {#swap_level_bar}. Both in DECISIONS.md
    # D-swap-row-two-cells.
    #
    # Rendered whether or not the guest is swapping, so the warn coloring on the label rather
    # than the row's presence is what draws the eye: hiding the row at rest made every VM
    # below it jump a row on each swap burst. Absent *counters* are the one case that still
    # hides it, because that state never flips back — see DECISIONS.md D-swap-row-always-on.
    # (A guest that reports a level but no counters therefore gets no row at all; no distro
    # kernel builds without `CONFIG_VM_EVENT_COUNTERS`, so that combination stays theoretical.)
    #
    # @param cache [Virt::Cache::VMCache] the VM's cache entry
    # @param column_width [Integer] width of one usage-bar column, so the separator lines up
    # @return [String, nil] the rendered line, or `nil` if the guest reports no swap counters
    def format_swap_line(cache, column_width)
      mem_stat = cache.data.mem_stat
      return nil unless mem_stat&.swap_data_available?

      theme = screen.theme
      label = cache.swap_out_rate&.positive? ? theme.warn('SWAP') : theme.swap('SWAP')
      # 3 spaces, not 4: 'SWAP' is a character wider than 'CPU'/'RAM', and this lines its
      # colon up with theirs — same trick as the 4-char disk labels above.
      "   #{label}:#{swap_level_bar(column_width, cache.guest_swap)} " \
        "#{COLUMN_SEPARATOR} #{swap_io_bar(column_width, cache.swap_out_rate, mem_stat)}"
    end

    # How full the guest's swap device is — the guest half of the swap row.
    #
    #    22%  1.8G #####--------------------     8G   <- 1.8G parked on an 8G device
    #      -        -------------------------         <- this guest cannot report a level
    #
    # Dashes rather than blank space for an unknown level, because blank reads as *nothing
    # parked* when it means *nobody asked*: the level needs a guest agent behind a persistent
    # virsh session (see {Virt::GuestAgent}), which plenty of guests will never have. Keeping
    # the cell occupied is also what keeps the rate in one column for every VM.
    #
    # @param width [Integer] width of one usage-bar column
    # @param level [ResourceUsage, nil] the guest's swap level, or `nil` if unavailable
    # @return [String] the rendered segment
    def swap_level_bar(width, level)
      theme = screen.theme
      return usage_bar(width, level, theme[:swap]) unless level.nil?

      # A full-width run of `rest_color` dashes: value 0 of 1.
      progress_bar('  -', '', width, 0, 1, theme[:swap])
    end

    # What the guest's swapping costs the host — the host half of the swap row: the rate now,
    # then the traffic since the guest booted.
    #
    #     3M/s ##-------------------- ↕  45M
    #
    # On the host side because that is what this column means everywhere else on the screen:
    # a guest's swap writes are the host's disk writes. The two lifetime counters are summed
    # for the same reason — `swap_out + swap_in` is the total traffic the host paid for, and
    # which direction it went is what the rate and the level already say.
    #
    # The gauge reads against {SWAP_RATE_FULL_SCALE} rather than a per-VM maximum, so two VMs'
    # bars mean the same thing.
    #
    # @param width [Integer] width of one usage-bar column
    # @param rate [Float, nil] bytes per second written to swap; `nil` on a first sample,
    #   where the counters are there but no interval has passed to diff them over
    # @param mem_stat [Virt::MemoryStat] the VM's memory stats, for the lifetime counters
    # @return [String] the rendered segment
    def swap_io_bar(width, rate, mem_stat)
      theme = screen.theme
      rate_text = rate.nil? ? '-' : format_byte_size(rate.round)
      # Right-aligned within the caption cell, one space clear of the bar — which puts the
      # figure in the same column the CPU/RAM rows end their own captions in.
      caption = "#{"#{rate_text.rjust(5)}/s".rjust(LABEL_WIDTH - 1)} "
      traffic = "#{theme.frame('↕')}#{format_byte_size(mem_stat.swap_out + mem_stat.swap_in).rjust(5)}"
      bar = Formatter.progress_bar((width - LABEL_WIDTH - SWAP_TOTALS_WIDTH - 1).clamp(0, nil),
                                   rate || 0, SWAP_RATE_FULL_SCALE, theme[:swap], theme[:frame])
      "#{caption}#{bar.to_ansi} #{traffic}"
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
    # @param left [String] left caption (padded to {LABEL_WIDTH} chars unless empty)
    # @param right [String] right caption (padded to 6 chars)
    # @param width [Integer] total width of the segment, in characters
    # @param value [Numeric] current value, for drawing the progress bar
    # @param max [Numeric] max value, for drawing the progress bar
    # @param color [Tuile::Color] progress bar color
    # @return [String] the rendered segment, including ANSI color codes
    def progress_bar(left, right, width, value, max, color)
      Formatter.labelled_bar(width, left, right, value, max, color, screen.theme[:frame],
                             label_width: LABEL_WIDTH)
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
