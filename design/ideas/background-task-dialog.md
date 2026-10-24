# Background task with a progress dialog

**Status:** built, no caller yet (2026-10-24). `UI::BackgroundTask`, `UI::ProgressWindow`,
`Cancellation` exist, with specs. The first user is the `i` info window
(`vm-info-window.md`). It needs a fresh `virsh dumpxml` when the key is pressed, and the UI thread
cannot run that read itself. The doc changes under *What it changes in the docs* land with that
first caller, since until then no backend read runs off the timer thread.

## The problem

When a key needs data that only a backend read can supply, there is no safe place to do the read
today:

- **On the UI thread:** the screen freezes for the duration of the read. If the read goes
  through the session (`query`), it can also wait behind the timer thread's slow guest-agent
  RPCs until the read timeout. The first invariant forbids this.
- **On the next tick:** up to 2 s of nothing happening, and the result needs a path from
  `AppLayout#update_data` into whatever is waiting for it.

The usual answer is a worker thread. That brings its own chores: hand the result back through
`screen.event_queue.submit`, tell the user something is happening, show the error if it fails,
and stop the user from firing the same thing twice. Every key that wanted this would repeat those
chores, so they should live in one helper.

## The proposal: `UI::BackgroundTask`

It is a class configured in its constructor, with a single `run`. The class form wins over a
plain `background_task(bg, ui)` function because Ruby gives each call one block. With the class,
the constructor takes the background block and `run` takes the UI block, so both are real blocks
and neither has to be a `-> { }` lambda passed as an argument:

```ruby
UI::BackgroundTask.new("Reading #{vm}'s definition") { virt.domain_config(vm) }
                  .run { |config| VMInfoWindow.open(config, cache) }
```

The function form would need one of the two blocks as a lambda argument:

```ruby
background_task("Reading …", -> { virt.domain_config(vm) }) { |config| VMInfoWindow.open(config, cache) }
```

It is not a Tuile subclass, so it gets no widget suffix (per the tuile skill). It *owns* a
`UI::ProgressWindow`, which is one. For the name, see `Q_name`.

### What `run` does

1. **Checks it is on the UI thread** (`screen.check_locked`) and raises otherwise. A task started
   from the timer thread is a bug.
2. **Opens a modal `Popup` with a `ProgressWindow` at once.** The window is titled `Please wait`
   and shows the caption plus a `Tuile::Component::ProgressBar.new(indeterminate: true)`. Tuile
   has had that mode since 0.17: a block slides across the bar at 5 fps on its own ticker, which
   starts on attach and stops on detach, so closing the popup also stops the animation. Its size
   is measured, a few rows by about 40 columns, the way `ConfirmWindow`'s `MeasuredPopup`
   measures its content. Because the popup is modal from the first instant, a second `i` cannot
   start a second task.
3. **Starts a `Thread`** that runs the background block and yields it the task's `Cancellation`
   (see *Cancel*).
   - **On success** it submits `finish(result)`. On the UI thread that closes the progress popup
     *first* and then yields `result` to the UI block. That order lets the UI block open a popup
     of its own (the info window), which then gets the focus.
   - **On a `StandardError`** it submits `fail(error)`. On the UI thread that closes the progress
     popup, logs `$log.error` with the backtrace, and opens
     `ConfirmWindow.alert("#{caption} failed", error.message)`. The UI block is never called.
     Besides `StandardError`, only `CanceledError` is caught (see *Cancel*). An `Interrupt` or
     `NoMemoryError` goes where it would go anyway.
4. **Returns the `Thread`,** so a spec can `join` it. Nothing else needs it.

### What it deliberately does not do

- **Catch the UI block's exceptions.** The UI block runs inside a submitted block on the event
  loop, so an exception there reaches `screen.on_error` (`$log.fatal` in `bin/virtui`). An
  exception in the code that *consumes* a good result is a bug, not a failed task, and showing
  it as "Reading web01 failed" would lie about which part broke.
- **Kill the thread on cancel.** `Thread#kill` in the middle of an `Open3` call leaves the child
  process orphaned. The background work runs until it finishes or checks its `Cancellation`, and
  any result is dropped (see *Cancel*).
