# frozen_string_literal: true

module Virt
  # VM information that is static and doesn't generally change unless the VM is shut down.
  #
  # - `name` {String} the VM name, both for display purposes, and also the VM identifier
  # - `cpus` {Integer} number of CPUs allocated
  # - `max_memory` {Integer} maximum memory allocated to a VM, in bytes. {MemStat.actual} can never be more than this.
  class DomainInfo < Data.define(:name, :cpus, :max_memory)
    def to_s
      "#{name}: CPUs: #{cpus}, RAM: #{format_byte_size(max_memory)}"
    end
  end
end
