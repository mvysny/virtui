# Guest swap & memory pressure via the QEMU guest agent

**Status:** both questions this note was opened for are decided and graduated.
The swap-level **read is BUILT** (2026-08-21) — {Virt::GuestAgent},
{Virt::GuestSwapSampler}, the `SWAP` row; the choice and roads not taken are
DECISIONS.md D_guest_swap_level, the contract is the yardocs, the user-facing
half is README. The **force-drain is REJECTED** (2026-08-31) — parked swap is
left to drain by demand paging; the analysis, the `swapoff`/`process_madvise`
roads not taken and the `guest-exec` capability question all live in
D_no_force_drain.

What keeps the file alive: one standalone open topic — **PSI / `Committed_AS`
as the controlled variable** — and the 2026-08-20 measurement the sibling note
cites. Sibling to `swap-despite-ballooning.md`: that note diagnoses *why* a
ballooned guest swaps and why the controller can't see it; this one holds the
open question of what the guest-agent channel should read next.

## Open: is PSI the controlled variable, or the swap level?

Answerable *today*: {Virt::GuestAgent#read_file} will hand over
`/proc/pressure/memory` for any guest, and the level is now on screen to
compare it against. PSI rises *before* reclaim does damage and, unlike the
`MemAvailable` metric, is not erased by the swap-out. If PSI wins, the framing
shifts from "see the scar" to "see the pressure before the damage" — and PSI
is a second read (three more agent calls per VM per tick), which is the cost
to weigh (below).

**`Committed_AS`** — the sibling note's fix 8, and its higher-value candidate:
it *leads* demand (a JVM's `-Xmx` commit can announce the burst before the
pages are touched). It is a `/proc/meminfo` field, so it is **already in the
bytes the shipped read fetches every tick** — the measurement fix 8 asks for
costs zero extra agent calls, only parsing.

Also behind the same channel: `Cached`, `pgsteal_*`,
`workingset_refault_file` (those three are `/proc/vmstat`, a second file).

### Cost of a second read

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
  writes and process exits. Now D_no_force_drain's evidence — the drain half
  happens for free once the headroom exists.
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
