# Architecture

How the pieces compose — what no single symbol can say and what would be expensive to overturn:
wiring and dependency direction, the lifecycle / threading / data-flow story, the flows a newcomer
needs, where to start reading. **Normative: the code conforms.** Change this file first, then the
code. Not here: why (`decisions.md` — cite the `D_`), what upstream does (`research.md` — cite
the `R_`), one symbol's behaviour (its doc comment), the module map (`AGENTS.md`). Only the
sections with content; the worked example in each is the ruler. Cap 12 KB — over it, research or
doc-comment content has crept in.

---

## Wiring

- Dependencies point down: `lib/ui/` → `lib/virt/` + `lib/system/` → the top-level helpers
  (`Run`, `Cooldown`, `ResourceUsage`, `Interpolator`). Nothing under `lib/virt/` or
  `lib/system/` references `UI::`; a presentation choice (a glyph, a colour) is a table in
  `lib/ui/` keyed by the data `Virt::` exposes.
- `bin/virtui` constructs everything once and hands objects in as constructor arguments; the
  only global is `$log`. The graph, top down: `UI::AppLayout(cache, ballooning)` →
  `Virt::Ballooning(cache)` → `Virt::Cache(virt, System::Info)` → `Virt::Virsh(runner,
  swap_sampler)` → `Virt::GuestSwapSampler(Virt::GuestAgent(runner))` and
  `Virt::VirshSession`.
- The backend is a role, not a class: `Virt::Virsh` and `Virt::VMEmulator` answer the same calls
  (`domain_data`, `guest_os`, `guest_swap`, `set_actual`, the power commands), so demo mode and
  most specs run the whole stack over the emulator with nothing faked apart.
- Under `Virt::Virsh` sits the *runner* seam — `query` / `sync` / `async`, a subcommand without
  the word `virsh`, splatted one argument per word — with two implementations: the long-lived
  `Virt::VirshSession` serves `query`, `Virt::VirshSpawn` runs `sync` / `async` as one process
  each, and the session falls back to spawning when its child misbehaves. The parsers take a
  fixture parameter, so parser specs bypass the runner entirely.
- `Virt::Cache` is the one thing the UI reads: thread-safe, an immutable `VMCache` per domain
  plus the host figures from `System::Info`. Every per-domain memo of a backend read (the
  guest-OS lookup) lives here, on the timer thread's side of the seam, never on `Virsh`.
- Every subprocess goes through `Run` as argv. `Virt::Ballooning` acts on a VM only through
  `Virt::Cache#set_actual`, which validates against the VM's limits before delegating to
  `Virsh#set_actual`; the UI's memory keys take the same path.

## Threads

Two threads, one hand-off. The **timer thread** (`Concurrent::TimerTask`, 2 s fixed rate, in
`bin/virtui`) owns every backend and host read: `Virt::Cache#update` runs the fleet `domstats`,
the guest-OS lookup for a domain not seen before, one swap-level read per running Linux guest
(three `qemu-agent-command` RPCs into a guest that may be sick), then the host's `/proc` and
`df`; it arms guest mem-stat collection through `Run.async` on every not-running → running
transition. When the cache is rebuilt it submits one block to tuile's `screen.event_queue`. The
**UI thread** (tuile's event loop) runs that block — `Virt::Ballooning#update`, then
`UI::AppLayout#update_data` — and every keypress. Keys reach the backend too, for the power
and memory commands, but only through `sync` / `async`, which spawn their own process; nothing
on the UI thread calls `query`. That is the reason for the split: `Virt::VirshSession`
serialises reads behind one mutex and one child, so a read from the UI thread would block the
screen on a slow guest. The two objects both threads touch are `Virt::Cache` (readers get
immutable snapshots) and `Cooldown` values (the session's read deadline; all others are
UI-thread-confined).

## Flows

**A tick** (every 2 s):

1. The `TimerTask` fires on the timer thread → `Virt::Cache#update`.
2. `Virsh#domain_data` → one `virsh domstats` through the session → a `DomainData` per domain.
3. Per domain: `guest_os` from the memo or one `virsh metadata` read; if running and declared
   Linux, `Virsh#guest_swap` → `GuestSwapSampler#swap` → `GuestAgent#swap` (open / read / close
   of the guest's `/proc/meminfo`), or `nil` when the guest is written off or the read fails.
   `VMCache.diff` derives CPU usage, swap-out rate and balloon-data age from the previous entry.
4. `System::Info` reads host memory and CPU, and `df` for every qcow2 file the fleet uses.
5. `screen.event_queue.submit { ballooning.update; layout.update_data }` — the hand-off.
6. On the UI thread, `Virt::Ballooning#update` runs one `BallooningVM#update` per domain: each
   voter and vetoer `observe`s the `VMCache`, the three rules decide, and a move goes
   `Cache#set_actual` → `Virsh#set_actual` → `runner.sync('setmem', …)` → a spawned process.
   `AppLayout#update_data` refreshes the panes; dirty components repaint.

**A power key** (UI thread only):

1. `UI::VMPane#handle_key` sees `p`, then the power submenu letter, for the selected VM.
2. `@virt_cache.virt.start(name)` → `Virsh#start` → `runner.async('start', name)` →
   `VirshSpawn#async` → `Run.async`: a process of its own, failure logged rather than raised.
3. Nothing on screen changes until the next tick's `domstats` reports the new state.

**A guest that cannot answer** (timer thread):

1. `GuestAgent#swap` raises `GuestAgent::Unavailable` for a phrasing in `EXPECTED_FAILURES`,
   anything else for a reply it does not understand.
2. `GuestSwapSampler` counts a strike and answers `nil`; on the third it arms a 60 s `Cooldown`
   write-off, logging `debug` for an expected failure and `warn` once otherwise.
3. The `VMCache` carries `guest_swap: nil`; the SWAP row draws a dashed level with a `-`.
4. `Cache#update` calls `forget_guest` for a domain it sees not running, so shutdown strikes
   do not greet the next boot.

## Where to start reading

`bin/virtui` — eighty lines that construct every object and show the whole dependency graph and
both threads — then `Virt::Cache` for the data model everything else reads, then
`Virt::BallooningVM#update` for the control loop.

## What is deliberately absent

- **No ruby-libvirt binding** — every backend call is a `virsh` process or REPL (`D_virsh_cli`).
- **No agent shipped into the guest, and no `guest-exec`** — the guest channel reads files only
  (`D_guest_swap_level`, `D_no_force_drain`).
- **No per-VM `virsh` sessions or circuit breakers** — one child serves the fleet
  (`D_virsh_session`).
- **No swap drain** — parked swap is left to demand paging (`D_no_force_drain`).
