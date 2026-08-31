# Guest swaps despite ballooning headroom

**Status:** brainstorm, nothing decided. Maintainer-facing.

The ballooning controller is supposed to make guest swapping impossible: grow the
VM at 65% usage, long before the guest is squeezed enough to reclaim. It doesn't.
A guest with `vm.swappiness=1`, 9.8 GiB of a 32 GiB balloon address space, and a
24 GiB configured ceiling was found sitting at **1.99 GiB of 4.00 GiB swap used**
while reporting a comfortable 61% to virtui.

This doc records the measurement, the three independent reasons the current design
can't prevent it, candidate fixes, one candidate *guideline* ("no disk cache in
the VM") that the same analysis turns out to bear on, and — folded in on
2026-08-21 — the shape of the **grow rule** itself, since "is +30% the right hop?"
turned out to answer itself, plus the shape of the **response** to a non-zero
`swap_out`, now that the signal has been watched long enough to be trusted. The `@trigger_increase_at`
comment in `BallooningVM` encodes one of the misconceptions, so it is a code-level
finding, not just an ops curiosity. A **second observation on 2026-08-26** watched
the same failure happen live rather than reading its scar afterwards; it is the
strongest evidence here that cause 3 is the one that matters.

Read the next section first: three questions about how swapping and guest caching
actually work gate everything else here.

## Blocked on three fundamentals

Nothing below should be turned into a code change or a `DECISIONS.md` entry until
these are answered. They are deliberately **not** brainstormed here — each is a
"how does the machinery actually work" question, and guessing at them is how the
`100 - swappiness` comment got written in the first place. Every open item further
down resolves differently depending on the answers.

1. **How does swapping actually work across guest + qemu + host, and how can it be
   configured?** The whole stack, as one picture: guest swap device, guest reclaim
   entry points, what the balloon does to a guest that is already swapping, how
   qemu's memory backing (`<memoryBacking>`, THP, `memfd` vs anonymous,
   `shared`/`locked`) affects it, whether the *host* swaps qemu's RSS, and which of
   these virtui can see or set. Needed because the controller currently reasons
   about guest reclaim through a single number and one folk formula.
2. **What are the fundamental pros/cons of having swap *in the guest* at all?**
   Candidate framing: a guest swap-out on a host with plenty of free RAM is pure
   waste — real host disk I/O to evict a page that host RAM could have held, plus
   a page that now returns only on demand. Against that: swap is what keeps a
   guest alive through a burst instead of invoking the OOM killer, and it is the
   only reclaim target once the page cache is gone. Includes: is `swapoff` in the
   guest a legitimate configuration for a ballooned VM, or does it just convert
   swap events into OOM kills?
3. **What are the pros/cons of guest disk caches?** Both directions of the
   candidate guideline below: what the guest's page cache buys (readahead, hot
   text, the balloon's shock absorber) versus what it costs (host RAM held in
   qemu's RSS, duplicated against the host's own copy of the image). This is the
   one that decides the guideline.

Where the answers land, per the doc rules: the guideline itself → a
`DECISIONS.md` entry (it has a real fork and a real road not taken); why a
threshold has its specific value → the yardoc next to that constant; anything a
user must configure in the guest → README.

## Measurement

Guest: Ubuntu, kernel 7.0.0-30-generic, 76 min uptime, swap on `/swap.img`
(4 GiB, prio -1), zswap off, no zram. Balloon present as `virtio4`
(`virtio_balloon`, built into the kernel — absent from `lsmod`, per README).

| Quantity | Value |
|---|---|
| virtui's metric `(MemTotal-MemAvailable)/MemTotal` | **61%** (6.01 / 9.80 GiB) → sweet spot, controller idle |
| Swap used | 1.99 / 4.00 GiB (49%) |
| …of which `SwapCached` (also still resident in RAM) | 1.00 GiB → **only ~1.0 GiB genuinely out of RAM** |
| Lifetime `pswpout` / `pswpin` | 2.59 GiB out / 1.59 GiB in — all within 76 min |
| PSI `/proc/pressure/memory` `avg10` / `avg60` | 0.00 / 0.00 — **zero pressure at observation time** |
| `pgsteal_direct` / `pgsteal_kswapd` | 202 435 / 6 130 937 |
| `pgscan_anon : pgscan_file` | 1 : 3.6 (1.65 M : 6.01 M) |
| `workingset_refault_file` | 3 040 842 — page cache actively thrashing |
| Balloon geometry | 256 × 128 MiB blocks = 32 GiB address space, deflated to 9.8 GiB |
| `vm.min_free_kbytes` / `watermark_boost_factor` | 67584 (66 MB) / 15000 |
| Guest page cache (`Cached`) / `balloon.disk_caches` | **not recorded** — gap; see the guideline section below |

Top swap holders were ordinary long-lived desktop processes (IDE, browser helpers,
node, JVMs) at 15–100 MB each — no single runaway. Consistent with a burst that
hit everything at once rather than one process misbehaving.

**The workload, named by the maintainer 2026-08-21:** a **Gradle Java build, or
IntelliJ IDEA starting up — each allocating about 3 GiB.** Not a synthetic burst;
the routine case, and consistent with the swap holders above. IDEA spreads its
3 GiB over tens of seconds (class loading, not a tight loop), perhaps
100–300 MiB/s; a Gradle compile with a warm daemon can be spikier. **The
allocation rate is still unmeasured** and it is the one number the whole
threshold/hop discussion below turns on — one `/proc/vmstat` delta away.

### Second observation, watched live — 2026-08-26

The measurement above is one snapshot taken *after* the event; this is the same
class of guest watched *through* it, so it supplies the ordering the snapshot
could only reconstruct. Reported by the maintainer from virtui's own display, no
guest-side instrumentation:

Workload: **IntelliJ IDEA starting up inside the VM** — the named workload above.

1. Guest used% sat at **55%**, the rest of the guest's RAM being **disk cache** —
   i.e. sitting exactly on `@trigger_decrease_at`, inside the deadband, controller
   idle.
2. Through the ramp the number **refused to rise.** It did not creep toward 65; it
   stayed put, "stubbornly", while IDEA allocated.
3. **Swap climbed instead, to ~2.5 GiB.**
4. *Only then* did used% jump to **65%**, and virtui grew the VM.

No new physics — this is cause 3 below, seen in the time domain instead of
reconstructed from a scar. What it adds:

- **The order of events is now observed, not inferred.** The snapshot was
  consistent with "the burst was absorbed by swap and the metric never moved", but
  it could not exclude "the metric rose, the controller grew, and swap was left
  over from earlier". It can now: **swap moved 2.5 GiB before the metric moved at
  all.**
- **The metric isn't merely erased — it is *pinned*.** Cause 3 predicts
  `percent_used` *falls* as anon pages leave RAM; what actually happened is that
  the fall from eviction and the rise from allocation cancelled, holding the
  reading flat at 55% for the entire ramp. A flat trace is the worst possible
  shape for a threshold controller: it is exactly what a healthy idle VM looks
  like, and unlike a falling trace it doesn't even hint that something is moving.
- **The controller was parked on the shrink edge while the guest was swapping.**
  55% *is* `@trigger_decrease_at`; a slightly heavier eviction would have tipped it
  under and the controller would have **shrunk the VM mid-burst** — the inversion
  in cause 3, one percentage point away from firing, in the routine case.
