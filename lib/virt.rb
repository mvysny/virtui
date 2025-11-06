# frozen_string_literal: true

require_relative 'sysinfo'
require 'date'

# A virt domain (=VM) identifier.
#
# - `id` {Integer} - temporary ID, only available when running. May be `nil`
# - `name` {String} - displayable name
class DomainId < Data.define(:id, :name)
  def to_s
    running? ? "#{id}: #{name}" : name
  end

  # @return [Boolean]
  def running?
    !id.nil?
  end
end

# A virt domain (=VM).
#
# - `id` {DomainId} - temporary ID, only available when running. May be `nil`
# - `state` {Symbol} - one of `:running`, `:shut_off`, `:paused`, `:other`
class Domain < Data.define(:id, :state)
  # @return [String] displayable domain name
  def name
    id.name
  end

  # @return [Boolean]
  def running?
    state == :running
  end

  def to_s
    "#{id}: #{state}"
  end
end

# VM memory stats
#
# - `actual` {Integer} The actual memory size in bytes available with ballooning enabled.
# - `unused` {Integer}  Inside the Linux kernel this actually is named `MemFree`.
#   That memory is available for immediate use as it is currently neither used by processes
#   or the kernel for caching. So it is really unused (and is just eating energy and provides no benefit).
#   `nil` if ballooning is unavailable.
# - `available` {Integer} Memory in bytes available for the guest OS. Inside the Linux kernel this is named `MemTotal`. This is
#   the maximum allowed memory, which is slightly less than the currently configured
#   memory size, as the Linux kernel and BIOS need some space for themselves.
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
#
# More info here: https://pmhahn.github.io/virtio-balloon/
class MemStat < Data.define(:actual, :unused, :available, :usable, :disk_caches, :rss)
  # @return [MemoryUsage | nil] the guest memory stats or nil if unavailable.
  def guest_mem
    guest_data_available? ? MemoryUsage.new(available, usable) : nil
  end

  # @return [MemoryUsage] the host memory stat: `rss` of `actual`
  def host_mem
    MemoryUsage.new(actual, actual - rss)
  end

  # Returns true if the guest memory data is available. false if the VM doesn't report guest data,
  # probably because ballooning service isn't running, or virt guest tools aren't installed,
  # or the VM lacks the ballooning device.
  # @return [Boolean] true if the guest data is available
  def guest_data_available?
    !available.nil? && !usable.nil? && !disk_caches.nil? && !unused.nil?
  end

  def to_s
    result = "#{format_byte_size(actual)}"
    result += "(rss=#{format_byte_size(rss)})" unless rss.nil?
    if guest_data_available?
      result += "; guest: #{guest_mem} (unused=#{format_byte_size(unused)}, disk_caches=#{format_byte_size(disk_caches)})"
    end
    result
  end
end

# VM information
#
# - `os_type` {String} e.g. `hvm`
# - `state` {Symbol} one of `:running`, `:shut_off`, `:paused`, `:other`
# - `cpus` {Integer} number of CPUs allocated
# - `max_memory` {Integer} maximum memory allocated to a VM, in bytes. {MemStat.actual} can never be more than this.
# - `used_memory` {Integer} Current value of {MemStat.actual}, in bytes.
class DomainInfo < Data.define(:os_type, :state, :cpus, :max_memory, :used_memory)
  def running?
    state == :running
  end

  def configured_memory
    MemoryUsage.new(max_memory, max_memory - used_memory)
  end

  def to_s
    "#{os_type}: #{state}; CPUs: #{cpus}; configured mem: #{configured_memory}"
  end
end

# A VM information
#
# - `info` {DomainInfo} info
# - `sampled_at` {Integer} milliseconds since the epoch
# - `cpu_time` {Integer} milliseconds of used CPU time (user + system)
# - `mem_stat` {MemStat} memory stats, nil if not running.
class DomainData < Data.define(:info, :sampled_at, :cpu_time, :mem_stat)
  def state
    info.state
  end
  def running?
    state == :running
  end
  def balloon?
    mem_stat.guest_data_available?
  end
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
    "#{info}, #{mem_stat}"
  end
end

# Info about host CPU:
#
# - `model` {String} e.g. "x86_64"
# - `sockets`, `cores_per_socket`, `threads_per_core`: {Integer}
class CpuInfo < Data.define(:model, :sockets, :cores_per_socket, :threads_per_core)
  def cpus
    sockets * cores_per_socket * threads_per_core
  end

  def to_s
    "#{model}: #{sockets}/#{cores_per_socket}/#{threads_per_core}"
  end
end

