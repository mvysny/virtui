# frozen_string_literal: true

require_relative '../sysinfo'
require 'date'
require_relative '../byte_prefixes'

# VM memory stats
#
# - `actual` {Integer} The actually configured memory size in bytes, given to the VM by host.
# - `unused` {Integer}  Inside the Linux kernel this actually is named `MemFree`.
#   That memory is available for immediate use as it is currently neither used by processes
#   or the kernel for caching. So it is really unused (and is just eating energy and provides no benefit).
#   `nil` if ballooning is unavailable.
# - `available` {Integer} Memory in bytes available for the guest OS. Inside the Linux kernel this is
#   named `MemTotal`. This is
#   the maximum allowed memory, which is slightly less than the currently configured
#   memory size `actual`, as the Linux kernel and BIOS need some space for themselves.
#   `nil` if ballooning is unavailable.
# - `usable` {Integer} Inside the Linux kernel this is named `MemAvailable`. This consists
#   of the free space plus the space, which can be easily reclaimed. This for example includes
#   read caches, which contain data read from IO devices, from which the data can be read
#   again if the need arises in the future.
#   `nil` if ballooning is unavailable.
# - `disk_caches` {Integer} disk cache size in bytes.
#   `nil` if ballooning is unavailable.
# - `rss` {Integer} The resident set size in bytes, which is the number of pages currently
#   "actively" used by the QEMU process on the host system. QEMU by default
#   only allocates the pages on demand when they are first accessed. A newly started VM actually
#   uses only very few pages, but the number of pages increases with each new memory allocation.
# - `last_updated` {Integer} seconds since epoch when the values have been retrieved from the VM.
#   If this number stays unchanged, you need to setup VM refresh.
#
# More info here: https://pmhahn.github.io/virtio-balloon
class MemStat < Data.define(:actual, :unused, :available, :usable, :disk_caches, :rss, :last_updated)
  # @return [MemoryUsage | nil] the guest memory stats or nil if unavailable.
  def guest_mem
    guest_data_available? ? MemoryUsage.new(available, usable) : nil
  end

  # @return [MemoryUsage] the host memory stat: `rss` of `actual`
  def host_mem = MemoryUsage.new(actual, actual - rss)

  # Returns true if the guest memory data is available. false if the VM doesn't report guest data,
  # probably because ballooning service isn't running, or virt guest tools aren't installed,
  # or the VM lacks the ballooning device.
  # @return [Boolean] true if the guest data is available
  def guest_data_available? = !available.nil? && !usable.nil? && !disk_caches.nil? && !unused.nil?

  def to_s
    result = "actual #{format_byte_size(actual)}"
    result += "(rss=#{format_byte_size(rss)})" unless rss.nil?
    if guest_data_available?
      result += "; guest: #{guest_mem} (unused=#{format_byte_size(unused)}, disk_caches=#{format_byte_size(disk_caches)})"
    end
    result
  end
end

# A VM disk statistics.
#
# - `name` {String} the name of the device, e.g. `vda` or `sda`
# - `allocation` {Integer} how much of the guest’s disk has real data behind it
# - `capacity` {Integer} maximum size of the guest disk
# - `physical` {Integer} how big the qcow2 file actually is on host's filesystem right now
# - `path` {String} path to the qcow2 file
class DiskStat < Data.define(:name, :allocation, :capacity, :physical, :path)
  # @return [MemoryUsage] `allocation` used out of `capacity`
  def guest_usage = MemoryUsage.of(capacity, allocation)

  # @return [Integer] how much data is allocated vs the max capacity. 0..100
  def percent_used = guest_usage.percent_used

  # @return [Integer] how much bigger `physical` (host storage size) is, compared to `allocation` (guest-stored data).
  # 0 if `physical` == `allocation`; may be less than zero if `physical` is smaller (e.g. due compression).
  def overhead_percent
    (((physical.to_f / allocation) - 1) * 100).clamp(-100, 999).to_i
  end

  def to_s
    "#{name}: #{format_byte_size(allocation)}/#{format_byte_size(capacity)} (#{percent_used}%); physical #{format_byte_size(physical)} (#{overhead_percent}% overhead)"
  end
