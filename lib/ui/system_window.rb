# frozen_string_literal: true

module UI
  # The host window: shows CPU model/flags and usage, RAM and swap usage, and per-disk
  # usage — each as a labelled progress bar built from {Virt::Cache} data. Pressing `h`
  # opens a help window explaining the host's virtualization CPU flags.
  class SystemWindow < Tuile::Component::Window
    include Tuile

    # @param virt_cache [Virt::Cache] the runtime cache to read host metrics from
    def initialize(virt_cache)
      super('System')
      self.content = Component::List.new
      @f = Formatter.new
      @virt_cache = virt_cache
      @cpu_info = format_cpu_info
      update
    end

    # Rebuilds the window's lines (CPU/RAM/disk bars) from the current cache data.
    # @return [void]
    def update
      theme = screen.theme
      content.lines do |lines|
        # CPU
        lines << header('CPU', @cpu_info, :cpu)
        host_cpu_usage = @virt_cache.host_cpu_usage.to_i
        lines << progress_bar("Used:#{host_cpu_usage.to_s.rjust(3)}%", host_cpu_usage, 100, theme[:cpu],
                              "#{@virt_cache.cpu_info.cpus} t")
        vm_cpu_usage = @virt_cache.total_vm_cpu_usage.to_i
        up = @virt_cache.up
        lines << progress_bar(" VMs:#{vm_cpu_usage.to_s.rjust(3)}%", vm_cpu_usage, 100, theme[:cpu_vm], "#{up} up")

        # Memory
        lines << header('RAM', '', :ram)
        host_ram = @virt_cache.host_mem_stat.ram
        lines << progress_bar2('Used', host_ram, theme[:ram])
        total_vm_rss_usage = @virt_cache.total_vm_rss_usage
        lines << progress_bar(" VMs:#{(total_vm_rss_usage * 100 / host_ram.total).to_s.rjust(3)}% #{format_byte_size(total_vm_rss_usage).rjust(5)}",
                              total_vm_rss_usage, host_ram.total, theme[:ram_vm], format_byte_size(host_ram.total))
        host_swap = @virt_cache.host_mem_stat.swap
        lines << progress_bar2('Swap', host_swap, theme[:ram])

        # Disk
        disks = @virt_cache.disks
        disk_usage = disks.values.inject(ResourceUsage::ZERO) { |sum, obj| sum + obj.usage }
        lines << header('Disks', format_byte_size(disk_usage.total), :disk)
        disks.each do |name, usage|
          lines << theme.disk_label("#{name}:")
          lines << progress_bar2('Used', usage.usage, theme[:disk])
          lines << progress_bar2(' VMs', ResourceUsage.new(usage.usage.total, usage.usage.total - usage.vm_usage),
                                 theme[:disk_vm])
        end
      end
    end

    # @return [String] the footer hint advertising the `h` (Help) key
    def keyboard_hint
      "h #{screen.theme.hint('Help')}"
    end

    # Handles a key press: `h` opens the CPU-flags help window.
    #
    # @param key [String] the pressed key
    # @return [Boolean] true if the key was handled
    def handle_key(key)
      return if super

      if key == 'h'
        show_help_window
        true
      else
        false
      end
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

    private

    # Builds the one-line CPU summary: model plus the notable virtualization flags
    # (`vmx`/`svm`, `ept`/`npt`, and assorted TLB/huge-page accelerators).
    #
    # @return [String] the CPU info line
    def format_cpu_info
      r = @virt_cache.cpu_info.model + ', '
      flags = @virt_cache.cpu_flags
      # Intel VT-x (Virtualization Technology) - required for KVM on Intel
      vmx = flags.include? 'vmx'
      # AMD-V (AMD Secure Virtual Machine, aka AMD-V) - required for KVM on AMD
      svm = flags.include? 'svm'
      r += 'software' if !vmx && !svm
      r += 'vmx' if vmx
      r += 'svm' if svm
      # EPT/NPT for memory virtualization (almost all CPUs since ~2008 have this)
      r += ' ept' if flags.include? 'ept'
      r += ' npt' if flags.include? 'npt'
      # Faster APIC timer (better timing in guests)
      r += ' tsc_deadline' if flags.include? 'tsc_deadline'
      # Process-Context Identifiers – speeds up context switches and TLB flushes in guests
      r += ' pcid' if flags.include? 'pcid'
      # (Intel) → tagged TLB, speeds up guest transitions
      r += ' vpid' if flags.include? 'vpid'
      # Single-instruction invalidation of PCID – further improves TLB performance
      r += ' invpcid' if flags.include? 'invpcid'
      # 1GB huge pages support (greatly improves memory performance for VMs)
      r += ' pdpe1gb' if flags.include? 'pdpe1gb'
      # Faster saving/restoring of extended CPU state during VM entry/exit
      r += ' xsave' if flags.any? { it.start_with? 'xsave' }
      r
    end

    # Opens an info window describing each virtualization-related CPU flag the host has.
    # @return [void]
    def show_help_window
      lines = []
      flags = @virt_cache.cpu_flags
      lines += [['vmx', 'Intel VT-x (Virtualization Technology) - required for KVM']] if flags.include? 'vmx'
      lines += [['svm', 'AMD-V (AMD Secure Virtual Machine, aka AMD-V) - required for KVM']] if flags.include? 'svm'
      lines += [['software', 'No virtualization supported by CPU, using slow software emulation']] if lines.empty?
      lines += [['ept', "Intel's Extended Page Tables memory virtualization"]] if flags.include? 'ept'
      lines += [['npt', "AMD's Nested Page Tables memory virtualization"]] if flags.include? 'npt'
      lines += [['tsc_deadline', 'Faster APIC timer (better timing in guest OS)']] if flags.include? 'tsc_deadline'
      if flags.include? 'pcid'
        lines += [['pcid', 'Process-Context Identifiers – speeds up context switches and TLB flushes in guests']]
      end
      if flags.include? 'vpid'
        lines += [['vpid', '(Intel) → tagged TLB (Translation Lookaside Buffer), speeds up guest transitions']]
      end
      if flags.include? 'invpcid'
        lines += [['invpcid', 'Single-instruction invalidation of PCID – further improves TLB performance']]
      end
      if flags.include? 'pdpe1gb'
        lines += [['pdpe1gb', '1GB huge pages support (greatly improves memory performance for VMs)']]
      end
      if flags.any? { it.start_with? 'xsave' }
        lines += [['xsave', 'Faster saving/restoring of extended CPU state during VM entry/exit']]
      end

      Component::InfoWindow.open('Help', lines.map { it[0] + ': ' + screen.theme.hint(it[1]) })
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
      left = left.ljust(16)
      right = right.rjust(6)
      pb_width = (rect.width - 4 - left.size - right.size).clamp(0, nil)
      pb = @f.progress_bar2(pb_width, value, max, color, screen.theme[:frame])
      left + pb.to_ansi + right
    end

    # Renders a {ResourceUsage} as a progress-bar row, captioning it with `tag`, the percent
    # used and the used/total byte sizes.
    #
    # @param tag [String] short (~4-char) label, e.g. `"Used"`/`"Swap"`
    # @param mem_usage [ResourceUsage] the resource usage to render
    # @param color [Tuile::Color] progress bar color
    # @return [String] the rendered row
    def progress_bar2(tag, mem_usage, color)
      progress_bar("#{tag}:#{mem_usage.percent_used.to_s.rjust(3)}% #{format_byte_size(mem_usage.used).rjust(5)}",
                   mem_usage.used, mem_usage.total, color,
                   format_byte_size(mem_usage.total))
    end
  end
end
