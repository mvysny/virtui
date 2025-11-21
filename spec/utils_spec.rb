# frozen_string_literal: true

require_relative 'spec_helper'
require 'utils'

describe Run do
  context 'sync' do
    it 'runs command successfully' do
      assert_equal 'foo', Run.sync('echo foo').strip
    end
    it 'raises when command doesnt exist' do
      assert_raises(StandardError) { Run.sync('echjasd foo') }
      assert_raises(StandardError) { Run.sync('cat non-existing-file') }
    end
  end
  context 'async' do
    it 'runs command successfully' do
      out = Helpers.setup_dummy_logger
      Run.async('echo foo').join
      assert_equal "• debug   'echo foo': OK", out.string.strip
    end
    it 'raises when command doesnt exist' do
      Helpers.setup_dummy_logger
      assert_raises(StandardError) { Run.async('echjasd foo') }
    end
    it 'logs error when command fails' do
      out = Helpers.setup_dummy_logger
      Run.async('cat non-existing-file').join
      assert out.string.strip.include?("⨯ error   'cat non-existing-file' failed with 1: cat: non-existing-file: No such file or directory"),
             out.string.strip
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
