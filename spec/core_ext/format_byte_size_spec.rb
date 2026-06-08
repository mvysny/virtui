# frozen_string_literal: true

require_relative '../spec_helper'

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
