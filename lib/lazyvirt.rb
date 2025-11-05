require_relative 'virt'
require_relative 'window'
require_relative 'sysinfo'
require_relative 'virtcache'
require 'tty-cursor'
require 'tty-screen'
require 'rufus-scheduler'
require 'io/console'
require_relative 'formatter'

scheduler = Rufus::Scheduler.new

$p = Pastel.new
virt = VirtCmd.new
# virt = LibVirtClient.new
virt_cache = VirtCache.new(virt)

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
      lines << @cpu
      lines << @f.format(@virt_cache.host_mem_stat)
      total_ram = @virt_cache.host_mem_stat.ram.total
      total_vm_rss_usage = @virt_cache.total_vm_rss_usage
      ram_use = { total_vm_rss_usage => :magenta, @virt_cache.host_mem_stat.ram.used => :bright_red }
      lines << "     [#{@f.progress_bar(20, total_ram, ram_use)}]  #{$p.magenta(format_byte_size(total_vm_rss_usage))} used by VMs"
    end
  end
end

class VMWindow < Window
  # @param virt_cache [VirtCache]
  def initialize(virt_cache)
    super('[1]-VMs')
    @f = Formatter.new
    @virt_cache = virt_cache
    update
  end

  def update
    domains = @virt_cache.domains.sort_by(&:name) # Array<DomainId>
    content do |lines|
      domains.each do |domain_id|
        line = $p.white(domain_id.name)
        state = @virt_cache.state(domain_id)
        line += " #{@f.format_domain_state(state)}"
        memstat = @virt_cache.memstat(domain_id) if domain_id.running?
        line += " #{@f.format(memstat)}" unless memstat.nil?
        lines << line
      end
    end
  end
end

class Screen
  # @param virt_cache [VirtCache]
  def initialize(virt_cache)
    @f = Formatter.new
    @virt_cache = virt_cache
    @system = SystemWindow.new(virt_cache)
    @vms = VMWindow.new(virt_cache)
  end

  # Clears the TTY screen
  def clear
    print TTY::Cursor.move_to(0, 0), TTY::Cursor.clear_screen
  end

  # Re-calculates all window sizes and re-positions them. Call initially, and
  # when TTY size changes.
  def calculate_window_sizes
    clear
    _, sw = TTY::Screen.size
    left_pane_w = sw / 2
    @system.rect = Rect.new(0, 0, left_pane_w, 5)
    @vms.rect = Rect.new(0, 5, left_pane_w, 10)
  end

  def update_data
    @system.update
    @vms.update
  end
end

screen = Screen.new(virt_cache)
screen.calculate_window_sizes

# Trap the WINCH signal (sent on terminal resize)
trap('WINCH') do
  screen.calculate_window_sizes
end

# https://github.com/jmettraux/rufus-scheduler
scheduler.every '3s' do
  virt_cache.update
  screen.update_data
end

loop do
  char = STDIN.getch
  break if char == 'q'

  # Show the code point (helps debug escape sequences)
  printf "Got: %p (ord: %d)\n", char, char.ord
end

scheduler.shutdown
screen.clear
