# frozen_string_literal: true

module Virt
  # Memory statistics for a single VM, spanning both the host's view (`actual`, `rss`) and
  # the guest's own view (`available`, `usable`, `unused`, `disk_caches`, `swap_in`,
  # `swap_out`).
  #
  # The guest-reported fields require a working balloon device plus guest tools; they are
  # `nil` when that data isn't available (see {#guest_data_available?}). More info:
  # https://pmhahn.github.io/virtio-balloon
  #
  # Every field is a level except `swap_in`/`swap_out`, which are since-boot counters: diff
  # two samples to get anything usable out of them ({Cache::VMCache} does it).
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
  # @!attribute [r] swap_in
  #   @return [Integer, nil] bytes the guest has read *back* from swap since boot (its
  #     `pswpin` counter); `nil` if not reported. Rising means the guest is healing, so
  #     this is not a harm signal — see {Cache::VMCache#swap_out_rate}
  # @!attribute [r] swap_out
  #   @return [Integer, nil] bytes the guest has written *to* swap since boot (its
  #     `pswpout` counter); `nil` if not reported. I/O counted, not memory occupied — it
  #     never falls when swap slots are freed, so the swap *level* can't be derived from
  #     it; only its rate is meaningful (see {Cache::VMCache#swap_out_rate})
  # @!attribute [r] rss
  #   @return [Integer] resident set size of the QEMU process on the host, in bytes — pages
  #     actually touched so far (QEMU allocates on demand, so this grows over the VM's life)
  # @!attribute [r] last_updated
  #   @return [Integer] epoch seconds when these values were fetched from the VM; stops
  #     advancing unless collection is armed (see {Virsh#set_mem_stats_period})
  class MemoryStat < Data.define(:actual, :unused, :available, :usable, :disk_caches,
                                 :swap_in, :swap_out, :rss, :last_updated)
    # @return [ResourceUsage | nil] the guest memory stats or nil if unavailable.
    def guest_mem
      guest_data_available? ? ResourceUsage.new(available, usable) : nil
    end

    # @return [ResourceUsage] the host memory stat: `rss` of `actual`
    def host_mem = ResourceUsage.new(actual, actual - rss)

    # Returns true if the guest memory data is available. false if the VM doesn't report guest data,
    # probably because ballooning service isn't running, or virt guest tools aren't installed,
    # or the VM lacks the ballooning device.
    # @return [Boolean] true if the guest data is available
    def guest_data_available? = !available.nil? && !usable.nil? && !disk_caches.nil? && !unused.nil?

    # Deliberately separate from {#guest_data_available?}: the balloon driver reports these
    # two only if the guest kernel has `CONFIG_VM_EVENT_COUNTERS`, so folding them in there
    # would stop ballooning entirely on a guest that reports everything else.
    #
    # @return [Boolean] true if {#swap_in} and {#swap_out} are present
    def swap_data_available? = !swap_in.nil? && !swap_out.nil?

    # @return [String] human-readable summary; includes guest detail only when available
    def to_s
      result = "actual #{format_byte_size(actual)}"
      result += "(rss=#{format_byte_size(rss)})" unless rss.nil?
      if guest_data_available?
        result += "; guest: #{guest_mem} (unused=#{format_byte_size(unused)}, disk_caches=#{format_byte_size(disk_caches)})"
      end
      # Only once the guest has actually touched swap: this string is debug-logged for every
      # VM on every poll, and `swap out=0 in=0` is what the whole healthy fleet reports.
      if swap_data_available? && (swap_out + swap_in).positive?
        result += "; swap out=#{format_byte_size(swap_out)} in=#{format_byte_size(swap_in)}"
      end
      result
    end
  end
end
