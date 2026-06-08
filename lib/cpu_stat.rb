# frozen_string_literal: true

# A representation of a single `cpu` line from `/proc/stat`. `name` is {String} `cpu`; others are {Integer}s.
#
# Immutable, thread-safe.
class CpuStat < Data.define(:name, :user, :nice, :system, :idle, :iowait, :irq, :softirq, :steal, :guest, :guest_nice)
  def clocks_idle
    idle + iowait
  end

  def clocks_non_idle
    user + nice + system + irq + softirq + steal
  end

  def clocks_total
    clocks_idle + clocks_non_idle
  end

  # Parses `/proc/stat` file.
  # @param proc_stat_file [String | nil] test contents of /proc/stat. For testing only.
  # @return [CpuStat]
  def self.parse(proc_stat_file = nil)
    stat = proc_stat_file || File.read('/proc/stat')
    cpu_line = stat.lines.filter { |line| line.strip.start_with? 'cpu ' }.first
    # example line "cpu  1000 50 800 5000 200 0 100 0 0 0"
    # The fields are (in order): user nice system idle iowait irq softirq steal guest guest_nice
    values = cpu_line.strip.split
    CpuStat.new(values[0], values[1].to_i, values[2].to_i, values[3].to_i, values[4].to_i, values[5].to_i,
                values[6].to_i, values[7].to_i, values[8].to_i, values[9].to_i, values[10].to_i)
  end

  def to_s
    "#{name}: user=#{user} nice=#{nice} system=#{system} idle=#{idle} iowait=#{iowait} irq=#{irq} softirq=#{softirq} steal=#{steal} guest=#{guest} guest_nice=#{guest_nice}"
  end
end