# A virt client, controls virt via the `virsh` program.
# Install the `virsh` program via `sudo apt install libvirt-clients`
class VirtCmd
  def initialize
    @states = { 3 => :paused, 1 => :running, 5 => :shut_off }
  end

  # Returns all available domain data.
  # @param domstats_file [String] outcome of `virsh domstats`, for testing only.
  # @param sampled_at [Integer] millis since epoch, for testing only.
  # @return [Hash<String => DomainData>] domain data
  def domain_data(domstats_file = nil, sampled_at = nil)
    domstats_file ||= `virsh domstats`
    sampled_at ||= DateTime.now.strftime('%Q').to_i

    # grab data
    data = {}
    current_domain = ''
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
      state = @states[values['state.state'].to_i] || :other
      mem_current = values['balloon.current'].to_i * 1024
      domain_info = DomainInfo.new(nil, state, values['vcpu.maximum'].to_i,
                                   values['balloon.maximum'].to_i * 1024, mem_current)
      cpu_time = values['cpu.time'].to_i / 1_000_000
      mem_unused = values['balloon.unused']&.to_i&.*(1024)
      mem_usable = values['balloon.usable']&.to_i&.*(1024)
      mem_available = values['balloon.available']&.to_i&.*(1024)
      mem_stat = MemStat.new(mem_current, mem_unused, mem_available, mem_usable,
        values['balloon.disk_caches']&.to_i&.*(1024),
        values['balloon.rss'].to_i * 1024
      )
      ddata = DomainData.new(domain_info, sampled_at, cpu_time, mem_stat)
      result[domain] = ddata
    end
    result
  end

  # Returns all domains, in all states.
  # @param virsh_list [String | nil] Output of `virsh list --all`, for testing only
  # @return [Array<Domain>] domains
  def domains(virsh_list = nil)
    virsh_list ||= `virsh list --all`
    list = virsh_list.lines.drop(2) # Drop the table header and underline
    list.map!(&:strip).filter! { |it| !it.empty? }
    list.map! do |line|
      m = /(\d+|-)\s+(.+)\s+(running|shut off|paused|other)/.match line
      raise "Unparsable line: #{line}" if m.nil?

      id = m[1] == '-' ? nil : m[1].to_i
      state = m[3].gsub(' ', '_').to_sym
      Domain.new(DomainId.new(id, m[2].strip), state)
    end
    list
  end

  # Runtime memory stats. Only available when the VM is running.
  #
  # @param domain [DomainId] domain
  # @param virsh_dommemstat [String | nil] output of `virsh dommemstat`, for testing only
  # @return [MemStat]
  def memstat(domain, virsh_dommemstat = nil)
    virsh_dommemstat ||= `virsh dommemstat #{domain.id}`
    values = virsh_dommemstat.lines.filter { |it| !it.strip.empty? }.map { |it| it.strip.split }.to_h
    MemStat.new(actual: values['actual'].to_i * 1024, unused: values['unused']&.to_i&.*(1024),
                available: values['available']&.to_i&.*(1024), usable: values['usable']&.to_i&.*(1024),
                disk_caches: values['disk_caches']&.to_i&.*(1024), rss: values['rss'].to_i * 1024)
  end

  # Domain (VM) information. Also available when VM is shut off.
  #
  # @param domain [DomainId] domain
  # @param virsh_dominfo [String | nil] output of `virsh dominfo`, for testing only
  # @return [DomainInfo]
  def dominfo(domain, virsh_dominfo = nil)
    did = domain.id || domain.name
    virsh_dominfo ||= `virsh dominfo "#{did}"`
    values = virsh_dominfo.lines.filter { |it| !it.strip.empty? }.map { |it| it.split ':' }.to_h
    values = values.transform_values(&:strip)
    state = values['State'].gsub(' ', '_').to_sym
    DomainInfo.new(os_type: values['OS Type'], state: state, cpus: values['CPU(s)'].to_i,
                   max_memory: values['Max memory'].to_i * 1024,
                   used_memory: values['Used memory'].to_i * 1024)
  end

  # @return [Boolean] whether this virt client is available
  def self.available?
    !`which virsh`.strip.empty?
  end

  # @return [CpuInfo]
  def hostinfo(virsh_nodeinfo = nil)
    virsh_nodeinfo ||= `virsh nodeinfo`
    values = virsh_nodeinfo.lines.filter { |it| !it.strip.empty? }.map { |it| it.split ':' }.to_h
    values = values.transform_values(&:strip)
    CpuInfo.new(values['CPU model'], values['CPU socket(s)'].to_i, values['Core(s) per socket'].to_i,
                values['Thread(s) per core'].to_i)
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
    MemStat.new(actual: values[Libvirt::Domain::MemoryStats::ACTUAL_BALLOON].to_i * 1024,
                unused: values[Libvirt::Domain::MemoryStats::UNUSED]&.to_i&.*(1024),
                available: values[Libvirt::Domain::MemoryStats::AVAILABLE]&.to_i&.*(1024),
                usable: nil, # values[Libvirt::Domain::MemoryStats::USABLE]&.to_i&.*(1024),
                disk_caches: nil, # values[Libvirt::Domain::MemoryStats::DISK_CACHES]&.to_i&.*(1024),
                rss: values[Libvirt::Domain::MemoryStats::RSS]&.to_i&.*(1024))
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
    DomainInfo.new(os_type: nil, state: @states[info.state] || :other, cpus: info.nr_virt_cpu,
                   max_memory: info.max_mem * 1024,
                   used_memory: info.memory * 1024)
  end
end