- **The grow fired ~2.5 GiB of swap-out too late**, and this time we know it was
  the metric's lateness rather than the poll cadence: 2.5 GiB at IDEA's
  100–300 MiB/s is on the order of 10–25 s, several sampling windows, not the
  5–12 s dead time of cause 2. Fixing the poll rate would not have caught this.
  **Cause 3 dominates cause 2 for this workload.**
- **Not cache starvation.** The guest was cache-rich when the burst began (the
  "rest of it was disk cache"), and the kernel swapped anyway — the same
  fallback-path finding as the 4.3 GiB `Cached` measurement, now with the
  reclaim watched live rather than inferred from `workingset_refault_file`.
- **Direct support for fix 1.** `swap_out` was advancing throughout steps 2–3, the
  whole time `percent_used` said nothing was happening. The one signal available
  today would have triggered the grow ~2.5 GiB earlier, and would have blocked the
  shrink the deadband edge was flirting with.

Not recorded, and worth capturing on the next occurrence — all of it visible from
the host, none needing a guest login: the wall-clock length of the flat stretch;
whether `Cached` fell as swap rose (it decides whether the page cache was spent
first, as swappiness=1 predicts, or bypassed); the `balloon.swap_out` delta per
sample, which is the allocation rate this note has wanted since 2026-08-21; and
whether a shrink actually fired at any point during the flat stretch.

## Root causes

### 1. `swappiness=1` does not mean "no swap"

`BallooningVM#initialize` carries:

```ruby
# When the guest mem usage (omitting cache) is above this value, increase guest memory.
# To prevent client swapping, set this lower than `100 - guest vm.swappiness`
@trigger_increase_at = 65
```

`100 - swappiness` is not a memory-percentage threshold and has no such meaning in
the kernel. Swappiness is the *relative cost weight* between the anon LRU and the
file LRU inside `get_scan_count()`, consulted **only once reclaim has already been
entered**. At 1 the kernel biases hard toward evicting page cache, but it falls
back to anon whenever the file LRU is too small or is thrashing — and on the
measured host it *is* thrashing (`workingset_refault_file` = 3.04 M). Observed
scan ratio anon:file = **1 : 3.6**, nowhere near the ~1 : 200 the weight nominally
implies: most anon scanning came from forced-fallback paths, not from the ratio.

Consequence: **no value of `@trigger_increase_at` makes swapping impossible.**
Lowering it buys headroom (see fix 2) but the formula justifying 65 specifically
should go.

Two reclaim paths ignore the controller entirely regardless of threshold:

- **Direct reclaim** (`pgsteal_direct` = 202 435): the allocating task stalled and
  reclaimed synchronously inside the allocation path. There is no window in which
  anything outside the guest can react.
- **Watermark boosting** (`watermark_boost_factor` = 15000, the default): on an
  external-fragmentation event kswapd temporarily raises watermarks by 150% and
  reclaims *above* the normal watermarks — i.e. while memory is still nominally
  plentiful.

### 2. The control loop is 5–12 s behind a µs-fast kernel

`Cache::VMCache#stale?` documents the lag in its own comment: virsh refreshes
balloon data only every ~5 s regardless of the configured stats period, virtui
polls every ~2 s on top, so healthy data is routinely **5–7 s old**, and `stale?`
tolerates up to **12 s** before disbelieving it.

A JVM fork, a `mvn -T` build, or IDE indexing allocates GB/s. The guest can go
60% → 95% → reclaim → swap 2 GiB out → back under 65%, entirely inside one
sampling window. `@increase_memory_by = 30` and the deliberate no-back-off on the
increase branch are the right instinct — the comment there already anticipates
"we may be already late and SWAP is ramping up already" — but they can only ever
fire after the fact.

### 3. Swapping *satisfies* the metric, so it erases its own evidence — and can invert the controller

`MemoryStat#guest_mem` is `ResourceUsage.new(available, usable)` =
`(MemTotal, MemAvailable)`, so `percent_used = (MemTotal - MemAvailable) / MemTotal`.
Evicting anon pages to swap **raises** `MemAvailable`, so `percent_used` falls.

Swap is therefore an unmodeled second actuator competing with the balloon for the
same controlled variable:

- burst → kernel swaps 2 GiB → `percent_used` settles ~60% → virtui reads "sweet
  spot", **never grows the VM**;
- a slightly larger swap-out pushes it to ≤55% → virtui **shrinks** the VM by 10%,
  cementing the swap that growing was supposed to prevent.

And nothing undoes it: swapped pages return only when faulted, one at a time.
Hence the observed end state — swap at half, PSI at 0.00. **A swapping VM and an
idle VM are indistinguishable in the current metric.** That is the core defect;
1 and 2 are what let the burst through in the first place. Watched live on
2026-08-26 (second observation above) the reading did not even sag — allocation
and eviction cancelled and it sat *pinned* at 55% for the whole ramp, which is
worse: a falling trace at least says something is moving.

Corollary for reading the number at all: swap-used is a **high-water scar**, not a
pressure gauge. Half of the measured 1.99 GiB (`SwapCached` = 1.00 GiB) is already
resident in RAM again, still holding its swap slot as a free backing copy.

## Consequence: the threshold must be low, and there are only three exits

Cause 2 is not a bug to be fixed, it is a floor. virsh refreshes balloon data
every ~5 s, virtui polls every ~2 s, and the guest kernel reclaims in
microseconds; no amount of host-side engineering closes a gap of that shape. So
the controller can never be a fast loop — it can only run with a **standing
reserve** large enough that a plausible burst is survivable *without reclaim*
until the next sample lands.