- **Time out.** The background block owns its own timeouts, the same as `GuestAgent` passes
  `--timeout`. `dumpxml` never touches the guest, so it has nothing to wait for. See `Q_timeout`.
- **Report progress.** The bar is indeterminate. Nothing in virtui knows a percentage, and a
  `progress=` setter would be a knob added ahead of any need.

### Cancel

`q` / `ESC` on the progress popup closes it, because that is `Popup`'s default. The task then
cancels its `Cancellation` (see `Q_close_hook` for how it hears of the close). Two things follow.

**The background block may stop early.** The `Cancellation` yielded to the background block has
two methods:

- `canceled?` returns whether the user has canceled.
- `check_canceled` raises `Cancellation::CanceledError` if so, and does nothing otherwise.

A quick block ignores it. Ruby drops a yielded argument that the block does not declare, so
`{ virt.domain_config(vm) }` needs no change. A block with several steps opts in with
`{ |cancel| … }` and calls `cancel.check_canceled` between the steps. This is cooperative
cancellation, the way .NET (`ThrowIfCancellationRequested`) and Kotlin (`ensureActive()`) do it.
Checking cannot interrupt a step that is blocked in a subprocess; see `Q_kill_child`.

**The result is dropped.** When the thread reports back after a cancel:

- `finish` does nothing,
- `fail` still logs (at `warn`), but shows no alert. The user walked away, and an error dialog
  appearing a second later would come from nowhere.
- A `CanceledError` ends the thread quietly with a `$log.debug`, and nothing is submitted. A
  `CanceledError` while the `Cancellation` was never canceled is a bug, and it goes through
  `fail` like any other error.

**`CanceledError` inherits from `Exception`, not `StandardError`.** It is not a real error: it is
an artificial exception that means the work was canceled. If it were a `StandardError`, a
`rescue => e` inside the block, or in a helper the block calls, would swallow the cancel. Ruby's
own `Timeout::ExitException`, `Interrupt` and `SystemExit` inherit from `Exception` for the same
reason. Kotlin's `CancellationException` is a `RuntimeException`, and `runCatching` eating it is a
known trap there. `ensure` blocks still run, so cleanup happens. RuboCop's `Lint/InheritException`
flags the class, so it carries a disable comment with this reason.

**`Cancellation` is top-level, not under `UI::`.** It lives in `lib/`, namespace-free like
`Cooldown`. A long block will want to pass the `Cancellation` down into a backend call, and
nothing under `lib/virt/` may reference `UI::`. The task yields this separate object rather than
itself, so the worker thread cannot reach `run` or the popup. The error is nested,
`Cancellation::CanceledError`: the two always travel together, and the move to Tuile along with
the task (see `Q_tuile_home`) is then one constant.

**The flag is a `Concurrent::Event`.** The UI thread sets it and the worker thread reads it.
Under MRI's GVL a plain instance variable would work in practice, but Ruby has no memory model
that promises it. An `Event` rather than an `AtomicBoolean`, because a cancelable wait can block on
an `Event` and wake the moment it is set (see `Q_kill_child`). concurrent-ruby is already a
dependency of virtui and of Tuile. `finish` and `fail` read the same `Cancellation`, so there is
one flag, not two.

### Mock-up

```
           ┌─ Please wait ─────────────────────┐
           │ Reading web01's definition…       │
           │ ░░░░░░░░████░░░░░░░░░░░░░░░░░░░░░ │
           └──────────────────── ESC to cancel ┘
```

If it fails:

```
           ┌─ Reading web01's definition failed ─┐
           │ error: failed to get domain 'web01' │
           │                                     │
           │               [ OK ]                │
           └─────────────────────────────────────┘
```

`ConfirmWindow.alert` is reused as it is. It already handles a one-button dialog that ESC, `q`
and a click all dismiss.

## What it changes in the docs

- **AGENTS.md, the first invariant.** It currently says "Backend reads run on the timer thread".
  It becomes something like *"Backend reads run off the UI thread, on the timer thread or in a
  `UI::BackgroundTask`; components are touched on the UI thread only, through the event queue."*
  The reason for the invariant (the UI must never wait on `virsh`) still holds; only where the
  read may run is widened.
