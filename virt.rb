# A virt domain (=QEMU VM).
#
# - `id` {Integer | nil} - temporary ID, only available when running
# - `name` {String} - displayable name
# - `state` {Symbol} - one of `:running`, `:shut_off`, `:paused`, `:other`
class Domain < Data.define(:id, :name, :state)
  def running?
    state == :running
  end
end

# VM memory stats
#
# - `actual` {Integer} The actual memory size in KiB available with ballooning enabled.
# - `available` {Integer} Memory in KiB available for the guest OS. Inside the Linux kernel this is named MemTotal. This is
#   the maximum allowed memory, which is slightly less than the currently configured
#   memory size, as the Linux kernel and BIOS need some space for themselves.
#   `nil` if ballooning is unavailable.
# - `unused` {Integer}  Inside the Linux kernel this actually is named MemFree.
#   That memory is available for immediate use as it is currently neither used by processes
#   or the kernel for caching. So it is really unused (and is just eating energy and provides no benefit).
#   `nil` if ballooning is unavailable.
# - `usable` {Integer} Inside the Linux kernel this is named MemAvailable. This consists
#   of the free space plus the space, which can be easily reclaimed. This for example includes
#   read caches, which contain data read from IO devices, from which the data can be read
#   again if the need arises in the future.
#   `nil` if ballooning is unavailable.
# - `disk_caches` {Integer} disk cache size in KiB.
#   `nil` if ballooning is unavailable.
# - `rss` {Integer} The resident set size in KiB, which is the number of pages currently
#   "actively" used by the QEMU process on the host system. QEMU by default
#   only allocates the pages on demand when they are first accessed. A newly started VM actually
#   uses only very few pages, but the number of pages increases with each new memory allocation.
#
# More info here: https://pmhahn.github.io/virtio-balloon/
class MemStat < Data.define(:actual, :unused, :available, :usable, :disk_caches, :rss)
  def ballooning_available?
    !(available.nil? or unused.nil? or usable.nil? or disk_caches.nil?)
  end
end

# VM information
#
# - `os_type` {String} e.g. `hvm`
# - `state` {Symbol} one of `:running`, `:shut_off`, `:paused`, `:other`
# - `cpus` {Integer} number of CPUs allocated
# - `max_memory` {Integer} maximum memory allocated to a VM, in KiB. {MemStat:actual} can never be more than this.
# - `used_memory` {Integer} Current value of {MemStat:actual}
# - `persistent` {Boolean}
# - `security_model` {String} e.g. `apparmor`
class DomainInfo < Data.define(:os_type, :state, :cpus, :max_memory, :used_memory, :persistent, :security_model)
end

# A virt client, controls virt via the `virsh` program.
# Install program via `sudo apt install libvirt-clients`
class VirtCmd
  # Returns all domains, in all states.
  # @return [Array<Domain>] domains
  def domains
    list = `virsh list --all`.lines
    list = list.drop(2)  # Drop the table header and underline
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
  # @return [MemStat]
  def memstat(domain)
    lines = `virsh dommemstat #{domain.id}`.lines
    values = lines.filter { |it| !it.strip.empty? } .map { |it| it.strip.split } .to_h
    MemStat.new(actual: values['actual'].to_i, unused: values['unused']&.to_i,
      available: values['available']&.to_i, usable: values["usable"]&.to_i,
      disk_caches: values["disk_caches"]&.to_i, rss: values["rss"].to_i)
  end
  
  # Domain (VM) information. Also available when VM is shut off.
  #
  # @param domain [Domain] domain
  # @return [DomainInfo]
  def dominfo(domain)
    did = domain.id || domain.name
    lines = `virsh dominfo "#{did}"`.lines
    values = lines.filter { |it| !it.strip.empty? } .map { |it| it.split ':' } .to_h
    values = values.transform_values(&:strip)
    state = values['State'].gsub(' ', '_').to_sym
    DomainInfo.new(os_type: values['OS Type'], state: state, cpus: values['CPU(s)'].to_i,
      max_memory: values['Max memory'].chomp(' KiB').to_i,
      used_memory: values['Used memory'].chomp(' KiB').to_i,
      persistent: values['Persistent'] == 'yes',
      security_model: values['Security model'])
  end
end

