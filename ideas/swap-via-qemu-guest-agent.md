# Guest swap level & force-drain via the QEMU guest agent

**Status:** ON HOLD — brainstorm, nothing decided, nothing built.

Two things are *settled* (don't re-litigate them; see the sections below):
the per-sample cost is affordable (31 ms, measured), and `qemu-agent-command`
is reachable from the Ruby binding today. What keeps this parked is that nothing needs it yet —
the PSI-vs-level question can be answered with hand-run calls, and the
polled-controller version is the most expensive version of a feature nobody
has asked for. Still open: whether swap level or PSI is the controlled
variable at all, and how a guest-agent read is exposed (on-demand keypress vs
polled, flag vs always-on).

Sibling to `swap-despite-ballooning.md`: that note diagnoses *why* a ballooned
guest swaps and why the controller can't see it. This one records a **channel
into the guest that turns out to already exist**, and the two capabilities it
puts back on the table — reading the current swap *level*, and *force-draining*
swap.

## What changed: the agent is already there

The sibling note's open questions repeatedly bottom out in "that needs a
guest-side reporting channel virtui can read", and the assumption was that such
a channel means writing and shipping a virtui agent — a scope expansion, and
explicitly ruled out.

That assumption was wrong. **`qemu-guest-agent` is already installed and running
on the managed VM**, and `qemu-ga` runs as **root**. So arbitrary root commands
in the guest are one call away with *zero guest-side code to write or
maintain*. Verified in the guest on 2026-08-20:

- `/dev/virtio-ports/org.qemu.guest_agent.0` present (plus the SPICE channel)
- `systemctl is-active qemu-guest-agent` → `active`
- **no `/etc/qemu/qemu-ga.conf`** → no blocked RPCs → `guest-exec` permitted
- it is a `virt-manager` default, not something installed for this experiment

"Write a custom in-guest agent" stays dead. "Reuse the guest agent that virt-manager
already put there" is a different proposition and is live.

## Two ways in, and they can be used at the same time

This is the discovery of 2026-08-21 and it reframes the whole note. There are
two independent transports to the same QMP-level RPC, and the choice is not
either/or:

| | `virsh qemu-agent-command` | `Libvirt::Domain#qemu_agent_command` |
|---|---|---|
| Available today | yes | **yes** — see below |
| Cost per call | **~31 ms measured** (57 % process spawn) | ≤~13 ms (spawn gone; RPC remains) |
| Timeout | `--timeout` CLI flag | native parameter |
| Blocks only the caller's thread | **yes** (`Process.wait` releases the GVL) | **NO — freezes every Ruby thread** |

**Crucially, the binding's known blockers do not apply here.** `D-virsh-cli`
defers to [bug #1](https://github.com/mvysny/virtui/issues/1), and the deleted
`Virt::LibVirtClient` (see `git show e3e0faa^:lib/virt/lib_virt_client.rb`)
pinned that on [libvirt-ruby#13](https://gitlab.com/libvirt/libvirt-ruby/-/issues/13)
(incomplete `memory_stats`) and [#14](https://gitlab.com/libvirt/libvirt-ruby/-/issues/14)
(no domstats equivalent). Both are in the **stats** API. The guest agent lives
in the *qemu-specific* API family (`libvirt-qemu.so.0`) and is untouched by
either bug.

So the natural shape, if this is ever built, is a **hybrid**: keep `virsh
domstats` for the O(1) fleet poll (the binding still can't do it), and use the
binding for the O(running-VMs) agent calls (where the spawn cost is what hurts).
Neither has to wait for the other.

## The Ruby binding path — verified 2026-08-21

Host: `ruby-libvirt` 0.8.4 (Ubuntu `ruby-libvirt` 0.8.4-1build1), libvirt 12.0.0.

```ruby
Libvirt::Domain#qemu_agent_command(command, timeout = nil, flags = 0)
```

Verified:

- the extension links `libvirt-qemu.so.0` and imports
  `virDomainQemuAgentCommand@LIBVIRT_QEMU_0.10.0` (plus `QemuMonitorCommand`,
  `QemuAttach`)
- arity is 1..3, and the call reaches the C function — probed against libvirt's
  daemon-less `test:///default` driver, which fails with *"this function is not
  supported by the connection driver"* rather than an arity or lookup error.
  `test:///default` is also the cheap way to get a real `Libvirt::Domain`
  without a daemon, useful for specs.
- timeout constants are exposed: `Libvirt::Domain::QEMU_AGENT_COMMAND_BLOCK`
  (-2), `_DEFAULT` (-1), `_NOWAIT` (0), `_SHUTDOWN` (60); a positive integer is
  seconds.

Inferred, **not** verified against a live qemu domain (no `virsh`/libvirtd on
the dev box): that it returns the raw JSON reply as a `String`, and that it
needs a read-write `qemu:///system` connection. Confirm both before relying on
them.

Note the API family: `qemu_agent_command` and `qemu_monitor_command` are
libvirt's qemu-specific escape hatches. The monitor one is explicitly
discouraged upstream; the agent one is the sanctioned half, but it is still
outside the stable cross-hypervisor API.

## The GVL trap — the reason the binding is not a free win

**ruby-libvirt 0.8.4 never releases the GVL.** Measured on 2026-08-21, and then
confirmed structurally: the extension imports **no** `rb_thread_call_without_gvl`
/ `rb_thread_blocking_region` symbol at all — in fact no `rb_thread_*` symbol.
Every libvirt call holds the GVL for its full duration.

The measurement: a Ruby thread ticking every 0.5 s stopped producing output the
instant a blocking `Libvirt::open("qemu+tcp://192.0.2.1/system")` (unroutable
TEST-NET-1, so the TCP connect hangs) was entered, and produced nothing for the
remaining ~10 s until the process was killed.

Consequence for virtui, and it is a big one:

- **`virsh` + `Run`/Open3 stalls only the timer thread.** `Process.wait` releases
  the GVL, so a wedged `qemu-ga` costs one late update; the UI thread keeps
  repainting and keeps accepting keys.
- **The binding freezes the whole TUI.** No repaint, no keyboard, for as long as
  the call takes. With N sick VMs at a T-second timeout, that is N×T seconds of
  frozen UI.

So the process spawn is not pure waste — **it buys thread isolation**, and the
binding trades ~20–40 ms per call for the risk of hanging the UI. That inverts
the naive "the binding is strictly faster" reading and is the single most
important thing on this page.

It also bears on `D-virsh-cli` well beyond this feature: that entry lists the
binding as "still wanted", and this is an argument against it that the entry
does not currently record. If this note is ever deleted, **that finding should
graduate to `D-virsh-cli` first.**

Mitigations, none free: a short timeout (~1 s) plus a per-VM circuit breaker so
repeat offenders are skipped rather than retried every tick; or confine binding
calls to a separate process; or simply keep using `virsh` for the agent calls
and accept the spawn.

## The mechanism, and the four things that bite

These four are transport-independent — they are properties of `guest-exec`
itself, and they apply equally whether the RPC goes via `virsh` or the binding.
**This section is why the file is being kept.**

```bash
virsh qemu-agent-command <dom> '{"execute":"guest-exec","arguments":{
  "path":"/bin/sh","arg":["-c","cat /proc/meminfo"],"capture-output":true}}'
# -> {"return":{"pid":162647}}
virsh qemu-agent-command <dom> '{"execute":"guest-exec-status","arguments":{"pid":162647}}'
# -> {"return":{"exited":true,"exitcode":0,"out-data":"<base64>","err-data":"<base64>"}}
```

1. **`guest-exec` is asynchronous.** It returns a PID and nothing else. Output
   comes from a separate `guest-exec-status` call, and only while the agent still
   remembers the process. A naive one-shot invocation looks like it silently
   produced no output — this is the first thing that goes wrong.
2. **`out-data` / `err-data` are base64.** Pipe through `base64 -d`.
3. **`path` is `execve`, not a shell.** No pipes, globs or redirection; go via
   `/bin/sh -c` for anything compound.
4. **Poll `exited`, and read `exitcode` from the reply.** QMP-level success says
   nothing about whether the guest command worked.

Plus one implementation rule learned the hard way: **never hand-escape the JSON
inside shell (or Ruby) quotes** — build it with `jq -n` / `JSON.generate`. The
first working attempt died on collapsed nested quoting, not on anything to do
with libvirt.

A tested reference script (builds both requests with `jq -n`, polls `exited`,
decodes both streams, propagates `exitcode`) was written during the 2026-08-20
session; re-derive it from the four rules above if it isn't to hand — it's ~25
lines.

**Don't poll `exited` in a sleep loop if this is ever wired into the update
loop.** Gotcha 1 forces two round-trips, but they need not be adjacent: fire
`guest-exec` on tick T and read `guest-exec-status` on tick T+1. Two seconds
later it has certainly exited, so there is no sleep and no third call — one
round-trip per VM per tick, amortized. The controller consumes 2 s-stale data,
which it already does (`domstats` is a snapshot from the top of the tick).
`concurrent-ruby` is already a dependency, so a `Promises` future parked across
ticks is the natural expression. `_NOWAIT` (timeout 0) does *not* help here —
the reply carries the PID, so it cannot be discarded.

## Cost: measured, and it is not the objection

Measured on the host 2026-08-21, `virsh qemu-agent-command Flow
'{"execute":"guest-ping"}'`, five runs:

| | value |
|---|---|
| wall | **31.16 ms** mean (29.68 – 32.28, spread 2.6 ms — remarkably tight) |
| CPU in `virsh` itself (usr+sys) | 17.78 ms — **57 %**, the spawn + dynamic link + client init |
| blocked waiting | 13.39 ms — libvirtd RPC + QMP + virtio-serial + `qemu-ga` |

No polkit penalty on this host (the user is in the `libvirt` group), so 31 ms is
the good case, not the median case.

Against the 2000 ms tick, one invocation per running VM per tick (the two-tick
amortization below), with the spawn-free column for comparison:

| Fleet | via `virsh` | share of tick | spawn-free floor | share |
|---|---|---|---|---|
| N=1 | 31 ms | 1.6 % | 13 ms | 0.7 % |
| N=6 | 187 ms | 9.3 % | 80 ms | 4.0 % |
| N=10 | 312 ms | 15.6 % | 134 ms | 6.7 % |
| N=12 | 374 ms | 18.7 % | 161 ms | 8.0 % |
| N=25 | 779 ms | 39.0 % | 335 ms | 16.7 % |

A naive exec+status+poll (3 invocations/VM) triples it: N=12 → ~56 %, N=25 blows
the tick and `:fixed_rate` starts running back-to-back.

**Two corrections to earlier reasoning on this page.** The original
"not obviously cheap enough for the loop" framing was wrong — O(running-VMs)
does not bind until ~25 VMs. But the follow-up claim that "~90 % of the cost is
process spawn" was also wrong: it is **57 %**. Eliminating the spawn (binding,
or a long-lived helper) is a **~2.3× win, not a 10× one** — 31 ms → ~13 ms at
best. The irreducible RPC is an order of magnitude more expensive than the
~1–3 ms first guessed, presumably libvirtd's domain-object locking plus a vmexit
and an idle-vCPU wakeup to reach `qemu-ga`.

**Still unmeasured, and it is the number that decides whether a persistent
connection is worth building:** how much of the 13.39 ms wait is libvirt
*connection setup* (socket connect, auth handshake, capability exchange — paid
per `virsh` invocation, eliminated by a persistent connection) versus the agent
RPC proper (irreducible). Decompose with three timings on the host:

```bash
time virsh --version                                          # spawn only, no daemon connection
time virsh hostname                                           # spawn + connect + trivial RPC
time virsh qemu-agent-command Flow '{"execute":"guest-ping"}'  # spawn + connect + agent RPC
```

Two related worries die outright regardless: guest-side CPU is ~4 ms × 43 200
samples/day ≈ 3 min/day ≈ 0.2 % of one core (so it does *not* meaningfully
perturb the very page-cache numbers being measured), and bandwidth is ~1.9 KB of
base64 per sample, ~6 KB/s at N=6, over a shared-memory ring.

What survives cost analysis untouched is **liveness**, not expense: a wedged
`qemu-ga` is not a 31 ms call, it is an unbounded one, and `bin/virtui:36` has a
single timer thread. A timeout is mandatory on either transport; see the GVL
section for why it is far more urgent on the binding.

## Working around the GVL: a long-lived helper process

Raised 2026-08-21. If the GVL is the binding's disqualifier, put the binding
behind a process boundary: a long-lived Ruby child holding a persistent libvirt
connection, driven over a pipe. The freeze is then confined to a process that
has no UI to freeze.

It is the *correct* answer to the GVL problem, and it is strictly better on
liveness than either direct transport: a blocked in-process libvirt call cannot
be cancelled at all, whereas a wedged child can be `SIGKILL`ed and respawned.
The child is also a natural per-VM circuit-breaker unit.

**One per VM, not one shared** — corrected 2026-08-21. The first draft of this
section argued for a single shared helper on RSS grounds, claiming sharding buys
only parallelism. That was wrong, and the GVL finding above is why: inside one
process libvirt calls cannot be overlapped *at all* (threads don't help, the GVL
is held for the call's duration), so a shared helper serialises every VM behind
every other VM and one wedged `qemu-ga` delays *every* VM's sample by up to the
timeout, every tick. Sharding therefore buys real fault isolation, independent
kill/restart, and a natural circuit-breaker unit. The RSS objection stands as a
thing to measure, not assume — identical processes share most of their pages, so
marginal cost per extra child should be well below a private copy.

**And measure the win before building it.** The numbers above say the helper
buys ~200 ms/tick at N=10 (15.6 % → 6.7 %), in exchange for an IPC protocol,
child lifecycle (spawn/reap/restart/orphan-on-parent-death), and multi-process
debugging. Ten percent of a tick is not worth that, and CLAUDE.md's *Readable,
not obfuscated* rule points the same way. This is the right design **if** this
ever becomes an always-on polled controller input at fleet scale, and
over-engineering for anything short of that — which is another argument for the
one-shot version below.

*Cheaper variant, now its own note:* `virsh` reads commands from stdin in
interactive mode, holding one connection for the session — which is spawn-free
**and** GVL-safe with no Ruby child, no binding dependency and no protocol to
invent. It is the only option on the table with both properties. It also carries
seven distinct gotchas, starting with the loss of `argv` (which drags the
never-hand-escape rule below straight back into play). Split out to
**`ideas/persistent-virsh-session.md`**; that file owns the mechanism, the
gotchas and the test plan.

## What it unlocks

1. **Current swap level.** `SwapTotal`/`SwapFree`/`SwapCached` from
   `/proc/meminfo`. The balloon gives only cumulative `pswpin`/`pswpout`
   (`balloon.swap_in`/`swap_out`) — a *rate*, never a level.
2. **Force-drain.** As root: `swapoff -a && swapon -a` (blunt, all-or-nothing,
   `try_to_unuse()`), or a rate-limited `process_madvise(pidfd, MADV_WILLNEED)`
   sweep over the swapped ranges found in `/proc/*/smaps`.
   **Caveat that partly re-kills the gradual variant:** there is no CLI for
   `process_madvise`, so it means deploying a *binary* into the guest — which is
   back inside the "custom agent" prohibition. `swapoff`/`swapon` is the only
   zero-code drain.
3. **Free with the same call — and this is arguably the bigger prize:**
   `/proc/pressure/memory` (**PSI**), `Cached`, `pgsteal_direct`/`pgsteal_kswapd`,
   `workingset_refault_file`. The sibling note's first open question asks whether
   PSI is the better controlled variable and notes "needs a guest-side reporting
   channel virtui can read — the balloon doesn't carry it". **This is that
   channel.** PSI rises *before* reclaim does damage and, unlike the
   `MemAvailable` metric, is not erased by the swap-out.

Note the split in *capability* between 1/3 and 2: both `/proc/meminfo` and
`/proc/pressure/memory` are world-readable, so the high-value **read** half
wants only a file read, while only the low-value **drain** half needs root.
QGA's `guest-file-open`/`read`/`close` is the narrower API for the read path —
smaller blast radius, and no process spawn in the guest. It is **not** a
portability win: Fedora/RHEL block `guest-file-*` and `guest-exec` together (see
Open questions). It costs one extra round-trip.

## Measured 2026-08-20, one host-side call

Same VM and same boot as the sibling note's measurement, ~6 h later. The balloon
had grown 9.8 → 22.2 GiB over that span.

| Quantity | Value | Note |
|---|---|---|
| `MemTotal` | 21.1 GiB | had been 22.2 GiB ten minutes earlier — **the balloon shrank ~1 GiB** |
| Swap used | 853 MiB | was 1.99 GiB at the earlier measurement |
| `SwapCached` | 295 MiB | was 1.00 GiB |
| **`Cached`** | **4.3 GiB** | the sibling note's "not recorded" gap, now filled |
| `pswpout` | flat over 10 min | so the shrink was **not** swap-induced |
| `workingset_refault_file` | 3.86 M | was 3.04 M — still climbing |
| PSI `some`/`full` `avg10` | 0.00 / 0.00 | at rest |
| `vmstat 1` `si`/`so` | 0 / 0 for 11 s | guest genuinely idle, swap level flat |

Three findings worth carrying over:

- **Swap drained on its own, by 1.14 GiB, as the balloon grew.** Nothing forced
  it; `pswpin` advanced ~515 MiB of that and the rest was slots released by
  writes and process exits. Weak evidence (one uncontrolled observation over six
  hours, growth not isolated from the workload) but it points the same way as the
  argument: *the drain half happens for free once the headroom exists.*
- **A shrink fired while 853 MiB sat in swap.** Not the sibling note's inversion
  in pure form — `pswpout` was flat, so the metric fell because the workload
  genuinely freed memory — but it is exactly the case that note's fix 1 would
  block: memory taken from a guest still holding swap it never had the headroom
  to fault back.
- **The guest page cache is 4.3 GiB, not tiny.** The sibling note braced for the
  fixture's 37 MB and reasoned about a "shrunken, thrashing file LRU".
  `workingset_refault_file` is still climbing *with* 4.3 GiB of cache, so **the
  thrash is not a size problem** — which weakens "more headroom fixes it" and
  strengthens the case against the "no disk cache in the VM" guideline (it would
  be reclaiming memory that is demonstrably in use, not idle duplication).

## If this comes back: build the cheapest useful version first

The parked proposal is a *polled controller input*, which is the most expensive
and most invasive shape. There is a middle version that dodges every objection
on this page and is the natural first step:

**One-shot, on the currently selected VM, on a keypress.** O(1) rather than
O(running-VMs), no polling, no flag needed, off the update loop entirely, and
`guest-exec` never becomes a runtime dependency of monitoring. It delivers the
actual diagnostic value — see a thrashing guest's real swap level and PSI while
you are looking at it — and it is exactly the "run a one-time process in the
guest" case that makes the gotchas above worth keeping.

Only if that proves insufficient does the polled version, the flag or UI toggle
to arm it, and the two-tick future mechanism become worth their cost.

## Open questions

- **Is PSI the controlled variable, or the swap level?** Answerable *today* with
  hand-run `virsh qemu-agent-command` calls during a thrash episode — no code.
  This is the question to settle before building anything, because if PSI wins,
  the level-reading capability matters much less and the framing shifts from
  "see the scar" to "see the pressure before the damage".
- **Read-only or root?** `guest-exec` is remote root in every managed VM.
  Making it a *hard runtime dependency of the monitoring loop* is a large change
  for a TUI that currently only reads counters. If only the read path is ever
  needed, `guest-file-*` is the narrower capability. Opt-in flag? Only for the
  drain action?
- **Graceful degradation is mandatory.** `qemu-ga` is not guaranteed:
  RHEL/Fedora-family packages ship `/etc/sysconfig/qemu-ga` with `guest-exec` and
  the `guest-file-*` family in `BLOCK_RPCS`, and plenty of guests have no agent at
  all. virtui must stay fully functional without it — so anything built on this
  channel is an *enhancement path*, never the primary one.
- **Does the drain actually help?** Open, and the sibling note's analysis says
  probably not much: `swapoff -a` can OOM the guest if only-in-swap exceeds
  `MemAvailable`; a `MADV_WILLNEED` sweep won't lower `SwapUsed` at all below the
  ~50%-swap-full slot-retention threshold (a read fault keeps the slot, the page
  lands in `SwapCached`); and draining converts free RAM into *cold anon*, i.e. it
  spends the burst headroom on pages nobody is going to touch. Fixes honesty, not
  performance.
- **Where does it live in the code?** A third backend seam (`Virt::GuestAgent`)
  alongside `Virt::Virsh`, or more methods on `Virsh`? An emulator counterpart is
  needed either way, per the CLAUDE.md convention. Note that a *general*
  `exec(domain, command)` public API hands out guest root before any caller
  needs it; the narrow read method with private exec plumbing captures the same
  knowledge without that.
- **Which transport, given the GVL finding?** Not obvious. `virsh` costs a spawn
  (57 % of 31 ms) but isolates the stall; the binding saves that spawn but can
  freeze the UI. A hybrid (virsh for the fleet poll, binding for agent calls) is
  available today but inherits the freeze risk; a long-lived helper process
  fixes it at a complexity cost. See the two sections above — and settle the
  connection-setup decomposition first, since it sets the size of the prize.

## Where the nuggets land when this graduates

- `qemu-guest-agent` as an optional prerequisite, what it buys, how to enable it →
  **README** (alongside the existing balloon-device / stats-period prerequisites)
- the decision to depend on `guest-exec` or not — with the custom-agent and
  balloon-only alternatives as the roads not taken → **DECISIONS.md**
- **the GVL finding → `D-virsh-cli`**, as an argument against the binding that
  the entry does not yet record. This one should graduate *before* the rest,
  because it outlives this note's topic (see the GVL section).
- the four `guest-exec` gotchas, as the contract of whatever class wraps them →
  **yardoc**
- "never call the guest agent from the UI thread" → **CLAUDE.md**, if this becomes
  real. Sharper form, given the GVL finding: it must not be able to stall the
  timer thread unbounded either, and via the binding it must not run anywhere
  without a short timeout.
- the measurements above are evidence, not durable facts: they die with this file
