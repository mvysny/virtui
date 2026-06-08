# frozen_string_literal: true

module System
  # Memory statistics: `ram` and `swap`, both {MemoryUsage}. Immutable, thread-safe.
  class MemoryStat < Data.define(:ram, :swap)
    def to_s
      "RAM: #{ram}, SWAP: #{swap}"
    end
  end
end
