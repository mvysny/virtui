require_relative 'sysinfo'

# A virt domain (=VM).
#
# - `id` {Integer} - temporary ID, only available when running. May be `nil`
# - `name` {String} - displayable name
# - `state` {Symbol} - one of `:running`, `:shut_off`, `:paused`, `:other`
class Domain < Data.define(:id, :name, :state)
  def running?
    state == :running
  end
  def to_s
    "#{id || '-'}: #{name}: #{state}"
  end
end

# VM memory stats
#
# - `actual` {Integer} The actual memory size in bytes available with ballooning enabled.
# - `available` {Integer} Memory in bytes available for the guest OS. Inside the Linux kernel this is named `MemTotal`. This is
#   the maximum allowed memory, which is slightly less than the currently configured
#   memory size, as the Linux kernel and BIOS need some space for themselves.
#   `nil` if ballooning is unavailable.
# - `unused` {Integer}  Inside the Linux kernel this actually is named `MemFree`.
#   That memory is available for immediate use as it is currently neither used by processes
#   or the kernel for caching. So it is really unused (and is just eating energy and provides no benefit).
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
  
  # Returns true if the guest memory data is available. false if the VM doesn't report guest data,
  # probably because ballooning service isn't running, or virt guest tools aren't installed,
  # or the VM lacks the ballooning device.
  # @return [Boolean] true if the guest data is available
  def guest_data_available?
    available != nil && usable != nil && disk_caches != nil && unused != nil
  end
  
  def to_s
    result = "#{format_byte_size(actual)}(rss=#{format_byte_size(rss)})"
    result += "; guest: #{guest_mem} (unused=#{format_byte_size(unused)}, disk_caches=#{format_byte_size(disk_caches)})" if guest_data_available?
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
# - `persistent` {Boolean}
# - `security_model` {String} e.g. `apparmor`
class DomainInfo < Data.define(:os_type, :state, :cpus, :max_memory, :used_memory, :persistent, :security_model)
  def running?
    state == :running
  end
  
  def configured_memory
    MemoryUsage.new(max_memory, max_memory - used_memory)
  end
  
  def to_s
    "#{os_type}: #{state}; CPUs: #{cpus}; configured mem: #{configured_memory}; persistent=#{persistent}; security_model=#{security_model}"
  end
end

# A virt client, controls virt via the `virsh` program.
# Install the `virsh` program via `sudo apt install libvirt-clients`
class VirtCmd
  # Returns all domains, in all states.
  # @param virsh_list [String | nil] Output of `virsh list --all`, for testing only
  # @return [Array<Domain>] domains
  def domains(virsh_list = nil)
    virsh_list = virsh_list || `virsh list --all`
    list = virsh_list.lines.drop(2)  # Drop the table header and underline
    list.map!(&:strip).filter! { |it| !it.empty? }
    list.map! do |line|
      m = /(\d+|-)\s+(.+)\s+(running|shut off|paused|other)/.match line
      raise "Unparsable line: #{line}" if m.nil?
      id = m[1] == '-' ? nil : m[1].to_i
      state = m[3].gsub(' ', '_').to_sym
      Domain.new(id, m[2].strip, state)
    end
    list
  end
  
  # Runtime memory stats. Only available when the VM is running.
  #
  # @param domain [Domain] domain
  # @param virsh_dommemstat [String | nil] output of `virsh dommemstat`, for testing only
  # @return [MemStat]
  def memstat(domain, virsh_dommemstat = nil)
    virsh_dommemstat = virsh_dommemstat || `virsh dommemstat #{domain.id}`
    values = virsh_dommemstat.lines.filter { |it| !it.strip.empty? } .map { |it| it.strip.split } .to_h
    MemStat.new(actual: values['actual'].to_i * 1024, unused: values['unused']&.to_i&.*(1024),
      available: values['available']&.to_i&.*(1024), usable: values["usable"]&.to_i&.*(1024),
      disk_caches: values["disk_caches"]&.to_i&.*(1024), rss: values["rss"].to_i * 1024)
  end
  
  # Domain (VM) information. Also available when VM is shut off.
  #
  # @param domain [Domain] domain
  # @param virsh_dominfo [String | nil] output of `virsh dominfo`, for testing only
  # @return [DomainInfo]
  def dominfo(domain, virsh_dominfo = nil)
    did = domain.id || domain.name
    virsh_dominfo = virsh_dominfo || `virsh dominfo "#{did}"`
    values = virsh_dominfo.lines.filter { |it| !it.strip.empty? } .map { |it| it.split ':' } .to_h
    values = values.transform_values(&:strip)
    state = values['State'].gsub(' ', '_').to_sym
    DomainInfo.new(os_type: values['OS Type'], state: state, cpus: values['CPU(s)'].to_i,
      max_memory: values['Max memory'].to_i * 1024,
      used_memory: values['Used memory'].to_i * 1024,
      persistent: values['Persistent'] == 'yes',
      security_model: values['Security model'])
  end
  
  # @return [Boolean] whether this virt client is available
  def self.available?
    !(`which virsh`.strip.empty?)
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
class LibVirt
  def initialize
    raise 'libvirt gem not available' unless LIBVIRT_GEM_AVAILABLE
    @conn = Libvirt::open("qemu:///system")
  end
  
  def close
    @conn.close
  end
  
  # Returns all domains, in all states.
  # @return [Array<Domain>] domains
  def domains()
    running_vm_ids = @conn.list_domains
    stopped_vm_names = @conn.list_defined_domains
    states = {Libvirt::Domain::PAUSED => :paused, Libvirt::Domain::RUNNING => :running, 5 => :shut_off}
    running = running_vm_ids.map do |id|
      d = @conn.lookup_domain_by_id(id)    # Libvirt::Domain
      state = states[d.state[0]] || :other
      Domain.new(id, d.name, state)
    end
    stopped = stopped_vm_names.map do |name|
      d = @conn.lookup_domain_by_name(name)    # Libvirt::Domain
      state = states[d.state[0]] || :other
      Domain.new(nil, name, state)
    end
    running + stopped
  end
  
  # @return [Boolean] whether this virt client is available
  def self.available?
    LIBVIRT_GEM_AVAILABLE
  end
end

