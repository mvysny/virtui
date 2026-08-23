# frozen_string_literal: true

module Virt
  # A libvirt client that drives libvirt by shelling out to the `virsh` CLI (parsing its
  # text output). Install it with `sudo apt install libvirt-clients`.
  #
  # Not the ruby-libvirt binding — see DECISIONS.md D-virsh-cli.
  #
  # Every call to the outside world goes through a *runner* ({VirshSpawn} by default,
  # {VirshSession} for a persistent child), so this class holds nothing but parsing:
  #
  #   Virsh.new                                   # a process per command
  #   Virsh.new(runner: VirshSession.new)         # reads served from one long-lived child
  #   Virsh.new(runner: session, guest_agent: GuestAgent.new(runner: session))  # + swap levels
  #
  # Stateless apart from the runner; the read methods accept fixture parameters for
  # testing, which bypass the runner entirely.
  class Virsh
    # Maps the numeric `state.state` from `virsh domstats` to our state symbols; anything
    # else becomes `:other`.
    @@states = { 3 => :paused, 1 => :running, 5 => :shut_off }

    # @param runner [VirshSpawn, VirshSession] transport for every `virsh` invocation
    # @param guest_agent [GuestAgent, nil] the channel {#guest_swap} reads through, or `nil`
    #   for a backend that reports no swap levels at all
    def initialize(runner: VirshSpawn.new, guest_agent: nil)
      @runner = runner
      @guest_agent = guest_agent
    end

    # @return [VirshSpawn, VirshSession] the transport in use
    attr_reader :runner

    # The guest's own view of how full its swap device is.
    #
    # Kept out of {#domain_data} deliberately: that is one `domstats` call for the whole
    # fleet, while this is three agent calls *per VM* that fail per VM — see DECISIONS.md
    # D-guest-swap-level.
    #
    # @param domain_name [String] VM name; must be running
    # @return [ResourceUsage, nil] swap used out of the guest's swap total, or `nil` if there
    #   is no guest agent to ask (see {GuestAgent#swap} for the other reasons)
    def guest_swap(domain_name) = @guest_agent&.swap(domain_name)

    # Drops what the guest agent remembers about a VM's failed samples.
    #
    # @param domain_name [String] VM name, typically one that has just stopped running (see
    #   {GuestAgent#forget})
    # @return [void]
    def forget_guest(domain_name) = @guest_agent&.forget(domain_name)

    # Reads runtime stats for every VM via `virsh domstats`.
    #
    # @param domstats_file [String, nil] canned `virsh domstats` output for testing; runs
    #   the real command when `nil`
    # @param sampled_at [Integer, nil] millis since epoch to stamp the snapshots with;
    #   defaults to now. For testing
    # @return [Hash{String => DomainData}] maps VM name to its {DomainData}
    # @raise [RuntimeError] if `virsh domstats` fails
    def domain_data(domstats_file = nil, sampled_at = nil)
      domstats_file ||= @runner.query('domstats')
      sampled_at ||= DomainData.millis_now

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

          mem_stat = MemoryStat.new(mem_current, mem_unused, mem_available, mem_usable,
                                    values['balloon.disk_caches']&.to_i&.KiB,
                                    values['balloon.swap_in']&.to_i&.KiB,
                                    values['balloon.swap_out']&.to_i&.KiB,
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
    # @raise [RuntimeError] if `virsh nodeinfo` fails
    def hostinfo(virsh_nodeinfo = nil)
      virsh_nodeinfo ||= @runner.query('nodeinfo')
      values = virsh_nodeinfo.lines.filter { |it| !it.strip.empty? }.to_h { |it| it.split ':' }
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

      @runner.sync('setmem', domain_name, (new_actual / 1024).to_s)
      $log.info "#{domain_name}: set new actual memory to #{format_byte_size(new_actual)}"
    end

    # Enables periodic guest memory-stat collection on a running VM, so the guest-reported
    # balloon fields (`balloon.usable`/`available`/`unused`/`last-update`) stay fresh.
    #
    # libvirt's collection period defaults to 0 (disabled): until something sets it, those
    # fields freeze at boot-time values while host-sourced fields (`cpu.time`,
    # `balloon.rss`) keep updating — making RAM look stuck even as CPU moves. The period is
    # a live property of the running QEMU process, so it must be re-armed after every full
    # power-off; {Cache#update} does that. Why virtui arms it at all instead of asking the
    # user to configure the domain XML: DECISIONS.md D-mem-stats-self-armed.
    #
    # Runs asynchronously (failures logged, not raised): a VM without a
    # balloon device rejects this command, and that must not abort the refresh loop.
    #
    # @param domain_name [String] VM name
    # @param period_seconds [Integer] how often the guest refreshes its stats, in seconds
    # @return [Thread] the thread running the command
    def set_mem_stats_period(domain_name, period_seconds)
      @runner.async('dommemstat', domain_name, '--period', period_seconds.to_s, '--live')
    end

    # Starts a stopped VM. Behaviour is undefined for an already-started or paused VM.
    #
    # Asynchronous: `virsh start` takes ~800ms, and the UI thread must not wait on it.
    #
    # @param domain_name [String] VM name
    # @return [Thread] the thread running the command
    def start(domain_name)
      @runner.async('start', domain_name)
    end

    # Asks a VM to shut down gracefully.
    #
    # Asynchronous: `virsh shutdown` takes 0.5–5s, and the UI thread must not wait on it.
    #
    # @param domain_name [String] VM name
    # @return [Thread] the thread running the command
    def shutdown(domain_name)
      @runner.async('shutdown', domain_name)
    end

    # Asks the VM to reboot itself gracefully.
    #
    # @param domain_name [String] VM name
    # @raise [RuntimeError] if `virsh reboot` fails
    def reboot(domain_name)
      @runner.sync('reboot', domain_name)
    end

    # Resets the VM forcefully (a hard power-cycle).
    #
    # @param domain_name [String] VM name
    # @raise [RuntimeError] if `virsh reset` fails
    def reset(domain_name)
      @runner.sync('reset', domain_name)
    end

    # Forces the VM off (a hard power-off, via `virsh destroy`).
    #
    # @param domain_name [String] VM name
    # @raise [RuntimeError] if `virsh destroy` fails
    def force_off(domain_name)
      @runner.sync('destroy', domain_name)
    end
  end
end
