# frozen_string_literal: true

require_relative '../spec_helper'

describe System::DiskUsage do
  def usage = System::DiskUsage.new(ResourceUsage.new(100.GiB, 60.GiB), 12.GiB, ['/a.qcow2'])

  it 'to_s summarizes filesystem usage and the VM share' do
    assert_equal '40G/100G (40%) (12G VMs)', usage.to_s
  end

  it 'add folds another qcow2 file into vm_usage without mutating the original' do
    added = usage.add(5.GiB, '/b.qcow2')
    assert_equal 17.GiB, added.vm_usage
    assert_equal ['/a.qcow2', '/b.qcow2'], added.qcow2_files
    assert_equal 12.GiB, usage.vm_usage # original untouched
  end
end
