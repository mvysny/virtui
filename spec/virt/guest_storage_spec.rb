# frozen_string_literal: true

require_relative '../spec_helper'

describe Virt::GuestStorage do
  def vt_ubuntu = Helpers.vt_ubuntu_storage

  it 'lists the partitions in disk order, not by number' do
    vda = vt_ubuntu.disk('vda')
    assert_equal '/dev/vda', vda.device
    assert_equal 14.GiB, vda.size
    assert_equal %w[vda13 vda14 vda15 vda1], vda.partitions.map(&:name)
    assert_equal [2_324_480 * 512, 13_517_807.KiB], [vda.partitions.last.start, vda.partitions.last.size]
  end

  it 'puts each filesystem under the partition it is mounted from' do
    vda = vt_ubuntu.disk('vda')
    assert_equal([['/boot'], [], ['/boot/efi'], ['/']], vda.partitions.map { _1.filesystems.map(&:mountpoint) })
    root = vda.partitions.last.filesystems.first
    assert_equal ['vda1', 'ext4', 13_329_502_208, 3_466_166_272], [root.name, root.fstype, root.total, root.used]
    assert_empty vda.filesystems
  end

  # What stays at the end of a GPT disk whose last partition fills it: the 33-sector backup
  # table, plus the half KiB /proc/partitions rounds vda1's odd sector count down by.
  it 'measures the space after the last partition' do
    assert_equal 17_408, vt_ubuntu.disk('vda').free_tail
  end

  it 'keeps the disks with no partitions, and knows no free tail for them' do
    storage = vt_ubuntu
    assert_equal %w[vda sda vdb], storage.disks.map(&:target)
    assert_equal(['/dev/vdb', 1.GiB, [], nil], storage.disk('vdb').then { [_1.device, _1.size, _1.partitions, _1.free_tail] })
    assert_nil storage.disk('vdc')
  end

  # The emulator's Windows layout's shape: a volume on no partition, and no /dev name to read
  # geometry for.
  it 'puts a filesystem on no known partition under its disk, and reads no guest file for it' do
    guestinfo = <<~TEXT
      fs.count            : 1
      fs.0.name           : \\\\?\\Volume{0f2c}\\
      fs.0.mountpoint     : C:\\
      fs.0.fstype         : NTFS
      fs.0.disk.count     : 1
      fs.0.disk.0.alias   : vda
      disk.count          : 1
      disk.0.name         : \\\\.\\PhysicalDrive0
      disk.0.partition    : no
      disk.0.alias        : vda
    TEXT
    vda = described_class.parse(guestinfo) { flunk "read #{_1}" }.disk('vda')
    assert_equal([['C:\\', 'NTFS', nil]], vda.filesystems.map { [_1.mountpoint, _1.fstype, _1.total] })
    assert_nil vda.size
  end

  it 'finds no mappers under a plain partition' do
    assert_empty vt_ubuntu.disk('vda').partitions.last.filesystems.first.mappers
  end

  # vt-ubuntu with a hot-plugged vdc holding ext4 on LVM on LUKS, mounted at /mnt/hc.
  it 'follows a filesystem down its LVM volume and LUKS mapping' do
    vdc = Helpers.vt_ubuntu_luks_storage.disk('vdc')
    assert_empty vdc.partitions
    hc = vdc.filesystems.first
    assert_equal %w[/mnt/hc dm-1], [hc.mountpoint, hc.name]
    assert_equal [Virt::GuestStorage::Mapper.new('dm-1', 'hcvg-hclv'), Virt::GuestStorage::Mapper.new('dm-0', 'hccrypt')],
                 hc.mappers
    assert_equal 'hccrypt (dm-0)', hc.mappers.last.to_s
  end

  it 'raises on a line that is not key : value' do
    assert_raises(RuntimeError) { described_class.parse("fs.count : 0\nnonsense\n") { '' } }
  end

  it 'raises on a start that is not a sector count' do
    files = Helpers.vt_ubuntu_guest_files.merge('/sys/class/block/vda1/start' => "oops\n")
    error = assert_raises(RuntimeError) do
      described_class.parse(File.read('spec/virt/guestinfo_vt-ubuntu.txt')) { files.fetch(_1) }
    end
    assert_includes error.message, '/dev/vda1'
  end
end
