# frozen_string_literal: true

require_relative 'spec_helper'

describe Cancellation do
  it 'starts live, and check_canceled lets the work go on' do
    c = Cancellation.new
    refute c.canceled?
    c.check_canceled
  end

  it 'stays canceled, and check_canceled then raises' do
    c = Cancellation.new
    c.cancel
    c.cancel
    assert c.canceled?
    assert_raises(Cancellation::CanceledError) { c.check_canceled }
  end

  it 'raises past a bare rescue, so the work in between cannot swallow the cancel' do
    c = Cancellation.new
    c.cancel
    assert_raises(Cancellation::CanceledError) do
      c.check_canceled
    rescue StandardError
      flunk 'a bare rescue caught the cancel'
    end
  end
end
