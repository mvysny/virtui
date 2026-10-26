# frozen_string_literal: true

require_relative '../spec_helper'

# A runner that answers `qemu-agent-command` from a script keyed by the agent command, so a
# test names only the replies it cares about; every call is recorded as argv for assertions.
# A scripted StandardError stands in for what a real transport raises when `virsh` fails.
class ScriptedAgentRunner
  attr_reader :calls

  # @param replies [Hash{String => String, StandardError}] agent command name => the JSON
  #   `virsh` would print, or an error to raise instead
  def initialize(replies)
    @replies = replies
    @calls = []
  end

  # @param args [Array<String>] the argv {Virt::GuestAgent} built
  # @return [String] the scripted reply
  def query(*args)
    @calls << args
    execute = JSON.parse(args[2])['execute']
    reply = @replies.fetch(execute) { raise "no reply scripted for #{execute}" }
    raise reply if reply.is_a?(StandardError)

    reply
  end
end

# The guest's /proc/meminfo as the agent hands it over: base64, inside a `guest-file-read`
# reply. The three replies together are one healthy sample.
MEMINFO_B64 = [File.read('spec/virt/guest_meminfo.txt')].pack('m0')
HEALTHY_AGENT = {
  'guest-file-open' => '{"return":13}',
  'guest-file-read' => %({"return":{"count":1431,"buf-b64":"#{MEMINFO_B64}","eof":false}}),
  'guest-file-close' => '{"return":{}}'
}.freeze

# A {ScriptedAgentRunner} that also answers `guestinfo`, with the recorded vt-ubuntu fixture.
class FsAgentRunner < ScriptedAgentRunner
  # @param ping [String, StandardError] the `guest-ping` reply, or an error to raise instead
  def initialize(ping)
    super('guest-ping' => ping)
  end

  def query(*args)
    return super unless args.first == 'guestinfo'

    @calls << args
    File.read('spec/virt/guestinfo_vt-ubuntu.txt')
  end
end

