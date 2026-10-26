# frozen_string_literal: true

module Virt
  # Whether a VM is set up the way virtui and the host's disk need it — the judgement behind
  # `M` → Health check:
  #
  #   health = virsh.health('vt-bios')
  #   health.findings.map { [_1.severity, _1.subject] }
  #   # => [[:note, "balloon"], [:warning, "agent"], [:warning, "sda"], [:skipped, "guest"]]
  #   health.findings[2].text   # => "the host drops this disk's discards: space the guest frees stays taken"
  #   health.findings[2].fix    # => "virt-xml vt-bios --edit target=sda --disk discard=unmap, then power it off and on"
  #
  # The discard checks are the point: every bus tells the guest it may discard, and the
  # guest's `fstrim` reports the same either way, so only the host's `<driver discard=>` says
  # whether freed space ever leaves the image (design/research.md R_discard_reclaim). Those
  # and the balloon and agent checks need only the definition; the guest checks — the
  # device-mapper layers, periodic trim, unused disk space — need it running, with an agent.
  #
  # Each finding is words for the user, and a fix to type; a fix virtui can run itself also
  # names it as a {Finding#remedy}, which the window offers as a button. Nothing here changes
  # the VM.
  #
  # @!attribute [r] findings
  #   @return [Array<Finding>] in the order the window lists them
  class Health < Data.define(:findings)
    # One judgement on one thing.
    # @!attribute [r] severity
    #   @return [Symbol] `:ok`, `:note` (worth knowing, nothing broken), `:warning` (costs
    #     disk or memory until fixed), or `:skipped` (could not be checked)
    # @!attribute [r] subject
    #   @return [String] what it is about: `balloon`, `agent`, a disk's target, a mountpoint,
    #     `trim`, `guest`
    # @!attribute [r] text
    #   @return [String] the finding, e.g. `the host drops this disk's discards`
    # @!attribute [r] fix
    #   @return [String, nil] what to do about it: a command, or a Maintenance item
    # @!attribute [r] remedy
    #   @return [Symbol, nil] the fix as one virtui can run, for {UI::HealthWindow}'s button:
    #     `:grow_root` (Maintenance → Grow root filesystem) or `:free_page_reporting`
    #     ({Virsh#enable_free_page_reporting}); `nil` when the fix is the user's to make.
    #     A Symbol, not a block: see design/decisions.md D_health_check
    Finding = Data.define(:severity, :subject, :text, :fix, :remedy) do
      def initialize(severity:, subject:, text:, fix:, remedy: nil) = super
    end

    # `systemctl enable fstrim.timer` makes this symlink, and so do distro presets.
    TRIM_TIMER = '/etc/systemd/system/timers.target.wants/fstrim.timer'

    # Judges a VM from its definitions and, when running, its guest.
    #
    # @param live [DomainConfig] `dumpxml`; on a stopped VM, the persistent definition
    # @param inactive [DomainConfig] `dumpxml --inactive`: what the next power-on brings
    # @param guest [GuestStorage, String, nil] the guest's disks; a String says why the guest
    #   could not tell; `nil` when it was not asked — the VM is stopped, or has no connected
    #   agent, which `live` says
    # @param read_file [#call] guest path → its contents, `String`; may raise
    #   {GuestAgent::Unavailable}
    # @param file_exist [#call] guest path → `Boolean`
    # @return [Health]
    def self.assess(live, inactive, guest, read_file:, file_exist:)
      findings = [balloon(live, inactive), agent(live)] + live.disks.select { checked_disk?(_1) }.map do |disk|
        discard(live.name, disk, inactive.disks.find { _1.target == disk.target })
      end
      findings += case guest
                  when GuestStorage then GuestChecks.new(live, guest, read_file, file_exist).findings
                  else [unasked(live, guest)]
                  end
      new(findings: findings)
    end

    # Whether {.assess} wants the guest's disks: the VM runs, and its agent is connected.
    # @param live [DomainConfig]
    # @return [Boolean]
    def self.ask_guest?(live) = live.running && live.agent == :connected

    # @param live [DomainConfig]
    # @param reason [String, nil] why the guest could not tell, when it was asked
    # @return [Finding] the one finding standing in for the guest checks
    private_class_method def self.unasked(live, reason)
      text = if !live.running then 'not running: start the VM for the guest checks'
             elsif reason then "cannot answer: #{reason}"
             elsif live.agent.nil? then 'cannot answer: no guest agent channel'
             else 'cannot answer: qemu-guest-agent is not answering'
             end
      Finding.new(:skipped, 'guest', text, nil)
    end

    # A disk the guest can write a filesystem to: no CD-ROM, no read-only image, no SCSI
    # passthrough (`lun`), whose discards are the device's own business.
    # @param disk [DomainConfig::Disk]
    # @return [Boolean]
    private_class_method def self.checked_disk?(disk) = disk.device == 'disk' && !disk.readonly

    # @param config [DomainConfig]
    # @param next_boot [DomainConfig] the inactive definition
    # @return [Finding]
    private_class_method def self.balloon(config, next_boot)
      balloon = config.balloon
      if balloon.nil?
        Finding.new(:warning, 'balloon', 'no balloon device: virtui cannot resize this VM\'s memory',
                    "virt-xml #{config.name} --edit --memballoon model=virtio, then power it off and on")
      elsif balloon.free_page_reporting
        Finding.new(:ok, 'balloon', "#{balloon.model}, free page reporting", nil)
      elsif next_boot.balloon&.free_page_reporting
        Finding.new(:note, 'balloon', "#{balloon.model}, free page reporting is set, and takes effect once the VM " \
                                      'is powered off and on', nil)
      else
        Finding.new(:note, 'balloon', "#{balloon.model}, no free page reporting: memory the guest frees " \
                                      'stays with it until the balloon takes it',
                    "virt-xml #{config.name} --edit --memballoon freePageReporting=on, then power it off and on",
                    :free_page_reporting)
      end
    end

    # @param config [DomainConfig]
    # @return [Finding]
    private_class_method def self.agent(config)
      case config.agent
      when nil
        Finding.new(:warning, 'agent', 'no guest agent channel: no swap level, no guest checks',
                    "virt-xml #{config.name} --add-device --channel " \
                    "unix,target.type=virtio,target.name=#{DomainConfig::AGENT_CHANNEL}, " \
                    'then install qemu-guest-agent in the guest')
      when :disconnected
        Finding.new(:warning, 'agent', 'channel present, but qemu-guest-agent is not answering',
                    'install and start qemu-guest-agent in the guest')
      when :connected then Finding.new(:ok, 'agent', 'connected', nil)
      else Finding.new(:ok, 'agent', 'channel present', nil)
      end
    end

    # @param vm [String]
    # @param disk [DomainConfig::Disk] from the live definition
    # @param next_boot [DomainConfig::Disk, nil] the same target in the inactive one
    # @return [Finding]
    private_class_method def self.discard(vm, disk, next_boot)
      target = disk.target
      fix = "virt-xml #{vm} --edit target=#{target} --disk discard=unmap, then power it off and on"
      if disk.discard == 'unmap'
        Finding.new(:ok, target, 'discards reach the image', nil)
      elsif next_boot&.discard == 'unmap'
        Finding.new(:note, target, 'discard=unmap is set, and takes effect once the VM is powered off and on', nil)
      elsif disk.shareable
        Finding.new(:note, target, 'shared with other VMs, and the host drops its discards', fix)
      else
        Finding.new(:warning, target, 'the host drops this disk\'s discards: space the guest frees stays taken', fix)
      end
    end

    # The checks that read the guest, for one {.assess}.
    class GuestChecks
      # @param live [DomainConfig]
      # @param guest [GuestStorage]
      # @param read_file [#call] see {Health.assess}
      # @param file_exist [#call] see {Health.assess}
      def initialize(live, guest, read_file, file_exist)
        @live = live
        @guest = guest
        @read_file = read_file
        @file_exist = file_exist
      end

      # @return [Array<Finding>] the mapper, trim and free-space findings; one `:skipped`
      #   finding instead if the guest stops answering midway
      def findings
        mappers + trim + free_tails
      rescue GuestAgent::Unavailable => e
        [Finding.new(:skipped, 'guest', "cannot answer: #{e.message.lines.first&.strip}", nil)]
      end

      private

      # One finding per filesystem on device-mapper. A layer whose `discard_max_bytes` is 0
      # stops every discard from above; the lowest such layer is the one to fix, since an
      # LVM volume merely inherits the 0 from the LUKS mapping beneath it.
      # @return [Array<Finding>]
      def mappers
        filesystems.reject { _1.mappers.empty? }.map do |fs|
          blocked = fs.mappers.select do |mapper|
            @read_file.call("/sys/class/block/#{mapper.device}/queue/discard_max_bytes").strip.to_i.zero?
          end
          if blocked.empty?
            Finding.new(:ok, fs.mountpoint, "discards pass #{fs.mappers.join(', ')}", nil)
          else
            Finding.new(:warning, fs.mountpoint, "#{blocked.last} blocks discard",
                        'if it is LUKS: add `discard` to its /etc/crypttab options, then reboot the guest')
          end
        end
      end

      # Whether freed space is ever trimmed, judged only when some disk passes discards. Not
      # for Windows, which has neither file to read.
      # @return [Array<Finding>]
      def trim
        return [] if @live.guest_os.windows?

        discarding = @live.disks.select { _1.discard == 'unmap' }.map(&:target)
        on_discarding = filesystems(@guest.disks.select { discarding.include?(_1.target) })
        return [] if on_discarding.empty?
        return [Finding.new(:ok, 'trim', 'fstrim.timer enabled', nil)] if @file_exist.call(TRIM_TIMER)

        options = mount_options
        undiscarded = on_discarding.map(&:mountpoint).reject { options.fetch(_1, []).include?('discard') }
        return [Finding.new(:ok, 'trim', 'every filesystem is mounted with discard', nil)] if undiscarded.empty?

        [Finding.new(:note, 'trim', "no periodic trim: fstrim.timer is off, and #{undiscarded.join(', ')} " \
                                    'not mounted with discard',
                     'systemctl enable --now fstrim.timer, in the guest')]
      end

      # @return [Array<Finding>]
      def free_tails
        grow_target = begin
          GuestRootGrow.plan(@guest).disk.target
        rescue GuestRootGrow::Refused
          nil
        end
        @guest.disks.filter_map do |disk|
          tail = disk.free_tail
          next if tail.nil? || tail < GuestStorage::MIN_FREE_TAIL

          last = disk.partitions.last.name
          growable = disk.target == grow_target
          fix = growable ? 'M → Grow root filesystem' : "grow #{last} into it, from inside the guest"
          Finding.new(:note, disk.target, "#{format_byte_size(tail)} unused after #{last}", fix,
                      (:grow_root if growable))
        end
      end

      # @param disks [Array<GuestStorage::Disk>]
      # @return [Array<GuestStorage::Filesystem>] every filesystem mounted from them, once
      def filesystems(disks = @guest.disks)
        disks.flat_map { [*_1.filesystems, *_1.partitions.flat_map(&:filesystems)] }.uniq
      end

      # `/proc/self/mounts` names a filesystem by `/dev/mapper/…` where guestinfo says `dm-1`,
      # so the mountpoint is the key; `\040` and friends are its octal escapes.
      # @return [Hash{String => Array<String>}] mountpoint → its options
      def mount_options
        @read_file.call('/proc/self/mounts').lines.to_h do |line|
          _device, mountpoint, _type, options = line.split
          [mountpoint.gsub(/\\(\d{3})/) { _1[1..].to_i(8).chr }, options.split(',')]
        end
      end
    end
  end
end
