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
  #   @return [Symbol] one of {FAMILIES}' keys, or `:unknown` for both an id no vendor in
  #     {VENDORS} matches and a definition that declared nothing
  # @!attribute [r] osinfo_id
  #   @return [String, nil] what was declared, e.g. `http://microsoft.com/win/11`; `nil` if
  #     nothing was. Kept even when unrecognised, so a log line can name it
  class GuestOS < Data.define(:family, :osinfo_id)
    # Every osinfo id vendor, grouped by the family virtui sorts it into.
    #
    # Each entry is an osinfo id's vendor host *plus first path segment* — not the host alone,
    # because `microsoft.com` ships both `win/*` and `msdos/*`, so a host-only map would need a
    # second structure for exactly those vendors. Every key pays one redundant-looking segment
    # (`ubuntu.com/ubuntu`) to keep {VENDORS} one flat lookup.
    #
    # **This is the complete set**, extracted from osinfo-db's own `<os id>` and `<family>`
    # elements (`gitlab.com/libosinfo/osinfo-db`, `main`, 2026-08-23: 980 OS entries, 76
    # distinct keys). virt-manager and `virt-install --os-variant` can only write an id that
    # exists there, so an id reaching `:unknown` means the definition declared something
    # outside osinfo-db — or that osinfo-db grew a vendor since. {Virsh#guest_os} logs such an
    # id at `debug`, which is how this table is meant to grow.
    #
    # Three entries are hand-corrections to what osinfo-db says, and stay that way on purpose:
    #
    # - `elementary.io/elementary` carries no `<family>` element at all — an osinfo-db
    #   omission; elementary OS is Ubuntu-derived, so `:linux`.
    # - `guix.gnu.org/guix-system` is the one key with *two* families in osinfo-db (`linux`
    #   and `hurd`, for the Hurd port). Keyed `:linux` for the overwhelmingly common variant;
    #   the cost of guessing wrong is that a Hurd guest is asked for a `/proc/meminfo` it may
    #   not have, which fails the same way an agentless guest does.
    # - `libosinfo.org/unknown` is a real declared id meaning *unknown*, so it is deliberately
    #   **absent** here and falls through to {UNKNOWN} like an undeclared domain.
    FAMILIES = {
      linux: %w[
        almalinux.org/almalinux almalinux.org/almalinux-kitten alpinelinux.org/alpinelinux
        altlinux.org/alt altlinux.org/altlinux android-x86.org/android-x86 archlinux.org/archlinux
        asianux.com/asianux cclinux.org/circle centos.org/centos centos.org/centos-stream
        cirros-cloud.net/cirros clearlinux.org/clearlinux debian.org/debian
        elementary.io/elementary endlessos.com/eos euro-linux.com/eurolinux
        fedoraproject.org/coreos fedoraproject.org/fedora fedoraproject.org/silverblue
        freenix.net/freenix gentoo.org/gentoo getsol.us/solus gnome.org/gnome
        gnome.org/gnome-continuous guix.gnu.org/guix-system hyperbola.info/hyperbola
        libosinfo.org/linux mageia.org/mageia mandriva.com/mandrake mandriva.com/mandriva
        mandriva.com/mbs mandriva.com/mes manjaro.org/manjaro miraclelinux.com/miraclelinux
        nixos.org/nixos openanolis.cn/anolis opensuse.org/opensuse oracle.com/oel oracle.com/ol
        pureos.net/pureos redhat.com/rhel redhat.com/rhel-atomic redhat.com/rhl
        rockylinux.org/rocky scientificlinux.org/scientificlinux slackware.com/slackware
        slackware.com/slackwarearm suse.com/caasp suse.com/sle suse.com/sled suse.com/slem
        suse.com/sles system76.com/popos trisquel.info/trisquel ubuntu.com/ubuntu
        univention.de/ucs voidlinux.org/voidlinux
      ],
      # osinfo-db splits these into `winnt`, `win9x` and `win16`; virtui needs none of that.
      windows: %w[microsoft.com/win microsoft.com/winnt],
      freebsd: %w[freebsd.org/freebsd],
      openbsd: %w[openbsd.org/openbsd],
      netbsd: %w[netbsd.org/netbsd],
      dragonflybsd: %w[dragonflybsd.org/dragonflybsd],
      # osinfo-db calls this family `darwin`; `:macos` is what the marker means to a reader.
      macos: %w[apple.com/macosx],
      solaris: %w[oracle.com/solaris sun.com/opensolaris sun.com/solaris],
      illumos: %w[omnios.org/bloody openindiana.org/hipster smartos.org/smartos],
      haiku: %w[haiku-os.org/haiku],
      dos: %w[freedos.org/freedos microsoft.com/msdos],
      netware: %w[novell.com/netware]
    }.freeze

    # {FAMILIES} inverted: the flat `vendor-host/first-segment => family` lookup
    # {.from_osinfo_id} actually reads. Grouped in the source because 12 families read better
    # than 75 near-identical `=> :linux` rows; flat here because the lookup is per-domain.
    VENDORS = FAMILIES.flat_map { |family, keys| keys.map { |key| [key, family] } }.to_h.freeze

    # Splits an osinfo id into the `host/first-segment` key {VENDORS} holds. A regex rather
    # than `URI.parse` because this runs on whatever a definition happens to contain, and a
    # malformed id must reach {UNKNOWN} instead of raising.
    OSINFO_KEY = %r{\Ahttps?://([^/]+)/([^/?#]+)}i

    # What a definition that declared nothing classifies to.
    UNKNOWN = GuestOS.new(:unknown, nil)

    # Classifies a declared osinfo id.
    #
    #   GuestOS.from_osinfo_id('http://ubuntu.com/ubuntu/25.10')   # => linux
    #   GuestOS.from_osinfo_id('http://haiku-os.org/haiku/r1')     # => haiku
    #   GuestOS.from_osinfo_id('http://example.com/os/1')          # => unknown, id kept
    #
    # @param osinfo_id [String, nil] the id from the domain's libosinfo metadata
    # @return [GuestOS] `family` is `:unknown` for an id outside {VENDORS}, with `osinfo_id`
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
    # `!linux?`, so **`:unknown` skips the read** along with every other family: a domain
    # declaring no OS reports no swap level, where before this class existed it would have
    # been asked and answered. Deliberate, and the reason a `windows? || freebsd?` gate —
    # which lets `:unknown` fall through, and which every family added to {FAMILIES} would
    # have to be threaded into — was not taken; the trade is invisible on a fleet built by
    # virt-manager, where nothing is `:unknown`. See DECISIONS.md D-guest-os-from-xml.
    #
    # @return [Boolean] `true` for every family except `:linux`
    def no_proc_meminfo? = !linux?

    # @return [String] e.g. `"windows (http://microsoft.com/win/11)"`, or just the family
    #   when nothing was declared
    def to_s = osinfo_id.nil? ? family.to_s : "#{family} (#{osinfo_id})"
  end
end
