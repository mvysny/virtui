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
      os = Virt::GuestOS.from_osinfo_id('http://example.com/madeup/1')
      assert_equal :unknown, os.family
      assert_equal 'http://example.com/madeup/1', os.osinfo_id
    end

    # The segment is why microsoft.com can't be a host-only key: DOS is not Windows.
    it 'keys on the first path segment, not just the vendor' do
      assert_equal :windows, Virt::GuestOS.from_osinfo_id('http://microsoft.com/win/11').family
      assert_equal :dos, Virt::GuestOS.from_osinfo_id('http://microsoft.com/msdos/6.22').family
    end

    # Every id below was read out of osinfo-db, not guessed — the wave-1 table guessed
    # `alpinelinux.org/alpine` and was wrong. See {Virt::GuestOS::FAMILIES}.
    it 'classifies one id per non-Linux family' do
      {
        'http://freebsd.org/freebsd/14.0' => :freebsd,
        'http://openbsd.org/openbsd/7.5' => :openbsd,
        'http://netbsd.org/netbsd/10.0' => :netbsd,
        'http://dragonflybsd.org/dragonflybsd/6.4' => :dragonflybsd,
        'http://apple.com/macosx/10.15' => :macos,
        'http://sun.com/solaris/11' => :solaris,
        'http://openindiana.org/hipster/2021.10' => :illumos,
        'http://haiku-os.org/haiku/r1beta4' => :haiku,
        'http://freedos.org/freedos/1.2' => :dos,
        'http://novell.com/netware/6.5' => :netware
      }.each { |id, family| assert_equal family, Virt::GuestOS.from_osinfo_id(id).family, id }
    end

    it 'classifies the Alpine id osinfo-db actually writes' do
      assert_equal :linux, Virt::GuestOS.from_osinfo_id('http://alpinelinux.org/alpinelinux/3.22').family
    end

    # osinfo-db ships this as a real, declarable id meaning \"unknown\"; it is deliberately
    # absent from FAMILIES so it lands where an undeclared domain lands.
    it 'treats the explicit libosinfo unknown id as undeclared' do
      assert_equal :unknown, Virt::GuestOS.from_osinfo_id('http://libosinfo.org/unknown/unknown').family
      assert_equal :linux, Virt::GuestOS.from_osinfo_id('http://libosinfo.org/linux/2022').family
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
    # and neither is a guest that declared nothing (see DECISIONS.md D_guest_os_from_xml).
    it 'is true for everything except a declared Linux' do
      refute Virt::GuestOS.from_osinfo_id('http://ubuntu.com/ubuntu/25.10').no_proc_meminfo?
      assert Virt::GuestOS.from_osinfo_id('http://microsoft.com/win/11').no_proc_meminfo?
      assert Virt::GuestOS.from_osinfo_id('http://freebsd.org/freebsd/14.0').no_proc_meminfo?
      assert Virt::GuestOS.from_osinfo_id('http://apple.com/macosx/10.15').no_proc_meminfo?
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

  context 'FAMILIES' do
    it 'inverts into VENDORS without a vendor landing in two families' do
      keys = Virt::GuestOS::FAMILIES.values.flatten
      assert_equal keys.size, Virt::GuestOS::VENDORS.size
      assert_equal keys.sort, Virt::GuestOS::VENDORS.keys.sort
    end

    # The lookup lowercases the key it builds, so an upper-case row would never be found.
    it 'holds every key lower-case and in host/segment shape' do
      Virt::GuestOS::FAMILIES.values.flatten.each do |key|
        assert_equal key.downcase, key
        assert_match %r{\A[a-z0-9.-]+/[a-z0-9.-]+\z}, key
      end
    end
  end

  it 'to_s names the family and what was declared' do
    assert_equal 'windows (http://microsoft.com/win/11)',
                 Virt::GuestOS.from_osinfo_id('http://microsoft.com/win/11').to_s
    assert_equal 'unknown', Virt::GuestOS::UNKNOWN.to_s
  end
end
