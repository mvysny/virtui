# frozen_string_literal: true

require_relative '../spec_helper'

describe Virt::DiskStat do
  it 'to_s' do
    ds = Virt::DiskStat.new('vda', 20_348_669_952, 68_719_476_736, 20_452_605_952, '/var/lib/libvirt/images/win11.qcow2')
    assert_equal 'vda: 19G/64G (29%); physical 19G (0% overhead)', ds.to_s
    ds = Virt::DiskStat.new('sda', 18_022_993_920, 137_438_953_472, 23_508_287_488, '/var/lib/libvirt/images/win11.qcow2')
    assert_equal 'sda: 17G/128G (13%); physical 22G (30% overhead)', ds.to_s
  end
end
