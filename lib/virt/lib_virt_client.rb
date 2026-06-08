# frozen_string_literal: true

# Accessess libvirt via libvirt Ruby bindings. Way faster than [VirtCmd], and recommended.
# Install the bindings via `sudo apt install ruby-libvirt`.
#
# - RubyDoc: https://ruby.libvirt.org/api/index.html
# - Library homepage: https://ruby.libvirt.org/
#
# WARNING: Currently doesn't retrieve all memory stats, making it unsuitable for ballooning!
class LibVirtClient
  # @param name [String] gem to probe for
  # @return [Boolean] whether the named library can be required
  def self.library_available?(name)
    # Gem::Specification.find_by_name(gem_name) is cleaner, but doesn't work with apt-installed gems
    require name
    true
  rescue LoadError
    false
  end

  # @return [Boolean] whether the libvirt Ruby bindings gem is installed.
  GEM_AVAILABLE = library_available? 'libvirt'

  def initialize
    raise 'libvirt gem not available' unless GEM_AVAILABLE

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
    GEM_AVAILABLE
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
