require 'virt'
require 'window'
require 'sysinfo'
require 'virtcache'
require 'tty-cursor'
require 'tty-screen'
require 'rufus-scheduler'
require 'io/console'

scheduler = Rufus::Scheduler.new

virt = VirtCmd.new
# virt = LibVirtClient.new
virt_cache = VirtCache.new(virt)

class Formatter
  def initialize
    @p = Pastel.new
  end

  def format(what)
    return format_cpu(what) if what.is_a? CpuInfo
    return format_memory_stat(what) if what.is_a? MemoryStat
    return format_mem_stat(what) if what.is_a? MemStat
    return format_memory_usage(what) if what.is_a? MemoryUsage

    what.to_s
  end

  # @param cpu [CpuInfo]
  def format_cpu(cpu)
    "#{@p.bright_blue('CPU')}: #{@p.bright_blue(cpu.model)}: #{@p.cyan(cpu.cpus)}:#{cpu.sockets}/#{cpu.cores_per_socket}/#{cpu.threads_per_core} sockets/cores/threads"
  end

  # @param ms [MemoryStat]
  def format_memory_stat(ms)
    "#{@p.bright_red('RAM')}: #{format(ms.ram)}; #{@p.bright_red('SWAP')}: #{format(ms.swap)}"
  end

  # @param mu [MemoryUsage]
  def format_memory_usage(mu)
    "#{@p.cyan(format_byte_size(mu.used))}/#{@p.cyan(format_byte_size(mu.total))} (#{@p.cyan(mu.percent_used)}%)"
  end

  # @param state [Symbol] one of `:running`, `:shut_off`, `:paused`
  def format_domain_state(state)
    case state
    when :running then @p.green('running')
    when :shut_off then @p.red('shut_off')
    else; @p.yellow(state)
    end
  end

  # @param ms [MemStat]
  def format_mem_stat(ms)
    result = "Host:#{format(ms.host_mem)}"
    result += " Guest:#{format(ms.guest_mem)}" unless ms.guest_mem.nil?
    result
  end
end

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
    @system.rect = Rect.new(0, 0, left_pane_w, 4)
    @vms.rect = Rect.new(0, 4, left_pane_w, 10)
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
