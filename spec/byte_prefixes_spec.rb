# frozen_string_literal: true

require_relative 'spec_helper'
require 'byte_prefixes'

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
