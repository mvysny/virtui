# frozen_string_literal: true

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
require 'tty-logger'
require 'rainbow'

# https://github.com/piotrmurach/tty-logger
$log = TTY::Logger.new do |config|
  config.level = :warn
end
scheduler = Rufus::Scheduler.new

# Don't use LibVirtClient for now: it doesn't provide all necessary data
# virt = LibVirtClient.new
virt = VirtCmd.new if VirtCmd.available?
virt ||= vm_emulator_demo
virt_cache = VirtCache.new(virt)

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
      pb = @f.progress_bar(20, 100, [[vm_cpu_usage.to_i, :magenta], [host_cpu_usage.to_i, :bright_blue]])
      lines << "     [#{pb}] #{Rainbow(vm_cpu_usage).magenta}% used by VMs"
      lines << @f.format(@virt_cache.host_mem_stat)

      # Memory
      total_ram = @virt_cache.host_mem_stat.ram.total
      total_vm_rss_usage = @virt_cache.total_vm_rss_usage
      ram_use = [[total_vm_rss_usage, :magenta], [@virt_cache.host_mem_stat.ram.used, :bright_red]]
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
    @virt_cache = virt_cache
    @ballooning = ballooning
    update
  end

  def update
    domains = @virt_cache.domains.sort # Array<String>
    content do |lines|
      domains.each do |domain_name|
        cache = @virt_cache.cache(domain_name)
        data = cache.data
        lines << format_vm_overview_line(cache)

        if data.running?
          cpu_usage = @virt_cache.cache(domain_name).guest_cpu_usage.round(2)
          guest_mem_usage = cache.data.mem_stat.guest_mem
          lines << "    #{Rainbow('Guest CPU').bright.blue}: [#{@f.progress_bar(20, 100,
                                                                                [[cpu_usage.to_i, :bright_blue]])}] #{@p.bright_blue(cpu_usage)}%; #{data.info.cpus} #cpus"
          unless guest_mem_usage.nil?
            lines << "    #{Rainbow('Guest RAM').bright.red}: [#{@f.progress_bar(20, guest_mem_usage.total,
                                                                                 [[guest_mem_usage.used, :bright_red]])}] #{@f.format(guest_mem_usage)}"
          end
        end
        data.disk_stat.each do |ds|
          lines << '    ' + @f.format(ds)
        end
      end
    end
  end

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
      line += "   #{@p.bright_red('Host RSS RAM')}: #{@f.format(memstat.host_mem)}"
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
    @system.rect = Rect.new(0, 0, left_pane_w, 6)
    @vms.rect = Rect.new(0, 6, left_pane_w, sh - 6)
    @log.rect = Rect.new(left_pane_w, 0, sw - left_pane_w, sh)

    # print status bar
    print TTY::Cursor.move_to(0, sh), ' ' * sw
    print TTY::Cursor.move_to(0, sh), "Q #{Rainbow('quit').cadetblue}"
  end

  def update_data
    @system.update
    @vms.update
  end
end

ballooning = Ballooning.new(virt_cache)
screen = Screen.new(virt_cache, ballooning)
screen.calculate_window_sizes

# Trap the WINCH signal (sent on terminal resize)
trap('WINCH') do
  screen.calculate_window_sizes
end

# https://github.com/jmettraux/rufus-scheduler
scheduler.every '2s' do
  virt_cache.update
  # Needs to go after virt_cache.update so that it reads up-to-date values
  ballooning.update
  # Needs to go last, to correctly update current ballooning status
  screen.update_data
rescue StandardError => e
  $log.fatal('Failed to update VM data', e)
end

begin
  loop do
    char = STDIN.getch
    break if char == 'q'

    $log.debug "Got: #{char} (ord: #{char.ord})"
  end
ensure
  scheduler.shutdown
  screen.clear
end
