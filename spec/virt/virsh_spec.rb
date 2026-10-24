# frozen_string_literal: true

require_relative '../spec_helper'

VIRSH_NODEINFO = <<~EOF
  CPU model:           x86_64
  CPU(s):              16
  CPU frequency:       1397 MHz
  CPU socket(s):       1
  Core(s) per socket:  8
  Thread(s) per core:  2
  NUMA cell(s):        1
  Memory size:         29987652 KiB
EOF

# One running VM's domstats, trimmed to the balloon fields. The swap counters are the pair
# measured in design/ideas/swap-despite-ballooning.md, where they were cross-checked against the
# guest's own /proc/vmstat: swap_out 3_205_344 KiB == pswpout 801_336 pages x 4096.
VIRSH_DOMSTATS_SWAPPING = <<~EOF
  Domain: 'swapper'
    state.state=1
    vcpu.maximum=8
    cpu.time=1000000000
    balloon.current=23068672
    balloon.maximum=25165824
    balloon.swap_in=2195252
    balloon.swap_out=3205344
    balloon.unused=4194304
    balloon.available=22118400
    balloon.usable=8388608
    balloon.last-update=1762371689
    balloon.disk_caches=4508876
    balloon.rss=23068672
EOF

# What `virsh metadata --uri http://libosinfo.org/xmlns/libvirt/domain/1.0 <dom>` prints for
# a domain virt-manager created. Content is as measured on the author's host (2026-08-23);
# note the missing `libosinfo:` prefix, which virsh strips even though the stored definition
# carries it.
VIRSH_METADATA_WIN = <<~EOF
  <libosinfo>
    <os id="http://microsoft.com/win/11"/>
  </libosinfo>
EOF

# Records what the runner was asked to do, so the assertions below read as argv lists.
class RecordingRunner
  attr_reader :calls

  def initialize = @calls = []
  def query(*args) = record(:query, args)
  def sync(*args) = record(:sync, args)
  def async(*args) = record(:async, args)

  private def record(kind, args)
    @calls << [kind, *args]
    ''
  end
end

