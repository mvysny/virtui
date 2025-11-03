# A virt domain (=QEMU VM).
#
# - `id` {Integer | nil} - temporary ID, only available when running
# - `name` {String} - displayable name
# - `state` {Symbol} - one of `:running`, `:shut_off`, `:paused`, `:other`
class Domain < Data.define(:id, :name, :state)
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
      status = m[3].gsub(' ', '_').to_sym
      Domain.new(id, m[2].strip, status)
    end
    list
  end
end

