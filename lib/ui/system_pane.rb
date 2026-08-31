# frozen_string_literal: true

module UI
  # The host pane: shows CPU model/flags and usage, RAM and swap usage, and per-disk
  # usage — each as a labelled progress bar built from {Virt::Cache} data. Pressing `h`
  # opens {CpuFlagsWindow}, explaining the host's virtualization CPU flags.
  #
  # A borderless `Layout::Vertical` (see DECISIONS.md D_panes_are_layouts): a one-row
  # header carrying the focus chip, over the {Tuile::Component::List}. The list carries a
  # {Tuile::Component::List::Cursor::Limited} over the bar rows — focus indication
  # consistent with {VMPane}, and keyboard scrolling when the disk list overflows the
  # pane's fixed height (`less`/`htop` move highlights through non-actionable rows the
  # same way); headers and blank rows are skipped, since a cursor parked on one reads
  # as a glitch.
  #
  # UI-thread-confined.
  class SystemPane < Tuile::Component::Layout::Vertical
    include Tuile

    # @param virt_cache [Virt::Cache] the runtime cache to read host metrics from
    def initialize(virt_cache)
      super()
      @virt_cache = virt_cache
      @header = Component::Label.new
      @list = Component::List.new
      @list.scrollbar_visibility = :visible
      add(@header, Fixed[1])
      add(@list, Expand[1])
      @cpu_info = format_cpu_info
      rebuild_header
      update
    end

    # @return [Tuile::Component::List] the metric list — the pane's focus target
    attr_reader :list

    # Focuses the metric list. The pane itself is passive layout; the list is what owns
    # the cursor and the keyboard.
    # @return [void]
    def focus
      @list.focus
    end

    # Rebuilds the pane's lines (CPU/RAM/disk bars) from the current cache data, and
    # recomputes the allowed cursor positions (the bar rows; section headers and disk
    # name rows are skipped).
    # @return [void]
    def update
      theme = screen.theme
      cursor_positions = []
      @list.build_lines do |lines|
        # CPU
        lines << header('CPU', @cpu_info, :cpu)
        host_cpu_usage = @virt_cache.host_cpu_usage.to_i
        cursor_positions << lines.size
        lines << progress_bar("Used:#{host_cpu_usage.to_s.rjust(3)}%", host_cpu_usage, 100, theme[:cpu],
                              "#{@virt_cache.cpu_info.cpus} t")
        vm_cpu_usage = @virt_cache.total_vm_cpu_usage.to_i
        up = @virt_cache.up
        cursor_positions << lines.size
        lines << progress_bar(" VMs:#{vm_cpu_usage.to_s.rjust(3)}%", vm_cpu_usage, 100, theme[:cpu_vm], "#{up} up")

        # Memory
        lines << header('RAM', '', :ram)
        host_ram = @virt_cache.host_mem_stat.ram
        cursor_positions << lines.size
        lines << usage_bar('Used', host_ram, theme[:ram])
        total_vm_rss_usage = @virt_cache.total_vm_rss_usage
        cursor_positions << lines.size
        lines << progress_bar(
          " VMs:#{(total_vm_rss_usage * 100 / host_ram.total).to_s.rjust(3)}% #{format_byte_size(total_vm_rss_usage).rjust(5)}",
          total_vm_rss_usage, host_ram.total, theme[:ram_vm], format_byte_size(host_ram.total)
        )
        host_swap = @virt_cache.host_mem_stat.swap
        cursor_positions << lines.size
        lines << usage_bar('Swap', host_swap, theme[:swap])

        # Disk
        disks = @virt_cache.disks
        disk_usage = disks.values.inject(ResourceUsage::ZERO) { |sum, obj| sum + obj.usage }
        lines << header('Disks', format_byte_size(disk_usage.total), :disk)
        disks.each do |name, usage|
          lines << theme.disk_label("#{name}:")
          cursor_positions << lines.size
          lines << usage_bar('Used', usage.usage, theme[:disk])
          cursor_positions << lines.size
          lines << usage_bar(' VMs', ResourceUsage.new(usage.usage.total, usage.usage.total - usage.vm_usage),
                             theme[:disk_vm])
        end
      end
      @list.cursor = Component::List::Cursor::Limited.new(cursor_positions, position: @list.cursor.position)
    end

    # @return [Tuile::StyledString] the pane's focus chip, inverted iff the pane owns the
    #   keyboard. `[2]` mirrors {AppLayout}'s focus-key map.
    def chip
      Formatter.chip('2', 'System', focused: active?, theme: screen.theme)
    end

    # @return [String] the footer hint advertising the `h` (Help) key
    def keyboard_hint
      "h #{screen.theme.hint('Help')}"
    end

    # Handles a key press: `h` opens {CpuFlagsWindow}.
    #
    # @param key [String] the pressed key
    # @return [Boolean] true if the key was handled
    def handle_key(key)
      return if super

      if key == 'h'
        CpuFlagsWindow.open(@virt_cache.cpu_flags)
        true
      else
        false
      end
    end

    # Rebuilds the header when the pane enters or leaves the focus chain — the chip's
    # inverted/dim state is baked into the header label's text.
    # @param value [Boolean]
    # @return [void]
    def active=(value)
      super
      rebuild_header
    end

    protected

    # Re-renders when the pane width changes (bar widths depend on it).
    # @return [void]
    def on_width_changed
      super
      rebuild_header
      update
    end

    # Re-renders when the theme changes, so colors follow the new palette.
    # @return [void]
    def on_theme_changed
      super
      rebuild_header
      update
    end

    private

    # Rebuilds the header row — the focus chip.
    # @return [void]
    def rebuild_header
      @header.text = chip
    end

    # Builds the one-line CPU summary — model, then whichever of the notable
    # virtualization flags the host has:
    #
    #   x86_64, svm npt tsc_deadline_timer pcid invpcid pdpe1gb xsave
    #
    # The flag list and its order come from {CpuFlag::ALL}; {CpuFlagsWindow} explains
    # each entry.
    #
    # @return [String] the CPU info line
    def format_cpu_info
      names = CpuFlag.present_in(@virt_cache.cpu_flags).map(&:name)
      "#{@virt_cache.cpu_info.model}, #{names.join(' ')}"
    end

    # Draws a section header: `left` and `right` captions in `token`'s color, joined by a
    # frame rule that fills the remaining width.
    #
    # @param left [String] what to show to the left
    # @param right [String] what to show to the right
    # @param token [Symbol] the theme token to draw `left` and `right` with
    # @return [String] the rendered header line
    def header(left, right, token)
      theme = screen.theme
      frame = '─' * (rect.width - left.size - right.size - 4).clamp(0, nil)
      theme.fg(token, left) + theme.frame(frame) + theme.fg(token, right)
    end

    # Renders one labelled progress-bar row: `left` caption, the bar filling the remaining
    # width, then `right` caption.
    #
    # @param left [String] left caption (padded to 16 chars)
    # @param value [Numeric] current value, for drawing the progress bar
    # @param max [Numeric] max value, for drawing the progress bar
    # @param color [Tuile::Color] progress bar color
    # @param right [String] right caption (padded to 6 chars)
    # @return [String] the rendered row, including ANSI color codes
    def progress_bar(left, value, max, color, right)
      Formatter.labelled_bar(rect.width - 4, left, right, value, max, color, screen.theme[:frame], label_width: 16)
    end

    # Renders a {ResourceUsage} as a progress-bar row, captioning it with `tag`, the percent
    # used and the used/total byte sizes.
    #
    # @param tag [String] short (~4-char) label, e.g. `"Used"`/`"Swap"`
    # @param mem_usage [ResourceUsage] the resource usage to render
    # @param color [Tuile::Color] progress bar color
    # @return [String] the rendered row
    def usage_bar(tag, mem_usage, color)
      progress_bar("#{tag}:#{mem_usage.percent_used.to_s.rjust(3)}% #{format_byte_size(mem_usage.used).rjust(5)}",
                   mem_usage.used, mem_usage.total, color,
                   format_byte_size(mem_usage.total))
    end
  end
end
