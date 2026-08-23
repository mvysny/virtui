# frozen_string_literal: true

module Virt
  # Which OS family a VM's libvirt definition *declares*, classified from its libosinfo id:
  #
  #   os = GuestOS.from_osinfo_id('http://microsoft.com/win/11')
  #   os.family                                  # => :windows
  #   os.no_proc_meminfo?                        # => true — don't ask this guest for a swap level
  #   GuestOS.from_osinfo_id(nil)                # => UNKNOWN
  #
  # A declaration, not an observation: available with the VM shut off and needing nothing
  # installed in the guest, but it says what the *creator* told libvirt. So it can be stale
  # (a definition made `--os-variant win10`, then used to install Linux) and it is absent
  # from a hand-written definition. Why this rather than asking `qemu-guest-agent` what is
  # actually booted: DECISIONS.md D-guest-os-from-xml.
  #
  # @!attribute [r] family
  #   @return [Symbol] `:windows`, `:linux`, `:freebsd`, or `:unknown` — the last for both an
  #     unrecognised vendor and a definition that declared nothing
  # @!attribute [r] osinfo_id
  #   @return [String, nil] what was declared, e.g. `http://microsoft.com/win/11`; `nil` if
  #     nothing was. Kept even when unrecognised, so a log line can name it
  class GuestOS < Data.define(:family, :osinfo_id)
    # Maps an osinfo id's vendor host *plus first path segment* to a family.
    #
    # Not the host alone: `microsoft.com` ships both `win/*` and `msdos/*`, so a host-only
    # map needs a second structure for exactly those vendors. Every entry pays one
    # redundant-looking segment (`ubuntu.com/ubuntu`) to keep one flat lookup.
    #
    # `microsoft.com/win` and `ubuntu.com/ubuntu` are measured; the rest follow osinfo-db's
    # `vendor-host/short-id` scheme. {Virsh#guest_os} logs an id that matches nothing, which
    # is how this table is meant to grow.
    VENDORS = {
      'microsoft.com/win' => :windows,
      'freebsd.org/freebsd' => :freebsd,
      'ubuntu.com/ubuntu' => :linux,
      'debian.org/debian' => :linux,
      'redhat.com/rhel' => :linux,
      'fedoraproject.org/fedora' => :linux,
      'centos.org/centos' => :linux,
      'almalinux.org/almalinux' => :linux,
      'rockylinux.org/rocky' => :linux,
      'opensuse.org/opensuse' => :linux,
      'suse.com/sles' => :linux,
      'archlinux.org/archlinux' => :linux,
      'linuxmint.com/linuxmint' => :linux,
      'alpinelinux.org/alpine' => :linux,
      'gentoo.org/gentoo' => :linux,
      'kali.org/kali' => :linux
    }.freeze

    # Splits an osinfo id into the `host/first-segment` key {VENDORS} holds. A regex rather
    # than `URI.parse` because this runs on whatever a definition happens to contain, and a
    # malformed id must reach {UNKNOWN} instead of raising.
    OSINFO_KEY = %r{\Ahttps?://([^/]+)/([^/?#]+)}i

    # What a definition that declared nothing classifies to.
    UNKNOWN = GuestOS.new(:unknown, nil)

    # Classifies a declared osinfo id.
    #
    #   GuestOS.from_osinfo_id('http://ubuntu.com/ubuntu/25.10')   # => linux
    #   GuestOS.from_osinfo_id('http://haiku-os.org/haiku/r1')     # => unknown, id kept
    #
    # @param osinfo_id [String, nil] the id from the domain's libosinfo metadata
    # @return [GuestOS] `family` is `:unknown` for an unrecognised id, with `osinfo_id`
    #   preserved so the caller can log what it saw
    def self.from_osinfo_id(osinfo_id)
      id = osinfo_id&.strip
      return UNKNOWN if id.nil? || id.empty?

      host, segment = id.match(OSINFO_KEY)&.captures
      new(VENDORS.fetch("#{host}/#{segment}".downcase, :unknown), id)
    end

    # @return [Boolean] whether this guest is declared Windows
    def windows? = family == :windows

    # @return [Boolean] whether this guest is declared Linux
    def linux? = family == :linux

    # @return [Boolean] whether this guest is declared FreeBSD
    def freebsd? = family == :freebsd

    # Whether asking this guest for `/proc/meminfo` is pointless — the gate on the
    # guest-agent swap read in {Cache#update}.
    #
    # `!linux?`, so **`:unknown` skips the read** along with Windows and FreeBSD: a domain
    # declaring no OS reports no swap level, where before this class existed it would have
    # been asked and answered. Deliberate, and the reason a `windows? || freebsd?` gate —
    # which lets `:unknown` fall through — was not taken; the trade is invisible on a fleet
    # built by virt-manager, where nothing is `:unknown`. See DECISIONS.md
    # D-guest-os-from-xml.
    #
    # @return [Boolean] `true` for every family except `:linux`
    def no_proc_meminfo? = !linux?

    # @return [String] e.g. `"windows (http://microsoft.com/win/11)"`, or just the family
    #   when nothing was declared
    def to_s = osinfo_id.nil? ? family.to_s : "#{family} (#{osinfo_id})"
  end
end
