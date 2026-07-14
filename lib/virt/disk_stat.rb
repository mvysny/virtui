# frozen_string_literal: true

module Virt
  # Statistics for a single VM disk device.
  #
  # Distinguishes three sizes that are easy to confuse: how much data the guest has
  # written (`allocation`), the guest disk's nominal size (`capacity`), and how many bytes
  # the backing qcow2 file currently occupies on the host (`physical`).
  #
  # @!attribute [r] name
  #   @return [String] the device name, e.g. `"vda"` or `"sda"`
  # @!attribute [r] allocation
  #   @return [Integer] bytes of the guest disk that have real data behind them
  # @!attribute [r] capacity
  #   @return [Integer] nominal (maximum) size of the guest disk, in bytes
  # @!attribute [r] physical
  #   @return [Integer] current on-host size of the qcow2 file, in bytes
  # @!attribute [r] path
  #   @return [String] path to the qcow2 file on the host
  class DiskStat < Data.define(:name, :allocation, :capacity, :physical, :path)
    # @return [ResourceUsage] `allocation` used out of `capacity`
    def guest_usage = ResourceUsage.of(capacity, allocation)

    # @return [Integer] how much data is allocated vs the max capacity. 0..100
    def percent_used = guest_usage.percent_used

    # @return [Integer] how much bigger `physical` (host storage size) is, compared to `allocation` (guest-stored data).
    # 0 if `physical` == `allocation`; may be less than zero if `physical` is smaller (e.g. due compression).
    def overhead_percent
      (((physical.to_f / allocation) - 1) * 100).clamp(-100, 999).to_i
    end

    # @return [String] human-readable summary of guest usage and host overhead
    def to_s
      "#{name}: #{format_byte_size(allocation)}/#{format_byte_size(capacity)} (#{percent_used}%); " \
        "physical #{format_byte_size(physical)} (#{overhead_percent}% overhead)"
    end
  end
end
