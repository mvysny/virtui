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
end
