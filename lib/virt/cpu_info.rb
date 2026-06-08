# frozen_string_literal: true

module Virt
  # Static topology of the host CPU, as reported by libvirt.
  #
  # Immutable and thread-safe (a frozen {Data} value object).
  #
  # @!attribute [r] model
  #   @return [String] CPU model/architecture, e.g. `"x86_64"`
  # @!attribute [r] sockets
  #   @return [Integer] number of physical CPU sockets
  # @!attribute [r] cores_per_socket
  #   @return [Integer] physical cores per socket
  # @!attribute [r] threads_per_core
  #   @return [Integer] hardware threads (e.g. hyperthreads) per core
  class CpuInfo < Data.define(:model, :sockets, :cores_per_socket, :threads_per_core)
    # @return [Integer] total logical CPUs (`sockets * cores_per_socket * threads_per_core`)
    def cpus = sockets * cores_per_socket * threads_per_core

    # @return [String] `model: sockets/cores_per_socket/threads_per_core`, e.g. `"x86_64: 1/4/2"`
    def to_s
      "#{model}: #{sockets}/#{cores_per_socket}/#{threads_per_core}"
    end
  end
end
