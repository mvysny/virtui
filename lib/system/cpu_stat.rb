# frozen_string_literal: true

module System
  # The aggregate `cpu` line from `/proc/stat`, broken into its clock-tick counters.
  #
  # Each counter is a cumulative count, since boot, of *USER_HZ ticks* the CPU spent in
  # that state (summed across all cores). A "tick" here is the kernel's scheduler-clock
  # tick, not a hardware CPU cycle: it is `1 / USER_HZ` of a second, where `USER_HZ` is
  # almost always 100 on Linux — so one tick is ~10 ms of CPU time. The fields therefore
  # measure *time*, not instructions: e.g. `user` is the total core-time spent in user
  # mode, `idle` the time spent idle.
  #
  # Because the counters only ever grow, an instantaneous reading is meaningless on its
  # own; CPU usage is the *delta* between two snapshots — `busy_delta / total_delta` over
  # the interval (see {System::CpuUsage}). `name` is the literal `"cpu"` label; every
  # other field is an {Integer} tick count. Immutable and thread-safe (a frozen {Data}
  # value object).
  class CpuStat < Data.define(:name, :user, :nice, :system, :idle, :iowait, :irq, :softirq, :steal, :guest, :guest_nice)
    # @return [Integer] ticks spent idle (`idle + iowait`)
    def clocks_idle
      idle + iowait
    end

    # @return [Integer] ticks spent doing work (everything except idle/iowait)
    def clocks_non_idle
      user + nice + system + irq + softirq + steal
    end

    # @return [Integer] total ticks (`clocks_idle + clocks_non_idle`)
    def clocks_total
      clocks_idle + clocks_non_idle
    end

    # Parses the aggregate `cpu` line out of `/proc/stat`.
    #
    # @param proc_stat_file [String, nil] contents of `/proc/stat`; reads the real file
    #   when `nil`. Pass a fixture string for testing.
    # @return [System::CpuStat] the parsed counters
    def self.parse(proc_stat_file = nil)
      stat = proc_stat_file || File.read('/proc/stat')
      cpu_line = stat.lines.filter { |line| line.strip.start_with? 'cpu ' }.first
      # example line "cpu  1000 50 800 5000 200 0 100 0 0 0"
      # The fields are (in order): user nice system idle iowait irq softirq steal guest guest_nice
      values = cpu_line.strip.split
      CpuStat.new(values[0], values[1].to_i, values[2].to_i, values[3].to_i, values[4].to_i, values[5].to_i,
                  values[6].to_i, values[7].to_i, values[8].to_i, values[9].to_i, values[10].to_i)
    end

    # @return [String] all counters on one line, e.g. `"cpu: user=1000 nice=50 …"`
    def to_s
      "#{name}: user=#{user} nice=#{nice} system=#{system} idle=#{idle} iowait=#{iowait} " \
        "irq=#{irq} softirq=#{softirq} steal=#{steal} guest=#{guest} guest_nice=#{guest_nice}"
    end
  end
end
