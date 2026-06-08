# frozen_string_literal: true

module Virt
  # Info about host CPU:
  #
  # - `model` {String} e.g. "x86_64"
  # - `sockets`, `cores_per_socket`, `threads_per_core`: {Integer}
  class CpuInfo < Data.define(:model, :sockets, :cores_per_socket, :threads_per_core)
    # @return [Integer] number of available threads
    def cpus = sockets * cores_per_socket * threads_per_core

    def to_s
      "#{model}: #{sockets}/#{cores_per_socket}/#{threads_per_core}"
    end
  end
end
