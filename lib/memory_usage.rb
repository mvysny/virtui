# frozen_string_literal: true

# Resource usage: `total` and `available`, in bytes, both {Integer}. Immutable, thread-safe.
class MemoryUsage < Data.define(:total, :available)
  ZERO = MemoryUsage.new(0, 0)
  def self.of(total, used) = MemoryUsage.new(total: total, available: total - used)
  # @return [Integer] bytes of resource used
  def used = total - available
  # @return [Integer] 0..100% used
  def percent_used = total.zero? ? 0 : (used * 100 / total).clamp(0, 100)
  def +(other) = MemoryUsage.new(total + other.total, available + other.available)

  def to_s
    "#{format_byte_size(used)}/#{format_byte_size(total)} (#{percent_used}%)"
  end
end
