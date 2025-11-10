# frozen_string_literal: true

require 'minitest/autorun'
require 'formatter'

class TestFormatter < Minitest::Test
  def initialize(test)
    super(test)
    @f = Formatter.new
  end

  def test_progress_bar_empty
    assert_equal '', @f.progress_bar(0, 100, {})
    assert_equal '', @f.progress_bar(100, 0, {})
  end

  def test_progress_bar_simple
    assert_equal "\e[31m# \e[0m", @f.progress_bar(2, 100, { 50 => :red })
    assert_equal '  ', @f.progress_bar(2, 100, { 0 => :red })
  end

  def test_progress_bar_multi
    assert_equal "\e[34maa\e[31maaa\e[32maaaaa\e[0m",
                 @f.progress_bar(10, 10, { 15 => :green, 5 => :red, 2 => :blue }, 'a')
  end

  def test_progress_bar_inl_empty
    assert_equal '', @f.progress_bar_inl(0, 100, {}, :red, 'Hello')
    assert_equal '', @f.progress_bar_inl(100, 0, {}, :red, 'Hello')
  end

  def test_progress_bar_inl_simple
    assert_equal "\e[30m\e[41ma\e[0;31mb\e[0m", @f.progress_bar_inl(2, 100, { 50 => :on_red }, :red, 'ab')
    assert_equal "\e[30m\e[0;31mab\e[0m", @f.progress_bar_inl(2, 100, { 0 => :on_red }, :red, 'ab')
  end

  def test_format_byte_size
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
