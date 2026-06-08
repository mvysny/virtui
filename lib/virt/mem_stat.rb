# frozen_string_literal: true

# VM memory stats
#
# - `actual` {Integer} The actually configured memory size in bytes, given to the VM by host.
# - `unused` {Integer}  Inside the Linux kernel this actually is named `MemFree`.
#   That memory is available for immediate use as it is currently neither used by processes
#   or the kernel for caching. So it is really unused (and is just eating energy and provides no benefit).
#   `nil` if ballooning is unavailable.
# - `available` {Integer} Memory in bytes available for the guest OS. Inside the Linux kernel this is
#   named `MemTotal`. This is
#   the maximum allowed memory, which is slightly less than the currently configured
#   memory size `actual`, as the Linux kernel and BIOS need some space for themselves.
#   `nil` if ballooning is unavailable.
# - `usable` {Integer} Inside the Linux kernel this is named `MemAvailable`. This consists
#   of the free space plus the space, which can be easily reclaimed. This for example includes
#   read caches, which contain data read from IO devices, from which the data can be read
#   again if the need arises in the future.
#   `nil` if ballooning is unavailable.
# - `disk_caches` {Integer} disk cache size in bytes.
#   `nil` if ballooning is unavailable.
# - `rss` {Integer} The resident set size in bytes, which is the number of pages currently
#   "actively" used by the QEMU process on the host system. QEMU by default
#   only allocates the pages on demand when they are first accessed. A newly started VM actually
#   uses only very few pages, but the number of pages increases with each new memory allocation.
# - `last_updated` {Integer} seconds since epoch when the values have been retrieved from the VM.
#   If this number stays unchanged, you need to setup VM refresh.
#
# More info here: https://pmhahn.github.io/virtio-balloon
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

  def to_s
    result = "actual #{format_byte_size(actual)}"
    result += "(rss=#{format_byte_size(rss)})" unless rss.nil?
    if guest_data_available?
      result += "; guest: #{guest_mem} (unused=#{format_byte_size(unused)}, disk_caches=#{format_byte_size(disk_caches)})"
    end
    result
  end
end
