# Guest swaps despite ballooning headroom

**Status:** brainstorm, nothing decided. Maintainer-facing.

The ballooning controller is supposed to make guest swapping impossible: grow the
VM at 65% usage, long before the guest is squeezed enough to reclaim. It doesn't.
A guest with `vm.swappiness=1`, 9.8 GiB of a 32 GiB balloon address space, and a
24 GiB configured ceiling was found sitting at **1.99 GiB of 4.00 GiB swap used**
while reporting a comfortable 61% to virtui.

This doc records the measurement, the three independent reasons the current design
can't prevent it, and candidate fixes. The `@trigger_increase_at` comment in
`BallooningVM` encodes one of the misconceptions, so it is a code-level finding,
not just an ops curiosity.

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

## Candidate fixes

Roughly in order of value. Not decided; 1 is the one that closes the inversion.

1. **Feed swap into the trigger.** virtio-balloon already reports `stat-swap-in` /
   `stat-swap-out` alongside the fields `MemoryStat` parses today. Proposal:
   - treat any advance in `swap_out` since the last sample as an **immediate growth
     trigger**, independent of `percent_used`;
   - **block the decrease branch entirely** while swap-used > 0 or `swap_out` is
     advancing.
   This is what makes a swapping VM visible to the controller at all, and it kills
   the shrink-after-swap inversion. Open: which field(s) libvirt actually surfaces
   in `domstats` on this setup, and whether swap-used is derivable or needs
   `stat-swap-*` deltas accumulated locally.
2. **Buy headroom for the 5–7 s blind spot.** Either drop `@trigger_increase_at` to
   ~50–55 (moving `@trigger_decrease_at` down to keep a deadband), or raise
   `@min_actual` above 8 GiB. The invariant to aim for: *a plausible burst must be
   survivable within one sampling window without reclaim.* At 65% of 9.8 GiB there
   are only 3.4 GiB of slack, which one parallel Maven build eats.
3. **Guest-side: raise `vm.min_free_kbytes`** (66 MB on the measured host). A bigger
   free reserve buys the allocator time to wait for the balloon instead of entering
   direct reclaim. Costs a little RAM; no controller change.
4. **Ops recovery:** `swapoff -a && swapon -a` clears the scar for a clean baseline.
   Safe when only-in-swap is small (~1.0 GiB here) and `MemAvailable` covers it.

## Open questions

- Is PSI the better controlled variable than `MemAvailable`? `/proc/pressure/memory`
  `some avg10` rises *before* reclaim does damage and, unlike the MemAvailable
  metric, does not get erased by the swap-out. Needs a guest-side reporting channel
  virtui can read — the balloon doesn't carry it. Worth designing?
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