end

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

# A VM information
#
# - `info` {DomainInfo} info
# - `state` {Symbol} one of `:running`, `:shut_off`, `:paused`, `:other`
# - `sampled_at` {Integer} milliseconds since the epoch; you can use [:millis_now]
# - `cpu_time` {Integer} milliseconds of used CPU time (user + system) since last sampling.
#   Used to calculate CPU usage.
# - `mem_stat` {MemStat} memory stats, `nil` if not running.
# - `disk_stat` {Array<DiskStat>} disk stats, one per every connected disk
class DomainData < Data.define(:info, :state, :sampled_at, :cpu_time, :mem_stat, :disk_stat)
  def running? = state == :running

  # @return [Boolean] true if VM has proper ballooning support.
  def balloon? = mem_stat.guest_data_available?

  # @return [Integer] now, represented as milliseconds since the epoch.
  def self.millis_now = DateTime.now.strftime('%Q').to_i

  # Calculates average CPU usage in the time period between older data and this data.
  # @param older_data [DomainData | nil]
  # @return [Float] CPU usage in %; 100% means one CPU core was fully utilized. 0 or greater, may be greater than 100.
  def cpu_usage(older_data)
    return 0.0 if older_data.nil?
    raise 'data is not older' if older_data.sampled_at >= sampled_at

    time_passed_millis = sampled_at - older_data.sampled_at
    cpu_used_millis = cpu_time - older_data.cpu_time
    cpu_used_millis.to_f / time_passed_millis * 100
  end

  def to_s
    result = "#{info}; #{state}"
    result += "; #{mem_stat}" unless mem_stat.nil?
    result
  end
end

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

# A virt client, controls virt via the `virsh` program.
# Install the `virsh` program via `sudo apt install libvirt-clients`
class VirtCmd
  @@states = { 3 => :paused, 1 => :running, 5 => :shut_off }

  # Returns all available domain data.
  # @param domstats_file [String] outcome of `virsh domstats`, for testing only.
  # @param sampled_at [Integer] millis since epoch, for testing only.
  # @return [Hash<String => DomainData>] domain data, maps VM name to {DomainData}
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

  # @param data [Hash{String => String}] contains info e.g. `block.0.capacity=1231`
  # @return [Array<DiskStat>] parsed stats
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

  # @return [Boolean] whether this virt client is available
  def self.available?
    # Don't use Run.sync() since which returns with error code 1 if
    # it can't find virsh.
    !`which virsh`.strip.empty?
  end

  # @return [CpuInfo]
  def hostinfo(virsh_nodeinfo = nil)
    virsh_nodeinfo ||= Run.sync('virsh nodeinfo')
    values = virsh_nodeinfo.lines.filter { |it| !it.strip.empty? }.map { |it| it.split ':' }.to_h
    values = values.transform_values(&:strip)
    CpuInfo.new(values['CPU model'], values['CPU socket(s)'].to_i, values['Core(s) per socket'].to_i,
                values['Thread(s) per core'].to_i)
  end

  # Sets new memory size to a running VM.
  # @param domain_name [String]
  # @param new_actual [Integer]
  def set_actual(domain_name, new_actual)
    raise "#{new_actual} must be at least 256m" if new_actual < 256.MiB

    Run.sync("virsh setmem '#{domain_name}' '#{new_actual / 1024}'")
    $log.info "#{domain_name}: setting new actual memory to #{format_byte_size(new_actual)}"
  end

  # Starts a VM if it was stopped. Undefined for started or paused VM.
  # @param domain_name [String] VM name
  def start(domain_name)
    # Async - this can take ~800ms during which the UI appears frozen.
    Run.async("virsh start '#{domain_name}'")
  end

  # Shuts down a VM gracefully - basically asks the VM to shut off.
  # @param domain_name [String] VM name
  def shutdown(domain_name)
    # Async - this can take 0,5-5s during which the UI appears frozen.
    Run.async("virsh shutdown '#{domain_name}'")
  end

  # Asks the VM to reboot itself gracefully.
  # @param domain_name [String] VM name
  def reboot(domain_name)
    Run.sync("virsh reboot '#{domain_name}'")
  end

  # Resets the VM forcefully.
  # @param domain_name [String] VM name
  def reset(domain_name)
    Run.sync("virsh reset '#{domain_name}'")
  end
