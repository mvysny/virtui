# frozen_string_literal: true

require_relative '../spec_helper'

module Tuile
  describe UI::VMInfoWindow do
    before { Screen.fake }
    after { Screen.close }

    def config(name) = Virt::DomainConfig.from_xml(File.read("spec/virt/dumpxml_#{name}.xml"))

    # @return [Array<String>] the window's text rows, styling stripped
    def text_of(window) = window.instance_variable_get(:@view).text.to_s.lines.map(&:rstrip)

    it 'shows a fully featured guest' do
      disks = [Virt::DiskStat.new('vda', 40.GiB, 3.GiB, nil), Virt::DiskStat.new('vdb', 1.GiB, 0, nil)]
      assert_equal <<~TEXT.lines.map(&:rstrip), text_of(UI::VMInfoWindow.new(config('vt-ubuntu'), disks))
        OS        linux — http://ubuntu.com/ubuntu/24.04
        Machine   x86_64, pc-q35-10.2, KVM
        Starts    by hand — no autostart
        UUID      4878e503-790a-4b94-a1fb-c3205aeb7ea0

        CPU       2 vCPUs, host-passthrough
        Memory    4G max (the balloon's ceiling), memfd, shared
        Balloon   virtio, free page reporting
        Agent     qemu-guest-agent channel, connected

        Firmware  UEFI, Secure Boot
                  /usr/share/OVMF/OVMF_CODE_4M.ms.fd
        NVRAM     /var/lib/libvirt/qemu/nvram/vt-ubuntu_VARS.fd
        Boot      hd
        TPM       2.0, emulator, tpm-crb

        Disks
          vda  virtio  qcow2  40G
               /var/lib/libvirt/images/vt-ubuntu.qcow2
          vdb  virtio  raw     1G  shared
               /var/lib/libvirt/images/vt-shared.raw
          sda  sata    cdrom       read-only
               /var/lib/libvirt/images/vt-seed.iso
        Shared folders
          virtiofs  /home/mavi/vt-share  as tag "share"
        Network
          virtio  network  default  52:54:00:cc:79:16
        Display
          spice on 127.0.0.1:5900
          video virtio
        Other
          sound ich9, redirdev spicevmc ×2, watchdog itco, rng virtio
      TEXT
    end

    it 'says when the VM starts with the host' do
      text = text_of(UI::VMInfoWindow.new(config('vt-bios'), autostart: true))
      assert_includes text, 'Starts    with the host (autostart)'
    end

    it 'says what a missing balloon and agent cost, and leaves empty sections out' do
      text = text_of(UI::VMInfoWindow.new(config('vt-fixture')))
      assert_includes text, 'Memory    2G max, hugepages'
      assert_includes text, 'Balloon   none — virtui cannot resize this VM'
      assert_includes text, 'Agent     no channel — no swap level for this VM'
      assert_includes text, 'CPU       4 vCPUs (2 online) — 1 socket × 2 cores × 2 threads, Skylake-Client'
      assert_includes text, 'OS        unknown — no osinfo declaration'
      refute(text.any? { _1.start_with?('NVRAM', 'TPM') }, text.join("\n"))
    end

    it 'shows pool volumes, empty drives, unassigned ports and passthrough' do
      text = text_of(UI::VMInfoWindow.new(config('vt-fixture')))
      assert_includes text, '       volume default/vt-fixture.qcow2'
      assert_includes text, '  sda  sata    cdrom    read-only'
      assert_includes text, '       (no media)'
      assert_includes text, '  vnc on 0.0.0.0 (port assigned at start)'
      assert_includes text, '  PCI 0000:01:00.0'
      assert_includes text, '  USB 046d:c52b'
      assert_includes text, 'Boot      sda, vda'
    end

    it "shows the guest's partitions in disk order under their disk, with what is mounted from each" do
      disks = [Virt::DiskStat.new('vda', 14.GiB, 0, nil)]
      text = text_of(UI::VMInfoWindow.new(config('vt-ubuntu'), disks, Helpers.vt_ubuntu_storage))
      at = text.index('       /var/lib/libvirt/images/vt-ubuntu.qcow2')
      assert_equal <<~TEXT.lines.map { "       #{_1.rstrip}" }, text[at, 5]
        /var/lib/libvirt/images/vt-ubuntu.qcow2
        vda13  1023M  ext4  /boot      108M / 921M  12%
        vda14     4M
        vda15   106M  vfat  /boot/efi  6.3M / 104M   7%
        vda1     13G  ext4  /          3.2G / 12G   27%
      TEXT
      # The 17 KiB a full GPT disk keeps at its end is no free space anyone left.
      refute(text.any? { _1.strip.start_with?('free') }, text.join("\n"))
    end

    it 'shows the space left after the last partition' do
      vda = Virt::VMEmulator.demo.guest_storage('Ubuntu')
      text = text_of(UI::VMInfoWindow.new(config('vt-ubuntu'), [], vda))
      assert_includes text, '       free    28G'
    end

    it 'says why the guest could not describe its disks' do
      text = text_of(UI::VMInfoWindow.new(config('vt-ubuntu'), [], 'Guest agent is not responding'))
      assert_includes text, '  The guest did not say how its disks are laid out: Guest agent is not responding'
    end

    it 'opens as a popup titled with the VM' do
      Screen.instance.content = Component::Label.new
      popup = UI::VMInfoWindow.open(config('vt-bios'))
      assert_equal [popup], Screen.instance.popups
      assert_equal 'vt-bios', popup.content.caption.to_s
    end
  end
end
