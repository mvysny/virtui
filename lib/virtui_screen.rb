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
    update
  end

  def update
    content do |lines|
      # CPU
      host_cpu_usage = @virt_cache.host_cpu_usage
      lines << "#{@cpu}; #{Rainbow(host_cpu_usage).blue.bright}% used"
      vm_cpu_usage = @virt_cache.total_vm_cpu_usage.round(2)
      pb = @f.progress_bar(20, 100, [[vm_cpu_usage.to_i, :magenta], [host_cpu_usage.to_i, :dodgerblue]])
      lines << "     [#{pb}] #{Rainbow(vm_cpu_usage).magenta}% used by VMs"
      lines << @f.format(@virt_cache.host_mem_stat)

      # Memory
      total_ram = @virt_cache.host_mem_stat.ram.total
      total_vm_rss_usage = @virt_cache.total_vm_rss_usage
      ram_use = [[total_vm_rss_usage, :magenta], [@virt_cache.host_mem_stat.ram.used, :crimson]]
      pb = @f.progress_bar(20, total_ram, ram_use)
      lines << "     [#{pb}] #{Rainbow(format_byte_size(total_vm_rss_usage)).magenta} used by VMs"
    end
  end
end

# Shows a quick overview of all VMs
class VMWindow < Window
  # - `owner_line` {Integer} for every line displayed in the window, this holds the index of the "owner line"
  #   (the line which holds the VM name). This line gets selected.
  # - `vm_name` {String} this line is related to this VM.
  class LineData < Data.define(:owner_line, :vm_name)
  end

  # @param virt_cache [VirtCache]
  # @param ballooning [Ballooning]
  def initialize(virt_cache, ballooning)
    super('[1]-VMs')
    @f = Formatter.new
    # {VirtCache}
    @virt_cache = virt_cache
    # {Ballooning}
    @ballooning = ballooning
    # {Array<LineData>} data for every line.
    @line_data = []
    self.selection = VMSelection.new(@line_data)
    update
  end

  class VMSelection < Selection::Single
    def initialize(line_data)
      super(index: 0)
      @line_data = line_data
    end

    protected

    def go_up
      return false if @selected <= 0

      owner_line = @line_data[@selected].owner_line
      return false if owner_line <= 0

      @selected = @line_data[owner_line - 1].owner_line
      true
    end

    def go_down(_line_count)
      current_data = @line_data[@selected]
      next_vm = @line_data[(@selected + 1)..].find { it.vm_name != current_data.vm_name }
      return false if next_vm.nil?

      @selected = next_vm.owner_line
      true
    end
  end

  def update
    domains = @virt_cache.domains.sort # Array<String>
    content do |lines|
      @line_data.clear
      domains.each do |domain_name|
        line_data = LineData.new(lines.size, domain_name)
        cache = @virt_cache.cache(domain_name)
        data = cache.data
        lines << format_vm_overview_line(cache)
        @line_data << line_data

        if data.running?
          cpu_usage = @virt_cache.cache(domain_name).guest_cpu_usage.round(2)
          guest_mem_usage = cache.data.mem_stat.guest_mem
          lines << "    #{Rainbow('Guest CPU').bright.blue}: [#{@f.progress_bar(20, 100,
                                                                                [[cpu_usage.to_i, :dodgerblue]])}] #{Rainbow(cpu_usage).bright.blue}%; #{data.info.cpus} #cpus"
          @line_data << line_data
          unless guest_mem_usage.nil?
            lines << "    #{Rainbow('Guest RAM').bright.red}: [#{@f.progress_bar(20, guest_mem_usage.total,
                                                                                 [[guest_mem_usage.used, :crimson]])}] #{@f.format(guest_mem_usage)}"
            @line_data << line_data
          end
        end
        data.disk_stat.each do |ds|
          lines << '    ' + @f.format(ds)
          @line_data << line_data
        end
      end
    end
  end

  def handle_key(key)
    super(key)

    current_vm = @line_data[selection.selected]&.vm_name
    return if current_vm.nil?

    state = @virt_cache.state(current_vm)

    if key == 's' # start
      if state == :shut_off
        $log.info "Starting '#{current_vm}'"
        @virt_cache.virt.start(current_vm)
      else
        $log.error "'#{current_vm}' is already running"
      end
    elsif key == 'S' # shutdown gracefully
      if state == :running
        $log.info "Shutting down '#{current_vm}' gracefully"
        @virt_cache.virt.shutdown(current_vm)
      else
        $log.error "'#{current_vm}' is not running"
      end
    elsif key == 'v' # view
      $log.info "Launching viewer for '#{current_vm}'"
      async_run("virt-manager --connect qemu:///system --show-domain-console '#{current_vm}'")
    elsif key == 'b' # toggle Ballooning
      if state == :running
        $log.info "Toggling balloning for '#{current_vm}'"
        @ballooning.toggle_enable(current_vm)
      else
        $log.error "'#{current_vm}' is not running"
      end
    elsif key == 'r' # reset
      $log.error 'reset unimplemented'
    elsif key == 'R' # reboot
      $log.error 'reboot unimplemented'
    elsif key == 'P' # pause
      $log.error 'pause unimplemented'
    elsif key == 'p' # unpause
      $log.error 'unpause unimplemented'
    end
  rescue StandardError => e
    $log.error('Command failed', e)
  end

  def keyboard_hint
    "s #{Rainbow('start').cadetblue}  S #{Rainbow('Shutdown').cadetblue}  v #{Rainbow('run Viewer').cadetblue}  b #{Rainbow('toggle Ballooning').cadetblue}  r #{Rainbow('reset').cadetblue}  R #{Rainbow('reboot').cadetblue}  P #{Rainbow('pause').cadetblue}  p #{Rainbow('unpause').cadetblue}"
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
    @system.set_rect_and_repaint(Rect.new(0, 0, left_pane_w, 6))
    @vms.set_rect_and_repaint(Rect.new(0, 6, left_pane_w, sh - 6))
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