This is the killer argument against the intuitive design ("act at 90%, why waste
RAM"). At 90% of 9.8 GiB the reserve is ~1 GiB — one JVM fork, gone inside a
single sampling window. The reserve has to be sized against *bursts*, not against
steady state, and the burst is what the controller is structurally unable to see.

And the reserve is not abstract free memory: in practice the part of it that
absorbs a burst without I/O is **clean page cache the kernel can drop for free**
(hence "the page cache is the balloon's shock absorber", below — it is the same
statement viewed from the other side).

The measurement says the current 65 / 55 pair is not enough: the guest sat at
**61%**, inside the deadband with the controller idle, while holding 2 GiB of
swap. So 65 is above the real safe line for that workload. Three exits, and only
three:

1. **Lower `@trigger_increase_at`** (and `@trigger_decrease_at` with it, to keep a
   deadband). Costs density: every VM holds more RAM than it needs, so fewer VMs
   fit on the host. Cheapest change; the value has to come from observation, not
   from a formula.
2. **Accept swapping, but make it cheap, reversible and visible** instead of
   trying to make it impossible. That is fix 1 (swap feeds the trigger, shrink is
   blocked while swapping) plus fix 5 (zram, so a swap-out is a compression rather
   than a disk write). Reframes the goal from *no swap* to *no harmful swap* —
   which, given cause 1, is the only goal actually achievable.
3. **Raise `@min_actual` above 8 GiB.** Disfavoured: `min_actual` is global, and
   some VMs are genuinely small ones for which 8 GiB is already generous — raising
   the floor wastes RAM on every one of them to protect one big workload. If this
   is ever taken it should be *per-VM*, not a new global default.

Worth noting about the shape of the knob, independent of its value: the trigger is
a **percentage**, so the absolute reserve scales with `actual` — 35% of 9.8 GiB is
3.4 GiB, but 35% of 2 GiB is 0.7 GiB. Bursts are absolute, not proportional; a
Maven build allocates the same GB in a small VM as in a big one. That argues the
reserve wants an absolute floor (`reserve = max(35%, ~2 GiB)`) rather than being
purely proportional — which would also let exit 1 be taken *without* penalising
large VMs, and is a strictly better lever than exit 3 for the same problem.

**And the named workload settles the floor's value by arithmetic.** At
`min_actual = 8 GiB` with a 65% trigger the controller acts when used ≥ 5.2 GiB, so
the free memory it is defending with is **2.8 GiB — against a 3 GiB allocation.**
The burst does not fit in the reserve at all, and what doesn't fit is reclaimed
before the next sample lands. That is the cleanest explanation yet for the
measurement, and it is arithmetic rather than a tuning opinion. Two consequences:
the absolute floor above wants to be **~4 GiB, not ~2 GiB** (the observed burst
plus dead-time margin); and for a build/IDE guest the honest answer really is
**exit 3, per-VM** — ≥3 GiB standing free at an 8 GiB floor implies a trigger
somewhere in the 25–50% range, which is absurd, so the floor is simply too low for
that role. No grow rule can substitute for a floor, because the grow arrives
5–12 s late by construction (cause 2); **hop size governs recovery, the standing
reserve governs survival.**

## The grow rule: a step where everyone else uses a target

Folded in from a separate note on 2026-08-21. The question that started it was
narrow — "is `+30%` of current `actual` a fast enough hop from the 8 GiB floor?" —
and it dissolved on contact with prior art: **no surveyed controller has a grow
step size at all.** The material is here rather than in its own file because its
conclusions are this note's conclusions (cause 2, cause 3, exit 3).

The constants, from `Virt::BallooningVM`:

```ruby
@trigger_increase_at = 65   # grow when guest used% >= 65
@increase_memory_by  = 30   # ...by 30% of the current actual
@trigger_decrease_at = 55   # shrink when used% <= 55
@decrease_memory_by  = 10   # ...by 10%, at most once per @back_off_seconds = 10
@min_actual          = 8.GiB
```

with `new_actual = actual * (100 + delta) / 100`, clamped to
`min_actual..max_memory`. Two cadence facts turn the hop into a *velocity*: the
`@last_update_at == mem_stat.last_updated` guard allows at most **one hop per new
guest sample** (~5 s — cause 2), and `back_off` after any change gates only the
*decrease* branch, so a hop buys ≥10 s of protection from the shrinker.

### Three properties of the current rule, in arithmetic

**1. Velocity scales with VM size, but bursts don't.** At the 8 GiB floor the
first hop is 2.4 GiB ≈ 490 MiB/s. At 20 GiB it is 6 GiB ≈ 1.2 GiB/s. The
geometric rule accelerates exactly where the absolute-burst argument says it
needn't, and is stingiest where a small VM is most exposed.

**2. Every hop from the trigger overshoots into shrink territory.** Inflating
doesn't change `used`, so after a hop taken at exactly 65% the guest reads
`65 / 1.3 =` **50%** — five points below `@trigger_decrease_at`. The largest hop
whose landing spot stays inside the deadband is `65/55 - 1 =` **18%**. Hop and
deadband are therefore not independent knobs, and at 30% the controller is
guaranteed to hunt: grow, 10 s back-off, one −10% shrink (50% → 55.6%), settle at
the very edge of the band. The parked RAM costs density for ~20 s per event —
6 GiB of it on a 20 GiB VM.

**3. Geometric growth's one virtue is O(log) hops.** 8 GiB → 24 GiB is **5 hops
≈ 25 s**; a flat 2 GiB step needs **8 hops ≈ 40 s**.

### The "cap the hop at ~2 GiB" idea is not a cap — it is a replacement

`hop = min(30% × actual, 2.GiB)` is active whenever `actual > 6.67 GiB`. Since
`@min_actual = 8.GiB` it is active for **every VM in the fleet, always** — the
proportional term never wins, so "capped at 2 GiB" silently degenerates to a flat
2 GiB step. Worse, 2 GiB is *below* today's 2.4 GiB first hop, so as literally
proposed it makes the 3 GiB-burst case slightly worse. A genuine cap has to exceed
`0.3 × min_actual = 2.4 GiB` to leave the proportional rule any range (4 GiB bites
above 13.3 GiB), and wants to be a multiple of the 128 MiB balloon block.

### Prior art, searched 2026-08-21

| Controller | Controlled variable | Target | Grow rule | Shrink rule |
|---|---|---|---|---|
| **Xen self-ballooning** (`drivers/xen/xen-selfballoon.c`) | `Committed_AS` (guest) | `Committed_AS + totalreserve_pages` | `up_hysteresis = 1` → **jump the entire gap**, one step | `down_hysteresis = 8` → 1/8 of the gap per 5 s |
| **oVirt MoM** (`doc/balloon.rules`) | `balloon_cur − mem_unused`, as a **moving average** (`StatAvg`) | `used + 20% × current` (`min_guest_free_percent`) | `max(+5%, target)` — the 5% is a *floor*, the target overrides it upward, **no upper limit** | exactly `−5%` of current (`max_balloon_change_percent`), floored at the target |
| **Hyper-V Dynamic Memory** | commit charge ("memory pressure") | `needed × (1 + buffer)`; buffer **20% default**, 5–200% range → target pressure 83% | undisclosed (pressure × weight arbitration) | undisclosed |
| **VMware ESXi** | *host* free-memory state (6/4/2/1%) | share-based entitlement, not guest demand | n/a — never grows on guest demand, only reclaims under host pressure | proportional-share + idle-memory tax |
| **K8s VPA** | p95 of usage *history* | `p95 + 15% margin` (`--recommendation-margin-fraction`) | n/a (restart / in-place resize) | n/a |
| **virtui today** | `MemAvailable`-derived used% | **none — a threshold, not a target** | `+30% of current` | `−10% per ≥10 s` |

Five findings, in descending order of how much they should change the design:

1. **Nobody has a grow step size; they compute a target and jump to it.** Xen's
   up-hysteresis of 1 and MoM's "target overrides the +5% floor" are the same rule:
   on the way up, gain 1, one step, no rate limit. `+30%` has no analogue in any of
   them — so the answer to "what hop do others use?" is *none*, which retires the
   question rather than answering it. Fix 7 below.
2. **The asymmetry is universal and lives entirely on the shrink side.** Xen
   1/8-of-gap, MoM a hard −5%; ours is −10%, twice MoM's. Grow-fast/shrink-slow is
   right, but we implement the *fast* half with a step where everyone else uses a
   target, and the *slow* half twice as fast as the closest comparable.
3. **Noise is damped on the input, not by limiting the output step.** MoM averages
   its stats (`StatAvg`), VPA takes p95 of history, Xen leans on a metric that is
   inherently smooth. This retires the obvious objection to a gain-1 jump ("one bad
   sample moves the VM a long way"): damp `used`, then jump — don't rate-limit the
   jump.
4. **The reserve everyone converges on is ~15–20%; ours is 35%.** MoM 20%, Hyper-V
   20% default, VPA 15%; our 65% trigger implies 35%, landing at 50% after a hop.
   **We are already far more conservative than any of them and the guest swapped
   anyway** — strong outside evidence that the defect is the *metric* (cause 3),
   not the threshold. It also means exit 1 is pushing on the one knob prior art
   says is already over-tightened.
5. **Both demand-driven controllers use a forward-looking metric.** Xen
   `Committed_AS`, Hyper-V commit charge — both count memory the guest has
   *promised itself*, which leads demand. `MemAvailable` trails it. That difference,
   not the hop, is what lets them get away with one jump per interval, and it is
   cause 3 seen from the outside: a trailing metric is erased by the very reclaim it
   should predict. Fix 8 below.

One caveat on all of it: Xen self-ballooning and MoM's `mem_unused` are read
*guest-side*, with no 5–12 s dead time. We cannot copy gain-1 grow without
accounting for that lag — which is precisely why fix 8 matters more than fix 7.

## Candidate fixes

Roughly in order of value. Not decided; 1 is the one that closes the inversion.

1. **Feed swap into the trigger.** virtio-balloon already reports `stat-swap-in` /
   `stat-swap-out` alongside the fields `MemoryStat` parses today. Proposal:
   **Both halves shipped 2026-08-26**, as two independent classes under
   `lib/virt/ballooning_vm/` — `SwapOutRaiseVoter` (rate over a 1 MiB/s noise floor →
   the same `+30%` the usage trigger takes) and `SwapOutShrinkVetoer` (a 60 s veto from
   the last such sample, i.e. the cooldown of correction 2 rather than the literal
   per-sample form). Rationale and roads not taken: `DECISIONS.md` D_swap_raise_vote and
   D_swap_shrink_veto; constants and their provenance sit next to their values in each
   class. **What is left of this fix is the bound on the raise** — see the open item
   below; everything else here is kept only where it still argues that.

   This is what makes a swapping VM visible to the controller at all, and it kills
   the shrink-after-swap inversion. **`swap_out` flat is what "at rest" looks
   like** — and it is exactly the distinction `MemAvailable` cannot make: the
   measured guest, 853 MiB parked in swap with `swap_out` motionless, is
   indistinguishable from a healthy one under today's metric and trivially
   distinguishable under this one.

   The signal was verified on 2026-08-20 and is sound. What we know now:

   - **The fields are surfaced, in KiB, and faithful.** `virsh domstats --balloon`
     carries `balloon.swap_in` / `balloon.swap_out`. Cross-checked against the
     guest's own `/proc/vmstat` in the same minute, they match **to the digit**:
     `swap_in` 2 195 252 KiB = `pswpin` 548 813 × 4096, `swap_out` 3 205 344 KiB =
     `pswpout` 801 336 × 4096. No libvirt-side smoothing, no unit surprise — the
     host number is an unmangled copy of the guest kernel counter.
   - **Swap-used is *not* derivable from them.** Slots are also freed by write
     faults and by process exit, with no corresponding `swap_in`, so the level can
     fall while both counters sit still. Rate and level are separate reads; the
     level needs `/proc/meminfo`, i.e. the guest agent — see
     `swap-via-qemu-guest-agent.md`. **Hence the "swap-used > 0" half of the
     shrink guard above is dropped**: it is unobtainable from `domstats`, and
     `swap_out` advancing is the part that matters anyway.
   - **Use `swap_out` only. `swap_in` is not a harm signal — it is inverted.**
     `swap_in` advancing means pages are being faulted *back*, i.e. the
     demand-driven drain working; on a desktop-ish guest it ticks constantly and
     every tick is a small good thing. A controller watching "swap activity" in
     general would grow the VM in response to the guest *healing*. At most,
     `swap_in` is a UI indicator ("draining") or a later input to *un*-blocking the
     shrink guard.
   - **Both counters are cumulative and monotonic within a boot.** A decrease is
     therefore only possible across a guest restart, where they reset to zero.
     Treat any decrease as a reset, not a negative delta, or the first sample after
     a power-cycle produces a large bogus swing. virtui already tracks that
     boundary — `Virsh#set_mem_stats_period` has to be re-armed after every full
     power-off.

   **The read half is built (2026-08-21).** `balloon.swap_in`/`swap_out` are parsed
   into `MemoryStat`, and `Cache::VMCache#swap_out_rate` differences them into
   bytes/s — the same seam that already derives `cpu_usage` and
   `mem_data_age_seconds`, so it inherits their lifecycle. `UI::VMWindow` renders a
   `SWAP` row per swapping VM — since 2026-08-21 with the guest's actual swap
   *level* beside it, read through the guest agent (D_guest_swap_level): root
   cause 3's erased evidence recovered rather than estimated. Nothing acts on
   either figure yet: **that was deliberate** — the trigger threshold had to be
   observed before it could be chosen, and the observation below is that
   measurement. Two mechanics worth keeping if this note
   is trimmed:

   - the rate is `Δswap_out / Δlast_updated`, i.e. per *guest-reported* interval, not
     per poll. That sidesteps libvirt's ~5 s refresh: when `last_updated` hasn't
     moved the previous rate is carried forward rather than reported as 0 (which
     would blink the signal off on every other poll);
   - a decrease in the counter is read as a reboot (fresh baseline, rate 0), never as
     a negative delta.

   **Watched in operation, 2026-08-21: the signal is quiet at rest.** With the row on
   screen across the fleet, the rate sits at exactly `0` unless something is genuinely
   happening to that VM. No baseline trickle, no idle drift, nothing that has to be
   thresholded away — **non-zero *is* the event.** That was the one number blocking
   the trigger (correction 1 below), and it landed on the good side. Two consequences:

   - the threshold stops being a tuned constant and becomes a **noise floor**: a few
     pages per interval is one aging pass, not pressure. It no longer has to separate
     "pressure" from "idle trickle", because on these guests there is no idle trickle
     to separate it from. Any value between "a handful of pages" and "a fraction of a
     balloon block per second" behaves identically, so the constant stops being
     load-bearing;
   - the ratchet pathologies correction 1 was defending against (cgroup-local reclaim,
     MGLRU aging) are **not what this fleet does**, so the threshold was never going to
     be what caught them: on a guest that *does* trickle, a threshold high enough to
     filter it is high enough to blind the trigger to a real burst. The defence has to
     move from filtering the **input** to bounding the **response**.

   Caveat to keep: "quiet at rest" is an observation about *these* guests (Ubuntu
   desktop-ish, `vm.swappiness=1`, disk swap, no zram). A guest with zram, MGLRU or a
   systemd `MemoryHigh=` slice may well trickle — which is why the noise floor stays
   in the design rather than being dropped for "any advance".

   **Two corrections to the proposal above, from designing it.**

   1. **The trigger must be a rate over a threshold, not "any advance"** — but the
      threshold is a noise floor, not the defence. A bare delta plus a shrink veto is
      a two-sided ratchet: cgroup-limited reclaim inside the guest (systemd
      `MemoryHigh=`, a container — where more VM memory relieves nothing) and
      MGLRU-style proactive aging of cold anon both tick `swap_out` benignly, and a VM
      grown 30% per tick and never allowed to shrink walks to `max_memory` and stays
      there. ~~The rate threshold is the whole defence, and its value has to come from
      watching an *idle* guest's trickle — a number nobody has measured yet.~~
      **Measured (above): at rest it is zero.** So the threshold is cheap and
      uncritical — and it cannot be the defence: the ratchet has to be stopped on the
      output side instead, with a bound on how far the swap signal alone may grow a VM
      plus a check that the growth actually helped.
   2. ~~**The shrink veto needs a cooldown, not per-sample "advancing".**~~
      **Graduated** — this is the shape that shipped, and the argument for it now
      lives in `DECISIONS.md` D_swap_shrink_veto.

   **And the veto alone is not enough** — worth stating plainly because it is easy to
   conclude the opposite from "accept the swapping, just stop making it worse". The
   inversion and the invisibility are separate halves of root cause 3: the veto fixes
   the inversion, but the *measured* state (61% used, controller idle, 2 GiB swapped)
   had no shrink in flight at all. Veto-only leaves a stable bad equilibrium — guest
   trickles to disk, `percent_used` sits mid-deadband, no shrink is attempted so the
   veto never fires, trickle continues. Only a grow trigger fixes what was observed.

   **Still open — the one thing left in this fix: the ratchet.** What shipped is the
   naive response: vote fires, `+30%`, every guest sample the rate stays up. Nothing
   bounds how far the swap signal alone may raise a VM except `max_memory`, and nothing
   checks that a raise *helped*. Two consequences, both recorded in D_swap_raise_vote so
   they are not rediscovered: a normal burst overshoots (8 GiB → ~22.8 GiB in ~20 s
   against a 3 GiB allocation, unwound over the following ~100 s by the ordinary
   shrink), and a guest whose reclaim more memory cannot fix — cgroup-limited inside the
   guest, MGLRU aging — is raised to `max_memory` and parks there. The material for the
   fix is "The response shape" below; the threshold value is *not* open (a noise floor),
   nor the cooldown length (60 s), nor the composition with the existing branches.
2. **Buy headroom for the 5–7 s blind spot.** Drop `@trigger_increase_at` to
   ~50–55 (moving `@trigger_decrease_at` down to keep a deadband), and/or give the
   reserve an absolute floor instead of a purely proportional one. The invariant to
   aim for: *a plausible burst must be survivable within one sampling window without
   reclaim.* At 65% of 9.8 GiB there are only 3.4 GiB of slack, which one parallel
   Maven build eats. See "the threshold must be low" above for why this is
   structural and for why raising `@min_actual` is the disfavoured exit.
3. **Guest-side: raise `vm.min_free_kbytes`** (66 MB on the measured host). A bigger
   free reserve buys the allocator time to wait for the balloon instead of entering
   direct reclaim. Costs a little RAM; no controller change.
4. **Ops recovery:** `swapoff -a && swapon -a` clears the scar for a clean baseline.
   Safe when only-in-swap is small (~1.0 GiB here) and `MemAvailable` covers it.
5. **Guest-side: `zram` swap with priority above the disk swap.** Not just a
   performance trick — it changes what root cause 3 does to the metric. A page
   compressed into zram *stays resident* (zsmalloc pages, which `MemAvailable`
   excludes), so a 1 GiB swap-out at 3:1 frees ~0.66 GiB rather than 1 GiB: the
   evidence-erasure is damped by the compression ratio instead of being total.
   And the scar heals — a zram `pswpin` is a decompression, not a disk read, so
   the guest naturally faults pages back in as it touches them, whereas a
   `/swap.img` page can sit out for hours. Deserves a slot above its number here;
   it is the cheapest thing on this list that touches the actual defect. Costs:
   RAM for the compressed pool, CPU per fault. Open: does it interact badly with
   the balloon (the pool is unreclaimable, so inflating against a full zram is
   worse than inflating against page cache)?
6. **Host-side: stop caching the disk image (`cache=none`).** See the candidate guideline below
   — the "don't cache the same bytes twice" instinct is right, but the layer to
   drop is the host's, not the guest's. Costs nothing on the controller, and
   removes a chunk of host RAM that virtui's host view currently attributes to
   nobody.
7. **Replace the fixed grow step with a target.** The prior-art consensus (grow
   rule section above), in our terms:

   ```
   target = used + max(reserve_pct × used, reserve_floor)
   new_actual = target.clamp(actual.., max_memory)   # the grow branch never shrinks
   ```

   Xen's `Committed_AS + reserve` and MoM's `used + 20%`, and the same thing as the
   absolute reserve floor argued under "the threshold must be low" — applied to the
   grow rule instead of to the trigger. It *unifies two knobs into one pair*:
   trigger value and hop size collapse into a set-point plus an absolute reserve
   floor, property 2's guaranteed overshoot disappears by construction, and
   time-to-inflate stops depending on distance. Two things prior art says to get
   right: **damp the input** (a 2–3 sample moving average of `used`, MoM-style)
   rather than rate-limiting the output, and **size `reserve_floor` from the
   observed burst** — 3 GiB observed means ~4 GiB, not the ~2 GiB first guessed.

   The shapes considered and rejected, kept for the eventual `DECISIONS.md` entry:

   - *proportional with an absolute cap* (`min(30% × actual, cap)`) — bounds the
     blast radius of one false-positive read on a big VM, which is its real merit,
     but no surveyed controller rate-limits growth, and see the "not a cap" finding
     above;
   - *flat absolute step* (`hop = 2.GiB`) — the honest form of "bursts are
     absolute", but below today's first hop and it costs time-to-inflate on big VMs;
   - *fraction of `max_memory`* (MoM's `max_balloon_change_percent` shape) — kills
     the size-dependent acceleration, but `max_memory` is often set carelessly large
     (32 GiB of balloon address space for a 9.8 GiB working size), so it is a poor
     proxy for operator intent. **Worth adopting on the shrink side regardless**,
     together with MoM's "change big enough" gate;
   - *rate-derived hop* (`Δused / Δt × lookahead`) — data is already there and it
     answers "fast enough?" by measurement, but the derivative of a 5 s-lagged
     quantized signal is noisy and it still can't see the burst *between* samples;
     improves the second hop, not the first. Composes with this fix as the lookahead
     term;
   - *escalating hop / slow-start* — costs one sample interval on the first hop of a
     real burst, precisely the window cause 2 says we can't afford;
   - *per-VM learned high-water mark* — VPA's p95-of-history is the disciplined
     version; sticky without a decay rule, and largely subsumed by making
     `@min_actual` per-VM, which is the auditable form of the same knowledge;
   - *no grow path at all — boot at max, shrink only* — ESXi's actual shape. Listed
     because it clarifies why grow-fast/shrink-slow exists: it destroys density at
     boot, and N VMs starting together would over-commit the host with only the slow
     path to fix it.
8. **Control on a forward-looking metric (`Committed_AS`).** Deserves a slot at the
   top of this list, not the bottom: it is the only candidate that attacks cause 2
   rather than working around it. Both demand-driven controllers in the wild lead
   demand instead of trailing it (finding 5 above), and the specific reason to care
   here is the named workload — **Gradle and IDEA are both JVMs with a fixed
   `-Xmx`**, so a JVM's committed heap can appear in `Committed_AS` when the heap is
   committed rather than when the pages are touched. That would turn the 3 GiB burst
   from an unpredictable event into an announced one, buying exactly the warning the
   5–12 s blind spot costs us.

   Not free and not proven. The balloon doesn't carry `Committed_AS`, so it needs
   the guest-agent channel (`swap-via-qemu-guest-agent.md` — already costed, already
   measured); and *how much* warning it really gives depends on JVM commit
   behaviour, which is a measurement rather than a claim. **Do that measurement
   before anything else here:** read `Committed_AS` and `MemAvailable` in the same
   loop while starting IDEA and see whether the former leads. If it does, it
   supersedes fix 7 and most of the grow-rule discussion; if it doesn't, fix 7 is
   the fallback.

## The response shape: what happens when `swap_out` is non-zero

**Overtaken in part, 2026-08-21 (later the same day): the swap *level* is now read
straight from the guest.** {Virt::GuestAgent} fetches `SwapTotal`/`SwapFree` from
the guest's own `/proc/meminfo` through `qemu-guest-agent`, and the `SWAP` row
shows it beside the rate (DECISIONS.md D_guest_swap_level, D_swap_row_two_cells).
What that does to this section:

- the **`debt` candidate below is now the fallback, not the plan.** For a guest
  with the agent there is nothing to reconstruct — the number it estimates is
  measured. `debt` matters only for guests that cannot be asked (no agent,
  Windows, `guest-file-*` in `BLOCK_RPCS`), and there its bias and its unresolved
  `HALF_LIFE` are the same problem they always were;
- the **"display-first, because the estimate is falsifiable" staging step is
  done** — by measurement rather than by estimate, which is the better version of
  it. `effective_used = used + level` is now a *fact* a controller could consume,
  which moves the open question from "is the estimate good?" to "should anything
  act on it?" (the three shapes below, unchanged);
- fork 1 (`HALF_LIFE`) applies only to the fallback now; fork 2 (a fleet-level
  host budget before any grow response) is untouched and still looks like the
  precondition;
- what is **not** answered: a level says nothing about *pressure*. If PSI turns
  out to be the better controlled variable
  (`ideas/swap-via-qemu-guest-agent.md`), this section is arguing about the wrong
  input.

Brainstormed 2026-08-21, on the back of the quiet-at-rest observation in fix 1 —
which is the whole premise: *non-zero means something*, so a response is worth
designing. **Nothing is decided here.** The section records one candidate in enough
detail to argue with, the three alternatives it has to be argued *against*, and the
forks that have to be settled before any of it is written. It sits next to fix 1
(the signal) and fix 7 (the grow rule) because it is the missing middle: fix 1 says
what we can see, fix 7 says how much to move, this says what seeing it should mean.

### Candidate: reconstruct the erased metric, don't add a second trigger

Root cause 3 is that swapping erases its own evidence — evicting N bytes raises
`MemAvailable` by ~N, so `used` falls by exactly the amount of harm done. A signal
that is reliably 0 at rest is enough to *reconstruct* what was erased, which is a
different move from bolting a trigger onto the side of the metric. One derived
number, no new branch in `BallooningVM`, no state machine: the existing 65/55
thresholds start working because they finally see a number that isn't lying.

```ruby
# Cache::VMCache.diff — the seam that already derives cpu_usage / swap_out_rate
debt = prev.swap_debt * 0.5**(Δt / HALF_LIFE) + Δswap_out - Δswap_in
debt = debt.clamp(0, nil)                       # 0 on a counter reset (reboot)
effective_used = mem_stat.guest_mem.used + debt
```

The invariant that makes it more than a fudge factor: **swapping is a transfer
between `used` and `debt`; only real allocation moves the sum.**

| event | `used` | `debt` | `used + debt` |
|---|---|---|---|
| guest allocates 3 GiB | ↑ | – | **↑ 3 GiB** — the thing the controller must see |
| kernel swaps 2 GiB out | ↓ 2 GiB | ↑ 2 GiB | flat |
| guest faults those pages back in | ↑ | ↓ | flat |
| a process holding swapped pages exits | – | ↑ phantom | ↑ phantom — the only error, and it errs safe |

So `debt` estimates *bytes currently parked in swap* — the level `domstats` cannot
give us (fix 1: slots are freed without a `swap_in`). Netting `swap_in` is what
makes it a level rather than an integral of activity, and it also disposes of fix
1's "`swap_in` is inverted" worry: a healing guest drains debt and raises `used` by
the same amount, so it is neither grown nor shrunk. The one bias — slots freed with
no fault-in — is the *only* reason `HALF_LIFE` exists, which is worth stating
because it makes the constant's provenance a bias correction rather than a tuning
opinion.

**Against the measurement** (`MemTotal` 9.8 GiB, `used` 6.01 = 61 %, ~2 GiB parked,
controller idle):

| | today | with debt |
|---|---|---|
| at rest, 2 GiB parked | 61 % → sweet spot, **idle forever** | (6.01+2)/9.8 = **82 %** → grow |
| after one +30 % hop (→ 12.7 GiB) | — | 47 % raw, **63 % effective** → deadband, settles |
| a further 200 MiB swap-out | 60 % → still idle | 65 % → nudged, proportionally |

One hop, landing inside the deadband, no hunting — and note this is the *same*
+30 % hop property 2 of the grow-rule section calls guaranteed overshoot, rescued
only because the debt term lands the VM back in the band. That coupling is a fork,
not a feature: it means the debt design and fix 7 have to be sized together.

**Two properties that distinguish it from the bare trigger.** First, it responds in
proportion to the harm — 200 MiB of swap moves the metric 2 points, 2 GiB moves it
20. Second, it is self-limiting: debt is bounded by the guest's swap device (4 GiB
on the measured guest) and every grow raises the denominator, so the loop converges
on `actual ≈ real demand + reserve`. The cgroup/`MemoryHigh=` pathology (fix 1
correction 1) therefore costs one hop plus one decay period of parked RAM instead
of a walk to `max_memory` — which would make the response cap and the "did growing
even help?" check optional safety rather than load-bearing. Fewer knobs than the
alternative, if it holds.

**Staging, display-first, because the estimate is falsifiable.** `debt` is the
number an operator actually wants on the SWAP row (*how much is parked*), and it can
be eyeballed against `free -h` inside the guest. Showing it validates or kills the
whole design before any control code exists — the same discipline that produced the
quiet-at-rest observation in the first place. Then the shrink veto (fix 1 correction
2), which cannot make anything worse and which debt makes mostly emergent anyway
(853 MiB parked lifts a 50 % VM to 59 %, out of shrink range). Then, and only then,
`effective_used` feeding the thresholds. One mechanical trap for that last step:
`ResourceUsage#percent_used` clamps to `0..100`, which is harmless for a threshold
comparison and wrong for fix 7's target rule, which needs the un-clamped demand.

### The three alternatives it has to beat

| shape | what happens when the rate is non-zero | the case against |
|---|---|---|
| **Bare second trigger** (fix 1 as first written) | `rate > floor` ⇒ grow `+30 %`, veto shrink | Swapping continues for seconds *after* the grow (queued writes, deflate latency), so the healthy case fires 2–3 times: 9.8 → 12.7 → 16.6 → 21.5 GiB, and the veto parks it there. **It ratchets on success, not just on pathology.** Response size is also unrelated to harm size |
| **Explicit latch** (`calm` → `swapping` → `recovering`) | state change; `recovering` forbids shrink and lowers the grow trigger | Readable, and it shows well in the UI. But it is a mode: it has to compose with `back_off`, the boot back-off and the user's disable, and its lowered trigger is a second copy of the 65/55 pair — two threshold sets to keep consistent |
| **Operator-only — no control action at all** | log the episode, mark the VM, let the human act | The honest conservative fork for a small app: the signal is good, and a feedback loop we cannot test on demand may be worse than a human reading a row that is now trustworthy. Costs nothing and forecloses nothing |

### Forks, none of them settled

1. **`HALF_LIFE` — forget the scar, or remember the lesson?** The widest axis, and
   it changes what the feature *is*: **seconds** → debt is just a rate integrator,
   barely better than the bare trigger; **~60 s** → a recovery window covering the
   burst plus the fault-back period; **hours** → the VM stays sized for the worst
   thing it did today; **∞, no decay** → the phantom bias becomes permanent and
   `used + debt` becomes a **high-water mark learned from evidence** — i.e. per-VM
   `min_actual` (exit 3, the note's own candidate for the real fix) arriving
   automatically with an audit trail instead of as a hand-set knob, and with one
   constant fewer. That last variant deserves weighing against the grow-rule
   section's *per-VM learned high-water mark* rejection, which called the shape
   "sticky without a decay rule" — here the decay rule is the whole question.
2. **Does a fleet-level host budget have to land first?** `BallooningVM` has no view
   of host RAM. Today's metric is so blind that simultaneous fleet-wide growth is
   unlikely; any working swap response makes "every VM swaps at once, every VM grows
   at once, the host over-commits and swaps qemu's RSS" a reachable state — strictly
   worse than the guest swapping, and the one failure mode none of the four shapes
   above defends against. Possibly a precondition rather than a follow-up.
3. **The at-`max_memory` case wants its own answer.** A VM swapping at its ceiling
   is the one state where virtui *cannot* help; today the status text says only "I
   want to increase memory … but can't go over configured max mem". With the signal
   we can say it is actively harming — which argues for a loud `$log.warn` and a UI
   state, once per **episode** rather than once per poll. That needs an episode
   object (opens on the first over-floor rate, closes after N seconds quiet,
   carrying peak rate and total bytes) — also the right unit for a sticky "swapped
   4 min ago" marker, since today's warn colouring only shows while the rate is
   live, so a burst between two glances leaves nothing behind but the lifetime
   totals.
4. **Does `disk_caches` join as a second input?** Same shape, no new data channel,
   and it is parsed-but-discarded today: refuse to shrink a guest whose page cache
   is already below a floor, because there is no cheap reclaim victim left. Already
   an open question below; listed here because it would share whatever seam `debt`
   lands in.

## Candidate guideline: "no disk cache in the VM — the host caches the image anyway"

Stated as a general rule to live by, not a one-off tweak, because it would guide
other decisions (past ones too): *don't cache the same bytes twice — the guest's
disk cache occupies host memory as well, so it is host RAM spent on a copy the
host already has.* Bound for `DECISIONS.md` once fundamental 3 is answered; the
verdict below is **provisional** and section 5 is the reason it can't be signed
off yet.

**Provisional verdict: the premise is right, the remedy is inverted — drop the
*host's* copy, not the guest's.** Five points, the first four against the
guideline in order of how decisive they are, the fifth for it:

### 1. It buys the controller nothing — the metric already excludes cache

`MemoryStat#guest_mem` is `(available, usable)` = `(MemTotal, MemAvailable)`, and
`MemAvailable` is *free + reclaimable file/slab − watermarks*. So
`percent_used = (MemTotal − MemAvailable) / MemTotal` is already ≈ *anon +
unreclaimable kernel*, with the page cache subtracted out. The
`@trigger_increase_at` comment's "(omitting cache)" is literally true. The
measured 61% was **not** inflated by cache, and a guest with zero page cache
would have reported the same 61%. Removing the cache moves the number by ~0.

Note the corollary: `disk_caches` (`balloon.disk_caches`) *is* already parsed by
`Virsh` and carried in `MemoryStat`, and is used by **nothing** — not the
controller, not the UI. It is free information about the guest's second-largest
memory consumer, currently discarded.

### 2. It makes root cause 1 *worse*: it removes the cheap reclaim victim

Cause 1 says the kernel falls back to evicting anon "whenever the file LRU is too
small or is thrashing", and the measurement shows exactly that
(`workingset_refault_file` = 3.04 M, anon:file scan 1 : 3.6 instead of the ~1 : 200
that `swappiness=1` nominally implies). A shrunken, thrashing file LRU is *the*
mechanism that produced the swap. Shrink it to zero and every reclaim event has
only one victim class left — anon — so *all* reclaim becomes swap. The direction
of travel indicated by the measurement is **more** guest cache, not less: it is
evidence supporting fix 2 (headroom), not an argument for starving the guest.

Same point from the balloon's side: **clean page cache is the balloon's shock
absorber.** Inflating a balloon is only free when the guest has droppable clean
pages to hand back. A guest with no page cache has nothing to give but anon, so
every inflation forces a swap-out. "No guest disk cache" and "ballooning" are
directly at odds.

Third angle, already in the data: `vm.swappiness=1` *is* "prefer to evict page
cache over anon" — the measured guest is already configured maximally against
keeping a page cache, and it swapped anyway.

### 3. It isn't implementable

Linux has no page-cache-off switch; buffered I/O goes through the page cache,
period. Everything that looks like a knob isn't:

- `vm.vfs_cache_pressure` — dentry/inode *slab*, not the page cache.
- `drop_caches` — a debug facility, global, and it evicts hot executable text and
  mmap'd pages too, so it buys a re-read storm.
- cgroup v2 — `memory.max`/`memory.high` cap *total* charge; there is no
  file-only limit.
- `swappiness` — see above, already at the extreme.
- `O_DIRECT` / `fadvise(DONTNEED)` — per-application, and the measured workload
  (IDE, JVMs, node, Maven) is all buffered I/O. Not imposable from outside.

Also, "no disk cache" would take the guest's *executable* pages with it: program
text and mmap'd libraries live in the file LRU and must be **resident in guest
RAM to run**. The host cannot lend the guest a page; it can only serve a fault.

### 4. Host cache hits aren't free, and the premise may not even hold

Terminology trap: the `cache=` attribute on `<disk><driver>` controls whether the
**host** caches the image — it has no effect on the guest's own page cache. And
whether the host caches at all depends on it: with `cache=writeback` /
`writethrough` / `unsafe` it does; with `cache=none` / `directsync` (O_DIRECT)
it does not. libvirt with no `cache=` attribute inherits QEMU's default
(`writeback`, host cache on), but `virt-manager` / `virt-install` commonly write
`cache='none'` — in which case there is no double caching to eliminate and the
premise is simply false for that VM. **Check the XML before reasoning about it.**
(Also: on ZFS the relevant cache is the ARC, not the page cache, and O_DIRECT
semantics differ.)

Even where the host does cache, the two hits are not interchangeable: a guest
cache hit is a memory read; a host cache hit costs a virtio-blk exit plus the
guest block layer (tens of µs) and *stalls the faulting thread*. The guest's
cache is also the semantically better-placed one — it knows file boundaries,
readahead windows and hot inodes, where the host sees opaque image offsets.

So the correct expression of the instinct is the opposite assignment: **one cache
layer, and put it in the guest** — `cache=none` on the disk, and give the guest
enough RAM (via the balloon) that its file LRU sits above the thrash point.
Exception where host caching genuinely wins: many VMs sharing a read-mostly base
image, where the host's copy dedups across guests.

Worth flagging for virtui specifically: host page cache holding a VM's image is
charged to the *host*, not to the VM, so `System::Info` shows it as host RAM
consumption belonging to nobody, and a large dirty image working set feeds host
`dirty_ratio` latency spikes. That is a small argument for `cache=none` that is
about virtui's own host view rather than about the guest.

### 5. The strongest form of the guideline — the reclaimability asymmetry

The point that keeps this open, and that the four objections above do not touch:
**the two caches differ in who can take them back.**

- The **host's** page cache for the image is, from the host kernel's view, clean
  reclaimable file pages. Under pressure they evaporate at zero cost, and they are
  shared across every VM booting the same base image.
- The **guest's** page cache is, from the host kernel's view, anonymous memory
  inside qemu's RSS. The host cannot reclaim it at all — not cheaply, not
  expensively-but-correctly. The only mechanism that gets it back is *inflating the
  balloon*, i.e. virtui itself, on a 5–12 s lag. Until then it is sticky host RAM.

So on pure host-RAM efficiency the guideline is **right**, and more strongly than
the original phrasing claims: caching in the guest doesn't merely duplicate, it
converts flexible host memory into inflexible host memory. That is a real cost,
and it is the cost the maintainer's instinct was pointing at.

The collision is with the shock-absorber argument: that same inflexible memory is
the only thing standing between a burst and a swap-out, precisely *because* the
host can't take it away mid-burst. Stickiness is the cost and the feature.

Which means this is a genuine trade-off, not a misconception to be corrected — and
it is exactly what fundamentals 2 and 3 have to settle before a decision gets
written. Possible shapes of the answer, for whoever picks it up: it may split by
VM role (a build/desktop VM wants the guest cache; a read-mostly server VM on a
shared base image wants the host's), or it may reduce to "keep the guest cache but
size it via `min_actual`/the reserve rather than by leaving it unbounded".

## Open questions

- Is PSI the better controlled variable than `MemAvailable`? `/proc/pressure/memory`
  `some avg10` rises *before* reclaim does damage and, unlike the MemAvailable
  metric, does not get erased by the swap-out. ~~Needs a guest-side reporting
  channel virtui can read — the balloon doesn't carry it.~~ **No longer blocked:**
  the balloon still doesn't carry it, but `qemu-guest-agent` reads it for free —
  see `swap-via-qemu-guest-agent.md`. Worth designing?
  **Second candidate, same channel, and now the higher-value one:**
  `Committed_AS` — see fix 8.
- Should shrink be gated on *any* evidence of recent reclaim (`pgsteal_*` deltas),
  not just swap? A VM whose page cache is being churned is also under pressure.
- ~~Is the increase step (+30% of current `actual`) fast enough from the 8 GiB
  floor?~~ **Answered: it is the wrong question** — see the grow-rule section. No
  surveyed controller has a grow step size, and against a 3 GiB burst at an 8 GiB
  floor no hop size helps. What replaces it: **does `Committed_AS` lead
  `MemAvailable` when IDEA or a Gradle daemon starts, and by how much?** That
  decides whether fix 8 exists, and everything else here is tuning by comparison.
- Should `@min_actual` become per-VM before any of this? For the named workload
  that looks like the real fix (exit 3), and it makes the grow-rule question much
  less urgent.
- Should the shrink side adopt MoM's `−5%` and its "change big enough" gate as a
  separate, cheap, low-risk change? Independent of the grow question, and our
  `−10%` is twice the closest comparable.
- Does the grow rule want asymmetric treatment near the floor? A VM at
  `@min_actual` has never been sized by observation, so its first move is the least
  informed one we ever make.
- Does the fix belong partly in the guest (a virtui-aware agent that reports PSI /
  swap deltas promptly) rather than entirely in host-side polling? That's a
  scope expansion — the README's ballooning prerequisites are currently
  "balloon device + stats period", nothing installed in the guest.
- Do these findings hold on a guest with a normal `swappiness=60`? The analysis
  predicts the inversion is *worse* there, not better.
- ~~How big *is* the guest's page cache when the controller reads 61%?~~
  **Answered: 4.3 GiB** — not the 37 MB the `domstats` fixture braced us for. So
  the guest is *not* cache-starved, and since `workingset_refault_file` keeps
  climbing *with* 4.3 GiB of cache, **the thrash is not a size problem** and cause
  1's fallback needs a different explanation. Measurement and consequences:
  `swap-via-qemu-guest-agent.md`. Still worth surfacing `disk_caches` (already in
  `MemoryStat`, still thrown away) in `UI::VMWindow`.
- Should `disk_caches` be a *second* input to the controller — e.g. refuse to
  shrink a VM whose page cache is already below some floor, on the grounds that
  there is no cheap reclaim victim left? Same shape as gating shrink on swap
  (fix 1), and it needs no new data channel.
- What `cache=` mode do the managed VMs actually use? Determines whether the
  double-caching in the guideline section is real or hypothetical, and it is one `virsh
  dumpxml` away. Does virtui want to *show* it (a per-VM column) so the question
  stops recurring?

## Where the nuggets land when this graduates

The intro to "Blocked on three fundamentals" covers the guideline's targets; this
is the rest, per the CLAUDE.md graduation map.

- the response to a non-zero `swap_out` finally chosen, with the three rejected
  shapes and the `HALF_LIFE` fork → **DECISIONS.md**. Both halves landed on
  2026-08-26 (D_swap_shrink_veto, D_swap_raise_vote); what is left to land is the
  *bound* on the raise, and it belongs in D_swap_raise_vote, which already names its
  absence as a consequence. Whatever constant survives
  (noise floor, half-life, cooldown) carries its provenance in the yardoc next to
  it — the noise floor's being "the rate is 0 at rest on these guests", the
  half-life's being "corrects the phantom debt from slots freed without a
  fault-in", not a tuning opinion.
- the grow rule finally chosen, **with the prior-art table as its provenance**, and
  the rejected shapes under fix 7 → **DECISIONS.md**. There is no entry covering
  the grow rule yet, so whichever shape wins earns the first one; the table is the
  strongest available argument for any constant that survives, and the rejected
  shapes are exactly the roads-not-taken material that file is for.
- what each surviving constant is sized against — the 3 GiB Gradle/IDEA burst for
  the reserve floor, the ~5 s sample cadence for anything rate-shaped → **the
  yardoc next to that constant**, per the numbers-carry-their-provenance rule.
- the user-visible behaviour change → **README**, "Automatic Balloon
  inflate/deflate", which currently states the flat 30% / 10% pair as fact.
- "damp the input, don't rate-limit the output" and "never call the guest agent
  from the UI thread" (if fix 8 lands) → **CLAUDE.md**, as cross-cutting
  invariants.
- if fix 8 wins, `Committed_AS` as a controlled variable → merges into
  `swap-via-qemu-guest-agent.md`'s open question (it already carries the
  candidate, and the fact that the field is in the already-fetched
  `/proc/meminfo`).
- the measurements, the properties-1–3 arithmetic and the exit/fix numbering are
  evidence about the *current* code, not durable facts: they die with this file.
