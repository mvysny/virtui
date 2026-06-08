# frozen_string_literal: true

require_relative '../spec_helper'
require 'timecop'

describe Virt::Cache do
  it 'smokes' do
    Virt::Cache.new(Virt::VMEmulator.new, PcEmulator.new)
  end

  context 'total_vm_rss_usage' do
    it 'is 0 for no VMs' do
      assert_equal 0, Virt::Cache.new(Virt::VMEmulator.new, PcEmulator.new).total_vm_rss_usage
    end

    it 'is calculated properly' do
      Timecop.freeze(Time.now) do
        assert_equal 2_415_919_104, Virt::Cache.new(Virt::VMEmulator.demo, PcEmulator.new).total_vm_rss_usage
      end
    end
  end

  context 'running?' do
    it 'works on demo data' do
      c = Virt::Cache.new(Virt::VMEmulator.demo, PcEmulator.new)
      assert c.running?('Ubuntu')
      assert c.running?('win11')
      assert !c.running?('BASE')
      assert !c.running?('non-existing-cm')
    end
  end
end
