# frozen_string_literal: true

require_relative '../spec_helper'
require 'timecop'

describe Virt::BallooningVM do
  it 'doesnt attempt to control stopped VM' do
    virt = Virt::VMEmulator.new
    virt.allow_set_actual = false
    virt.add(Virt::VMEmulator::VM.simple('vm0'))
    virt_cache = Virt::Cache.new(virt, System::Emulator.new)

    b = Virt::BallooningVM.new(virt_cache, 'vm0')
    b.update
    Timecop.freeze(Time.now + 200) do
      b.update
    end
  end

  it 'increases memory even though in backoff' do
    virt = Virt::VMEmulator.new
    virt.allow_set_actual = false
    vm = virt.add(Virt::VMEmulator::VM.simple('vm0'))
    vm.start
    virt_cache = Virt::Cache.new(virt, System::Emulator.new)
    assert_equal 2.GiB, vm.to_mem_stat.actual

    b = Virt::BallooningVM.new(virt_cache, 'vm0')
    b.min_actual = 2.GiB
    b.update
    # should issue no update - the VM is just starting
    assert_equal 'only 0% memory used, but backing off for 20.0s; d=0', b.status.to_s

    virt.allow_set_actual = true
    Timecop.freeze(Time.now + 10) do
      # overshoot the used memory
      vm.memory_app = 4.GiB
      virt_cache.update
      # ballooning should issue the memory_resize command immediately
      b.update

      assert_equal 'VM reports 1.9G (100%), updating actual by 30% to 2.6G; d=30', b.status.to_s
      assert_equal 2_791_728_742, vm.to_mem_stat.actual
    end
  end

  it 'does not act on stale guest data, even at high usage' do
    now = 1_762_378_459_933
    info = Virt::DomainInfo.new('vm0', 2, 16.GiB)
    # 7G of 8G used (87%) would normally trigger an increase, but last-update is an hour old.
    mem = Virt::MemoryStat.new(8.GiB, 0, 8.GiB, 1.GiB, 0, 4.GiB, (now / 1000) - 3600)
    vmcache = Virt::Cache::VMCache.diff(nil, Virt::DomainData.new(info, :running, now, 0, mem, []))
    assert vmcache.stale?

    # Minimal Cache stand-in exposing only what BallooningVM#update reads.
    fake_cache = Struct.new(:mem, :vmcache) do
      def memstat(_vmid) = mem
      def running?(_vmid) = true
      def cache(_vmid) = vmcache
    end.new(mem, vmcache)

    b = Virt::BallooningVM.new(fake_cache, 'vm0')
    b.update
    assert_equal 'guest memory data is stale, doing nothing; d=0', b.status.to_s
  end
end
