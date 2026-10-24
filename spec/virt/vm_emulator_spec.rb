# frozen_string_literal: true

require_relative '../spec_helper'

describe Virt::VMEmulator do
  it 'new_empty' do
    assert Virt::VMEmulator.new.domain_data.empty?
    assert !Virt::VMEmulator.new.hostinfo.nil?
  end

  it 'smoke_virtcache' do
    Virt::Cache.new(Virt::VMEmulator.new, System::Emulator.new)
  end

  it 'virtcache_with_some_vms' do
    e = Virt::VMEmulator.new
    e.add(Virt::VMEmulator::VM.simple('vm0')).start
    e.add(Virt::VMEmulator::VM.simple('vm1'))
    assert_equal 2, e.domain_data.size
    c = Virt::Cache.new(e, System::Emulator.new)
    assert_equal %w[vm0 vm1], c.domains
  end

  it 'set_active_on_running_vm' do
    e = Virt::VMEmulator.new
    e.add(Virt::VMEmulator::VM.simple('vm0')).start
    e.set_actual 'vm0', 3.GiB
    assert_equal 3.GiB, e.vm('vm0').to_mem_stat.actual
  end

  it 'add_raises_on_duplicate_name' do
    e = Virt::VMEmulator.new
    e.add(Virt::VMEmulator::VM.simple('vm0'))
    assert_raises(RuntimeError) { e.add(Virt::VMEmulator::VM.simple('vm0')) }
  end

  it 'delete_removes_vm' do
    e = Virt::VMEmulator.new
    e.add(Virt::VMEmulator::VM.simple('vm0'))
    e.delete('vm0')
    assert e.domain_data.empty?
  end

  it 'vm_returns_nil_for_unknown_name' do
    assert_nil Virt::VMEmulator.new.vm('unknown')
  end

  it 'set_actual_raises_when_disabled' do
    e = Virt::VMEmulator.new
    e.allow_set_actual = false
    e.add(Virt::VMEmulator::VM.simple('vm0')).start
    assert_raises(RuntimeError) { e.set_actual('vm0', 3.GiB) }
  end

  it 'domain_data_reflects_running_state' do
    e = Virt::VMEmulator.new
    e.add(Virt::VMEmulator::VM.simple('vm0')).start
    e.add(Virt::VMEmulator::VM.simple('vm1'))
    dd = e.domain_data
    assert_equal :running, dd['vm0'].state
    assert_equal :shut_off, dd['vm1'].state
    assert !dd['vm0'].mem_stat.nil?
    assert_nil dd['vm1'].mem_stat
  end

  it 'domain_data_disk_stat' do
    e = Virt::VMEmulator.new
    e.add(Virt::VMEmulator::VM.simple('vm0')).start
    disk = e.domain_data['vm0'].disk_stat.first
    assert_equal 'vda', disk.name
    assert_equal 64.GiB, disk.allocation
    assert_equal 128.GiB, disk.capacity
  end

  it 'demo_creates_correct_vm_states' do
    dd = Virt::VMEmulator.demo.domain_data
    assert_equal 4, dd.size
    assert_equal :running, dd['Ubuntu'].state
    assert_equal :running, dd['win11'].state
    assert_equal :shut_off, dd['BASE'].state
    assert_equal :shut_off, dd['Fedora'].state
  end

  it 'demo declares three different guest OS families' do
    e = Virt::VMEmulator.demo
    assert e.guest_os('Ubuntu').linux?
    assert e.guest_os('Fedora').linux?
    assert e.guest_os('win11').windows?
    assert_equal Virt::GuestOS::UNKNOWN, e.guest_os('BASE')
  end

  it 'guest_os answers UNKNOWN for a VM it does not know' do
    assert_equal Virt::GuestOS::UNKNOWN, Virt::VMEmulator.new.guest_os('nope')
  end

  it 'domain_config gives each demo VM a definition its declared OS suggests' do
    e = Virt::VMEmulator.demo
    win11 = e.domain_config('win11')
    assert_equal [:uefi, true, :connected], [win11.firmware, win11.secure_boot, win11.agent]
    assert_equal 16.GiB, win11.max_memory
    refute_nil win11.tpm
    base = e.domain_config('BASE')
    assert_equal [:bios, nil, nil], [base.firmware, base.agent, base.tpm]
    assert_equal :unknown, e.domain_config('Fedora').agent, 'a shut-off VM has no channel state'
  end

  it 'guest_storage gives a Linux guest the easy layout: / last, room after it' do
    vda = Virt::VMEmulator.demo.guest_storage('Ubuntu').disk('vda')
    assert_equal Virt::VMEmulator::DISK_CAPACITY, vda.size
    assert_equal([%w[vda15 /boot/efi], %w[vda1 /]], vda.partitions.map { [_1.name, _1.filesystems.first.mountpoint] })
    assert_equal 128.GiB - 107.MiB - 100.GiB, vda.free_tail
  end

  it 'guest_storage gives a Windows guest one volume and no partitions' do
    vda = Virt::VMEmulator.demo.guest_storage('win11').disk('vda')
    assert_equal [[], ['C:\\']], [vda.partitions, vda.filesystems.map(&:mountpoint)]
  end

  it 'guest_storage calls a stopped or agent-less guest Unavailable' do
    e = Virt::VMEmulator.demo
    assert_raises(Virt::GuestAgent::Unavailable) { e.guest_storage('Fedora') }
    e.vm('BASE').start
    assert_raises(Virt::GuestAgent::Unavailable) { e.guest_storage('BASE') }
  end

  it 'domain_config raises for a VM it does not know' do
    assert_raises(RuntimeError) { Virt::VMEmulator.new.domain_config('nope') }
  end
end
