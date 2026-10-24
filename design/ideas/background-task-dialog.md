# Background task with a progress dialog

**Status:** proposal, nothing built (2026-10-24). The first user is the `i` info window
(`vm-info-window.md`). It needs a fresh `virsh dumpxml` when the key is pressed, and the UI thread
cannot run that read itself.

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
`UI::ProgressWindow`, which is one. The name you suggested, `BackgroundTaskWithDialog`, describes
the same thing; `BackgroundTask` is shorter, and the dialog is not optional, so the suffix adds
nothing. See `Q_name`.

### What `run` does

1. **Checks it is on the UI thread** (`screen.check_locked`) and raises otherwise. A task started
   from the timer thread is a bug.
2. **Opens a modal `Popup` with a `ProgressWindow` at once.** The window is titled `Please wait`
   and shows the caption plus an indeterminate `Tuile::Component::ProgressBar`, which already
   animates by itself. Its size is measured, a few rows by about 40 columns, the way
   `ConfirmWindow`'s `MeasuredPopup` measures its content. Because the popup is modal from the
   first instant, a second `i` cannot start a second task.
3. **Starts a `Thread`** that runs the background block.
   - **On success** it submits `finish(result)`. On the UI thread that closes the progress popup
     *first* and then yields `result` to the UI block. That order lets the UI block open a popup
     of its own (the info window), which then gets the focus.
   - **On a `StandardError`** it submits `fail(error)`. On the UI thread that closes the progress
     popup, logs `$log.error` with the backtrace, and opens
     `ConfirmWindow.alert("#{caption} failed", error.message)`. The UI block is never called.
     Only `StandardError` is caught; an `Interrupt` or `NoMemoryError` goes where it would go
     anyway.
4. **Returns the `Thread`,** so a spec can `join` it. Nothing else needs it.

### What it deliberately does not do

- **Catch the UI block's exceptions.** The UI block runs inside a submitted block on the event
  loop, so an exception there reaches `screen.on_error` (`$log.fatal` in `bin/virtui`). An
  exception in the code that *consumes* a good result is a bug, not a failed task, and showing
  it as "Reading web01 failed" would lie about which part broke.
- **Kill the thread on cancel.** `Thread#kill` in the middle of an `Open3` call leaves the child
  process orphaned. The background work runs to completion, and its result is dropped (see
  *Cancel*).
- **Time out.** The background block owns its own timeouts, the same as `GuestAgent` passes
  `--timeout`. `dumpxml` never touches the guest, so it has nothing to wait for. See `Q_timeout`.
- **Report progress.** The bar is indeterminate. Nothing in virtui knows a percentage, and a
  `progress=` setter would be a knob added ahead of any need.

### Cancel

`q` / `ESC` on the progress popup closes it, because that is `Popup`'s default. The task notices
and marks itself cancelled. When the thread later reports back:

- `finish` does nothing,
- `fail` still logs (at `warn`), but shows no alert. The user walked away, and an error dialog
  appearing a second later would come from nowhere.

The cancelled flag is written and read on the UI thread only (in the close hook, `finish` and
`fail`), so it needs no lock. How the task learns that the popup closed depends on what Tuile's
`Overlay` exposes; see `Q_close_hook`.

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

## Open questions

- `Q_tuile_home`: the class is entirely generic: a popup, an indeterminate bar, an alert, and
  `event_queue.submit`, with nothing virtui-specific except `$log`. Tuile is yours and already
  ships `ConfirmWindow` and `Notification`, so it could become `Tuile::Component::...` or a
  `Tuile::BackgroundTask` there. I lean towards building it in `lib/ui/` first, where one real
  caller shapes it, and moving it upstream once a second app wants it. Errors would then go to
  `Tuile.logger` instead of `$log`.
- `Q_flash`: `dumpxml` through a fresh process takes roughly 30–80 ms, so the progress popup
  appears for a frame or two before the info window replaces it. Options:
  - accept the flicker;
  - open the popup at once but paint it blank until about 300 ms have passed, so it is modal
    from the start but only becomes visible for slow tasks. This needs a one-shot timer, and
    `EventQueue` has only the repeating `tick`, which can be cancelled after its first fire;
  - wait about 150 ms before opening it at all, which reopens the double-press window.

  I lean towards accepting the flicker first and looking at it on the real host.
- `Q_close_hook`: does Tuile's `Overlay`/`Popup` have an on-close listener the task can
  subscribe to? If not, `ProgressWindow` can override `handle_key?` for `q`/`ESC` itself, or
  Tuile gains the hook (see `Q_tuile_home`).
- `Q_testing`: `FakeEventQueue#submit` runs its block inline. If it does that on the worker
  thread too, a spec touches components off the UI thread. Either the spec joins the returned
  thread and then drains the queue, or the class takes an executor (`Thread.method(:new)` by
  default, an inline one in specs). I lean towards join-and-drain if `FakeEventQueue` allows it,
  so as not to add a knob for tests.
- `Q_timeout`: should the task show a "still waiting…" hint after a few seconds, or even an
  error after a hard limit? Nothing virtui would run through it today can hang, so not yet.
- `Q_name`: `BackgroundTask` or `BackgroundTaskWithDialog`?

## Where the nuggets land when this graduates

- The class itself, with its contract in its yardoc: UI-thread entry, the close-then-yield order,
  that the UI block's exceptions are not caught, and that cancel drops the result.
- AGENTS.md's first invariant, architecture.md's *Threads* and a `D_background_task` entry, as
  listed above.
