# frozen_string_literal: true

require_relative '../spec_helper'

describe Virt::DiskStat do
  it 'to_s' do
    ds = Virt::DiskStat.new('vda', 68_719_476_736, 20_452_605_952, '/var/lib/libvirt/images/win11.qcow2')
    assert_equal 'vda: 19G on host, of 64G', ds.to_s
  end
end
