# frozen_string_literal: true

module Virt
  # A disk image libvirt manages as a storage-pool volume — which is what lets virtui resize
  # it: libvirtd runs `qemu-img` as root on an image the user cannot even read.
  #
  #   vol = virsh.volume('/var/lib/libvirt/images/vt-ubuntu.qcow2')
  #   vol.pool             # => "default"
  #   vol.capacity         # => 15032385536, what the guest sees
  #   virsh.resize_volume(vol.path, vol.capacity + 10.GiB)
  #
  # @!attribute [r] path
  #   @return [String] the image file
  # @!attribute [r] pool
  #   @return [String] the storage pool it belongs to
  # @!attribute [r] capacity
  #   @return [Integer] bytes, the size the guest sees
  # @!attribute [r] allocation
  #   @return [Integer] bytes the image takes on the host; a sparse qcow2 takes far less
  # @!attribute [r] pool_available
  #   @return [Integer] bytes still free in the pool
  class Volume < Data.define(:path, :pool, :capacity, :allocation, :pool_available)
  end
end
