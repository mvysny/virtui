# frozen_string_literal: true

require_relative '../spec_helper'

describe Virt::MemoryStat do
  # actual, unused, available, usable, disk_caches, rss, last_updated
  def with_guest = Virt::MemoryStat.new(8.GiB, 4.GiB, 8.GiB, 6.GiB, 1.GiB, 3.GiB, 1000)
  def without_guest = Virt::MemoryStat.new(8.GiB, nil, nil, nil, nil, 3.GiB, 1000)

  it 'reports guest data as available only when every guest field is present' do
    assert with_guest.guest_data_available?
    refute without_guest.guest_data_available?
  end

  it 'exposes guest and host views as ResourceUsage' do
    assert_equal '2G/8G (25%)', with_guest.guest_mem.to_s # used = available - usable
    assert_equal '3G/8G (37%)', with_guest.host_mem.to_s # used = rss out of actual
  end

  it 'has no guest_mem when ballooning is unavailable' do
    assert_nil without_guest.guest_mem
    assert_equal '3G/8G (37%)', without_guest.host_mem.to_s # host view still works
  end

  it 'to_s includes guest detail only when available' do
    assert_equal 'actual 8G(rss=3G); guest: 2G/8G (25%) (unused=4G, disk_caches=1G)', with_guest.to_s
    assert_equal 'actual 8G(rss=3G)', without_guest.to_s
  end
end
