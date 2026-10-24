# frozen_string_literal: true

module Virt
  # Statistics for a single VM disk device, as libvirt sees it from the host: the disk's
  # nominal size and what its image costs the host. How full the guest has filled it is the
  # guest's business, read separately ({Cache::VMCache#guest_fs_usage}).
  #
  # @!attribute [r] name
  #   @return [String] the device name, e.g. `"vda"` or `"sda"`
  # @!attribute [r] capacity
  #   @return [Integer] nominal (maximum) size of the guest disk, in bytes
  # @!attribute [r] allocated
  #   @return [Integer] bytes the image's blocks occupy on the host, as `du` counts them —
  #     not the file's length, which a trimmed qcow2 overstates by its holes
  # @!attribute [r] path
  #   @return [String, nil] path to the image on the host
  class DiskStat < Data.define(:name, :capacity, :allocated, :path)
    # @return [String] human-readable summary
    def to_s = "#{name}: #{format_byte_size(allocated)} on host, of #{format_byte_size(capacity)}"
  end
end
