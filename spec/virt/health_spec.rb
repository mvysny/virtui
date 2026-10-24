# frozen_string_literal: true

require_relative '../spec_helper'

describe Virt::Health do
  def config(name) = Virt::DomainConfig.from_xml(File.read("spec/virt/dumpxml_#{name}.xml"))

  # @param files [Hash{String => String}] the guest's files; a path missing here does not exist
  # @return [Virt::Health]
  def assess(live, inactive, guest, files = {})
    missing = ->(path) { raise Virt::GuestAgent::Unavailable, "#{path}: No such file or directory" }
    described_class.assess(live, inactive, guest, read_file: ->(path) { files.fetch(path, &missing) },
                                                  file_exist: ->(path) { files.key?(path) })
  end

  def rows(health) = health.findings.map { [_1.severity, _1.subject] }

  def finding(health, subject) = health.findings.find { _1.subject == subject }

  # The recorded live definition predates `discard=unmap` on vda, the inactive one has it;
  # the guest has ext4 on LVM on LUKS without allow-discards at /mnt/hc.
  context 'vt-ubuntu with discard pending on vda, and a LUKS disk' do
    let(:health) do
      assess(config('vt-ubuntu'), config('vt-ubuntu-inactive'), Helpers.vt_ubuntu_luks_storage,
             Helpers.vt_ubuntu_luks_guest_files)
    end

    it 'checks the writable disks, not the CD-ROM' do
      assert_equal [[:ok, 'balloon'], [:ok, 'agent'], [:note, 'vda'], [:note, 'vdb'], [:warning, '/mnt/hc']], rows(health)
    end

    it 'says a discard set for the next power-on is waiting for it' do
      assert_includes finding(health, 'vda').text, 'takes effect once the VM is powered off and on'
      assert_nil finding(health, 'vda').fix
    end

    it 'notes a shared disk without discard, with the command that sets it' do
      vdb = finding(health, 'vdb')
      assert_includes vdb.text, 'shared'
      assert_equal 'virt-xml vt-ubuntu --edit target=vdb --disk discard=unmap, then power it off and on', vdb.fix
    end

    # Both layers read 0, but the LV only inherits it from the LUKS mapping beneath.
    it 'blames the lowest device-mapper layer that blocks discard' do
      assert_equal 'hccrypt (dm-0) blocks discard', finding(health, '/mnt/hc').text
    end

    # No disk passes discards in the live definition yet, so whether the guest trims is moot.
    it 'does not judge periodic trim while no disk passes discards' do
      assert_nil finding(health, 'trim')
    end
  end

  context 'vt-ubuntu once discard=unmap is applied' do
    let(:live) { config('vt-ubuntu-inactive') }

    it 'passes vda, and passes trim on the fstrim.timer symlink' do
      health = assess(live, live, Helpers.vt_ubuntu_storage, Helpers.vt_ubuntu_guest_files.merge(
                                                               Virt::Health::TRIM_TIMER => "[Unit]\n"
                                                             ))
      assert_equal [[:ok, 'balloon'], [:ok, 'agent'], [:ok, 'vda'], [:note, 'vdb'], [:ok, 'trim']], rows(health)
      assert_equal 'discards reach the image', finding(health, 'vda').text
    end

    it 'names the filesystems no trim reaches without the timer' do
      files = Helpers.vt_ubuntu_guest_files.merge('/proc/self/mounts' => File.read('spec/virt/guest_mounts.txt'))
      trim = finding(assess(live, live, Helpers.vt_ubuntu_storage, files), 'trim')
      assert_equal :note, trim.severity
      assert_includes trim.text, '/boot, /boot/efi not mounted with discard'
      assert_equal 'systemctl enable --now fstrim.timer, in the guest', trim.fix
    end

    it 'points unused space after the root partition at Grow root filesystem' do
      files = Helpers.vt_ubuntu_guest_files
      grown = files.merge('/proc/partitions' => files['/proc/partitions'].sub('14680064 vda', '16777216 vda'))
      storage = Virt::GuestStorage.parse(File.read('spec/virt/guestinfo_vt-ubuntu.txt')) { grown.fetch(_1) }
      vda = assess(live, live, storage, grown.merge(Virt::Health::TRIM_TIMER => '')).findings.last
      assert_equal [:note, 'vda', '2.0G unused after vda1', 'M → Grow root filesystem'],
                   [vda.severity, vda.subject, vda.text, vda.fix]
    end
  end

  context 'the definition alone' do
    it 'judges a stopped VM, and skips the guest until it runs' do
      stopped = config('vt-ubuntu-inactive')
      health = assess(stopped, stopped, nil)
      assert_equal [[:ok, 'balloon'], [:ok, 'agent'], [:ok, 'vda'], [:note, 'vdb'], [:skipped, 'guest']], rows(health)
      assert_equal 'not running: start the VM for the guest checks', finding(health, 'guest').text
    end

    # The vt-bios fixture is a running VM, with no OS and no agent channel.
    it 'judges a VM without an agent, and says why the guest goes unchecked' do
      bios = config('vt-bios')
      health = assess(bios, bios, nil)
      assert_equal 'cannot answer: no guest agent channel', finding(health, 'guest').text
      assert_equal [[:note, 'balloon'], [:warning, 'agent'], [:warning, 'sda'], [:skipped, 'guest']], rows(health)
      assert_includes finding(health, 'agent').fix, '--add-device --channel unix,target.type=virtio'
      assert_includes finding(health, 'balloon').fix, 'freePageReporting=on'
    end

    it 'warns about a VM with no balloon' do
      fixture = config('vt-fixture')
      balloon = finding(assess(fixture, fixture, nil), 'balloon')
      assert_equal :warning, balloon.severity
      assert_includes balloon.text, 'cannot resize'
    end
  end

  it 'skips the guest checks with the reason the guest gave' do
    live = config('vt-ubuntu')
    assert_equal 'cannot answer: QEMU guest agent is not connected',
                 finding(assess(live, live, 'QEMU guest agent is not connected'), 'guest').text
  end

  it 'skips the guest checks when the guest stops answering midway' do
    live = config('vt-ubuntu')
    files = Helpers.vt_ubuntu_luks_guest_files.except('/sys/class/block/dm-1/queue/discard_max_bytes')
    health = assess(live, live, Helpers.vt_ubuntu_luks_storage, files)
    assert_equal [:skipped, 'guest'], rows(health).last
    assert_nil finding(health, '/mnt/hc')
  end
end
