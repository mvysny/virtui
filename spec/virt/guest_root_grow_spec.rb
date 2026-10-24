# frozen_string_literal: true

require_relative '../spec_helper'

# Answers the `qemu-agent-command`s {Virt::GuestRootGrow} spawns: `guest-info` from the recorded
# fixture, `guest-exec` with a fresh pid, `guest-exec-status` with an exit — the scripted one
# for each command, by its path.
class ScriptedExecRunner
  attr_reader :execs

  # @param guest_info [String] the `guest-info` reply
  # @param exits [Hash{String => Array(Integer, String)}] command path => exit code and stderr;
  #   0 and nothing for a command not named
  def initialize(guest_info: File.read('spec/virt/guest_info_vt-ubuntu.json'), exits: {})
    @guest_info = guest_info
    @exits = exits
    @execs = []
    @pids = {}
  end

  def sync(*args)
    request = JSON.parse(args[2])
    case request['execute']
    when 'guest-info' then @guest_info
    when 'guest-exec'
      a = request['arguments']
      @execs << [[a['path'], *a['arg']], a['input-data']&.unpack1('m')]
      @pids[@execs.size] = a['path']
      %({"return":{"pid":#{@execs.size}}})
    when 'guest-exec-status'
      code, err = @exits.fetch(@pids.fetch(request['arguments']['pid']), [0, ''])
      JSON.generate(return: { exited: true, exitcode: code, 'err-data': [err].pack('m0') })
    else raise "unscripted #{request['execute']}"
    end
  end
end

# Hands {Virt::GuestRootGrow#check} the guest files it reads.
class ScriptedFiles
  def initialize(files) = @files = files
  def read_file(_domain, path) = @files.fetch(path)
end

describe Virt::GuestRootGrow do
  before { Helpers.setup_dummy_logger }

  # @return [Virt::GuestStorage] the demo's easy layout: vda15 EFI, then / on vda1, 28 GiB after it
  def roomy = Virt::VMEmulator.demo.guest_storage('Ubuntu')

  # @param storage [Virt::GuestStorage]
  # @return [String] the refusal's message
  def refusal(storage) = assert_raises(Virt::GuestRootGrow::Refused) { described_class.plan(storage) }.message

  # @param partitions [Array<Virt::GuestStorage::Partition>] vda's partitions instead
  # @return [Virt::GuestStorage] {#roomy} with them
  def roomy_with(partitions)
    storage = roomy
    storage.with(disks: [storage.disk('vda').with(partitions: partitions)])
  end

  context 'plan' do
    it 'grows / on the last partition into all the space after it' do
      plan = described_class.plan(roomy)
      assert_equal ['vda1', 1, 28.GiB - 107.MiB], [plan.partition.name, plan.number, plan.growth]
      assert_equal [[%w[sfdisk -N 1 --no-reread --no-tell-kernel /dev/vda], ", +\n"],
                    [%w[partx -u /dev/vda], nil],
                    [%w[resize2fs /dev/vda1], nil]], plan.commands
    end

    it 'grows a btrfs / with btrfs itself' do
      vda15, vda1 = roomy.disk('vda').partitions
      btrfs = vda1.with(filesystems: [vda1.filesystems.first.with(fstype: 'btrfs')])
      assert_equal %w[btrfs filesystem resize max /], described_class.plan(roomy_with([vda15, btrfs])).commands.last[0]
    end

    it 'finds no room on a disk the root partition already fills' do
      assert_equal "there is no free space after vda1: grow vda's image first", refusal(Helpers.vt_ubuntu_storage)
    end

    it 'refuses / behind LVM or encryption, on another filesystem, or not last' do
      vda15, vda1 = roomy.disk('vda').partitions
      root = vda1.filesystems.first
      assert_includes refusal(roomy_with([vda15, vda1.with(filesystems: [root.with(name: 'dm-0')])])), 'LVM or encryption'
      assert_includes refusal(roomy_with([vda15, vda1.with(filesystems: [root.with(fstype: 'xfs')])])), '/ is xfs'
      assert_includes refusal(roomy_with([vda1, vda15])), 'vda1 is not the last partition on vda: vda15 sits after it'
    end

    it 'refuses a guest that reports no / on a partition' do
      assert_equal 'the guest reports no / on a partition', refusal(Virt::VMEmulator.demo.guest_storage('win11'))
    end
  end

  context 'check' do
    let(:plan) { described_class.plan(roomy) }
    let(:gpt) { { '/sys/class/block/vda/dev' => "253:0\n", '/run/udev/data/b253:0' => "E:ID_PART_TABLE_TYPE=gpt\n" } }

    def check(plan, runner: ScriptedExecRunner.new, files: gpt)
      described_class.new(runner: runner, agent: ScriptedFiles.new(files)).check('vt-ubuntu', plan)
    end

    it 'passes a GPT disk whose agent runs commands' do
      check(plan)
    end

    it 'refuses an agent with guest-exec disabled' do
      info = File.read('spec/virt/guest_info_vt-ubuntu.json')
                 .sub('"enabled":true,"name":"guest-exec"', '"enabled":false,"name":"guest-exec"')
      refute_equal info, File.read('spec/virt/guest_info_vt-ubuntu.json'), 'the fixture lists guest-exec as expected'
      error = assert_raises(Virt::GuestRootGrow::Refused) { check(plan, runner: ScriptedExecRunner.new(guest_info: info)) }
      assert_includes error.message, 'does not run guest-exec'
    end

    it 'refuses a logical partition on MBR, and a table it does not know' do
      vda15, vda1 = roomy.disk('vda').partitions
      vda5 = vda1.with(device: '/dev/vda5', filesystems: [vda1.filesystems.first.with(name: 'vda5')])
      logical = described_class.plan(roomy_with([vda15, vda5]))
      dos = gpt.merge('/run/udev/data/b253:0' => "E:ID_PART_TABLE_TYPE=dos\n")
      check(plan, files: dos)
      error = assert_raises(Virt::GuestRootGrow::Refused) { check(logical, files: dos) }
      assert_includes error.message, 'vda5 is a logical partition'
      error = assert_raises(Virt::GuestRootGrow::Refused) { check(plan, files: gpt.merge('/run/udev/data/b253:0' => "E:ID_PART_TABLE_TYPE=atari\n")) }
      assert_includes error.message, '"atari"'
    end
  end

  context 'grow' do
    let(:plan) { described_class.plan(roomy) }

    it 'runs the commands in order, sfdisk fed its script' do
      runner = ScriptedExecRunner.new
      described_class.new(runner: runner).grow('vt-ubuntu', plan)
      assert_equal plan.commands, runner.execs
    end

    it 'stops at the first command that fails, with its stderr' do
      runner = ScriptedExecRunner.new(exits: { 'partx' => [1, "partx: /dev/vda: failed\n"] })
      error = assert_raises(RuntimeError) { described_class.new(runner: runner).grow('vt-ubuntu', plan) }
      assert_equal 'partx -u /dev/vda failed with 1: partx: /dev/vda: failed', error.message
      assert_equal(%w[sfdisk partx], runner.execs.map { _1[0][0] })
    end
  end
end
