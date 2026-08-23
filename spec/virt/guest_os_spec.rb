# frozen_string_literal: true

require_relative '../spec_helper'

describe Virt::GuestOS do
  context 'from_osinfo_id' do
    it 'classifies the ids measured on a real host' do
      assert_equal :windows, Virt::GuestOS.from_osinfo_id('http://microsoft.com/win/11').family
      assert_equal :linux, Virt::GuestOS.from_osinfo_id('http://ubuntu.com/ubuntu/25.10').family
    end

    it 'classifies a vendor from the table regardless of version' do
      assert_equal :linux, Virt::GuestOS.from_osinfo_id('http://redhat.com/rhel/9.4').family
      assert_equal :freebsd, Virt::GuestOS.from_osinfo_id('http://freebsd.org/freebsd/14.0').family
    end

    it 'keeps the id it did not recognise, so it can be logged' do
      os = Virt::GuestOS.from_osinfo_id('http://haiku-os.org/haiku/r1')
      assert_equal :unknown, os.family
      assert_equal 'http://haiku-os.org/haiku/r1', os.osinfo_id
    end

    # The segment is why microsoft.com can't be a host-only key: DOS is not Windows.
    it 'keys on the first path segment, not just the vendor' do
      assert_equal :windows, Virt::GuestOS.from_osinfo_id('http://microsoft.com/win/11').family
      assert_equal :unknown, Virt::GuestOS.from_osinfo_id('http://microsoft.com/msdos/6.22').family
    end

    it 'is UNKNOWN for a domain that declared nothing' do
      assert_equal Virt::GuestOS::UNKNOWN, Virt::GuestOS.from_osinfo_id(nil)
      assert_equal Virt::GuestOS::UNKNOWN, Virt::GuestOS.from_osinfo_id('   ')
    end

    it 'does not raise on a malformed id' do
      assert_equal :unknown, Virt::GuestOS.from_osinfo_id('not-a-uri').family
      assert_equal :unknown, Virt::GuestOS.from_osinfo_id('http://microsoft.com').family
    end
  end

  context 'no_proc_meminfo?' do
    # The whole point of the class: Windows and FreeBSD are never asked for /proc/meminfo,
    # and neither is a guest that declared nothing (see DECISIONS.md D-guest-os-from-xml).
    it 'is true for everything except a declared Linux' do
      refute Virt::GuestOS.from_osinfo_id('http://ubuntu.com/ubuntu/25.10').no_proc_meminfo?
      assert Virt::GuestOS.from_osinfo_id('http://microsoft.com/win/11').no_proc_meminfo?
      assert Virt::GuestOS.from_osinfo_id('http://freebsd.org/freebsd/14.0').no_proc_meminfo?
      assert Virt::GuestOS::UNKNOWN.no_proc_meminfo?
    end
  end

  context 'family predicates' do
    it 'all answer false for an unclassified guest' do
      refute Virt::GuestOS::UNKNOWN.windows?
      refute Virt::GuestOS::UNKNOWN.linux?
      refute Virt::GuestOS::UNKNOWN.freebsd?
    end
  end

  it 'to_s names the family and what was declared' do
    assert_equal 'windows (http://microsoft.com/win/11)',
                 Virt::GuestOS.from_osinfo_id('http://microsoft.com/win/11').to_s
    assert_equal 'unknown', Virt::GuestOS::UNKNOWN.to_s
  end
end
