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
    @cpu = @f.format(virt_cache.cpu_info)
    @cpu_info = "#{virt_cache.cpu_info.model}, #{virt_cache.cpu_info.cpus} threads"
    update
  end

  def update
    content do |lines|
      # CPU
      lines << header('CPU', @cpu_info, :dodgerblue)
      host_cpu_usage = @virt_cache.host_cpu_usage
      lines << "#{@cpu}; #{Rainbow(host_cpu_usage).blue.bright}% used"
      vm_cpu_usage = @virt_cache.total_vm_cpu_usage.round(2)
      pb = @f.progress_bar(20, 100, [[vm_cpu_usage.to_i, :magenta], [host_cpu_usage.to_i, :dodgerblue]])
      lines << "     [#{pb}] #{Rainbow(vm_cpu_usage).magenta}% used by VMs"

      # Memory
      lines << header('RAM', '', :crimson)
      lines << @f.format(@virt_cache.host_mem_stat)
      total_ram = @virt_cache.host_mem_stat.ram.total
      total_vm_rss_usage = @virt_cache.total_vm_rss_usage
      ram_use = [[total_vm_rss_usage, :magenta], [@virt_cache.host_mem_stat.ram.used, :crimson]]
      pb = @f.progress_bar(20, total_ram, ram_use)
      lines << "     [#{pb}] #{Rainbow(format_byte_size(total_vm_rss_usage)).magenta} used by VMs"

      # Disk
      lines << header('Disks', '', '#ffffff')
      disks = @virt_cache.disks
      disk_usage = disks.values.inject(MemoryUsage::ZERO) { |sum, obj| sum + obj.usage }
      lines << "Disk: #{@f.format(disk_usage)}"
      disks.each do |name, usage|
        use = [[usage.vm_usage, :magenta], [usage.usage.used, :gray]]
        pb = @f.progress_bar(20, usage.usage.total, use)
        lines << "   #{name}: [#{pb}] #{Rainbow(format_byte_size(usage.vm_usage)).magenta} used by VMs"
      end
    end
  end

  protected

  def on_width_changed
    update
  end

  private

  # Draws and returns a header.
  # @param left [String] what to show to the left
  # @param right [String] what to show to the right
  # @param color [Symbol | String] the color to draw `left` and `right`
  def header(left, right, color)
    left = left.to_s
    right = right.to_s
    frame = '─' * (rect.width - left.size - right.size - 4).clamp(0, nil)
    Rainbow(left).fg(color) + Rainbow(frame).fg('#333333') + Rainbow(right).fg(color)
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
    content do |lines|
      @line_data.clear
      domains.each do |domain_name|
        cursor_positions << lines.size
        cache = @virt_cache.cache(domain_name)
        data = cache.data
        lines << format_vm_overview_line(cache)
        @line_data << domain_name

        if data.running?
          cpu_usage = @virt_cache.cache(domain_name).guest_cpu_usage.round(2)
          guest_mem_usage = cache.data.mem_stat.guest_mem
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

  private

  # @param cache [VirtCache::VMCache]
  # @return [String]
  def format_vm_overview_line(cache)
    line = "#{@f.format_domain_state(cache.data.state)} #{Rainbow(cache.info.name).white}"
    memstat = cache.data.mem_stat
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
      line += "   #{Rainbow('Host RSS RAM').bright.red}: #{@f.format(memstat.host_mem)}"
    end
    line
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
    left_pane_w = sw / 2
    sh -= 1 # make way for the status bar
    system_height = 11
    @system.set_rect_and_repaint(Rect.new(0, 0, left_pane_w, system_height))
    @vms.set_rect_and_repaint(Rect.new(0, system_height, left_pane_w, sh - system_height))
    @vms.active = true
    @log.set_rect_and_repaint(Rect.new(left_pane_w, 0, sw - left_pane_w, sh))

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
