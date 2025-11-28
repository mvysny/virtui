# frozen_string_literal: true

require_relative 'virt'
require_relative 'window'
require_relative 'sysinfo'
require_relative 'virtcache'
require 'tty-cursor'
require 'tty-screen'
require_relative 'formatter'
require_relative 'ballooning'
require_relative 'vm_emulator'
require 'rainbow'
require_relative 'utils'

# Shows host OS info, such as CPU info, memory info.
class SystemWindow < Window
  # @param virt_cache [VirtCache]
  def initialize(virt_cache)
    super('System')
    @f = Formatter.new
    @virt_cache = virt_cache
    @cpu_info = format_cpu_info
    update
  end

  def update
    content do |lines|
      # CPU
      lines << header('CPU', @cpu_info, :dodgerblue)
      host_cpu_usage = @virt_cache.host_cpu_usage.to_i
      lines << progress_bar("Used:#{host_cpu_usage.to_s.rjust(3)}%", host_cpu_usage, 100, :dodgerblue,
                            "#{@virt_cache.cpu_info.cpus} t")
      vm_cpu_usage = @virt_cache.total_vm_cpu_usage.to_i
      up = @virt_cache.up
      lines << progress_bar(" VMs:#{vm_cpu_usage.to_s.rjust(3)}%", vm_cpu_usage, 100, :royalblue, "#{up} up")

      # Memory
      lines << header('RAM', '', :maroon)
      host_ram = @virt_cache.host_mem_stat.ram
      lines << progress_bar2('Used', host_ram, :maroon)
      total_vm_rss_usage = @virt_cache.total_vm_rss_usage
      lines << progress_bar(" VMs:#{(total_vm_rss_usage * 100 / host_ram.total).to_s.rjust(3)}% #{format_byte_size(total_vm_rss_usage).rjust(5)}",
                            total_vm_rss_usage, host_ram.total, :magenta, format_byte_size(host_ram.total))
      host_swap = @virt_cache.host_mem_stat.swap
      lines << progress_bar2('Swap', host_swap, :maroon)

      # Disk
      disks = @virt_cache.disks
      disk_usage = disks.values.inject(MemoryUsage::ZERO) { |sum, obj| sum + obj.usage }
      lines << header('Disks', format_byte_size(disk_usage.total), :goldenrod)
      disks.each do |name, usage|
        lines << Rainbow("#{name}:").fg(:gold)
        lines << progress_bar2('Used', usage.usage, :goldenrod)
        lines << progress_bar2(' VMs', MemoryUsage.new(usage.usage.total, usage.usage.total - usage.vm_usage),
                               :chocolate)
      end
    end
  end

  protected

  def on_width_changed
    update
  end

  private

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
    r += ' ept' if flags.include? 'ept'
    r += ' npt' if flags.include? 'npt'
    # EPT/NPT for memory virtualization (almost all CPUs since ~2008 have this)
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

  # Draws and returns a header.
  # @param left [String] what to show to the left
  # @param right [String] what to show to the right
  # @param color [Symbol | String] the color to draw `left` and `right`
  def header(left, right, color)
    frame = '─' * (rect.width - left.size - right.size - 4).clamp(0, nil)
    Rainbow(left).fg(color) + Rainbow(frame).fg('#333333') + Rainbow(right).fg(color)
  end

  # @param left [String] of size 14
  # @param right [String] of size 5
  # @param value [Integer] current value, for drawing of the progress bar
  # @param max [Integer] max value, for drawing of the progress bar
  def progress_bar(left, value, max, color, right)
    left = left.ljust(16)
    right = right.rjust(6)
    pb_width = (rect.width - 4 - left.size - right.size).clamp(0, nil)
    pb = @f.progress_bar2(pb_width, value, max, color)
    left + pb + right
  end

  # @param tag [String] 4-char tag
  # @param mem_usage [MemoryUsage] resource usage
  def progress_bar2(tag, mem_usage, color)
    progress_bar("#{tag}:#{mem_usage.percent_used.to_s.rjust(3)}% #{format_byte_size(mem_usage.used).rjust(5)}",
                 mem_usage.used, mem_usage.total, color,
                 format_byte_size(mem_usage.total))
  end
end

