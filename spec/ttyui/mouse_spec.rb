# frozen_string_literal: true

require_relative '../spec_helper'
require 'ttyui/mouse'

describe MouseEvent do
  it 'parses' do
    assert_equal MouseEvent.new(:left, 1, 2), MouseEvent.parse("\e[M !\"")
  end

  it 'parses 2' do
    assert_nil MouseEvent.parse('')
    assert_nil MouseEvent.parse('[M')
    assert_nil MouseEvent.parse("\e[M")
    assert_nil MouseEvent.parse(Keys::PAGE_DOWN)
  end
end
