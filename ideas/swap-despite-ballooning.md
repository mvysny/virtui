# Guest swaps despite ballooning headroom

**Status:** brainstorm, nothing decided. Maintainer-facing.

The ballooning controller is supposed to make guest swapping impossible: grow the
VM at 65% usage, long before the guest is squeezed enough to reclaim. It doesn't.
A guest with `vm.swappiness=1`, 9.8 GiB of a 32 GiB balloon address space, and a
24 GiB configured ceiling was found sitting at **1.99 GiB of 4.00 GiB swap used**
while reporting a comfortable 61% to virtui.

This doc records the measurement, the three independent reasons the current design
can't prevent it, candidate fixes, and one candidate *guideline* ("no disk cache in
the VM") that the same analysis turns out to bear on. The `@trigger_increase_at`
comment in `BallooningVM` encodes one of the misconceptions, so it is a code-level
finding, not just an ops curiosity.

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
1 and 2 are what let the burst through in the first place.

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

## Candidate fixes

Roughly in order of value. Not decided; 1 is the one that closes the inversion.

1. **Feed swap into the trigger.** virtio-balloon already reports `stat-swap-in` /
   `stat-swap-out` alongside the fields `MemoryStat` parses today. Proposal:
   - treat any advance in `swap_out` since the last sample as an **immediate growth
     trigger**, independent of `percent_used`;
   - **block the decrease branch entirely** while `swap_out` is advancing.

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
   `SWAP` row per swapping VM. Nothing acts on it yet: **that is deliberate**, the
   threshold below has to be observed before it can be chosen. Two mechanics worth
   keeping if this note is trimmed:

   - the rate is `Δswap_out / Δlast_updated`, i.e. per *guest-reported* interval, not
     per poll. That sidesteps libvirt's ~5 s refresh: when `last_updated` hasn't
     moved the previous rate is carried forward rather than reported as 0 (which
     would blink the signal off on every other poll);
   - a decrease in the counter is read as a reboot (fresh baseline, rate 0), never as
     a negative delta.

   **Two corrections to the proposal above, from designing it.**

   1. **The trigger must be a rate over a threshold, not "any advance".** A bare
      delta plus a shrink veto is a two-sided ratchet: cgroup-limited reclaim inside
      the guest (systemd `MemoryHigh=`, a container — where more VM memory relieves
      nothing) and MGLRU-style proactive aging of cold anon both tick `swap_out`
      benignly, and a VM grown 30% per tick and never allowed to shrink walks to
      `max_memory` and stays there. The rate threshold is the whole defence, and its
      value has to come from watching an *idle* guest's trickle — a number nobody has
      measured yet. Hence the visualization landing first.
   2. **The shrink veto needs a cooldown, not per-sample "advancing".** Literal
      per-sample unblocks on the first quiet tick, which is precisely the case
      `swap-via-qemu-guest-agent.md` observed: a shrink fired with 853 MiB in swap and
      `pswpout` flat. A guest that just swapped and went quiet is the one that least
      wants shrinking — it hasn't had time to fault its working set back. Cooldown
      from the last over-threshold sample also serves as the level-free proxy for the
      one thing the swap *level* would have answered: when is it safe to shrink again.

   **And the veto alone is not enough** — worth stating plainly because it is easy to
   conclude the opposite from "accept the swapping, just stop making it worse". The
   inversion and the invisibility are separate halves of root cause 3: the veto fixes
   the inversion, but the *measured* state (61% used, controller idle, 2 GiB swapped)
   had no shrink in flight at all. Veto-only leaves a stable bad equilibrium — guest
   trickles to disk, `percent_used` sits mid-deadband, no shrink is attempted so the
   veto never fires, trickle continues. Only a grow trigger fixes what was observed.

   Still open: the threshold value (observation), the cooldown length, and how the
   latch composes with `BallooningVM`'s existing grow/shrink branches.
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
- Should shrink be gated on *any* evidence of recent reclaim (`pgsteal_*` deltas),
  not just swap? A VM whose page cache is being churned is also under pressure.
- Is the increase step (+30% of current `actual`) fast enough from the 8 GiB floor?
  Two steps to reach ~13.5 GiB, ≥10 s of real time given the data lag.
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
