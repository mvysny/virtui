# frozen_string_literal: true

module Virt
  # A libvirt client that drives libvirt by shelling out to the `virsh` CLI (parsing its
  # text output). Install it with `sudo apt install libvirt-clients`.
  #
  # Stateless; the read methods accept fixture parameters for testing.
  class Virsh
    # Maps the numeric `state.state` from `virsh domstats` to our state symbols; anything
    # else becomes `:other`.
    @@states = { 3 => :paused, 1 => :running, 5 => :shut_off }

    # Reads runtime stats for every VM via `virsh domstats`.
    #
    # @param domstats_file [String, nil] canned `virsh domstats` output for testing; runs
    #   the real command when `nil`
    # @param sampled_at [Integer, nil] millis since epoch to stamp the snapshots with;
    #   defaults to now. For testing
    # @return [Hash{String => DomainData}] maps VM name to its {DomainData}
    # @raise [RuntimeError] if `virsh domstats` fails (via {Run.sync})
    def domain_data(domstats_file = nil, sampled_at = nil)
      domstats_file ||= Run.sync('virsh domstats')
      sampled_at ||= DomainData.millis_now

      # grab data. Hash{String => current_values}
      data = {}
      current_domain = ''
      # Hash{String => String}
      current_values = {}
      domstats_file.lines.each do |line|
        line = line.strip
        next if line.empty?

        if line.start_with? 'Domain:'
          current_domain = line[9..-2]
          current_values = {}
          data[current_domain] = current_values
          next
        end
        key, value = line.split '='
        current_values[key.strip] = value.strip
      end

      # parse the data
      result = {}
      data.each do |domain, values|
        state = @@states[values['state.state'].to_i] || :other
        mem_current = values['balloon.current'].to_i.KiB
        domain_info = DomainInfo.new(domain, values['vcpu.maximum'].to_i,
                                     values['balloon.maximum'].to_i.KiB)
        cpu_time = values['cpu.time'].to_i / 1_000_000
        mem_stat = nil
        if values.include?('balloon.rss') && values.include?('balloon.last-update')
          mem_unused = values['balloon.unused']&.to_i&.KiB
          mem_usable = values['balloon.usable']&.to_i&.KiB
          mem_available = values['balloon.available']&.to_i&.KiB
          last_updated = values['balloon.last-update'].to_i

          mem_stat = MemStat.new(mem_current, mem_unused, mem_available, mem_usable,
                                 values['balloon.disk_caches']&.to_i&.KiB,
                                 values['balloon.rss'].to_i.KiB, last_updated)
        end

        disk_stat = parse_disk_data(values)
        ddata = DomainData.new(domain_info, state, sampled_at, cpu_time, mem_stat, disk_stat)
        result[domain] = ddata
      end
      result
    end

    # Extracts per-disk stats from the flattened `block.N.*` keys of one VM's domstats.
    # Disks missing any of name/allocation/capacity/physical are skipped.
    #
    # @param data [Hash{String => String}] one VM's domstats, e.g. `block.0.capacity=1231`
    # @return [Array<DiskStat>] parsed stats, one per fully-described disk
    private def parse_disk_data(data)
      count = data['block.count'].to_i
      result = []
      (0...count).each do |block_index|
        name = data["block.#{block_index}.name"]
        allocation = data["block.#{block_index}.allocation"]&.to_i
        capacity = data["block.#{block_index}.capacity"]&.to_i
        physical = data["block.#{block_index}.physical"]&.to_i
        path = data["block.#{block_index}.path"]
        unless allocation.nil? || capacity.nil? || physical.nil? || name.nil?
          result << DiskStat.new(name, allocation, capacity,
                                 physical, path)
        end
      end
      result
    end

    # @return [Boolean] whether `virsh` is installed and on the `PATH`
    def self.available?
      # Don't use Run.sync() since which returns with error code 1 if
      # it can't find virsh.
      !`which virsh`.strip.empty?
    end

    # Reads the host CPU topology via `virsh nodeinfo`.
    #
    # @param virsh_nodeinfo [String, nil] canned `virsh nodeinfo` output for testing; runs
    #   the real command when `nil`
    # @return [CpuInfo] the host CPU topology
    # @raise [RuntimeError] if `virsh nodeinfo` fails (via {Run.sync})
    def hostinfo(virsh_nodeinfo = nil)
      virsh_nodeinfo ||= Run.sync('virsh nodeinfo')
      values = virsh_nodeinfo.lines.filter { |it| !it.strip.empty? }.map { |it| it.split ':' }.to_h
      values = values.transform_values(&:strip)
      CpuInfo.new(values['CPU model'], values['CPU socket(s)'].to_i, values['Core(s) per socket'].to_i,
                  values['Thread(s) per core'].to_i)
    end

    # Sets the current (`actual`) memory size of a running VM via `virsh setmem`.
    #
    # @param domain_name [String] VM name
    # @param new_actual [Integer] new memory size, in bytes
    # @raise [RuntimeError] if `new_actual` is below 256 MiB, or if `virsh setmem` fails
    def set_actual(domain_name, new_actual)
      raise "#{new_actual} must be at least 256m" if new_actual < 256.MiB

      Run.sync("virsh setmem '#{domain_name}' '#{new_actual / 1024}'")
      $log.info "#{domain_name}: set new actual memory to #{format_byte_size(new_actual)}"
    end

    # Starts a stopped VM. Behaviour is undefined for an already-started or paused VM.
    #
    # Runs asynchronously since `virsh start` can take ~800ms, during which the UI would
    # otherwise appear frozen; failures are logged, not raised.
    #
    # @param domain_name [String] VM name
    # @return [Thread] the thread running the command (see {Run.async})
    def start(domain_name)
      Run.async("virsh start '#{domain_name}'")
    end

    # Asks a VM to shut down gracefully.
    #
    # Runs asynchronously since `virsh shutdown` can take 0.5–5s, during which the UI would
    # otherwise appear frozen; failures are logged, not raised.
    #
    # @param domain_name [String] VM name
    # @return [Thread] the thread running the command (see {Run.async})
    def shutdown(domain_name)
      Run.async("virsh shutdown '#{domain_name}'")
    end

    # Asks the VM to reboot itself gracefully.
    #
    # @param domain_name [String] VM name
    # @raise [RuntimeError] if `virsh reboot` fails (via {Run.sync})
    def reboot(domain_name)
      Run.sync("virsh reboot '#{domain_name}'")
    end

    # Resets the VM forcefully (a hard power-cycle).
    #
    # @param domain_name [String] VM name
    # @raise [RuntimeError] if `virsh reset` fails (via {Run.sync})
    def reset(domain_name)
      Run.sync("virsh reset '#{domain_name}'")
    end

    # Forces the VM off (a hard power-off, via `virsh destroy`).
    #
    # @param domain_name [String] VM name
    # @raise [RuntimeError] if `virsh destroy` fails (via {Run.sync})
    def force_off(domain_name)
      Run.sync("virsh destroy '#{domain_name}'")
    end
  end
end
