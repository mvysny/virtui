# frozen_string_literal: true

require_relative '../spec_helper'

describe Numeric do
  describe '#KiB' do
    it 'converts 1 to 1024' do
      assert_equal 1024, 1.KiB
    end

    it 'converts 4 to 4096' do
      assert_equal 4096, 4.KiB
    end

    it 'converts 0 to 0' do
      assert_equal 0, 0.KiB
    end

    it 'works with floats' do
      assert_equal 512, 0.5.KiB
    end

    it 'works with negative numbers' do
      assert_equal(-1024, -1.KiB)
    end
  end

  describe '#MiB' do
    it 'converts 1 to 1_048_576' do
      assert_equal 1_048_576, 1.MiB
    end

    it 'converts 256 to 268_435_456' do
      assert_equal 268_435_456, 256.MiB
    end

    it 'converts 0 to 0' do
      assert_equal 0, 0.MiB
    end

    it 'works with floats' do
      assert_equal 524_288, 0.5.MiB
    end

    it 'works with negative numbers' do
      assert_equal(-1_048_576, -1.MiB)
    end

    it 'equals 1024 KiB' do
      assert_equal 1024.KiB, 1.MiB
    end
  end

  describe '#GiB' do
    it 'converts 1 to 1_073_741_824' do
      assert_equal 1_073_741_824, 1.GiB
    end

    it 'converts 8 to 8_589_934_592' do
      assert_equal 8_589_934_592, 8.GiB
    end

    it 'converts 0 to 0' do
      assert_equal 0, 0.GiB
    end

    it 'works with floats' do
      assert_equal 536_870_912, 0.5.GiB
    end

    it 'works with negative numbers' do
      assert_equal(-1_073_741_824, -1.GiB)
    end

    it 'equals 1024 MiB' do
      assert_equal 1024.MiB, 1.GiB
    end
  end
end

describe 'format_byte_size' do
  it 'formats byte size' do
    assert_equal '0', format_byte_size(0)
    assert_equal '999', format_byte_size(999)
    assert_equal '1000', format_byte_size(1000)
    assert_equal '1023', format_byte_size(1023)
    assert_equal '1K', format_byte_size(1024)
    assert_equal '-1K', format_byte_size(-1024)
    assert_equal '1.5K', format_byte_size(1536)
    assert_equal '4.9K', format_byte_size(5000)
    assert_equal '24M', format_byte_size(25_000_000)
    assert_equal '8G', format_byte_size(8_589_934_592)
    assert_equal '8.0G', format_byte_size(8_590_000_000)
  end
end
