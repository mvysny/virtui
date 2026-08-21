# frozen_string_literal: true

module System
  # Host memory statistics: physical `ram` and `swap` usage.
  #
  # @!attribute [r] ram
  #   @return [ResourceUsage] physical RAM usage
  # @!attribute [r] swap
  #   @return [ResourceUsage] swap usage
  class MemoryStat < Data.define(:ram, :swap)
    # The four `/proc/meminfo` keys {.parse} needs; a file missing any of them is truncated
    # or not `/proc/meminfo` at all.
    REQUIRED_KEYS = %w[MemTotal MemAvailable SwapTotal SwapFree].freeze

    # Parses the contents of a Linux `/proc/meminfo`.
    #
    # On the value object rather than in {Info} because the file is not only the host's: a
    # *guest*'s copy, read through the QEMU guest agent, is the same format and the only
    # place a VM's swap level exists (see {Virt::MemoryStat#swap_out}).
    #
    # @param meminfo_file [String] the contents of `/proc/meminfo`
    # @return [MemoryStat] RAM (`MemTotal`/`MemAvailable`) and swap (`SwapTotal`/`SwapFree`)
    # @raise [RuntimeError] if any required key is missing — which is how a short read from
    #   a guest surfaces, rather than as a plausible-looking zero
    def self.parse(meminfo_file)
      # Lines without a colon are dropped rather than raising on the split: a truncated
      # guest read ends mid-key, and the missing-key check below is the better error.
      mem = meminfo_file.lines.map { |it| it.split(':', 2) }.select { |it| it.size == 2 }.to_h
      missing = REQUIRED_KEYS.reject { |key| mem.key?(key) }
      raise "/proc/meminfo lacks #{missing.join(', ')}: #{meminfo_file[0, 200].inspect}" unless missing.empty?

      MemoryStat.new(ResourceUsage.new(total: mem['MemTotal'].strip.to_i.KiB,
                                       available: mem['MemAvailable'].strip.to_i.KiB),
                     ResourceUsage.new(total: mem['SwapTotal'].strip.to_i.KiB,
                                       available: mem['SwapFree'].strip.to_i.KiB))
    end

    # @return [String] human-readable summary, e.g. `"RAM: 4G/8G (50%), SWAP: 0/2G (0%)"`
    def to_s
      "RAM: #{ram}, SWAP: #{swap}"
    end
  end
end