# Shows a quick overview of all VMs
class VMWindow < Window
  # @param virt_cache [VirtCache]
  # @param ballooning [Ballooning]
  def initialize(virt_cache, ballooning)
    super('[1]-VMs')
    @f = Formatter.new
    # {VirtCache}
    @virt_cache = virt_cache
    # {Ballooning}
    @ballooning = ballooning
    # {Array<String>} VM name for every line.
    @line_data = []
    self.cursor = Cursor.new
    update
  end

  def update
    domains = @virt_cache.domains.sort_by(&:upcase) # Array<String>
    cursor_positions = [] # allowed cursor positions
    column_width = (rect.width - 4 - 4) / 2
    cpus = @virt_cache.cpu_info.cpus
    content do |lines|
      @line_data.clear
      domains.each do |domain_name|
        cursor_positions << lines.size
        cache = @virt_cache.cache(domain_name)
        data = cache.data
        lines << format_vm_overview_line(cache)
        @line_data << domain_name

        if data.running?
          cpu_usage = cache.guest_cpu_usage.to_i
          host_cpu_usage = (cache.cpu_usage / cpus).to_i
          cpuguest = progress_bar("#{cpu_usage.to_s.rjust(3)}%", "#{data.info.cpus.to_s.rjust(3)} t", column_width,
                                  cpu_usage, 100, :royalblue)
          cpuhost = progress_bar("#{host_cpu_usage.to_s.rjust(3)}%", "#{cpus.to_s.rjust(3)} t", column_width,
                                 host_cpu_usage, 100, :dodgerblue)
          lines << '  CPU: ' + cpuguest + ' | ' + cpuhost
          guest_mem_usage = cache.data.mem_stat.guest_mem
          host_mem_usage = cache.data.mem_stat.host_mem
          memguest = progress_bar2(column_width, guest_mem_usage, :magenta)
          memhost = progress_bar2(column_width, host_mem_usage, :maroon)
          lines << "  RAM: #{memguest} | #{memhost}"
          lines << "    #{Rainbow('Guest CPU').bright.blue}: [#{@f.progress_bar(20, 100,
                                                                                [[cpu_usage.to_i, :dodgerblue]])}] #{Rainbow(cpu_usage).bright.blue}%; #{data.info.cpus} #cpus"
          @line_data << domain_name
          unless guest_mem_usage.nil?
            lines << "    #{Rainbow('Guest RAM').bright.red}: [#{@f.progress_bar(20, guest_mem_usage.total,
                                                                                 [[guest_mem_usage.used, :crimson]])}] #{@f.format(guest_mem_usage)}"
            @line_data << domain_name
          end
        end
        data.disk_stat.each do |ds|
          lines << '    ' + @f.format(ds)
          @line_data << domain_name
        end
      end
    end
    self.cursor = Cursor::Limited.new(cursor_positions, position: cursor.position)
  end

  def handle_key(key)
    super
    current_vm = @line_data[cursor.position] || return
    state = @virt_cache.state(current_vm)

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
    elsif key == 'v' # view
      $log.info "Launching viewer for '#{current_vm}'"
      Run.async("virt-manager --connect qemu:///system --show-domain-console '#{current_vm}'")
    elsif key == 'b' # toggle Ballooning
      if state == :running
        $log.info "Toggling balloning for '#{current_vm}'"
        @ballooning.toggle_enable(current_vm)
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

  def keyboard_hint
    "s #{Rainbow('start').cadetblue}  o #{Rainbow('shutdOwn').cadetblue}  v #{Rainbow('run Viewer').cadetblue}  b #{Rainbow('toggle autoBallooning').cadetblue}  r #{Rainbow('reboot').cadetblue}  R #{Rainbow('reset').cadetblue}"
  end

  protected

  def on_width_changed
    update
  end

  private

  # @param cache [VirtCache::VMCache]
  # @return [String]
  def format_vm_overview_line(cache)
    line = "#{@f.format_domain_state(cache.data.state)} #{Rainbow(cache.info.name).white}"
    cache.data.mem_stat
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
      #   line += "   #{Rainbow('Host RSS RAM').bright.red}: #{@f.format(memstat.host_mem)}"
    end
    header(line)
  end

  # Draws and returns a header.
  # @param left [String] what to show to the left
  def header(left)
    left_size = Unicode::DisplayWidth.of(Rainbow.uncolor(left))
    frame = '─' * (rect.width - left_size - 4).clamp(0, nil)
    left + Rainbow(frame).fg('#333333')
  end

  # @param left [String] of size 10
  # @param right [String] of size 5
  # @param width [Integer] width of the bar in chars.
  # @param value [Integer] current value, for drawing of the progress bar
  # @param max [Integer] max value, for drawing of the progress bar
  # @param color [Symbol | String] progress bar color
  def progress_bar(left, right, width, value, max, color)
    left = left.ljust(11)
    right = right.rjust(6)
    pb_width = (width - 4 - left.size - right.size).clamp(0, nil)
    pb = @f.progress_bar2(pb_width, value, max, color)
    left + pb + right
  end

  # @param width [Integer] the width of the bar in chars.
  # @param mem_usage [MemoryUsage] resource usage
  def progress_bar2(width, mem_usage, color)
    progress_bar("#{mem_usage.percent_used.to_s.rjust(3)}% #{format_byte_size(mem_usage.used).rjust(5)}",
                 format_byte_size(mem_usage.total), width, mem_usage.used, mem_usage.total, color)
  end
end

# A screen, holding all windows.
class Screen
  # @param virt_cache [VirtCache]
  # @param ballooning [Ballooning]
  def initialize(virt_cache, ballooning)
    @f = Formatter.new
    @virt_cache = virt_cache
    @system = SystemWindow.new(virt_cache)
    @vms = VMWindow.new(virt_cache, ballooning)
    @log = LogWindow.new
    @log.configure_logger $log
  end

  # Clears the TTY screen
  def clear
    print TTY::Cursor.move_to(0, 0), TTY::Cursor.clear_screen
  end

  # Re-calculates all window sizes and re-positions them. Call initially, and
  # when TTY size changes.
  def calculate_window_sizes
    clear
    sh, sw = TTY::Screen.size
    system_width = (sw / 2).clamp(0, 60)
    sh -= 1 # make way for the status bar
    system_height = 13
    vms_height = sh - system_height
    @system.set_rect_and_repaint(Rect.new(0, vms_height, system_width, system_height))
    @vms.set_rect_and_repaint(Rect.new(0, 0, sw, vms_height))
    @vms.active = true
    @log.set_rect_and_repaint(Rect.new(system_width, vms_height, sw - system_width, system_height))

    # print status bar
    print TTY::Cursor.move_to(0, sh), ' ' * sw
    print TTY::Cursor.move_to(0, sh), "Q #{Rainbow('quit').cadetblue}  ", active_window.keyboard_hint
  end

  def update_data
    @system.update
    @vms.update
  end

  # Called when a character is pressed on keyboard.
  def handle_key(key)
    active_window.handle_key(key)
  end

  private

  def active_window
    [@system, @vms, @log].find(&:active?)
  end
end
