# frozen_string_literal: true

require_relative '../spec_helper'

# These exercise a real `virsh` against `test:///default` — libvirt's in-process test
# driver, which needs no libvirtd. Without virsh installed there is nothing to test.
describe Virt::VirshSession do
  before do
    skip 'virsh not installed' unless Virt::Virsh.available?

    @log = Helpers.setup_dummy_logger
    @session = Virt::VirshSession.new(uri: 'test:///default')
  end

  after { @session&.close }

  # The safety argument for swapping transports rests on this: the parser must not be
  # able to tell which one fetched the text.
  it 'returns the same bytes as spawning a process per command' do
    spawn = Virt::VirshSpawn.new
    %w[domstats nodeinfo].each do |subcommand|
      assert_equal spawn.query('-c', 'test:///default', subcommand), @session.query(subcommand),
                   "#{subcommand} differed between transports"
    end
  end

  it 'feeds Virsh well enough to parse' do
    virsh = Virt::Virsh.new(runner: Virt::VirshSession.new(uri: 'test:///default'))
    info = virsh.hostinfo
    refute info.model.empty?
    assert_operator info.cpus, :>, 0
    assert_equal 1, virsh.domain_data.size
  ensure
    virsh&.runner&.close
  end

  it 'handles a multi-line reply, an empty reply and a repeat' do
    assert_operator @session.query('dominfo', 'test').lines.size, :>, 5
    assert_equal '', @session.query('setmaxmem', 'test', '1048576', '--config')
    assert_operator @session.query('domstats').bytesize, :>, 0
  end

  # The reply is framed by a sentinel whose bytes cannot appear in the echoed request, so
  # a payload carrying the prompt string must not cut the read short.
  it 'survives a payload containing the prompt' do
    assert_equal 'virsh # FORGED', @session.query('echo', 'virsh # FORGED')
    assert_equal 'still-here', @session.query('echo', 'still-here')
  end

  # Resizing the terminal signals virtui's whole process group, and the child runs GNU
  # readline: on SIGWINCH it repaints its line — ~520 bytes nobody asked for — into the
  # reply stream, and the next read finds them ahead of its echo. The child therefore
  # lives in a process group of its own. see DECISIONS.md D-virsh-own-pgroup
  it 'is deaf to the resize signal that reaches virtui process group' do
    child = @session.instance_variable_get(:@wait).pid
    refute_equal Process.getpgid(0), Process.getpgid(child), 'the child shares our process group'

    Process.kill('WINCH', -Process.getpgid(0))
    sleep 0.1

    assert_equal 'still-here', @session.query('echo', 'still-here')
    refute_includes @log.string, 'respawning'
  end

  it 'raises with virsh stderr when the command fails, and stays usable' do
    e = assert_raises(RuntimeError) { @session.query('dominfo', 'nosuchdomain') }
    assert_includes e.message, 'nosuchdomain'
    refute @session.degraded?, 'a command failure must not write off the session'
    assert_equal 'ok', @session.query('echo', 'ok')
  end

  # The guard that matters most. A wedged child must never let one command's output be
  # returned as another's; recovery is to respawn, so the retry sees a clean child.
  it 'never mis-attributes a reply from a wedged child' do
    session = Virt::VirshSession.new(uri: 'test:///default', read_timeout: 0.5)
    # Wedge it: `event --loop` blocks, so this command's output is still pending.
    stdin = session.instance_variable_get(:@stdin)
    stdin.write("event --loop --all --timeout 20\n")
    stdin.flush
    sleep 0.2

    reply = session.query('domstats')
    assert reply.start_with?("Domain: 'test'"), "got someone else's output: #{reply.inspect}"
    refute_includes reply, 'event loop'
    assert_includes @log.string, 'respawning'
    refute session.degraded?, 'one respawn was enough, so it must not have given up'
  ensure
    session&.close
  end

  # And when respawning does not help either, reads must keep working.
  it 'degrades to spawning when a respawn does not fix it' do
    stub = Class.new(Virt::VirshSpawn) do
      def query(_subcommand) = 'FROM-SPAWN'
    end.new
    session = Virt::VirshSession.new(uri: 'test:///default', spawn: stub, read_timeout: 0.3)

    # Wedge the child, and keep wedging it after every respawn.
    def session.start
      super
      @stdin.write("event --loop --all --timeout 30\n")
      @stdin.flush
    end
    session.send(:restart)

    assert_equal 'FROM-SPAWN', session.query('domstats')
    assert session.degraded?
    assert_includes @log.string, 'falling back'
  ensure
    session&.close
  end

  # An apostrophe in a VM name used to build `virsh setmem 'it's' …` and die in /bin/sh.
  # Both transports must now carry it verbatim.
  it "carries an apostrophe through, the way a VM named it's needs" do
    hostile = "it's a \"VM\" \\ odd"
    assert_equal hostile, @session.query('echo', hostile)
    assert_equal hostile, Virt::VirshSpawn.new.query('-c', 'test:///default', 'echo', hostile)
  end

  it 'degrades to spawning after close, rather than raising' do
    stub = Class.new(Virt::VirshSpawn) do
      def query(_subcommand) = 'FROM-SPAWN'
    end.new
    session = Virt::VirshSession.new(uri: 'test:///default', spawn: stub)
    session.close
    assert session.degraded?
    assert_equal 'FROM-SPAWN', session.query('domstats')
  end
end

# No virsh needed: quoting is pure string work.
describe 'Virt::VirshSession.quote' do
  it 'wraps an apostrophe the way virsh echo --shell does' do
    assert_equal %('it'\\''s'), Virt::VirshSession.quote("it's")
  end

  # Readline acts on these as editing keys before the tokenizer sees them, which would
  # corrupt the command and misattribute every reply after it. Quoting cannot help.
  it 'refuses a control byte rather than quoting it' do
    ["tab\there", "kill\x15me", "del\x7f", "nul\0"].each do |hostile|
      assert_raises(RuntimeError, "#{hostile.inspect} should be refused") { Virt::VirshSession.quote(hostile) }
    end
  end
end

describe Virt::VirshSpawn do
  it 'prefixes the subcommand with virsh' do
    skip 'virsh not installed' unless Virt::Virsh.available?

    runner = Virt::VirshSpawn.new
    assert_includes runner.query('-c', 'test:///default', 'nodeinfo'), 'CPU model'
    assert_equal runner.query('-c', 'test:///default', 'nodeinfo'),
                 runner.sync('-c', 'test:///default', 'nodeinfo')
    runner.close
  end
end
