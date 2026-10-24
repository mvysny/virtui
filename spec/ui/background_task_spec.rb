# frozen_string_literal: true

require_relative '../spec_helper'

module Tuile
  describe UI::BackgroundTask do
    before do
      Screen.fake
      Screen.instance.content = Component::Label.new
      @log = Helpers.setup_dummy_logger
    end
    after { Screen.close }

    # Holds the work back until the spec has done what it needs while the task runs.
    let(:gate) { Queue.new }

    # @return [Tuile::Component::Popup, nil] the open progress popup
    def progress_popup = Screen.instance.popups.find { _1.content.is_a?(UI::ProgressWindow) }

    # @return [Tuile::Component::ConfirmWindow, nil] the open failure alert
    def alert = Screen.instance.popups.map(&:content).find { _1.is_a?(Component::ConfirmWindow) }

    # @return [UI::BackgroundTask] a task whose work raises once the gate opens
    def failing_task
      UI::BackgroundTask.new('Reading web01') do
        gate.pop
        raise 'no domain web01'
      end
    end

    # Lets the gated work go on, waits for it, and plays the loop turn its hand-off queued.
    # @param thread [Thread] the worker {UI::BackgroundTask#run} returned
    # @return [void]
    def release(thread)
      gate << :go
      thread.join
      Testing.loop
    end

    it 'shows the progress popup while the work runs, then hands the result to the UI thread' do
      got = nil
      task = UI::BackgroundTask.new('Reading web01') do
        gate.pop
        'xml'
      end
      thread = task.run { |r| got = [r, Thread.current, Screen.instance.popups.dup] }
      assert progress_popup
      release(thread)
      assert_equal ['xml', Thread.current, []], got, 'the popup closes before the result block runs'
    end

    it 'turns a failure into an alert and logs it, and never calls the result block' do
      thread = failing_task.run { flunk 'the result block ran after a failure' }
      release(thread)
      assert_nil progress_popup
      assert_equal 'Reading web01 failed', alert.caption.to_s
      assert_equal 'no domain web01', alert.message
      assert_includes @log.string, 'Reading web01 failed'
    end

    it 'drops the result of a task canceled with ESC' do
      thread = UI::BackgroundTask.new('Reading web01') { gate.pop }
                                 .run { flunk 'the result of a canceled task was delivered' }
      Screen.instance.key(Keys::ESC)
      assert_nil progress_popup
      release(thread)
    end

    it 'keeps a non-cancelable task running through ESC and q, and delivers its result' do
      got = nil
      thread = UI::BackgroundTask.new('Resizing vda', cancelable: false) { |cancel| [gate.pop, cancel.canceled?] }
                                 .run { got = _1 }
      Screen.instance.key(Keys::ESC)
      Screen.instance.key('q')
      assert progress_popup
      release(thread)
      assert_equal [:go, false], got
    end

    it 'hands the work a Cancellation that ESC cancels, and a check then ends it quietly' do
      reached = false
      task = UI::BackgroundTask.new('Reading web01') do |cancel|
        gate.pop
        cancel.check_canceled
        reached = true
      end
      thread = task.run { flunk 'the result of a canceled task was delivered' }
      Screen.instance.key(Keys::ESC)
      release(thread)
      refute reached, 'the work went on past its check'
      assert_empty Screen.instance.popups
      assert_includes @log.string, 'Reading web01: canceled'
    end

    it 'only logs a failure that comes after a cancel' do
      thread = failing_task.run { nil }
      Screen.instance.key(Keys::ESC)
      release(thread)
      assert_empty Screen.instance.popups
      assert_includes @log.string, 'Reading web01 failed after it was canceled'
    end

    it 'fails the task on a CanceledError nobody asked for' do
      UI::BackgroundTask.new('Reading web01') { raise Cancellation::CanceledError, 'stray' }.run { nil }.join
      Testing.loop
      assert_equal 'Reading web01 failed', alert.caption.to_s
    end

    it 'refuses to start off the UI thread' do
      task = UI::BackgroundTask.new('Reading web01') { nil }
      worker = Thread.new do
        Thread.current.report_on_exception = false
        task.run { nil }
      end
      assert_raises(Tuile::Error) { worker.value }
    end

    it 'runs once' do
      task = UI::BackgroundTask.new('Reading web01') { nil }
      task.run { nil }.join
      assert_raises(RuntimeError) { task.run { nil } }
    end
  end
end
