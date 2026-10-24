# frozen_string_literal: true

module Virt
  # Grows a running guest's root partition, and the filesystem on it, into the free space at
  # the end of its disk — what a disk image resize leaves behind:
  #
  #   plan = GuestRootGrow.plan(virsh.guest_storage('vt-ubuntu'))   # raises Refused if it can't
  #   grower = GuestRootGrow.new
  #   grower.check('vt-ubuntu', plan)                              # the guest-side checks
  #   grower.grow('vt-ubuntu', plan)                               # sfdisk, partx, resize2fs
  #
  # The simplest layout only: `/` is ext4 or btrfs directly on a partition — no LVM, no
  # encryption — and that partition is physically the last on its disk. Everything else is
  # refused with the reason, for the user to grow by hand.
  #
  # The one sanctioned use of `guest-exec`: three fixed commands, run as root in the guest,
  # only from an operator-confirmed `M` item (design/decisions.md D_guest_root_grow). Every
  # call spawns its own `virsh`, the mutating ones and the polls alike.
  #
  # Never on the UI thread: a grow runs for as long as the guest's `resize2fs` does.
  class GuestRootGrow
    # Why a grow cannot happen, in words for the user: the guest's layout is not the simple
    # one, there is no room, or its agent will not run commands.
    class Refused < StandardError; end

    # What one grow does to which partition.
    # @!attribute [r] disk
    #   @return [GuestStorage::Disk] the disk the root partition is on
    # @!attribute [r] partition
    #   @return [GuestStorage::Partition] the root partition, last on {#disk}
    # @!attribute [r] filesystem
    #   @return [GuestStorage::Filesystem] `/`
    class Plan < Data.define(:disk, :partition, :filesystem)
      # @return [Integer] the partition's number, from its kernel name (`vda1`, `nvme0n1p2`)
      def number = partition.name[/\d+\z/].to_i

      # @return [Integer] bytes the partition grows by: all of the disk after it
      def growth = disk.free_tail

      # @return [Array<Array(Array<String>, String)>] each command's argv, with what it reads
      #   on stdin (`nil` for nothing)
      def commands
        grow_fs = if filesystem.fstype == 'btrfs'
                    %w[btrfs filesystem resize max /]
                  else
                    ['resize2fs', partition.device]
                  end
        # ", +" keeps the partition's start and grows it to the end of the disk. --no-reread:
        # the disk is in use, so a re-read fails; partx tells the kernel instead.
        [[['sfdisk', '-N', number.to_s, '--no-reread', '--no-tell-kernel', disk.device], ", +\n"],
         [['partx', '-u', disk.device], nil],
         [grow_fs, nil]]
      end
    end

    # The filesystems a grow knows the command for.
    FSTYPES = %w[ext4 btrfs].freeze

    # Seconds `virsh` waits for one agent call; generous, since `guest-exec` returns at once
    # and the polls are cheap.
    TIMEOUT_SECONDS = 10

    # How often {#grow} asks whether a command has exited.
    POLL_SECONDS = 0.2

    # How long one command may run before {#grow} stops waiting: an online `resize2fs` over a
    # large filesystem takes a while. The command runs on in the guest after that.
    DEADLINE_SECONDS = 600

    # The plan for the guest's layout, or why there is none.
    #
    # @param storage [GuestStorage] the guest's disks, fresh
    # @return [Plan]
    # @raise [Refused] if `/` is not ext4 or btrfs directly on the last partition of its disk,
    #   with room after it
    def self.plan(storage)
      storage.disks.each do |disk|
        raise Refused, "/ sits on the whole of #{disk.target}, with no partition to grow" if
          disk.filesystems.any? { _1.mountpoint == '/' }

        disk.partitions.each do |partition|
          root = partition.filesystems.find { _1.mountpoint == '/' }
          return checked(Plan.new(disk: disk, partition: partition, filesystem: root)) if root
        end
      end
      raise Refused, 'the guest reports no / on a partition'
    end

    # @param plan [Plan]
    # @return [Plan] the same plan
    # @raise [Refused] see {.plan}
    private_class_method def self.checked(plan)
      part = plan.partition.name
      fs = plan.filesystem
      raise Refused, "/ is on #{fs.name} inside #{part}, LVM or encryption, which virtui does not grow" if fs.name != part
      raise Refused, "/ is #{fs.fstype}; virtui grows #{FSTYPES.join(' and ')} only" unless FSTYPES.include?(fs.fstype)

      last = plan.disk.partitions.last
      raise Refused, "#{part} is not the last partition on #{plan.disk.target}: #{last.name} sits after it" if last != plan.partition
      raise Refused, "#{part} has no number to grow it by" if part !~ /\d\z/

      tail = plan.growth
      if tail.nil? || tail < GuestStorage::MIN_FREE_TAIL
        raise Refused, "there is no free space after #{part}: grow #{plan.disk.target}'s image first"
      end

      plan
    end

    # @param runner [VirshSpawn] transport for the agent calls; a process each
    # @param agent [GuestAgent] reads the guest files {#check} needs
    def initialize(runner: VirshSpawn.new, agent: GuestAgent.new(runner: runner))
      @runner = runner
      @agent = agent
    end

    # The checks only the guest can answer: that its agent runs commands, and that the
    # partition table can grow the partition in place.
    #
    # @param domain [String] VM name; must be running
    # @param plan [Plan] from {.plan}
    # @return [void]
    # @raise [Refused] if `guest-exec` is disabled, or the partition is a logical one inside
    #   an MBR extended partition
    # @raise [GuestAgent::Unavailable] if the guest was never going to answer
    def check(domain, plan)
      enabled = command(domain, 'guest-info').fetch('supported_commands').select { _1['enabled'] }.map { _1['name'] }
      missing = %w[guest-exec guest-exec-status] - enabled
      raise Refused, "the guest agent does not run #{missing.join(' or ')}: grow it from inside the guest" unless missing.empty?

      table = partition_table(domain, plan.disk)
      raise Refused, "#{plan.disk.target} has a #{table.inspect} partition table, neither gpt nor dos" unless %w[gpt dos].include?(table)
      # Numbers 5 and up on MBR are logical partitions, inside an extended one that would have to grow first.
      raise Refused, "#{plan.partition.name} is a logical partition inside an extended one" if table == 'dos' && plan.number > 4
    end

    # Runs the plan's commands in the guest, one after the other.
    #
    # @param domain [String] VM name
    # @param plan [Plan] from {.plan}, {#check}ed
    # @return [void]
    # @raise [RuntimeError] on the first command that exits non-zero, with its stderr; the
    #   ones after it never run
    def grow(domain, plan)
      plan.commands.each do |argv, stdin|
        status = exec(domain, argv, stdin)
        out, err = %w[out-data err-data].map { status[_1].to_s.unpack1('m').force_encoding(Encoding::UTF_8) }
        $log.info "#{domain}: #{argv.join(' ')} exited #{status['exitcode']}"
        $log.debug "#{domain}: #{argv.first}: #{out}#{err}"
        raise "#{argv.join(' ')} failed with #{status['exitcode']}: #{err.strip}" unless status['exitcode'].zero?
      end
    end

    # @param domain [String]
    # @param disk [GuestStorage::Disk]
    # @return [String] udev's `ID_PART_TABLE_TYPE` for the disk: `gpt` or `dos`
    # @raise [RuntimeError] if udev has not recorded one
    private def partition_table(domain, disk)
      numbers = @agent.read_file(domain, "/sys/class/block/#{File.basename(disk.device)}/dev").strip
      data = @agent.read_file(domain, "/run/udev/data/b#{numbers}")
      data[/^E:ID_PART_TABLE_TYPE=(.*)$/, 1] or raise "#{domain}: udev knows no partition table for #{disk.device}"
    end

    # Starts one command in the guest and waits for it to exit.
    # @param domain [String]
    # @param argv [Array<String>] the command; the agent finds it on the guest's `PATH`
    # @param stdin [String, nil]
    # @return [Hash{String => Object}] the final `guest-exec-status`: `exitcode`, base64 `out-data`/`err-data`
    # @raise [RuntimeError] if it is still running after {DEADLINE_SECONDS}
    private def exec(domain, argv, stdin)
      arguments = { path: argv.first, arg: argv.drop(1), 'capture-output': true }
      arguments['input-data'] = [stdin].pack('m0') if stdin
      pid = command(domain, 'guest-exec', arguments).fetch('pid')
      deadline = Cooldown.of(DEADLINE_SECONDS)
      loop do
        status = command(domain, 'guest-exec-status', { pid: pid })
        return status if status['exited']
        raise "#{domain}: #{argv.join(' ')} still runs after #{DEADLINE_SECONDS} s; it goes on in the guest" unless deadline.active?

        sleep POLL_SECONDS
      end
    end

    # @param domain [String]
    # @param execute [String] the agent command
    # @param arguments [Hash, nil]
    # @return [Object] the reply's `return` member
    # @raise [GuestAgent::Unavailable] if the guest was never going to answer
    # @raise [RuntimeError] if `virsh` failed or the agent answered with an `error`
    private def command(domain, execute, arguments = nil)
      request = { execute: execute }
      request[:arguments] = arguments unless arguments.nil?
      raw = @runner.sync('qemu-agent-command', domain, JSON.generate(request), '--timeout', TIMEOUT_SECONDS.to_s)
      reply = JSON.parse(raw)
      raise "#{domain}: #{execute} failed: #{reply['error']}" if reply.key?('error')

      reply.fetch('return')
    rescue StandardError => e
      raise GuestAgent::Unavailable, e.message if GuestAgent.expected_failure?(e)

      raise
    end
  end
end
