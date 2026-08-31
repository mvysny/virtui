# Guest swap level & force-drain via the QEMU guest agent

**Status:** the **read half is BUILT and fully graduated** (2026-08-21) —
{Virt::GuestAgent} reads the guest's `/proc/meminfo` via
`guest-file-open`/`read`/`close`, {Virt::GuestSwapSampler} polls it per tick,
and the `SWAP` row shows it. The choice and the roads not taken are DECISIONS.md
D_guest_swap_level; the gotchas' contract, the timeout, and the JSON-generation
rule are the yardocs on {Virt::GuestAgent}; the user-facing prerequisite and row
are README. Nothing below restates any of that.

What is still open, and why the file is not deleted:

- the **drain half stays parked** — it needs `guest-exec`, which the shipped
  read deliberately avoids, and the four `guest-exec` gotchas below are what any
  future drain must face;
- the drain analysis (`swapoff -a`, `process_madvise`) and the evidence that it
  probably fixes honesty rather than performance;
- **PSI (and `Committed_AS`) as possibly-better controlled variables** — the
  sibling note's question, unanswered, and now one `read_file` call away from
  measurable;
- the 2026-08-20 measurement, which the sibling note cites as evidence.

Sibling to `swap-despite-ballooning.md`: that note diagnoses *why* a ballooned
guest swaps and why the controller can't see it; this one records the channel
into the guest and what it still puts on the table.

## The drain channel: `guest-exec`, and the four things that bite

The shipped read never touches `guest-exec` (see D_guest_swap_level for why);
a *drain* has no other option — `swapoff` is a command, not a file. These four
are properties of `guest-exec` itself and apply on any transport. **This
section is most of why the file is being kept.**

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

## Cost of adding a second read (what the PSI question weighs)

Measured on the host 2026-08-21 (`guest-ping` ×5, via a spawned `virsh`):
31 ms wall per agent call, of which ~18 ms is the process spawn and ~13 ms the
irreducible libvirtd+QMP+virtio-serial round-trip — so on the (default)
{Virt::VirshSession} one call is ~13 ms. The shipped meminfo read is three
calls, ~40 ms per running VM against the 2 s tick; a second file (PSI) is
another trio, doubling that. Fine for this fleet, and the point where it stops
being fine (~a quarter of the tick) arrives around a dozen VMs — which is also
the point where D_guest_swap_level's "one `guest-exec` cats several files at
once" reconsideration clause activates.

Guest-side cost is noise either way: ~4 ms of guest CPU per sample (~0.2 % of
one core at the 2 s tick — it does not perturb the page-cache numbers being
measured) and ~2 KB per sample over a shared-memory ring.

## What it still unlocks

1. **Force-drain.** As root: `swapoff -a && swapon -a` (blunt, all-or-nothing,
   `try_to_unuse()`), or a rate-limited `process_madvise(pidfd, MADV_WILLNEED)`
   sweep over the swapped ranges found in `/proc/*/smaps`.
   **Caveat that partly re-kills the gradual variant:** there is no CLI for
   `process_madvise`, so it means deploying a *binary* into the guest — which is
   back inside the "custom agent" prohibition. `swapoff`/`swapon` is the only
   zero-code drain. Needs root and `guest-exec` where everything shipped so far
   reads a world-readable file — the capability fork D_guest_swap_level
   deliberately left open.
2. **Better controlled variables, read for free or nearly so:**
   - `/proc/pressure/memory` (**PSI**) — rises *before* reclaim does damage
     and, unlike the `MemAvailable` metric, is not erased by the swap-out. One
     extra `read_file` trio per VM per tick (the cost section above).
   - **`Committed_AS`** — the sibling note's fix 8, and its higher-value
     candidate: it *leads* demand (a JVM's `-Xmx` commit can announce the burst
     before the pages are touched). Note it is a `/proc/meminfo` field, so it is
     **already in the bytes the shipped read fetches every tick** — the
     measurement fix 8 asks for costs zero extra agent calls, only parsing.
   - Also behind the same channel: `Cached`, `pgsteal_*`,
     `workingset_refault_file` (those three are `/proc/vmstat`, a second file).

## Measured 2026-08-20, one host-side call

Kept as evidence for the open questions here and in the sibling note (which
cites it for the `Cached` finding); not a durable fact. Same VM and same boot
as the sibling note's measurement, ~6 h later. The balloon had grown
9.8 → 22.2 GiB over that span.

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

Three findings worth carrying:

- **Swap drained on its own, by 1.14 GiB, as the balloon grew.** Nothing forced
  it; `pswpin` advanced ~515 MiB of that and the rest was slots released by
  writes and process exits. Weak evidence (one uncontrolled observation over six
  hours, growth not isolated from the workload) but it points the same way as the
  argument: *the drain half happens for free once the headroom exists.*
- **A shrink fired while 853 MiB sat in swap — and the since-shipped
  {Virt::BallooningVM::SwapOutShrinkVetoer} would not have blocked it**, because
  it keys on the swap-out *rate* and `pswpout` was flat. Memory was taken from a
  guest still holding swap it never had the headroom to fault back: evidence for
  the sibling note's still-open "gate shrink on the *level* / on reclaim
  evidence" question.
- **The guest page cache is 4.3 GiB, not tiny.** The sibling note braced for the
  fixture's 37 MB and reasoned about a "shrunken, thrashing file LRU".
  `workingset_refault_file` is still climbing *with* 4.3 GiB of cache, so **the
  thrash is not a size problem** — which weakens "more headroom fixes it" and
  strengthens the case against the "no disk cache in the VM" guideline (it would
  be reclaiming memory that is demonstrably in use, not idle duplication).

## Open questions

- **Is PSI the controlled variable, or the swap level?** Answerable *today*:
  {Virt::GuestAgent#read_file} will hand over `/proc/pressure/memory` for any
  guest, and the level is now on screen to compare it against. If PSI wins, the
  framing shifts from "see the scar" to "see the pressure before the damage" —
  and PSI would be a second read (three more agent calls), which is the cost to
  weigh. (`Committed_AS`, the other candidate, is free — see above.)
- **Does the drain actually help?** Open, and the sibling note's analysis says
  probably not much: `swapoff -a` can OOM the guest if only-in-swap exceeds
  `MemAvailable`; a `MADV_WILLNEED` sweep won't lower `SwapUsed` at all below the
  ~50%-swap-full slot-retention threshold (a read fault keeps the slot, the page
  lands in `SwapCached`); and draining converts free RAM into *cold anon*, i.e. it
  spends the burst headroom on pages nobody is going to touch. Fixes honesty, not
  performance.
- **What would a drain cost in capability?** It needs `guest-exec` — remote root
  in every managed VM, and a *write* path where everything shipped so far only
  reads a file. Opt-in flag? Only on an explicit keypress, never in the loop?
  That is the fork D_guest_swap_level deliberately did not settle.
