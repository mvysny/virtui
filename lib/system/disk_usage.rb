# frozen_string_literal: true

module System
  # Disk usage for one filesystem, tracking how much of it VM disk images account for.
  #
  # {#add} returns a new instance rather than mutating, so per-VM contributions can be
  # accumulated.
  #
  # @!attribute [r] usage
  #   @return [ResourceUsage] overall used/total bytes of the filesystem
  # @!attribute [r] vm_usage
  #   @return [Integer] bytes consumed by VM qcow2 files on this disk
  # @!attribute [r] qcow2_files
  #   @return [Array<String>] paths of the qcow2 files counted in `vm_usage`
  class DiskUsage < Data.define(:usage, :vm_usage, :qcow2_files)
    # @return [String] human-readable summary, e.g. `"40G/100G (40%) (12G VMs)"`
    def to_s = "#{usage} (#{format_byte_size(vm_usage)} VMs)"

    # Returns a copy with one more qcow2 file folded into `vm_usage`/`qcow2_files`.
    #
    # @param physical [Integer] the qcow2 file's on-disk size, in bytes
    # @param qcow2_file [String] path to the qcow2 file
    # @return [DiskUsage] a new instance with the file accounted for
    def add(physical, qcow2_file) = DiskUsage.new(usage, vm_usage + physical, qcow2_files + [qcow2_file])
  end
end
