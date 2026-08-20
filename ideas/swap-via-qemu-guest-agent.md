# Guest swap level & force-drain via the QEMU guest agent

**Status:** brainstorm, nothing decided. Maintainer-facing.

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
in the guest are one `virsh` call away with *zero guest-side code to write or
maintain*. Verified in the guest on 2026-08-20:

- `/dev/virtio-ports/org.qemu.guest_agent.0` present (plus the SPICE channel)
- `systemctl is-active qemu-guest-agent` → `active`
- **no `/etc/qemu/qemu-ga.conf`** → no blocked RPCs → `guest-exec` permitted
- it is a `virt-manager` default, not something installed for this experiment

"Write a custom in-guest agent" stays dead. "Reuse the guest agent that virt-manager
already put there" is a different proposition and is live.

## The mechanism, and the four things that bite

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

## Open questions

- **Diagnostic tool, or controller input?** Cost per sample: two round-trips over
  virtio-serial plus a process spawn *in the guest*, per VM, per 2 s poll —
  against one `virsh domstats` for the whole fleet. Cheap enough for on-demand
  diagnosis; not obviously cheap enough for the loop.
- **Security posture.** `guest-exec` is remote root in every managed VM. Making it
  a *hard runtime dependency of the monitoring loop* is a large change for a TUI
  that currently only reads counters. Opt-in flag? Only for the drain action?
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
- **Is PSI now the controlled variable?** With the channel available this stops
  being blocked. If PSI wins, the level-reading capability matters less than the
  pressure-reading one, and the whole framing shifts from "see the scar" to "see
  the pressure before the damage".
- **Where does it live in the code?** A third backend seam (`Virt::GuestAgent`)
  alongside `Virt::Virsh`, or more methods on `Virsh`? An emulator counterpart is
  needed either way, per the CLAUDE.md convention.
- **Threading.** A `guest-exec` round-trip blocks. It must run on the background
  timer thread via `Run`, never from the UI thread (CLAUDE.md invariant).
  Two sequential round-trips per VM makes the timer-thread budget a real question.

## Where the nuggets land when this graduates

- `qemu-guest-agent` as an optional prerequisite, what it buys, how to enable it →
  **README** (alongside the existing balloon-device / stats-period prerequisites)
- the decision to depend on `guest-exec` or not — with the custom-agent and
  balloon-only alternatives as the roads not taken → **DECISIONS.md**
- the four `guest-exec` gotchas, as the contract of whatever class wraps them →
  **yardoc**
- "never call the guest agent from the UI thread" → **CLAUDE.md**, if this becomes
  real
- the measurements above are evidence, not durable facts: they die with this file
