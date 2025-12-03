# frozen_string_literal: true

require_relative 'virt/virt'
require_relative 'ttyui/window'
require_relative 'sysinfo'
require_relative 'virt/virtcache'
require 'tty-cursor'
require_relative 'formatter'
require_relative 'virt/ballooning'
require_relative 'virt/vm_emulator'
require 'rainbow'
require_relative 'utils'
require_relative 'ttyui/screen'
require_relative 'system_window'
require_relative 'ttyui/picker_window'

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
    # {Boolean} show disk stats for shutoff'd VMs
    @show_disk_stat = false
    self.cursor = Cursor.new
    update
  end

  # {Boolean} show disk stats for shutoff'd VMs
  attr_reader :show_disk_stat

  def show_disk_stat=(value)
    @show_disk_stat = !!value
    update
  end

  def update
    domains = @virt_cache.domains.sort_by(&:upcase) # Array<String>
    cursor_positions = [] # allowed cursor positions
    column_width = (rect.width - 16) / 2
    cpus = @virt_cache.cpu_info.cpus
    host_ram = @virt_cache.host_mem_stat.ram
    content do |lines|
      @line_data.clear
      domains.each do |domain_name|
        cursor_positions << lines.size
        # {VMCache}
        cache = @virt_cache.cache(domain_name)
        # {DomainData}
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
          lines << "    #{Rainbow('CPU').fg(:dodgerblue)}:#{cpuguest} | #{cpuhost}"
          @line_data << domain_name

          guest_mem_usage = cache.data.mem_stat.guest_mem
          host_mem_usage = cache.data.mem_stat.host_mem
          memguest = progress_bar2(column_width, guest_mem_usage, :magenta)
          memhost = progress_bar2(column_width, MemoryUsage.of(host_ram.total, host_mem_usage.used), :maroon)
          lines << "    #{Rainbow('RAM').fg(:maroon)}:#{memguest} | #{memhost}"
          @line_data << domain_name
        end
        next unless @show_disk_stat || data.running?

        data.disk_stat.each do |ds| # {DiskStat}
          name = Rainbow(ds.name[0..3].rjust(4)).fg(:gold)
          guest_du = progress_bar2(column_width, ds.guest_usage, :chocolate)
          host_du = progress_bar_qcow2(column_width, ds)
          lines << "   #{name}:#{guest_du} | #{host_du}"
          @line_data << domain_name
        end
      end
    end
    self.cursor = Cursor::Limited.new(cursor_positions, position: cursor.position)
  end

  def handle_key(key)
    return true if super

    current_vm = @line_data[cursor.position]
    return false if current_vm.nil?

    state = @virt_cache.state(current_vm)

    if key == 'p' # Power menu
      show_power_popup
      true
    elsif key == 'v' # view
      $log.info "Launching viewer for '#{current_vm}'"
      Run.async("virt-manager --connect qemu:///system --show-domain-console '#{current_vm}'")
      true
    elsif key == 'b' # toggle Ballooning
      if state == :running
        $log.info "Toggling balloning for '#{current_vm}'"
        @ballooning.toggle_enable(current_vm)
      else
        $log.error "'#{current_vm}' is not running"
      end
      true
    elsif key == 'd'
      self.show_disk_stat = !show_disk_stat
      true
    else
      false
    end
  end

  def keyboard_hint
    "p #{Rainbow('Power').cadetblue}  v #{Rainbow('run Viewer').cadetblue}  b #{Rainbow('toggle autoBallooning').cadetblue}  d #{Rainbow('toggle Disk stat').cadetblue}"
  end

  protected

  def on_width_changed
    update
  end

  private

  def show_power_popup
    current_vm = @line_data[cursor.position] || return
    state = @virt_cache.state(current_vm)
    opts = [['s', 'Start'], ['o', 'shut dOwn gracefully'], ['r', 'reboot'], ['R', 'Reset']]
    PickerWindow.open('Power', opts) do |key|
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
  end

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
    left = left.ljust(11) unless left.empty?
    right = right.rjust(6)
    pb_width = (width - left.size - right.size).clamp(0, nil)
    pb = @f.progress_bar2(pb_width, value, max, color)
    left + pb + right
  end

  # @param width [Integer] the width of the bar in chars.
  # @param mem_usage [MemoryUsage] resource usage
  def progress_bar2(width, mem_usage, color)
    return ' ' * width if mem_usage.nil?

    progress_bar("#{mem_usage.percent_used.to_s.rjust(3)}% #{format_byte_size(mem_usage.used).rjust(5)}",
                 format_byte_size(mem_usage.total), width, mem_usage.used, mem_usage.total, color)
  end

  # @param width [Integer] the width of the bar in chars.
  # @param ds [DiskStat]
  # @return [String | nil]
  def progress_bar_qcow2(width, ds)
    host_du = @virt_cache.host_disk_usage(ds)
    return nil if host_du.nil?

    overhead_percent = ds.overhead_percent
    overhead_color = case overhead_percent
                     when ..10
                       :green
                     when 10..20
                       :yellow
                     else
                       :red
                     end
    op = Rainbow(overhead_percent.to_s.rjust(3)).fg(overhead_color)
    prefix = "#{op}% #{format_byte_size(host_du.used).rjust(5)} "
    prefix + progress_bar('', format_byte_size(host_du.total), width - 11, host_du.used, host_du.total, :goldenrod)
  end
end