end

def library_available?(name)
  # Gem::Specification.find_by_name(gem_name) is cleaner, but doesn't work with apt-installed gems
  require name
  true
rescue LoadError
  false
end

LIBVIRT_GEM_AVAILABLE = library_available? 'libvirt'

# Accessess libvirt via libvirt Ruby bindings. Way faster than [VirtCmd], and recommended.
# Install the bindings via `sudo apt install ruby-libvirt`.
#
# - RubyDoc: https://ruby.libvirt.org/api/index.html
# - Library homepage: https://ruby.libvirt.org/
#
# WARNING: Currently doesn't retrieve all memory stats, making it unsuitable for ballooning!
class LibVirtClient
  def initialize
    raise 'libvirt gem not available' unless LIBVIRT_GEM_AVAILABLE

    @conn = Libvirt.open('qemu:///system')
    @states = { Libvirt::Domain::PAUSED => :paused, Libvirt::Domain::RUNNING => :running, 5 => :shut_off }
  end

  def close
    @conn.close
  end

  # TODO: need to implement domain_data function, but libvirt-ruby doesn't have it atm:
  # https://gitlab.com/libvirt/libvirt-ruby/-/issues/14

  # Returns all domains, in all states.
  # @return [Array<Domain>] domains
  def domains
    running_vm_ids = @conn.list_domains
    stopped_vm_names = @conn.list_defined_domains
    running = running_vm_ids.map do |id|
      d = @conn.lookup_domain_by_id(id) # Libvirt::Domain
      state = @states[d.state[0]] || :other
      Domain.new(DomainId.new(id, d.name), state)
    end
    stopped = stopped_vm_names.map do |name|
      d = @conn.lookup_domain_by_name(name) # Libvirt::Domain
      state = @states[d.state[0]] || :other
      Domain.new(nil, name, state)
    end
    running + stopped
  end

  # @return [Boolean] whether this virt client is available
  def self.available?
    LIBVIRT_GEM_AVAILABLE
  end

  # Runtime memory stats. Only available when the VM is running.
  #
  # WARNING: RETURNS INCOMPLETE DATA!!! Reported upstream: https://gitlab.com/libvirt/libvirt-ruby/-/issues/13
  #
  # @param domain [DomainId] domain
  # @return [MemStat]
  def memstat(domain)
    raise 'domain not running' if domain.id.nil?

    # Array<Libvirt::Domain::MemoryStats>
    mstats = @conn.lookup_domain_by_id(domain.id).memory_stats
    values = mstats.map { |it| [it.tag, it.instance_variable_get(:@val)] }.to_h
    MemStat.new(actual: values[Libvirt::Domain::MemoryStats::ACTUAL_BALLOON].to_i.KiB,
                unused: values[Libvirt::Domain::MemoryStats::UNUSED]&.to_i&.KiB,
                available: values[Libvirt::Domain::MemoryStats::AVAILABLE]&.to_i&.KiB,
                usable: nil, # values[Libvirt::Domain::MemoryStats::USABLE]&.to_i&.KiB,
                disk_caches: nil, # values[Libvirt::Domain::MemoryStats::DISK_CACHES]&.to_i&.KiB,
                rss: values[Libvirt::Domain::MemoryStats::RSS]&.to_i&.KiB)
  end

  # Domain (VM) information. Also available when VM is shut off.
  #
  # @param domain [DomainId] domain
  # @return [DomainInfo]
  def dominfo(domain)
    d = @conn.lookup_domain_by_id(domain.id) unless domain.id.nil?
    d ||= @conn.lookup_domain_by_name(domain.name)
    # Libvirt::Domain::Info
    info = d.info
    DomainInfo.new(state: @states[info.state] || :other, cpus: info.nr_virt_cpu,
                   max_memory: info.max_mem.KiB)
  end
end
