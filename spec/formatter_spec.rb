# frozen_string_literal: true

require_relative 'spec_helper'
require 'formatter'

describe Formatter do
  let(:f) do
    Rainbow.enabled = true # force-enable for CI
    Formatter.new
  end
  context 'progress_bar' do
    it 'is empty' do
      assert_equal '', f.progress_bar(0, 100, {})
      assert_equal '', f.progress_bar(100, 0, {})
    end
    it 'draws for one value' do
      assert_equal "\e[31m#\e[0m ", f.progress_bar(2, 100, { 50 => :red })
      assert_equal '  ', f.progress_bar(2, 100, { 0 => :red })
    end
    it 'draws for two values' do
      assert_equal "\e[34maa\e[0m\e[31maaa\e[0m\e[32maaaaa\e[0m",
                   f.progress_bar(10, 10, { 15 => :green, 5 => :red, 2 => :blue }, 'a')
    end
  end

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
