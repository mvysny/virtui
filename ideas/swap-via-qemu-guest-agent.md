# Guest swap level & force-drain via the QEMU guest agent

**Status:** the **read half is BUILT** (2026-08-21) — {Virt::GuestAgent} reads the
guest's `/proc/meminfo` via `guest-file-open`/`read`/`close`, {Virt::Cache#update}
samples one level per running VM, and the `SWAP` row shows it. See DECISIONS.md
D-guest-swap-level (the choice, and `guest-exec` as the road not taken) and
D-swap-row-two-cells (the row). The **drain half stays parked**, and so does the
question of whether anything should *act* on the level.

What this page is still for, and why it is not deleted yet:

- the four `guest-exec` gotchas below, which the shipped code deliberately avoids
  and which any future *drain* would have to face;
- the drain analysis (`swapoff -a`, `process_madvise`) and the evidence that it
  probably fixes honesty rather than performance;
- PSI as a possibly-better controlled variable — still unanswered, and now one
  `read_file` call away from being measurable;
- the 2026-08-20 measurement table, which is evidence rather than a durable fact.

Graduated and cut from here: the transport question (D-guest-swap-level), the GVL
finding (D-virsh-cli, which now carries it as an argument against the binding),
the persistent-session idea (D-virsh-session, whose own
note has since graduated and been deleted), and the four gotchas' *contract* (the yardoc on
{Virt::GuestAgent#read_file}).

Sibling to `swap-despite-ballooning.md`: that note diagnoses *why* a ballooned
guest swaps and why the controller can't see it. This one records a **channel
into the guest that turns out to already exist**, and the two capabilities it
puts back on the table — reading the current swap *level*, and *force-draining*
swap.

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

Against the 2000 ms tick, one invocation per running VM per tick, with the
spawn-free column for comparison:

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

Two related worries die outright regardless: guest-side CPU is ~4 ms × 43 200
samples/day ≈ 3 min/day ≈ 0.2 % of one core (so it does *not* meaningfully
perturb the very page-cache numbers being measured), and bandwidth is ~1.9 KB of
base64 per sample, ~6 KB/s at N=6, over a shared-memory ring.

What survives cost analysis untouched is **liveness**, not expense: a wedged
`qemu-ga` is not a 31 ms call, it is an unbounded one, and `bin/virtui:36` has a
single timer thread. A timeout is mandatory on either transport — the shipped
read passes `--timeout 2`.

## What it unlocks

1. ~~**Current swap level.**~~ **Built** — `SwapTotal`/`SwapFree` from
   `/proc/meminfo`, because the balloon gives only cumulative `pswpin`/`pswpout`
   — a rate, never a level. See D-guest-swap-level; nothing here to decide.
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

## Open questions

- **Is PSI the controlled variable, or the swap level?** Answerable *today*:
  {Virt::GuestAgent#read_file} will hand over `/proc/pressure/memory` for any
  guest, and the level is now on screen to compare it against. If PSI wins, the
  framing shifts from "see the scar" to "see the pressure before the damage" —
  and PSI would be a second read (three more agent calls), which is the cost to
  weigh.
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
  That is the fork D-guest-swap-level deliberately did not settle.