describe Virt::Virsh do
  context 'guest_swap' do
    before { Helpers.setup_dummy_logger }

    it 'is nil without a swap sampler, and never touches the transport' do
      runner = RecordingRunner.new
      assert_nil Virt::Virsh.new(runner: runner).guest_swap('ubuntu')
      assert_empty runner.calls
    end

    it 'delegates to the swap sampler it was given' do
      # The sampler's own failure path (no agent in the guest) is what a RecordingRunner's
      # empty reply produces, so this asserts the wiring, not the parse.
      runner = RecordingRunner.new
      sampler = Virt::GuestSwapSampler.new(agent: Virt::GuestAgent.new(runner: runner))
      assert_nil Virt::Virsh.new(runner: runner, swap_sampler: sampler).guest_swap('ubuntu')
      assert_equal 'qemu-agent-command', runner.calls.first[1]
    end
  end

  context 'guest_os' do
    before { Helpers.setup_dummy_logger }

    it 'reads the declared family out of a virsh metadata reply' do
      os = Virt::Virsh.new.guest_os('win11', VIRSH_METADATA_WIN)
      assert_equal :windows, os.family
      assert_equal 'http://microsoft.com/win/11', os.osinfo_id
    end

    it 'asks virsh for the libosinfo namespace' do
      runner = RecordingRunner.new
      Virt::Virsh.new(runner: runner).guest_os('win11')
      assert_equal [:query, 'metadata', 'win11', '--uri', Virt::Virsh::LIBOSINFO_URI], runner.calls.first
    end

    it 'is UNKNOWN when the domain declares nothing' do
      # A RecordingRunner replies with '', which is also what a domain with no metadata
      # element looks like once virsh has had its say.
      assert_equal Virt::GuestOS::UNKNOWN, Virt::Virsh.new(runner: RecordingRunner.new).guest_os('BASE')
    end

    it 'is UNKNOWN rather than an exception when virsh fails' do
      runner = Class.new { def query(*_args) = raise('error: failed to get domain') }.new
      assert_equal Virt::GuestOS::UNKNOWN, Virt::Virsh.new(runner: runner).guest_os('vanished')
    end
  end

  # The fixtures are `virsh -q domifaddr` of guest `Flow` on the NAT `default` network, as
  # measured on the author's host (2026-09-21).
  context 'ip_address' do
    let(:lease) { File.read('spec/virt/domifaddr_lease.txt') }
    let(:arp) { File.read('spec/virt/domifaddr_arp.txt') }
    # Assumed, not yet recorded: what `-q` prints for a guest with no lease.
    let(:none) { '' }

    it 'takes the lease, without its prefix' do
      assert_equal '192.168.122.137', Virt::Virsh.new.ip_address('Flow', lease, '')
    end

    it 'falls back to arp, whose /0 prefix is dropped too' do
      assert_equal '192.168.122.137', Virt::Virsh.new.ip_address('Flow', none, arp)
    end

    it 'is nil when neither table has a row' do
      assert_nil Virt::Virsh.new.ip_address('Flow', none, none)
    end

    it 'asks lease first and arp only when lease has no row' do
      runner = RecordingRunner.new
      Virt::Virsh.new(runner: runner).ip_address("it's")
      assert_equal [[:query, 'domifaddr', "it's", '--source', 'lease'],
                    [:query, 'domifaddr', "it's", '--source', 'arp']], runner.calls
    end

    it 'raises on a row it does not recognise' do
      assert_raises(RuntimeError) { Virt::Virsh.new.ip_address('Flow', " vnet0 52:54:00:ae:9d:2f ipv4\n", none) }
    end

    # What a transport without `-q` would hand over: raising is what keeps it from reading as
    # "no address".
    it 'raises on a table header' do
      header = " Name       MAC address          Protocol     Address\n#{'-' * 79}\n"
      assert_raises(RuntimeError) { Virt::Virsh.new.ip_address('Flow', header + lease, none) }
    end
  end

  context 'domain_config' do
    it 'parses the dumpxml it is handed' do
      xml = File.read('spec/virt/dumpxml_vt-bios.xml')
      assert_equal :bios, Virt::Virsh.new(runner: RecordingRunner.new).domain_config('vt-bios', xml).firmware
    end

    # sync, not query: a process of its own, never queued behind the session.
    it 'spawns a plain dumpxml, never with --security-info' do
      runner = RecordingRunner.new
      runner.define_singleton_method(:sync) { |*args| record(:sync, args) && File.read('spec/virt/dumpxml_vt-bios.xml') }
      Virt::Virsh.new(runner: runner).domain_config('vt-bios')
      assert_equal [[:sync, 'dumpxml', 'vt-bios']], runner.calls
    end
  end

  context 'health' do
    # vt-bios has no agent channel, so its guest is never asked.
    it 'reads both definitions, and nothing from a guest without an agent' do
      runner = RecordingRunner.new
      runner.define_singleton_method(:sync) { |*args| record(:sync, args) && File.read('spec/virt/dumpxml_vt-bios.xml') }
      health = Virt::Virsh.new(runner: runner).health('vt-bios')
      assert_equal [[:sync, 'dumpxml', 'vt-bios'], [:sync, 'dumpxml', 'vt-bios', '--inactive']], runner.calls
      assert_equal([:skipped, 'guest'], health.findings.last.then { [_1.severity, _1.subject] })
    end
  end

  context 'volume' do
    it 'parses the vol-pool, vol-info and pool-info it is handed' do
      vol = Virt::Virsh.new.volume('/var/lib/libvirt/images/vt-ubuntu.qcow2', "default\n",
                                   File.read('spec/virt/vol_info_vt-ubuntu.txt'),
                                   File.read('spec/virt/pool_info_default.txt'))
      assert_equal Virt::Volume.new(path: '/var/lib/libvirt/images/vt-ubuntu.qcow2', pool: 'default',
                                    capacity: 15_032_385_536, allocation: 607_207_424,
                                    pool_available: 95_989_456_896), vol
    end

    it 'spawns each read, by path, in --bytes' do
      runner = RecordingRunner.new
      replies = { 'vol-pool' => "default\n", 'vol-info' => File.read('spec/virt/vol_info_vt-ubuntu.txt'),
                  'pool-info' => File.read('spec/virt/pool_info_default.txt') }
      runner.define_singleton_method(:sync) { |*args| record(:sync, args) && replies.fetch(args.first) }
      Virt::Virsh.new(runner: runner).volume('/img/it.qcow2')
      assert_equal [[:sync, 'vol-pool', '/img/it.qcow2'], [:sync, 'vol-info', '--bytes', '/img/it.qcow2'],
                    [:sync, 'pool-info', '--bytes', 'default']], runner.calls
    end

    it 'answers nil for an image in no pool, and raises on any other failure' do
      runner = RecordingRunner.new
      runner.define_singleton_method(:sync) do |*|
        raise "Command 'virsh -q vol-pool /home/it.qcow2' failed with 1: error: failed to get vol '/home/it.qcow2'\n" \
              "error: Storage volume not found: no storage vol with matching path '/home/it.qcow2'"
      end
      assert_nil Virt::Virsh.new(runner: runner).volume('/home/it.qcow2')
      runner.define_singleton_method(:sync) { |*| raise 'error: failed to connect to the hypervisor' }
      assert_raises(RuntimeError) { Virt::Virsh.new(runner: runner).volume('/home/it.qcow2') }
    end

    it 'raises on a vol-info without the byte count' do
      assert_raises(RuntimeError) do
        Virt::Virsh.new.volume('/img/it.qcow2', 'default', "Capacity:       14,00 GiB\n", "Available: 1\n")
      end
    end

    it 'resize_volume spawns vol-resize with the bytes, never --shrink' do
      Helpers.setup_dummy_logger
      runner = RecordingRunner.new
      Virt::Virsh.new(runner: runner).resize_volume('/img/it.qcow2', 24.GiB)
      assert_equal [[:sync, 'vol-resize', '/img/it.qcow2', 24.GiB.to_s]], runner.calls
    end
  end

  context 'guest_storage' do
    it 'parses the guestinfo and guest files it is handed' do
      storage = Virt::Virsh.new.guest_storage('vt-ubuntu', File.read('spec/virt/guestinfo_vt-ubuntu.txt'),
                                              Helpers.vt_ubuntu_guest_files)
      assert_equal 'vda1', storage.disk('vda').partitions.last.name
    end

    it 'spawns guestinfo, and calls a guest that cannot answer Unavailable' do
      runner = RecordingRunner.new
      runner.define_singleton_method(:sync) do |*args|
        record(:sync, args)
        raise "Command 'virsh -q guestinfo' failed with 1: error: Guest agent is not responding: " \
              'QEMU guest agent is not connected'
      end
      assert_raises(Virt::GuestAgent::Unavailable) { Virt::Virsh.new(runner: runner).guest_storage('vt-ubuntu') }
      assert_equal [[:sync, 'guestinfo', 'vt-ubuntu', '--filesystem', '--disk']], runner.calls
    end

    it 'lets any other guestinfo failure through' do
      runner = RecordingRunner.new
      runner.define_singleton_method(:sync) { |*| raise 'error: boom' }
      error = assert_raises(RuntimeError) { Virt::Virsh.new(runner: runner).guest_storage('vt-ubuntu') }
      refute_kind_of Virt::GuestAgent::Unavailable, error
    end
  end

  it 'hostinfo' do
    info = Virt::Virsh.new.hostinfo(VIRSH_NODEINFO)
    assert_equal 'x86_64: 1/8/2', info.to_s
  end

  it 'domain_data' do
    result = Virt::Virsh.new.domain_data(File.read('spec/virt/domstats0.txt'), 0)
    assert_equal 2, result.size
    assert_equal 'ubuntu: CPUs: 8, RAM: 12G; running; actual 12G(rss=3.4G); guest: 241M/11G (2%) (unused=11G, disk_caches=37M)',
                 result['ubuntu'].to_s
    assert_equal 'win11: CPUs: 4, RAM: 8G; shut_off', result['win11'].to_s
    assert_equal 'sda: 18G/128G (13%); physical 18G (2% overhead)', result['win11'].disk_stat.join(',')
    assert_equal 'vda: 23G/64G (36%); physical 25G (9% overhead)', result['ubuntu'].disk_stat.join(',')
  end

  it 'parses the guest swap counters, converting KiB to bytes' do
    mem = Virt::Virsh.new.domain_data(VIRSH_DOMSTATS_SWAPPING, 0)['swapper'].mem_stat
    assert mem.swap_data_available?
    assert_equal 801_336 * 4096, mem.swap_out # the guest's pswpout, in bytes
    assert_equal 548_813 * 4096, mem.swap_in
  end

  it 'reports swap as unavailable when the guest omits the counters' do
    # a guest kernel without CONFIG_VM_EVENT_COUNTERS: everything else is still parsed
    stats = VIRSH_DOMSTATS_SWAPPING.lines.grep_v(/balloon\.swap_/).join
    mem = Virt::Virsh.new.domain_data(stats, 0)['swapper'].mem_stat
    refute mem.swap_data_available?
    assert mem.guest_data_available?
  end

  it 'cpu usage' do
    millis_since_epoch = 1_762_378_459_933
    result0 = Virt::Virsh.new.domain_data(File.read('spec/virt/domstats0.txt'), millis_since_epoch)['ubuntu']
    result1 = Virt::Virsh.new.domain_data(File.read('spec/virt/domstats1.txt'), millis_since_epoch + (10 * 1000))['ubuntu']
    assert_equal 22.51, result1.cpu_usage(result0).round(2)
    result2 = Virt::Virsh.new.domain_data(File.read('spec/virt/domstats2.txt'), millis_since_epoch + (20 * 1000))['ubuntu']
    assert_equal 181.43, result2.cpu_usage(result1).round(2)
  end

  # A VM whose name contains an apostrophe used to build `virsh setmem 'it's' …`, which
  # /bin/sh rejected with an unterminated-quote error. Every command that names a VM must
  # hand the name over as one argument, with no quoting of its own.
  context 'passes VM names as arguments, never as shell text' do
    let(:runner) { RecordingRunner.new }
    let(:hostile) { "it's a \"VM\"" }

    it 'set_actual' do
      Helpers.setup_dummy_logger
      Virt::Virsh.new(runner: runner).set_actual(hostile, 1.GiB)
      assert_equal [[:sync, 'setmem', hostile, '1048576']], runner.calls
    end

    it 'the power commands' do
      virsh = Virt::Virsh.new(runner: runner)
      virsh.start(hostile)
      virsh.shutdown(hostile)
      virsh.reboot(hostile)
      virsh.reset(hostile)
      virsh.force_off(hostile)
      assert_equal [[:async, 'start', hostile], [:async, 'shutdown', hostile],
                    [:sync, 'reboot', hostile], [:sync, 'reset', hostile],
                    [:sync, 'destroy', hostile]], runner.calls
    end

    it 'set_mem_stats_period' do
      Virt::Virsh.new(runner: runner).set_mem_stats_period(hostile, 2)
      assert_equal [[:async, 'dommemstat', hostile, '--period', '2', '--live']], runner.calls
    end
  end
end