describe Virt::GuestAgent do
  before { @log = Helpers.setup_dummy_logger }

  # @param runner [ScriptedAgentRunner] the runner the agent talked to
  # @return [Array<String>] the agent commands it was asked for, in order
  def executes(runner) = runner.calls.map { |it| JSON.parse(it[2])['execute'] }

  it 'reads the swap level out of the guest /proc/meminfo' do
    agent = Virt::GuestAgent.new(runner: ScriptedAgentRunner.new(HEALTHY_AGENT))
    assert_equal '1.2G/4G (30%)', agent.swap('Ubuntu').to_s
  end

  it 'asks for the file in three calls, JSON-encoded, with a timeout' do
    runner = ScriptedAgentRunner.new(HEALTHY_AGENT)
    Virt::GuestAgent.new(runner: runner).swap('it\'s')

    assert_equal [['qemu-agent-command', 'it\'s',
                   '{"execute":"guest-file-open","arguments":{"path":"/proc/meminfo","mode":"r"}}',
                   '--timeout', '2'],
                  ['qemu-agent-command', 'it\'s',
                   '{"execute":"guest-file-read","arguments":{"handle":13,"count":16384}}',
                   '--timeout', '2'],
                  ['qemu-agent-command', 'it\'s',
                   '{"execute":"guest-file-close","arguments":{"handle":13}}',
                   '--timeout', '2']],
                 runner.calls
  end

  # qemu-ga keeps an open handle until the guest reboots, so the close must survive a failed
  # read — otherwise a guest that fails reads slowly runs out of handles.
  it 'closes the handle even when the read fails' do
    runner = ScriptedAgentRunner.new(HEALTHY_AGENT.merge('guest-file-read' => RuntimeError.new('error: boom')))
    assert_raises(RuntimeError) { Virt::GuestAgent.new(runner: runner).swap('Ubuntu') }
    assert_equal %w[guest-file-open guest-file-read guest-file-close], executes(runner)
  end

  # A refusal (a blocked RPC, a missing file) arrives as a well-formed reply, so it must not
  # be read as data.
  it 'treats an error member as a failure, not as a reply' do
    runner = ScriptedAgentRunner.new(HEALTHY_AGENT.merge(
                                       'guest-file-open' => '{"error":{"class":"CommandNotFound","desc":"blocked"}}'
                                     ))
    error = assert_raises(RuntimeError) { Virt::GuestAgent.new(runner: runner).swap('Ubuntu') }
    assert_includes error.message, 'blocked'
    # Nothing to close: the open never produced a handle.
    assert_equal ['guest-file-open'], executes(runner)
  end

  it 'refuses half a file rather than reporting it as a level' do
    truncated = [File.read('spec/virt/guest_meminfo.txt')[0, 40]].pack('m0')
    runner = ScriptedAgentRunner.new(
      HEALTHY_AGENT.merge('guest-file-read' => %({"return":{"count":40,"buf-b64":"#{truncated}","eof":false}}))
    )
    error = assert_raises(RuntimeError) { Virt::GuestAgent.new(runner: runner).swap('Ubuntu') }
    assert_includes error.message, 'SwapTotal'
  end

  context 'sysrq_mask' do
    # @param content [String] the guest's /proc/sys/kernel/sysrq
    def agent_reading(content)
      b64 = [content].pack('m0')
      Virt::GuestAgent.new(runner: ScriptedAgentRunner.new(
        HEALTHY_AGENT.merge('guest-file-read' => %({"return":{"count":4,"buf-b64":"#{b64}","eof":true}}))
      ))
    end

    it 'reads the number out of /proc/sys/kernel/sysrq' do
      assert_equal 176, agent_reading("176\n").sysrq_mask('vt-ubuntu')
    end

    it 'refuses a file that is not one number' do
      error = assert_raises(RuntimeError) { agent_reading("176 16\n").sysrq_mask('vt-ubuntu') }
      assert_includes error.message, 'is not a number'
    end
  end

  context 'exist?' do
    it 'opens and closes the file, reading nothing' do
      runner = ScriptedAgentRunner.new(HEALTHY_AGENT)
      assert Virt::GuestAgent.new(runner: runner).exist?('vt-ubuntu', '/etc/fstab')
      assert_equal %w[guest-file-open guest-file-close], executes(runner)
    end

    it 'answers false for a missing file' do
      runner = ScriptedAgentRunner.new('guest-file-open' => RuntimeError.new(
        "error: internal error: unable to execute QEMU agent command 'guest-file-open': failed to open file " \
        "'/etc/systemd/system/timers.target.wants/fstrim.timer' (mode: 'r'): No such file or directory"
      ))
      refute Virt::GuestAgent.new(runner: runner).exist?('vt-ubuntu', '/etc/systemd/system/timers.target.wants/fstrim.timer')
    end

    it 'still raises for a guest that cannot answer' do
      runner = ScriptedAgentRunner.new('guest-file-open' => RuntimeError.new(
        'error: Guest agent is not responding: QEMU guest agent is not connected'
      ))
      assert_raises(Virt::GuestAgent::Unavailable) { Virt::GuestAgent.new(runner: runner).exist?('vt-ubuntu', '/x') }
    end
  end

  # The class of the error, not the log level, is what a caller polling this hangs its
  # write-off and its log level off — see design/decisions.md D_guest_agent_backoff.
  context 'failure classification' do
    # @param replies [Hash{String => String, StandardError}] the scripted agent
    # @return [StandardError] what {Virt::GuestAgent#read_file} raised against it
    def error_of_read(replies)
      agent = Virt::GuestAgent.new(runner: ScriptedAgentRunner.new(replies))
      assert_raises(StandardError) { agent.read_file('win11', '/proc/meminfo') }
    end

    it 'raises Unavailable for a guest that was never going to answer' do
      error = error_of_read('guest-file-open' => RuntimeError.new(
        'error: Guest agent is not responding: QEMU guest agent is not connected'
      ))
      assert_kind_of Virt::GuestAgent::Unavailable, error
    end

    it 'leaves a reply nobody documents an ordinary error' do
      error = error_of_read(HEALTHY_AGENT.merge('guest-file-read' => '{"return":{"count":0}}'))
      refute_kind_of Virt::GuestAgent::Unavailable, error
      assert_includes error.message, 'gave no buf-b64'
    end
  end

  context 'fs_usage' do
    it 'pings the agent, then reads the filesystems through guestinfo' do
      runner = FsAgentRunner.new('{"return":{}}')
      usage = Virt::GuestAgent.new(runner: runner).fs_usage('vt-ubuntu')
      assert_equal 3_585_975_808, usage['vda'].used
      assert_equal [['qemu-agent-command', 'vt-ubuntu', '{"execute":"guest-ping"}', '--timeout', '2'],
                    %w[guestinfo vt-ubuntu --filesystem]], runner.calls
    end

    # guestinfo has no --timeout and waits out a hung agent; the ping is what bounds that.
    it 'never reaches guestinfo when the ping times out' do
      runner = FsAgentRunner.new(RuntimeError.new("error: guest agent command timed out: guest agent didn't " \
                                                  "respond to command within '2' seconds"))
      assert_raises(RuntimeError) { Virt::GuestAgent.new(runner: runner).fs_usage('vt-ubuntu') }
      assert_equal ['qemu-agent-command'], runner.calls.map(&:first)
    end

    it 'classifies a domain with no agent channel as unavailable' do
      runner = FsAgentRunner.new(RuntimeError.new('error: argument unsupported: QEMU guest agent is not configured'))
      assert_raises(Virt::GuestAgent::Unavailable) { Virt::GuestAgent.new(runner: runner).fs_usage('vt-bios') }
    end
  end

  context 'connected?' do
    # @param output [String] what `virsh dumpxml --xpath` prints
    # @return [Boolean, RuntimeError] the agent's answer, or what it raised
    def connected_over(output)
      runner = Object.new
      runner.define_singleton_method(:query) { |*_args| output }
      Virt::GuestAgent.new(runner: runner).connected?('vt-ubuntu')
    rescue RuntimeError => e
      e
    end

    # Recorded from vt-ubuntu across a reboot, as virsh prints them: a leading space, a newline.
    it 'reads the channel state' do
      assert connected_over(" state=\"connected\"\n")
      refute connected_over(" state=\"disconnected\"\n")
    end

    it 'answers false for a domain that is not running or has no agent channel' do
      refute connected_over('')
    end

    it 'refuses a state it does not know' do
      assert_includes connected_over(' state="hungry"').message, 'unexpected agent channel'
    end
  end

  # The payload is nothing but nested quotes, and this is the end-to-end proof that the
  # session does not mangle it: `test:///default` needs no libvirtd but does reach libvirt's own
  # virDomainQemuAgentCommand, which it then declines — so a quoting bug would surface as a
  # different error, or as a desynchronised session.
  context 'against a real virsh' do
    before { skip 'virsh not installed' unless Virt::Virsh.available? }

    it 'survives the round-trip through a session' do
      session = Virt::VirshSession.new(uri: 'test:///default')
      # The class of the refusal is libvirt's business; that it reached that function is ours.
      error = assert_raises(StandardError) { Virt::GuestAgent.new(runner: session).swap('test') }
      assert_includes error.message, 'virDomainQemuAgentCommand'
      refute session.degraded?, 'a declined agent call must not write off the session'
      assert_equal 'ok', session.query('echo', 'ok'), 'the session must still line up'
    ensure
      session&.close
    end

    it 'reads a channel state through a session' do
      session = Virt::VirshSession.new(uri: 'test:///default')
      refute Virt::GuestAgent.new(runner: session).connected?('test'), 'the test driver declares no agent channel'
      assert_equal 'ok', session.query('echo', 'ok'), 'the session must still line up'
    ensure
      session&.close
    end
  end
end
