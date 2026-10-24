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

  # @return [Float] seconds the block took, on the monotonic clock
  def elapsed
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end

  # Cancels `cancellation` from another thread after `delay` seconds.
  # @return [Thread]
  def cancel_later(cancellation, delay = 0.05)
    Thread.new do
      Kernel.sleep(delay)
      cancellation.cancel
    end
  end

  context 'sleep' do
    it 'sleeps the whole time while not canceled' do
      assert_operator elapsed { Cancellation.new.sleep(0.05) }, :>=, 0.05
    end

    it 'wakes at once on a cancel, and raises' do
      c = Cancellation.new
      canceler = cancel_later(c)
      took = elapsed { assert_raises(Cancellation::CanceledError) { c.sleep(10) } }
      assert_operator took, :<, 1
      canceler.join
    end

    it 'raises without sleeping once canceled' do
      c = Cancellation.new
      c.cancel
      took = elapsed { assert_raises(Cancellation::CanceledError) { c.sleep(10) } }
      assert_operator took, :<, 1
    end
  end

  context 'join' do
    it 'returns the thread once it ends' do
      worker = Thread.new { 42 }
      assert_same worker, Cancellation.new.join(worker)
      assert_equal 42, worker.value
    end

    it 're-raises what the thread died of' do
      worker = Thread.new do
        Thread.current.report_on_exception = false
        raise 'boom'
      end
      error = assert_raises(RuntimeError) { Cancellation.new.join(worker) }
      assert_equal 'boom', error.message
    end

    it 'raises on a cancel, leaving the thread running' do
      gate = Queue.new
      worker = Thread.new { gate.pop }
      c = Cancellation.new
      canceler = cancel_later(c)
      took = elapsed { assert_raises(Cancellation::CanceledError) { c.join(worker) } }
      assert_operator took, :<, 1
      assert worker.alive?, 'join stopped the thread, not just the waiting'
    ensure
      gate << :go
      worker.join
      canceler.join
    end
  end
end
