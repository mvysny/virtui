# frozen_string_literal: true

require_relative '../spec_helper'
require 'ttyui/event_queue'

describe EventQueue do
  let(:queue) { EventQueue.new }
  let(:events) { [] }
  let(:run_thread) do
    Thread.new do
      queue.run { events << it }
    end
  end

  it 'terminates on stop' do
    t = run_thread
    queue.stop
    assert t.join(1)
  end

  it 'yields events' do
    t = run_thread
    queue.post 'Hello'
    queue.stop
    assert t.join(1)
    assert_equal ['Hello'], events
  end

  it 'rethrows errors' do
    t = run_thread
    queue.post 'Hi'
    queue.post EventQueue::ErrorEvent.new(ArgumentError.new('foo'))
    assert_raises(StandardError) do
      t.join(1)
    end
    assert_equal ['Hi'], events
  end
end
