# frozen_string_literal: true

module Virt
  # Memory statistics for a single VM, spanning both the host's view (`actual`, `rss`) and
  # the guest's own view (`available`, `usable`, `unused`, `disk_caches`).
  #
  # The guest-reported fields require a working balloon device plus guest tools; they are
  # `nil` when that data isn't available (see {#guest_data_available?}). Immutable and
  # thread-safe (a frozen {Data} value object). More info:
  # https://pmhahn.github.io/virtio-balloon
  #
  # @!attribute [r] actual
  #   @return [Integer] currently configured memory size given to the VM by the host, in bytes
  # @!attribute [r] unused
  #   @return [Integer, nil] truly unused memory (kernel `MemFree`): neither used by
  #     processes nor held as cache, in bytes. `nil` if ballooning is unavailable
  # @!attribute [r] available
  #   @return [Integer, nil] memory the guest OS sees as total (kernel `MemTotal`), in
  #     bytes — slightly less than `actual` since kernel/BIOS reserve some. `nil` if
  #     ballooning is unavailable
  # @!attribute [r] usable
  #   @return [Integer, nil] memory the guest can readily use (kernel `MemAvailable`):
  #     free space plus easily reclaimable caches, in bytes. `nil` if ballooning is unavailable
  # @!attribute [r] disk_caches
  #   @return [Integer, nil] guest disk cache size, in bytes. `nil` if ballooning is unavailable
  # @!attribute [r] rss
  #   @return [Integer] resident set size of the QEMU process on the host, in bytes — pages
  #     actually touched so far (QEMU allocates on demand, so this grows over the VM's life)
  # @!attribute [r] last_updated
  #   @return [Integer] epoch seconds when these values were fetched from the VM; if it
  #     stops advancing, VM refresh needs to be set up
  class MemStat < Data.define(:actual, :unused, :available, :usable, :disk_caches, :rss, :last_updated)
    # @return [MemoryUsage | nil] the guest memory stats or nil if unavailable.
    def guest_mem
      guest_data_available? ? MemoryUsage.new(available, usable) : nil
    end

    # @return [MemoryUsage] the host memory stat: `rss` of `actual`
    def host_mem = MemoryUsage.new(actual, actual - rss)

    # Returns true if the guest memory data is available. false if the VM doesn't report guest data,
    # probably because ballooning service isn't running, or virt guest tools aren't installed,
    # or the VM lacks the ballooning device.
    # @return [Boolean] true if the guest data is available
    def guest_data_available? = !available.nil? && !usable.nil? && !disk_caches.nil? && !unused.nil?

    # @return [String] human-readable summary; includes guest detail only when available
    def to_s
      result = "actual #{format_byte_size(actual)}"
      result += "(rss=#{format_byte_size(rss)})" unless rss.nil?
      if guest_data_available?
        result += "; guest: #{guest_mem} (unused=#{format_byte_size(unused)}, disk_caches=#{format_byte_size(disk_caches)})"
      end
      result
    end
  end
end
