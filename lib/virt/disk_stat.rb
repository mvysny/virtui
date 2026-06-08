# frozen_string_literal: true

# A VM disk statistics.
#
# - `name` {String} the name of the device, e.g. `vda` or `sda`
# - `allocation` {Integer} how much of the guest’s disk has real data behind it
# - `capacity` {Integer} maximum size of the guest disk
# - `physical` {Integer} how big the qcow2 file actually is on host's filesystem right now
# - `path` {String} path to the qcow2 file
class DiskStat < Data.define(:name, :allocation, :capacity, :physical, :path)
  # @return [MemoryUsage] `allocation` used out of `capacity`
  def guest_usage = MemoryUsage.of(capacity, allocation)

  # @return [Integer] how much data is allocated vs the max capacity. 0..100
  def percent_used = guest_usage.percent_used

  # @return [Integer] how much bigger `physical` (host storage size) is, compared to `allocation` (guest-stored data).
  # 0 if `physical` == `allocation`; may be less than zero if `physical` is smaller (e.g. due compression).
  def overhead_percent
    (((physical.to_f / allocation) - 1) * 100).clamp(-100, 999).to_i
  end

  def to_s
    "#{name}: #{format_byte_size(allocation)}/#{format_byte_size(capacity)} (#{percent_used}%); physical #{format_byte_size(physical)} (#{overhead_percent}% overhead)"
  end
end
