require_relative 'virt'
require_relative 'window'
require_relative 'sysinfo'
require_relative 'virtcache'
require 'tty-cursor'
require 'tty-screen'
require 'rufus-scheduler'
require 'io/console'
require_relative 'formatter'
require_relative 'ballooning'
require_relative 'vm_emulator'

scheduler = Rufus::Scheduler.new

$p = Pastel.new

# Don't use LibVirtClient for now: it doesn't provide all necessary data
# virt = LibVirtClient.new
virt = VirtCmd.new if VirtCmd.available?
virt ||= vm_emulator_demo
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
      # CPU
      host_cpu_usage = @virt_cache.host_cpu_usage
      lines << "#{@cpu}; #{$p.bright_blue(host_cpu_usage)}% used"
      vm_cpu_usage = @virt_cache.total_vm_cpu_usage.round(2)
      pb = @f.progress_bar(20, 100, [[vm_cpu_usage.to_i, :magenta], [host_cpu_usage.to_i, :bright_blue]])
      lines << "     [#{pb}] #{$p.bright_blue(vm_cpu_usage)}% used by VMs"
      lines << @f.format(@virt_cache.host_mem_stat)

      # Memory
      total_ram = @virt_cache.host_mem_stat.ram.total
      total_vm_rss_usage = @virt_cache.total_vm_rss_usage
      ram_use = [[total_vm_rss_usage, :magenta], [@virt_cache.host_mem_stat.ram.used, :bright_red]]
      pb = @f.progress_bar(20, total_ram, ram_use)
      lines << "     [#{pb}] #{$p.magenta(format_byte_size(total_vm_rss_usage))} used by VMs"
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
    domains = @virt_cache.domains.sort # Array<String>
    content do |lines|
      domains.each do |domain_name|
        data = @virt_cache.data(domain_name)
        state = data.state
        line = "#{@f.format_domain_state(state)} #{$p.white(domain_name)}"
        memstat = data.mem_stat
        if data.running?
          line += " \u{1F388}" if data.balloon?
          line += "   #{$p.bright_red('Host RSS RAM')}: #{@f.format(memstat.host_mem)}"
        end
        lines << line
        if data.running?

          cpu_usage = @virt_cache.cpu_usage(domain_name).round(2)
          guest_mem_usage = memstat.guest_mem
          lines << "    #{$p.bright_blue('Guest CPU')}: [#{@f.progress_bar(20, 100,
                                                                           [[cpu_usage.to_i, :bright_blue]])}] #{$p.bright_blue(cpu_usage)}%; #{data.info.cpus} #cpus"
          unless guest_mem_usage.nil?
            lines << "    #{$p.bright_red('Guest RAM')}: [#{@f.progress_bar(20, guest_mem_usage.total,
                                                                            [[guest_mem_usage.used, :bright_red]])}] #{@f.format(guest_mem_usage)}"
          end
        end
        data.disk_stat.each do |ds|
          lines << '    ' + @f.format(ds)
        end
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
    $log = LogWindow.new
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
    @system.rect = Rect.new(0, 0, left_pane_w, 6)
    @vms.rect = Rect.new(0, 6, left_pane_w, sh - 6)
    $log.rect = Rect.new(left_pane_w, 0, sw - left_pane_w, sh)
  end

  def update_data
    @system.update
    @vms.update
  end
end

screen = Screen.new(virt_cache)
screen.calculate_window_sizes
ballooning = Ballooning.new(virt_cache)

# Trap the WINCH signal (sent on terminal resize)
trap('WINCH') do
  screen.calculate_window_sizes
end

# https://github.com/jmettraux/rufus-scheduler
scheduler.every '2s' do
  virt_cache.update
  screen.update_data
  #  ballooning.update
rescue StandardError => e
  $log.error 'Failed to update VM data', e: e
end

loop do
  char = STDIN.getch
  break if char == 'q'

  # Show the code point (helps debug escape sequences)
  printf "Got: %p (ord: %d)\n", char, char.ord
end

scheduler.shutdown
screen.clear
