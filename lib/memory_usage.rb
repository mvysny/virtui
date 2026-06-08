# frozen_string_literal: true

# A byte-usage value object pairing `total` capacity with currently `available` bytes.
#
# Used across the codebase for any total/available resource — RAM, disk, VM memory.
# Immutable and thread-safe (a frozen {Data} value object), so instances can be shared
# freely between the background timer thread and the UI thread.
#
# @!attribute [r] total
#   @return [Integer] total capacity, in bytes
# @!attribute [r] available
#   @return [Integer] currently unused capacity, in bytes
class MemoryUsage < Data.define(:total, :available)
  # The empty usage (zero total, zero available); a neutral element for {#+}.
  ZERO = MemoryUsage.new(0, 0)

  # Builds a usage from `total` capacity and bytes already `used`.
  #
  # @param total [Integer] total capacity, in bytes
  # @param used [Integer] bytes already consumed
  # @return [MemoryUsage] usage whose `available` is `total - used`
  def self.of(total, used) = MemoryUsage.new(total: total, available: total - used)

  # @return [Integer] bytes of resource used (`total - available`)
  def used = total - available

  # @return [Integer] percentage used, clamped to `0..100` (0 when `total` is zero)
  def percent_used = total.zero? ? 0 : (used * 100 / total).clamp(0, 100)

  # Adds two usages component-wise, e.g. to sum per-disk usage into a host total.
  #
  # @param other [MemoryUsage] the usage to add
  # @return [MemoryUsage] sum of the two `total`s and the two `available`s
  def +(other) = MemoryUsage.new(total + other.total, available + other.available)

  # @return [String] human-readable `used/total (percent%)`, e.g. `"4.0 GiB/8.0 GiB (50%)"`
  def to_s
    "#{format_byte_size(used)}/#{format_byte_size(total)} (#{percent_used}%)"
  end
end
