# frozen_string_literal: true

module UI
  # Runs a slow backend read off the UI thread behind a modal {ProgressWindow}, then hands
  # the result to a block back on the UI thread:
  #
  #   BackgroundTask.new("Looking up #{vm}'s address") { virt.ip_address(vm) }
  #                 .run { |ip| Tuile::Component::ConfirmWindow.alert(vm, ip.to_s) }
  #
  # The constructor's block runs on a fresh thread; {#run}'s block runs on the UI thread once
  # the popup has closed, so it may open a popup of its own. When the work raises a
  # `StandardError`, the popup gives way to a "… failed" alert instead, and {#run}'s block
  # never runs.
  #
  # ESC cancels: the result is dropped, and a later error is only logged. Work that takes a
  # while accepts the task's {Cancellation} and checks it between its steps to stop early:
  #
  #   BackgroundTask.new('Reading the VMs') { |cancel| vms.map { cancel.check_canceled; virt.guest_os(_1) } }
  #
  # The work owns its own timeouts. Nothing here kills the thread: `Thread#kill` mid-`Open3`
  # orphans the child process.
  #
  # == Implementation details
  # Exceptions from {#run}'s block are not caught. They reach `Screen#on_error` as the bug
  # they are, rather than an alert blaming the read.
  #
  # UI-thread-confined.
  class BackgroundTask
    # @param caption [String] what the work does, e.g. "Reading web01's definition"; shown
    #   in the progress popup and in the failure alert's title
    # @yield [cancel] the work, run on a fresh thread
    # @yieldparam cancel [Cancellation] canceled once the user dismisses the popup
    # @yieldreturn [Object] the result handed to {#run}'s block
    # @raise [ArgumentError] without a block
    def initialize(caption, &work)
      raise ArgumentError, 'block required' unless work

      @caption = caption
      @work = work
      @cancellation = Cancellation.new
      @popup = nil
    end

    # Opens the progress popup and starts the work. Runs once per task.
    # @yield [result] on the UI thread, after the popup has closed, unless the work failed
    #   or was canceled
    # @yieldparam result [Object] what the work returned
    # @return [Thread] the worker; nothing but a spec needs it
    # @raise [ArgumentError] without a block
    # @raise [Tuile::Error] off the UI thread
    # @raise [RuntimeError] when this task has already run
    def run(&on_done)
      raise ArgumentError, 'block required' unless on_done

      screen = Tuile::Screen.instance
      screen.check_locked
      raise "#{@caption}: a BackgroundTask runs once" unless @popup.nil?

      @popup = ProgressWindow.open(@caption)
      # Fires on every close, finish's and report_failure's own included, so both read
      # canceled? before closing.
      @popup.on_close { @cancellation.cancel }
      Thread.new { run_work(screen.event_queue, on_done) }
    end

    private

    # The worker thread's body: runs the work and submits its outcome to the UI thread.
    # @param event_queue [Tuile::EventQueue]
    # @param on_done [Proc]
    # @return [void]
    def run_work(event_queue, on_done)
      result = @work.call(@cancellation)
      event_queue.submit { finish(result, on_done) }
    rescue Cancellation::CanceledError => e
      # One the user never asked for is a bug, and fails the task like one.
      if @cancellation.canceled?
        $log.debug("#{@caption}: canceled")
      else
        event_queue.submit { report_failure(e) }
      end
    rescue StandardError => e
      event_queue.submit { report_failure(e) }
    end

    # @param result [Object]
    # @param on_done [Proc]
    # @return [void]
    def finish(result, on_done)
      return if @cancellation.canceled?

      @popup.close
      on_done.call(result)
    end

    # @param error [Exception]
    # @return [void]
    def report_failure(error)
      if @cancellation.canceled?
        $log.warn("#{@caption} failed after it was canceled", error)
        return
      end

      @popup.close
      $log.error("#{@caption} failed", error)
      Tuile::Component::ConfirmWindow.alert("#{@caption} failed", error.message)
    end
  end
end
