# frozen_string_literal: true

module Virt
  # Static VM configuration that doesn't change while the VM is running.
  #
  # Immutable and thread-safe (a frozen {Data} value object).
  #
  # @!attribute [r] name
  #   @return [String] the VM name — used both for display and as the VM identifier
  # @!attribute [r] cpus
  #   @return [Integer] number of virtual CPUs allocated
  # @!attribute [r] max_memory
  #   @return [Integer] maximum memory allocated to the VM, in bytes; {MemStat}'s `actual`
  #     can never exceed this
  class DomainInfo < Data.define(:name, :cpus, :max_memory)
    # @return [String] human-readable summary, e.g. `"web: CPUs: 4, RAM: 8.0G"`
    def to_s
      "#{name}: CPUs: #{cpus}, RAM: #{format_byte_size(max_memory)}"
    end
  end
end
