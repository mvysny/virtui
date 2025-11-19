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
  # @param virt_cache [VirtCache]
  # @param ballooning [Ballooning]
  def initialize(virt_cache, ballooning)
    super('[1]-VMs')
    @f = Formatter.new
    # {VirtCache}
    @virt_cache = virt_cache
    # {Ballooning}
    @ballooning = ballooning
    # {Array<Integer>} for every line displayed in the window, this holds the index of the "owner line"
    # (the line which holds the VM name). This line gets selected.
    @owner_lines = []
    self.selection = VMSelection.new(@owner_lines)
    update
  end

  class VMSelection < Selection::Single
    def initialize(owner_lines)
      super(index: 0)
      @owner_lines = owner_lines
    end

    protected

    def go_up
      return false if @selected <= 0

      owner_line = @owner_lines[@selected]
      return false if owner_line <= 0

      @selected = @owner_lines[owner_line - 1]
      true
    end

    def go_down(line_count)
      current_owner_line = @owner_lines[@selected]
      next_owner_line = @owner_lines[(@selected + 1)..].find { it != current_owner_line }
      return false if next_owner_line.nil?

      @selected = next_owner_line
      true
    end
  end

  def update
    domains = @virt_cache.domains.sort # Array<String>
    content do |lines|
      @owner_lines.clear
      domains.each do |domain_name|
        owner_line = lines.size
        cache = @virt_cache.cache(domain_name)
        data = cache.data
        lines << format_vm_overview_line(cache)
        @owner_lines << owner_line

        if data.running?
          cpu_usage = @virt_cache.cache(domain_name).guest_cpu_usage.round(2)
          guest_mem_usage = cache.data.mem_stat.guest_mem
          lines << "    #{Rainbow('Guest CPU').bright.blue}: [#{@f.progress_bar(20, 100,
                                                                                [[cpu_usage.to_i, :dodgerblue]])}] #{Rainbow(cpu_usage).bright.blue}%; #{data.info.cpus} #cpus"
          @owner_lines << owner_line
          unless guest_mem_usage.nil?
            lines << "    #{Rainbow('Guest RAM').bright.red}: [#{@f.progress_bar(20, guest_mem_usage.total,
                                                                                 [[guest_mem_usage.used, :crimson]])}] #{@f.format(guest_mem_usage)}"
            @owner_lines << owner_line
          end
        end
        data.disk_stat.each do |ds|
          lines << '    ' + @f.format(ds)
          @owner_lines << owner_line
        end
      end
    end
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
          sc = if balloon_status.memory_delta.negative?
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
    @log.set_rect_and_repaint(Rect.new(left_pane_w, 0, sw - left_pane_w, sh))

    # print status bar
    print TTY::Cursor.move_to(0, sh), ' ' * sw
    print TTY::Cursor.move_to(0, sh), "Q #{Rainbow('quit').cadetblue}"
  end

  def update_data
    @system.update
    @vms.update
  end

  # Called when a character is pressed on keyboard.
  def handle_key(key)
    @vms.handle_key(key)
  end
end
