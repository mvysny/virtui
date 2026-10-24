# frozen_string_literal: true

module Virt
  # A libvirt client that drives libvirt by shelling out to the `virsh` CLI (parsing its
  # text output). Install it with `sudo apt install libvirt-clients`.
  #
  # Not the ruby-libvirt binding — see design/decisions.md D_virsh_cli.
  #
  # Every call to the outside world goes through a *runner* ({VirshSession} for a
  # persistent child, {VirshSpawn} for a process per command), so this class holds nothing
  # but parsing:
  #
  #   # what the app builds:
  #   Virsh.new(runner: session, guest_sampler: GuestSampler.new(agent: GuestAgent.new(runner: session)))
  #   Virsh.new(runner: VirshSpawn.new)           # a process per command
  #   Virsh.new                                   # ditto, and the parser-spec default
  #
  # The constructor default stays {VirshSpawn} even though the app runs a session: a
  # default that spawns a persistent child would leave one behind for every `Virsh.new`
  # that is never closed, which is most of the specs. `bin/virtui` picks the transport.
  #
  # Stateless apart from the runner; the read methods accept fixture parameters for
  # testing, which bypass the runner entirely.
  class Virsh
    # Maps the numeric `state.state` from `virsh domstats` to our state symbols; anything
    # else becomes `:other`.
    @@states = { 3 => :paused, 1 => :running, 5 => :shut_off }

    # The metadata namespace virt-manager and `virt-install --os-variant` declare the guest
    # OS under (see {#guest_os}).
    LIBOSINFO_URI = 'http://libosinfo.org/xmlns/libvirt/domain/1.0'

    # Pulls the declared id out of a `virsh metadata` reply. Deliberately prefix-blind:
    # `virsh` prints the element *without* the `libosinfo:` prefix the stored definition
    # carries, so matching `<libosinfo:os` finds nothing.
    OSINFO_ID = /<os\s+id="([^"]*)"/

    # @param runner [VirshSpawn, VirshSession] transport for every `virsh` invocation
    # @param guest_sampler [GuestSampler, nil] the channel {#guest_swap} and {#guest_fs_usage}
    #   read through, or `nil` for a backend that reports neither
    def initialize(runner: VirshSpawn.new, guest_sampler: nil)
      @runner = runner
      @guest_sampler = guest_sampler
      # Spawned, for the reason {#domain_config} is: {#guest_storage} runs behind a progress popup.
      @spawned_agent = GuestAgent.new(runner: VirshSpawn.new)
      @root_grow = GuestRootGrow.new(runner: VirshSpawn.new, agent: @spawned_agent)
    end

    # @return [VirshSpawn, VirshSession] the transport in use
    attr_reader :runner

    # The guest's own view of how full its swap device is.
    #
    # Kept out of {#domain_data} deliberately: that is one `domstats` call for the whole
    # fleet, while this is three agent calls *per VM* that fail per VM — see design/decisions.md
    # D_guest_swap_level.
    #
    # @param domain_name [String] VM name; must be running
    # @return [ResourceUsage, nil] swap used out of the guest's swap total, or `nil` if there
    #   is no sampler to ask (see {GuestSampler#swap} for the other reasons)
    def guest_swap(domain_name) = @guest_sampler&.swap(domain_name)

    # The guest's own view of how full each of its disks is, from its mounted filesystems.
    #
    #   virsh.guest_fs_usage('vt-ubuntu')   # => {"vda" => #<ResourceUsage 3.4G/15G (23%)>}
    #
    # Out of {#domain_data} for the reason {#guest_swap} is, and cheaper than it: one
    # `guest-ping` and one `guestinfo`, which {Cache} asks only every
    # {Cache::GUEST_FS_SECONDS}.
    #
    # @param domain_name [String] VM name; must be running
    # @return [Hash{String => ResourceUsage}, nil] keyed by host target, or `nil` if there is
    #   no sampler to ask (see {GuestSampler#fs_usage} for the other reasons)
    def guest_fs_usage(domain_name) = @guest_sampler&.fs_usage(domain_name)

    # The OS family the VM's definition declares, from its libosinfo metadata.
    #
    #   virsh.guest_os('win11')   # => windows (http://microsoft.com/win/11)
    #   virsh.guest_os('BASE')    # => unknown — nothing declared, or an unknown vendor
    #
    # Works on a *shut-off* domain, and needs no guest agent — which is the whole reason
    # virtui reads the declaration rather than asking the running guest (design/decisions.md
    # D_guest_os_from_xml). Cheap but not free: one `virsh` round-trip per call, so callers
    # memoize it per domain ({Cache#update} does).
    #
    # Never raises. A domain that vanished mid-read, a `virsh` that refuses, metadata that
    # is simply absent — all of it is a guest we cannot classify, which is
    # {GuestOS::UNKNOWN}, not an error.
    #
    # @param domain_name [String] VM name
    # @param metadata [String, nil] canned `virsh metadata` output for testing; runs the
    #   real command when `nil`
    # @return [GuestOS] the declared family; {GuestOS::UNKNOWN} if the domain declares
    #   nothing, names a vendor {GuestOS::VENDORS} does not know, or could not be read
    def guest_os(domain_name, metadata = nil)
      metadata ||= @runner.query('metadata', domain_name, '--uri', LIBOSINFO_URI)
      GuestOS.from_osinfo_id(metadata[OSINFO_ID, 1]).tap do |os|
        # An unrecognised vendor is the one outcome worth a line: it is how VENDORS grows.
        $log.debug("#{domain_name}: unknown guest OS #{os.osinfo_id}") if os.family == :unknown && !os.osinfo_id.nil?
      end
    rescue StandardError => e
      $log.debug("#{domain_name}: no declared guest OS: #{e.message.lines.first&.strip}")
      GuestOS::UNKNOWN
    end

    # The VM's address as the host knows it: the first row of `virsh domifaddr --source
    # lease`, or of `--source arp` when libvirt's DHCP handed out no lease.
    #
    #   virsh.ip_address('Flow')   # => "192.168.122.137"
    #
    # IPv4 in practice, prefix dropped (`arp` reports every address as `/0`). `lease` covers
    # guests on libvirt's own networks, `arp` bridged ones in the host's neighbour table — which
    # can still hold an address the guest has moved off (design/research.md R_virsh_domifaddr).
    #
    # Not `--source agent`: an agent-less guest fails that read rather than answering an empty
    # table, making the address a second read allowed to go quiet.
    #
    # @param domain_name [String] VM name; must be running
    # @param lease [String, nil] canned `domifaddr --source lease` output for testing; runs
    #   the real command when `nil`
    # @param arp [String, nil] canned `domifaddr --source arp` output, likewise
    # @return [String, nil] the address, or `nil` if neither table has a row
    # @raise [RuntimeError] if `virsh domifaddr` fails, or prints a row it does not document
    def ip_address(domain_name, lease = nil, arp = nil)
      lease ||= @runner.query('domifaddr', domain_name, '--source', 'lease')
      first_address(lease) ||
        first_address(arp || @runner.query('domifaddr', domain_name, '--source', 'arp'))
    end

    # The domain's definition, from `virsh dumpxml`: live for a running domain, persistent
    # for a shut-off one.
    #
    #   virsh.domain_config('vt-ubuntu').firmware   # => :uefi
    #
    # A read, yet spawned through {VirshSession#sync}: on the session it would queue behind the
    # tick's guest-agent calls while the user waits on a progress popup.
    #
    # Never pass `--security-info`: without it libvirt leaves the VNC/SPICE `passwd=` out.
    #
    # @param domain_name [String] VM name
    # @param xml [String, nil] canned `dumpxml` output for testing; runs the real command
    #   when `nil`
    # @param inactive [Boolean] the definition the next power-on brings (`--inactive`), rather
    #   than the one running now
    # @return [DomainConfig]
    # @raise [RuntimeError] if `virsh dumpxml` fails, e.g. for an unknown domain
    # @raise [ArgumentError] if what it printed is not a domain definition
    def domain_config(domain_name, xml = nil, inactive: false)
      DomainConfig.from_xml(xml || @runner.sync('dumpxml', domain_name, *('--inactive' if inactive)))
    end

    # The running guest's own view of its disks: partitions, and what is mounted where.
    #
    #   virsh.guest_storage('vt-ubuntu').disk('vda').partitions.last.name   # => "vda1"
    #
    # `virsh guestinfo` plus a few guest file reads (see {GuestStorage}), all spawned, like
    # {#domain_config}: ~0.25 s for a disk of four partitions.
    #
    # @param domain_name [String] VM name; must be running, with an agent
    # @param guestinfo [String, nil] canned `guestinfo --filesystem --disk` output for testing;
    #   runs the real command when `nil`
    # @param guest_files [Hash{String => String}, nil] canned guest files by path for testing;
    #   read through the agent when `nil`
    # @return [GuestStorage]
    # @raise [GuestAgent::Unavailable] if the guest was never going to answer
    # @raise [RuntimeError] if `virsh` or the agent fails otherwise, or replies with
    #   something it does not document
    def guest_storage(domain_name, guestinfo = nil, guest_files = nil)
      guestinfo ||= begin
        @runner.sync('guestinfo', domain_name, '--filesystem', '--disk')
      rescue RuntimeError => e
        raise GuestAgent::Unavailable, e.message if GuestAgent.expected_failure?(e)

        raise
      end
      GuestStorage.parse(guestinfo) do |path|
        guest_files ? guest_files.fetch(path) : @spawned_agent.read_file(domain_name, path)
      end
    end

    # Whether the VM is set up the way virtui and the host's disk need it (see {Health}).
    #
    #   virsh.health('vt-ubuntu').findings.reject { _1.severity == :ok }
    #
    # Both definitions, then, on a running VM whose agent is connected, {#guest_storage} and
    # the guest files {Health.assess} asks for; all spawned, ~0.5 s on vt-ubuntu. A guest that
    # cannot answer turns into a skipped finding rather than a failed check.
    #
    # @param domain_name [String] VM name
    # @return [Health]
    # @raise [RuntimeError] if `virsh` fails otherwise, or replies with something it does not
    #   document
    def health(domain_name)
      live = domain_config(domain_name)
      inactive = domain_config(domain_name, inactive: true)
      guest = guest_or_reason(domain_name) if Health.ask_guest?(live)
      Health.assess(live, inactive, guest, read_file: ->(path) { @spawned_agent.read_file(domain_name, path) },
                                           file_exist: ->(path) { @spawned_agent.exist?(domain_name, path) })
    end

    # @param domain_name [String] a running VM with a connected agent
    # @return [GuestStorage, String] the guest's disks, or virsh's reason it could not tell
    private def guest_or_reason(domain_name)
      guest_storage(domain_name)
    rescue GuestAgent::Unavailable => e
      # virsh's own `error: …` line, not the `Command '…' failed` wrapper around it.
      e.message[/error: ([^\n]*)/, 1] || e.message.lines.first.strip
    end

    # The storage-pool volume behind a disk image, found by its path.
    #
    #   virsh.volume('/var/lib/libvirt/images/vt-ubuntu.qcow2').pool   # => "default"
    #
    # Three spawned reads, like {#domain_config}. Works though the user cannot read the pool's
    # directory: libvirtd looks the path up.
    #
    # @param path [String] the image, as `<disk><source file=>` names it
    # @param vol_pool [String, nil] canned `vol-pool` output for testing; runs the real
    #   command when `nil`
    # @param vol_info [String, nil] canned `vol-info --bytes` output, likewise
    # @param pool_info [String, nil] canned `pool-info --bytes` output, likewise
    # @return [Volume, nil] `nil` if the image is in no storage pool
    # @raise [RuntimeError] if `virsh` fails otherwise, or prints a field it does not document
    def volume(path, vol_pool = nil, vol_info = nil, pool_info = nil)
      pool = (vol_pool || pool_of(path) || return).strip
      vol = fields(vol_info || @runner.sync('vol-info', '--bytes', path))
      pool_fields = fields(pool_info || @runner.sync('pool-info', '--bytes', pool))
      Volume.new(path: path, pool: pool, capacity: bytes(vol, 'Capacity'), allocation: bytes(vol, 'Allocation'),
                 pool_available: bytes(pool_fields, 'Available'))
    end

    # Grows a stopped VM's disk image to a new capacity, via `virsh vol-resize`.
    #
    # Grows only: libvirt refuses a capacity below the current one unless given `--shrink`,
    # which this never passes. A running VM's image is refused too — QEMU holds its write
    # lock, so `qemu-img` cannot open it — and that covers a VM started after the caller
    # checked its state.
    #
    # @param path [String] the image (see {#volume})
    # @param capacity [Integer] the new size the guest will see, in bytes
    # @return [void]
    # @raise [RuntimeError] if `virsh vol-resize` fails
    def resize_volume(path, capacity)
      @runner.sync('vol-resize', path, capacity.to_s)
      $log.info "#{path}: resized to #{format_byte_size(capacity)}"
    end

    # How a running guest's root filesystem would grow into the free space after it, checked
    # against the guest's layout and its agent (see {GuestRootGrow}).
    #
    #   plan = virsh.root_grow_plan('vt-ubuntu')
    #   plan.growth   # => 1073741824, after a 1 GiB image resize
    #
    # @param domain_name [String] VM name; must be running, with an agent
    # @return [GuestRootGrow::Plan]
    # @raise [GuestRootGrow::Refused] if the layout is not the simple one, or there is no room
    # @raise [GuestAgent::Unavailable] if the guest was never going to answer
    def root_grow_plan(domain_name)
      GuestRootGrow.plan(guest_storage(domain_name)).tap { @root_grow.check(domain_name, _1) }
    end

    # Grows the guest's root partition and filesystem as the plan says, through `guest-exec`.
    #
    # @param domain_name [String] VM name
    # @param plan [GuestRootGrow::Plan] from {#root_grow_plan}
    # @return [void]
    # @raise [RuntimeError] if a command in the guest fails
    def grow_root(domain_name, plan) = @root_grow.grow(domain_name, plan)

    # Drops what the guest sampler remembers about a VM's failed samples.
    #
    # @param domain_name [String] VM name, typically one that has just stopped running (see
    #   {GuestSampler#forget})
    # @return [void]
    def forget_guest(domain_name) = @guest_sampler&.forget(domain_name)

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

        disk_stat = parse_disk_data(values, state)
        ddata = DomainData.new(domain_info, state, sampled_at, cpu_time, mem_stat, disk_stat)
        result[domain] = ddata
      end
      result
    end

    # Extracts per-disk stats from the flattened `block.N.*` keys of one VM's domstats.
    # Disks missing any of name/allocation/capacity/physical are skipped.
    #
    # The image's `du` is `allocation` on a shut-off domain but `physical` on a running one:
    # libvirt fills both fields from a different source per state, and a running domain's
    # `allocation` is QEMU's highest written offset — 0 right after a start
    # (design/research.md R_virsh_domstats_block).
    #
    # @param data [Hash{String => String}] one VM's domstats, e.g. `block.0.capacity=1231`
    # @param state [Symbol] the domain's state, as {#domain_data} maps it
    # @return [Array<DiskStat>] parsed stats, one per fully-described disk
    private def parse_disk_data(data, state)
      count = data['block.count'].to_i
      result = []
      (0...count).each do |block_index|
        name = data["block.#{block_index}.name"]
        allocation = data["block.#{block_index}.allocation"]&.to_i
        capacity = data["block.#{block_index}.capacity"]&.to_i
        physical = data["block.#{block_index}.physical"]&.to_i
        path = data["block.#{block_index}.path"]
        next if allocation.nil? || capacity.nil? || physical.nil? || name.nil?

        result << DiskStat.new(name, capacity, state == :shut_off ? allocation : physical, path)
      end
      result
    end

    # @param path [String] a disk image
    # @return [String, nil] `virsh vol-pool`'s answer, or `nil` if the image is in no pool
    # @raise [RuntimeError] if `virsh vol-pool` fails otherwise
    private def pool_of(path)
      @runner.sync('vol-pool', path)
    rescue RuntimeError => e
      raise unless e.message.include?('Storage volume not found')
    end

    # @param text [String] `Key: value` lines, as `vol-info` and `pool-info` print them
    # @return [Hash{String => String}]
    private def fields(text)
      text.lines.filter_map { |line| line.split(':', 2).map(&:strip) if line.include?(':') }.to_h
    end

    # @param fields [Hash{String => String}] from {#fields}
    # @param key [String] e.g. `Capacity`
    # @return [Integer] the field's bytes, from `--bytes` output (`15032385536 bytes`, or bare)
    # @raise [RuntimeError] if the field is missing or not a byte count
    private def bytes(fields, key)
      value = fields[key]
      raise "virsh printed no byte count for #{key}: #{fields.inspect}" unless value&.match?(/\A\d+( bytes)?\z/)

      value.to_i
    end

    # The Address column of a `virsh -q domifaddr` table's first row, without its `/prefix`.
    #
    # `-q` drops the header and the `---` rule, so every non-blank line is a row, and a header
    # that does reach here raises rather than hiding the address behind it.
    #
    # @param domifaddr [String] the table; empty means no rows
    # @return [String, nil] the address, or `nil` if the table has no rows
    # @raise [RuntimeError] if a row does not have the four documented columns
    private def first_address(domifaddr)
      row = domifaddr.lines.find { |it| !it.strip.empty? }
      return nil if row.nil?

      columns = row.split # Name, MAC address, Protocol, Address
      raise "unparseable domifaddr row: #{row.inspect}" unless columns.size == 4 && columns[3].include?('/')

      columns[3].split('/').first
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
    # user to configure the domain XML: design/decisions.md D_mem_stats_self_armed.
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
