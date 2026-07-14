# frozen_string_literal: true

require_relative '../spec_helper'

describe Virt::Ballooning do
  # log_statuses writes through $log, so every #update needs a logger installed.
  before { @log = Helpers.setup_dummy_logger }

  # A Ballooning over the demo fleet: BASE + Fedora shut off, Ubuntu + win11 running.
  # @return [Array(Virt::Cache, Virt::Ballooning)]
  def build
    cache = Virt::Cache.new(Virt::VMEmulator.demo, System::Emulator.new)
    [cache, Virt::Ballooning.new(cache)]
  end

  it 'reports safe defaults for an unknown VM' do
    _cache, b = build
    b.update
    assert_nil b.status('does-not-exist')
    refute b.enabled?('does-not-exist')
  end

  it 'creates a ballooner for every VM on update' do
    cache, b = build
    b.update
    cache.domains.each { |vm| refute_nil b.status(vm), vm }
  end

  it 'has ballooning enabled by default for each VM' do
    _cache, b = build
    b.update
    assert b.enabled?('Ubuntu')
  end

  it 'enabled toggles a single VM on and off' do
    _cache, b = build
    b.update
    b.enabled('Ubuntu', false)
    refute b.enabled?('Ubuntu')
    b.enabled('Ubuntu', true)
    assert b.enabled?('Ubuntu')
  end

  it 'toggle_enable flips the current state' do
    _cache, b = build
    b.update
    assert b.enabled?('Ubuntu')
    b.toggle_enable('Ubuntu')
    refute b.enabled?('Ubuntu')
    b.toggle_enable('Ubuntu')
    assert b.enabled?('Ubuntu')
  end

  it 'reuses each VM ballooner across updates, keeping per-VM state' do
    _cache, b = build
    b.update
    b.toggle_enable('Ubuntu') # disable
    b.update                  # a fresh ballooner here would reset it back to enabled
    refute b.enabled?('Ubuntu')
  end

  it 'debug-logs only the VMs that were running' do
    _cache, b = build
    b.update
    out = @log.string
    assert out.include?('Ubuntu'), out
    assert out.include?('win11'), out
    refute out.include?('BASE'), out
    refute out.include?('Fedora'), out
  end
end
