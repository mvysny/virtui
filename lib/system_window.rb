# frozen_string_literal: true

require_relative 'ttyui/window'
require_relative 'formatter'
require_relative 'ttyui/popup_window'

# Shows host OS info, such as CPU info, memory info.
class SystemWindow < Window
  # @param virt_cache [VirtCache]
  def initialize(virt_cache)
    super('[2]-System')
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

  def keyboard_hint
    "h #{Rainbow('Help').cadetblue}"
  end

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

  def show_help_window
    lines = []
    flags = @virt_cache.cpu_flags
    lines += [['vmx', 'Intel VT-x (Virtualization Technology) - required for KVM on Intel']] if flags.include? 'vmx'
    if flags.include? 'svm'
      lines += [['svm', 'AMD-V (AMD Secure Virtual Machine, aka AMD-V) - required for KVM on AMD']]
    end
    lines += [['software', 'No virtualization supported by CPU, using slow software emulation']] if lines.empty?
    lines += [['ept', "Intel's Extended Page Tables memory virtualization"]] if flags.include? 'ept'
    lines += [['npt', "AMD's Nested Page Tables memory virtualization"]] if flags.include? 'npt'
    lines += [['tsc_deadline', 'Faster APIC timer (better timing in guest OS)']] if flags.include? 'tsc_deadline'
    if flags.include? 'pcid'
      lines += [['pcid', 'Process-Context Identifiers – speeds up context switches and TLB flushes in guests']]
    end
    lines += [['vpid', '(Intel) → tagged TLB, speeds up guest transitions']] if flags.include? 'vpid'
    if flags.include? 'invpcid'
      lines += [['invpcid', 'Single-instruction invalidation of PCID – further improves TLB performance']]
    end
    if flags.include? 'pdpe1gb'
      lines += [['pdpe1gb', '1GB huge pages support (greatly improves memory performance for VMs)']]
    end
    lines += [['xsave', 'Faster saving/restoring of extended CPU state during VM entry/exit']] if flags.any? do
      it.start_with? 'xsave'
    end

    InfoPopupWindow.open('Help', lines.map { it[0] + ': ' + Rainbow(it[1]).cadetblue })
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
