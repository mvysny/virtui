# frozen_string_literal: true

require_relative '../spec_helper'

# The fixtures are `virsh -q dumpxml` as recorded on the author's host (2026-10-24):
# vt-ubuntu and vt-bios are the running test VMs of bin/test-vms.sh, and vt-fixture a domain
# defined only to be dumped (never started), carrying what those two lack.
describe Virt::DomainConfig do
  def config(name) = Virt::DomainConfig.from_xml(File.read("spec/virt/dumpxml_#{name}.xml"))

  context 'a UEFI + Secure Boot + TPM guest, live' do
    let(:c) { config('vt-ubuntu') }

    it 'reads the machine and the declared OS' do
      assert_equal 'vt-ubuntu', c.name
      assert_equal '4878e503-790a-4b94-a1fb-c3205aeb7ea0', c.uuid
      assert_equal %w[kvm x86_64 pc-q35-10.2], [c.hypervisor, c.arch, c.machine]
      assert_equal 'http://ubuntu.com/ubuntu/24.04', c.guest_os.osinfo_id
      assert c.guest_os.linux?
    end

    it 'reads CPU and memory' do
      assert_equal [2, 2, 'host-passthrough', nil, nil], [c.vcpus, c.vcpus_online, c.cpu_mode, c.cpu_model, c.topology]
      assert_equal 4.GiB, c.max_memory
      assert_equal %w[memfd shared], c.memory_backing
    end

    it 'reads the balloon and the connected agent' do
      assert_equal Virt::DomainConfig::Balloon.new('virtio', false, true), c.balloon
      assert_equal :connected, c.agent
    end

    # Auto-selected UEFI arrives as both firmware='efi' and the expanded explicit loader.
    it 'reads the firmware' do
      assert_equal :uefi, c.firmware
      assert c.secure_boot
      assert_equal '/usr/share/OVMF/OVMF_CODE_4M.ms.fd', c.loader
      assert_equal '/var/lib/libvirt/qemu/nvram/vt-ubuntu_VARS.fd', c.nvram
      assert_equal %w[hd], c.boot
      assert_equal Virt::DomainConfig::Tpm.new('tpm-crb', 'emulator', '2.0'), c.tpm
    end

    it 'reads a qcow2, a shareable raw disk and a read-only CD-ROM' do
      assert_equal [Virt::DomainConfig::Disk.new('vda', 'virtio', 'disk', 'file', 'qcow2',
                                                 '/var/lib/libvirt/images/vt-ubuntu.qcow2', false, false),
                    Virt::DomainConfig::Disk.new('vdb', 'virtio', 'disk', 'file', 'raw',
                                                 '/var/lib/libvirt/images/vt-shared.raw', true, false),
                    Virt::DomainConfig::Disk.new('sda', 'sata', 'cdrom', 'file', 'raw',
                                                 '/var/lib/libvirt/images/vt-seed.iso', false, true)], c.disks
    end

    it 'reads the virtiofs share, the network, the display and the other devices' do
      assert_equal [Virt::DomainConfig::Filesystem.new('virtiofs', '/home/mavi/vt-share', 'share')], c.filesystems
      # The live XML also names the bridge; the network is what the definition says.
      assert_equal [Virt::DomainConfig::Interface.new('network', 'default', 'virtio', '52:54:00:cc:79:16')],
                   c.interfaces
      assert_equal [Virt::DomainConfig::Graphics.new('spice', '127.0.0.1', 5900)], c.graphics
      assert_equal %w[virtio], c.video
      assert_empty c.hostdevs
      assert_equal ['sound ich9', 'redirdev spicevmc', 'redirdev spicevmc', 'watchdog itco', 'rng virtio'],
                   c.other_devices
    end
  end

  context 'a BIOS guest with no agent and no declared OS' do
    let(:c) { config('vt-bios') }

    it 'reads BIOS, no agent channel and an unknown OS' do
      assert_equal [:bios, false, nil, nil, nil], [c.firmware, c.secure_boot, c.loader, c.nvram, c.tpm]
      assert_nil c.agent
      assert_equal Virt::GuestOS::UNKNOWN, c.guest_os
      assert_equal 256.MiB, c.max_memory
      assert_empty c.memory_backing
      assert_empty c.filesystems
      assert_empty c.other_devices
    end
  end

  context 'a shut-off domain with pool, network and block disks, passthrough and no balloon' do
    let(:c) { config('vt-fixture') }

    it 'reads hotplug vCPUs, the topology, the custom model and hugepages' do
      assert_equal [4, 2], [c.vcpus, c.vcpus_online]
      assert_equal %w[custom Skylake-Client], [c.cpu_mode, c.cpu_model]
      assert_equal Virt::DomainConfig::Topology.new(1, 2, 2), c.topology
      assert_equal %w[hugepages], c.memory_backing
    end

    it "reads model='none' as no balloon" do
      assert_nil c.balloon
    end

    it 'takes the boot order from the devices when <os> names none' do
      assert_equal %w[sda vda], c.boot
    end

    it 'locates a volume, a network disk, a block device and an empty CD-ROM' do
      assert_equal ['default/vt-fixture.qcow2', 'nbd://nbd.example.com:10809/export1', '/dev/vt-nonexistent/shared',
                    nil], c.disks.map(&:source)
      assert_equal %w[volume network block file], c.disks.map(&:type)
      assert c.disks[2].shareable
    end

    it 'reads 9p, a bridge, macvtap and passthrough' do
      assert_equal [Virt::DomainConfig::Filesystem.new('9p', '/srv/vt-9p', 'hostshare')], c.filesystems
      assert_equal ['br0', 'eth0 (bridge)'], c.interfaces.map(&:source)
      assert_equal [Virt::DomainConfig::Hostdev.new('pci', '0000:01:00.0'),
                    Virt::DomainConfig::Hostdev.new('usb', '046d:c52b')], c.hostdevs
    end

    # Defined with passwd='sekrit'; plain dumpxml leaves it out, which is why domain_config
    # never asks for --security-info.
    it 'has no assigned port and no VNC password' do
      assert_equal [Virt::DomainConfig::Graphics.new('vnc', '0.0.0.0', nil)], c.graphics
      refute File.read('spec/virt/dumpxml_vt-fixture.xml').include?('passwd')
    end
  end

  it 'reads a shut-off domain’s agent channel, which has no state, as :unknown' do
    xml = File.read('spec/virt/dumpxml_vt-ubuntu.xml').sub(" state='connected'", '')
    assert_equal :unknown, Virt::DomainConfig.from_xml(xml).agent
  end

  it 'raises on what is not a domain definition' do
    assert_raises(ArgumentError) { Virt::DomainConfig.from_xml('error: failed to get domain') }
    assert_raises(ArgumentError) { Virt::DomainConfig.from_xml('<network><name>default</name></network>') }
    assert_raises(ArgumentError) { Virt::DomainConfig.from_xml('<domain><name>x</') }
  end

  it 'raises on a size in a unit dumpxml never writes' do
    xml = File.read('spec/virt/dumpxml_vt-bios.xml').sub("<memory unit='KiB'>262144", "<memory unit='MiB'>256")
    assert_raises(ArgumentError) { Virt::DomainConfig.from_xml(xml) }
  end
end
