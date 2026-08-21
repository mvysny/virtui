# frozen_string_literal: true

require_relative '../spec_helper'

describe Virt::MemoryStat do
  # actual, unused, available, usable, disk_caches, swap_in, swap_out, rss, last_updated
  def with_guest = Virt::MemoryStat.new(8.GiB, 4.GiB, 8.GiB, 6.GiB, 1.GiB, 512.MiB, 2.GiB, 3.GiB, 1000)
  def without_guest = Virt::MemoryStat.new(8.GiB, nil, nil, nil, nil, nil, nil, 3.GiB, 1000)
  # A guest kernel built without CONFIG_VM_EVENT_COUNTERS: every other field, no swap counters.
  def without_swap = with_guest.with(swap_in: nil, swap_out: nil)

  it 'reports guest data as available only when every guest field is present' do
    assert with_guest.guest_data_available?
    refute without_guest.guest_data_available?
  end

  it 'reports swap counters separately from the rest of the guest data' do
    assert with_guest.swap_data_available?
    refute without_swap.swap_data_available?
    # the point of the split: no swap counters must not disable ballooning
    assert without_swap.guest_data_available?
    refute without_guest.swap_data_available?
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
    assert_equal 'actual 8G(rss=3G); guest: 2G/8G (25%) (unused=4G, disk_caches=1G); swap out=2G in=512M',
                 with_guest.to_s
    assert_equal 'actual 8G(rss=3G)', without_guest.to_s
    assert_equal 'actual 8G(rss=3G); guest: 2G/8G (25%) (unused=4G, disk_caches=1G)', without_swap.to_s
  end

  it 'to_s omits the swap clause for a guest that has never swapped' do
    never_swapped = with_guest.with(swap_in: 0, swap_out: 0)
    assert_equal 'actual 8G(rss=3G); guest: 2G/8G (25%) (unused=4G, disk_caches=1G)', never_swapped.to_s
  end
end