- **design/architecture.md, *Threads*.** A third kind of thread: short-lived and started from a
  key. The section gets a sentence on its hand-off (the same `submit`) and a rule that it reads
  through a **spawned** process, never the session. A task waiting on the session mutex would
  queue behind the tick's guest-agent RPCs, up to the session's read timeout. That would not
  freeze the screen, but the user would watch a spinner because some other guest is sick.
- **design/decisions.md.** A `D_background_task` entry on why a worker thread with a modal
  progress dialog, and not a request flag read by the next tick or a read on the UI thread.

## Decided

- `Q_tuile_home`: **prototype it in virtui, then open a PR to Tuile once it is stable.** The class
  is entirely generic: a popup, an indeterminate bar, an alert and `event_queue.submit`, with
  nothing virtui-specific except `$log`. Tuile already ships `ConfirmWindow` and `Notification`,
  so this fits next to them. Building it here first means one real caller, the `i` info window,
  shapes the API before Tuile commits to it. To keep the move cheap:
  - `UI::BackgroundTask` and `UI::ProgressWindow` use nothing from virtui except `$log`. In
    Tuile, `$log` becomes `Tuile.logger`.
  - `Cancellation` goes upstream too, as `Tuile::Cancellation` with its nested error. It is not
    UI, but the background task is its only producer. The backend must then never name the
    class or its error, or `lib/virt/` would depend on the Tuile gem. Duck typing is enough for
    that: a backend call only ever calls methods on the object it is given (see
    `Q_kill_child`).
  - The PR adds Tuile's own specs for the class. virtui's specs then shrink to the one caller.
- `Q_flash`: **accept the flicker; revisit once it bites.** `dumpxml` through a fresh process
  takes roughly 30–80 ms, so the progress popup appears for a frame or two before the info window
  replaces it. If it ever bothers, there are two fixes:
  - open the popup at once but paint it blank until about 300 ms have passed, so it is modal
    from the start but only becomes visible for slow tasks. This needs a one-shot timer, and
    `EventQueue` has only the repeating `tick`, which can be canceled after its first fire;
  - wait about 150 ms before opening it at all, which reopens the double-press window.
- `Q_close_hook`: **Tuile already has the hook (`Overlay#on_close`), so no feature request.** It
  is a `Listeners` (`popup.on_close << ->(_event) { cancellation.cancel }`) and has been in Tuile
  since 0.17. It fires from `handle_detached`, on the UI thread, once the overlay has left the
  screen **however it left**: `close`, `Screen#remove_popup`, an outside click, or
  `Screen#close` at teardown. Three consequences:
  - Quitting virtui while a task runs cancels the task, which is right.
  - `finish` and `fail` close the popup themselves, and that close fires `on_close` too and
    cancels the `Cancellation`. So both read `canceled?` *before* they close the popup. Canceling
    after the fact is harmless, because the thread has already finished.
  - An outside click would cancel too, because `Popup` defaults to
    `close_on_outside_click: true`. The progress popup passes `false`. A stray click must not
    throw away a read the user asked for, and the footer only promises `ESC`.

- `Q_timeout`: **not yet.** No "still waiting…" hint after a few seconds, and no error after a
  hard limit. Nothing virtui would run through the task today can hang. Revisit with the first
  task that talks to a guest.
- `Q_name`: **`BackgroundTask`.** The dialog is not optional, so a `WithDialog` suffix would add
  nothing.
- `Q_testing`: **join the worker, then `Testing.loop`**, which Tuile master added for
  [tuile#65](https://github.com/mvysny/tuile/issues/65). Tuile 0.17's `FakeEventQueue#submit` ran
  its block inline on whichever thread called it, so on the worker `finish` closed the popup off
  the UI thread and `Screen#check_locked` raised. On master, `submit` queues from every thread,
  the spec's own included, and `Testing.loop` plays the loop turn that runs the queue (every
  `Testing` call and `FakeScreen` gesture also runs it). A spec reads:

  ```ruby
  thread = UI::BackgroundTask.new("Reading web01") { "xml" }.run { |r| got = r }
  thread.join
  Testing.loop
  assert_equal "xml", got
  ```

  Rejected: an injected executor (`Thread.method(:new)` by default, an inline one in specs). It
  is a constructor knob only tests use, and an inline executor never runs the real thread, so the
  hand-off back to the UI thread, which is the point of the class, goes untested. The Tuile change
  also covers every other worker → `submit` path, virtui's poll thread included, and the class's
  own specs need it once it moves to Tuile (see `Q_tuile_home`). Until a Tuile release has it,
  virtui pins Tuile master, as it has before.
