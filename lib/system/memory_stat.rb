# frozen_string_literal: true

module System
  # Host memory statistics: physical `ram` and `swap` usage.
  #
  # Immutable and thread-safe (a frozen {Data} value object).
  #
  # @!attribute [r] ram
  #   @return [ResourceUsage] physical RAM usage
  # @!attribute [r] swap
  #   @return [ResourceUsage] swap usage
  class MemoryStat < Data.define(:ram, :swap)
    # @return [String] human-readable summary, e.g. `"RAM: 4.0G/8.0G (50%), SWAP: 0/2.0G (0%)"`
    def to_s
      "RAM: #{ram}, SWAP: #{swap}"
    end
  end
end
