# frozen_string_literal: true

module System
  # - `usage` {MemoryUsage} the disk usage
  # - `vm_usage` {Integer} bytes used by VM qcow2 files
  # - `qcow2_files` {Array<String>} qcow2 files stored on this disk
  #
  # Immutable, thread-safe.
  class DiskUsage < Data.define(:usage, :vm_usage, :qcow2_files)
    def to_s = "#{usage} (#{format_byte_size(vm_usage)} VMs)"
    # @param physical [Integer] qcow2 file size
    # @param qcow2_file [String] path to the qcow2 file
    # @return [DiskUsage]
    def add(physical, qcow2_file) = DiskUsage.new(usage, vm_usage + physical, qcow2_files + [qcow2_file])
  end
end