- `Q_kill_child`: **`Cancellation#join` plus a `cancellation:` keyword on `Run.sync`, built with
  the first long task; `Cancellation#sleep` with its first caller.** Checking the `Cancellation`
  only helps between steps, and almost every background block is one blocking `virsh` call.
  Nothing needs more yet, because `dumpxml` takes about 50 ms.
  - `Cancellation#join(thread)` joins `thread` in rounds of `POLL_INTERVAL` and raises
    `CanceledError` between rounds once canceled. About 0.1 s: instant to a human, free to run.
    It returns the thread, as `Thread#join` does. It polls because Ruby cannot report the end of
    an arbitrary thread. **It stops the waiting, not the thread**, and its yardoc says so.
  - `Run.sync(*command, cancellation: nil)` starts the child with `popen3`, with reader threads
    for stdout and stderr as `capture3` has inside, and waits with `join`. On cancel it stops
    and reaps the child, then re-raises. That is the safe version of what `Thread#kill` does
    badly: the child is stopped and reaped, not orphaned. Without a `cancellation:` it waits as
    today.

    ```ruby
    begin
      cancellation.join(wait_thr)
    ensure
      if wait_thr.alive? # join raised, so the child is still running
        Process.kill('TERM', wait_thr.pid)
        wait_thr.join
      end
    end
    ```

    An `ensure` rather than a `rescue`, so `Run` never names the error class, and a child
    outlives no other exception either. The cancel is handled before the non-zero-exit raise. A child killed by `TERM` has no exit
    status, and would otherwise come out as "… failed with :" and an alert. `TERM` only: virsh
    exits on it. A `KILL` after a grace period waits for a virsh that ignores `TERM`.
  - The `Cancellation` reaches `Run` as an explicit keyword through each backend read that
    needs it (`Virsh#ip_address(vm, cancellation:)` → `VirshSpawn` → `Run.sync`), and only on
    the reads a long task uses.
  - `Cancellation#sleep(seconds)` needs no polling: `@event.wait(seconds)`, then
    `check_canceled`. `Event#wait` loops over spurious wakeups itself, and measures its timeout on
    `Concurrent.monotonic_time`, the clock `Cooldown` uses too.
  - No other waits (`Queue#pop`, `IO#wait_readable`) until something needs one.

  Rejected:
  - Java-style interruption. Ruby's nearest is `Thread#raise`, which lands on whatever line the
    thread is at, `ensure` included. Raised into `Open3.capture3`, it unwinds through
    `popen_run`'s `ensure`, which waits for the child, so the worker would sit until virsh
    exits by itself.
  - A `canceled` block (`-> { … }`) instead of the object. `Run` would then have to pick the
    error and name its class; with the object, `check_canceled` raises and `Run` never decides.
  - An `on_cancel` listener on `Cancellation` that kills the child at once. There would be no
    polling delay, but `Cancellation` grows a listener API, and the listener must be removed
    before the child is reaped. Polling keeps `Cancellation` one flag plus its waits, and the
    process handling in `Run`.
  - A thread-local `Cancellation` that the task sets on its worker. Every subprocess on the
    worker would become cancelable for free, but nothing in `Run.sync`'s signature would say
    it can be canceled.

## Where the nuggets land when this graduates

- The class itself, with its contract in its yardoc: UI-thread entry, the close-then-yield order,
  that the UI block's exceptions are not caught, and that cancel drops the result.
- `Cancellation` in `lib/`, with its contract in its yardoc. The `CanceledError` yardoc says in
  one line why it inherits from `Exception`; the full argument goes into `D_background_task`.
- With the first long task: `Cancellation#join` and `Run.sync(cancellation:)` as in
  `Q_kill_child`, and the rejected alternatives into `D_background_task`.
- Once stable: a PR moving `BackgroundTask`, `ProgressWindow` and `Cancellation` into Tuile,
  then a virtui commit that bumps Tuile and deletes the local copies.
- AGENTS.md's first invariant, architecture.md's *Threads* and a `D_background_task` entry, as
  listed above.
