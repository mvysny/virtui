# How other hypervisors decide balloon size

**What this file owns:** reference material about *other* systems — the balloon
control rules of the established hypervisors, as evidence for virtui's own
choices. It is deliberately descriptive: it records what other people built and
what they picked, not what virtui should do. The *decision* that cites this
evidence belongs in `DECISIONS.md`; the per-constant rationale belongs in the
yardoc next to the constant. Surveyed 2026-08-21.

> This is the sixth documentation kind in `CLAUDE.md`'s "Documentation kinds"
> table, and the rule that governs it is there: **this file describes,
> `DECISIONS.md` decides.** Keep our conclusions out of it so the survey stays
> re-usable by the next decision, and mark every claim primary-source or
> secondary — these are other people's constants and they move.

## The one-screen version

| System | Decision input | Target rule | Grow limit | Shrink limit | Cadence |
|---|---|---|---|---|---|
| **Xen self-ballooning** (guest-side) | `Committed_AS` | `Committed_AS + totalreserve_pages` | none — `up_hysteresis=1`, jump the whole gap | `down_hysteresis=8` → ⅛ of the gap | 5 s |
| **oVirt MoM** | `balloon_cur − mem_unused`, moving average | `used + 20% × cur` | none — target overrides the `+5%` floor | exactly `−5%` of cur | host-pressure driven |
| **Hyper-V Dynamic Memory** | commit charge ("pressure") | `needed × (1 + buffer)`, buffer 20% default | undisclosed | undisclosed | continuous |
| **Proxmox VE** | **host** used vs an 80% target | share-proportional: `balloon_min + (pool/Σshares) × shares` | **`maxchange` = 100 MiB per VM per round** | same 100 MiB, symmetric | 10 s |
| **XenServer `squeezed`** | **host** free memory | every VM at the same `(t−dmin)/(dmax−dmin)` fraction | none stated; 5 s no-progress ⇒ "inactive" | same | 10 s |
| **VMware ESXi** | **host** free state + *sampled* active memory | share-based entitlement, idle-taxed | n/a — never grows on guest demand | n/a | 60 s sample period |
| **virtui today** | `MemAvailable`-derived used% | **none — a threshold, not a target** | `+30% of current` | `−10%` per ≥10 s | ~5 s |

Two axes separate these, and virtui is unusual on both.

**Axis 1 — what drives the decision.** *Host pressure* (Proxmox, `squeezed`,
ESXi): the input is how full the **host** is; guest demand is at most a
tie-breaker for who gets served first. These systems never grow a VM because the
guest wants memory — they grow it because the host has spare. *Guest demand*
(Xen self-ballooning, Hyper-V, MoM, virtui): the input is a number from inside
the guest, and the host budget is a constraint applied afterwards.

**Axis 2 — step or target.** Everyone except virtui computes a **target** and
moves toward it. virtui is the only surveyed system that picks a **step** —
`+30%` — with no notion of where it is trying to end up. That is why "what hop
size do others use?" has no answer: mostly the question doesn't arise.

## Host-pressure redistributors

### Proxmox VE — the one system that *does* cap the hop absolutely

Primary source: `PVE/AutoBalloon.pm` (`compute_alg1`) and `PVE/Service/pvestatd.pm`
(`auto_ballooning`). The most directly comparable design here, because it is
also a KVM/QEMU + `virsh`-era toolstack driving `virtio-balloon`.

```perl
# pvestatd.pm — once per $updatetime = 10 s
my $target = int($config->{'ballooning-target'} // 80);   # keep the HOST at 80%
my $goal   = int($memtotal * $target / 100 - $memused);   # bytes to hand out (or claw back)
my $maxchange = 100 * 1024 * 1024;                        # 100 MiB, per VM, per round
PVE::AutoBalloon::compute_alg1($vmstatus, $goal, $maxchange);
```

- **Deadband on the goal, in absolute bytes:** grow only if `goal > 10 MiB`,
  shrink only if `goal < -10 MiB`, else do nothing. A "not worth the churn" gate.
- **Per-VM desired size is share-proportional**, not demand-proportional:
  `desired = balloon_min + int((alloc_new / shares_total) * shares)`, where
  `shares` defaults to 1000 (0 opts the VM out entirely). VMs that hit `maxmem`
  or `balloon_min` are removed and the remainder is redistributed — the `while
  ($rest && $repeat && $progress)` loop.
- **`maxchange` is a hard, symmetric, absolute per-round cap.** Combined with the
  10 s cadence that is **10 MiB/s per VM** — roughly 50× slower than virtui's
  ~490 MiB/s first hop from the 8 GiB floor. So the "cap the hop in absolute
  bytes" instinct *is* represented in the wild; it is just set two orders of
  magnitude lower, because Proxmox is not trying to survive a guest burst. It is
  slowly rebalancing a host, and a guest that allocates faster than 10 MiB/s
  simply reclaims locally instead.
- Guest demand enters only as a **priority split**: a VM counts as comfortable if
  `freemem > balloon_min * 0.25`, and grow requests are offered to the
  *un*-comfortable list first, shrink requests to the comfortable list first.

### XenServer / XCP-ng `squeezed` — the admin declares the range, the host picks one fraction

Primary source: the [`squeezed` design doc](https://github.com/xapi-project/xenopsd/blob/master/squeezed/doc/design/README.md).
The purest form of host-pressure redistribution, and it uses **no guest metric at
all**.

Each domain gets an admin-set `dynamic-min` / `dynamic-max` range. The policy
then keeps every domain at the *same* position within its own range:

```
(target − dynamic-min) / (dynamic-max − dynamic-min)   ... equal for all domains
```

Memory plentiful ⇒ everyone sits at `dynamic-max`. Memory scarce ⇒ everyone sits
at `dynamic-min`. There is one scalar for the whole host and the per-VM answer
falls out of the admin's declared range. Notable mechanics virtui has no
equivalent of:

- the policy engine is polled every **10 s**, and can also be driven on demand by
  an allocation request (starting a VM);
- a domain that **fails to make progress toward its target within 5 s is declared
  *inactive***, has `maxmem` pinned, and is excluded from that round — an explicit
  liveness check on the balloon driver. virtui assumes the balloon obeyed;
- `maxmem` is used as a hard ceiling so a domain cannot allocate past what the
  policy intends while it is being squeezed.

### VMware ESXi — sampled active memory, share-based entitlement, idle tax

Architecturally the outlier: ESXi neither asks the guest nor trusts it. It
**statistically samples page accesses** to estimate *active* memory
(`Mem.SamplePeriod`, 60 s default), and derives each VM's entitlement from its
shares — adjusted by the **idle memory tax** (`Mem.IdleTax`, default **75%**),
applied progressively as the idle/active ratio rises, so a VM hoarding untouched
pages has its shares-per-page ratio discounted and is reclaimed from first.

Reclamation is gated by host free-memory *states* — classically the 6% / 4% / 2%
/ 1% high/soft/hard/low thresholds (newer releases derive these from `minFree`
rather than fixed percentages) — and proceeds in a fixed order: page sharing,
then ballooning, then compression, then host swapping. The balloon can claim at
most ~65% of guest RAM.

The point for virtui: **ESXi has no grow-on-demand path whatsoever.** A guest
under pressure is not a signal it acts on; it acts when the *host* is under
pressure. Growth happens only as the passive consequence of the host having spare
memory to un-reclaim.

## Guest-demand targeters

### Xen self-ballooning — target-driven, gain 1 on the way up

Primary source: `drivers/xen/xen-selfballoon.c`. Note two caveats before drawing
conclusions from it: it runs **inside the guest** (so it has no host-side
sampling lag at all), and it was removed from mainline Linux along with the tmem
driver. As a control law it is still the cleanest statement of the pattern:

```c
goal_pages = vm_committed_as + totalreserve_pages;
if (cur_pages > goal_pages)
    tgt_pages = cur_pages - ((cur_pages - goal_pages) / selfballoon_downhysteresis);  /* 8 */
else if (cur_pages < goal_pages)
    tgt_pages = cur_pages + ((goal_pages - cur_pages) / selfballoon_uphysteresis);    /* 1 */
```

Defaults: `uphysteresis = 1`, `downhysteresis = 8`, interval 5 s. Up-hysteresis of
1 means **jump the entire gap in one step**; down-hysteresis of 8 gives back an
eighth of the excess per interval. The asymmetry virtui implements with two
percentages, Xen implements with one divisor each way.

### oVirt MoM — a hybrid, and the closest thing to a peer

Primary source: [`doc/balloon.rules`](https://github.com/oVirt/mom/blob/master/doc/balloon.rules).
Also KVM/libvirt, also polling `virtio-balloon` stats from the host, so its
choices transfer most directly. Constants:

| Constant | Value | Meaning |
|---|---|---|
| `pressure_threshold` | 0.20 | host free below this ⇒ host is under pressure |
| `pressure_critical` | 0.05 | ⇒ balloon aggressively, accept guest swapping |
| `min_guest_free_percent` | 0.20 | free memory an unconstrained guest should keep |
| `max_balloon_change_percent` | 0.05 | per-step change limit |
| `min_balloon_change_percent` | 0.0025 | below this, don't bother — churn costs more |

The outer policy is host-pressure driven (shrink everyone / grow everyone), but
the per-VM target is guest-demand driven:

```lisp
;; grow
guest_used_mem = (StatAvg "balloon_cur") - (StatAvg "mem_unused")
balloon_min    = max(guest.balloon_min, guest_used_mem + 0.20 * balloon_cur)
balloon_size   = balloon_cur * (1 + 0.05)
if balloon_size < balloon_min: balloon_size = balloon_min      ;; target WINS
clamp to balloon_max; apply only if change_big_enough
```

Three things to take from it:

1. **On grow, the `+5%` is a *floor*, not a cap** — `balloon_min` (the target)
   overrides it upward, with no upper limit. Grow is target-driven and unbounded;
   only *shrink* is genuinely rate-limited at `−5%`.
2. **`StatAvg`, not the latest sample.** MoM damps the *input* with a moving
   average. This is how a gain-1 jump is made safe against a noisy reading —
   rather than by limiting the output step.
3. `change_big_enough` (0.25% of current) is the absolute-granularity gate that
   Proxmox spells as 10 MiB and virtui doesn't have.

### Hyper-V Dynamic Memory — the buffer, stated as a product feature

Per [Microsoft's docs](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/dynamic-memory),
Hyper-V reads "performance counters in the virtual machine that identify
**committed** memory" and sizes the VM as:

```
memory buffer = (memory the VM actually needs) × (buffer % / 100)
```

with the buffer reportedly defaulting to **20%** over a 5–200% range — i.e. a
steady-state target pressure of `100/(100+20) ≈ 83%` used. `Startup` / `Minimum`
/ `Maximum RAM` bound it, and `Memory Weight` arbitrates when the host cannot
satisfy every VM's buffer. Microsoft does not publish the increment or the rate.

## Adjacent mechanisms, for completeness

- **Bare QEMU/KVM + libvirt has no policy at all.** `virsh setmem` is a
  mechanism; nothing in the stack decides when to call it. That absence is the
  reason both MoM and virtui exist.
- **virtio-mem** replaces the balloon for resizing rather than steering it: the
  host sets a `requested-size` and the guest plugs/unplugs blocks. It is a target
  interface by construction — there is no percentage logic, and block granularity
  (multi-MiB) is the quantum instead.
- **Free page reporting** (`virtio-balloon` `VIRTIO_BALLOON_F_PAGE_REPORTING`) is
  passive: the guest hints which pages are free and the host may reclaim them. No
  controller, no target, complementary to any of the above.
- **VirtualBox** exposes the balloon as a manual operation
  (`VBoxManage controlvm … guestmemoryballoon`) with no built-in automatic policy.
- **Kubernetes VPA** is not a hypervisor, but it is the same control problem and
  its convention is worth recording: target the **p95 of observed usage history**
  plus a **15% safety margin** (`--recommendation-margin-fraction`). Third
  independent instance of "damp the input over time, then target it".

## What this survey says about virtui

Descriptive, not prescriptive — the argument belongs in `DECISIONS.md`, and the
live analysis is in `ideas/swap-despite-ballooning.md`.

1. **Nobody grows by a fixed percentage step.** virtui's `+30%` has no analogue
   in any surveyed system. Every one of them either computes a target and moves
   toward it, or moves by an absolute per-round quantum.
2. **Where a hop limit exists it is absolute, not proportional** — Proxmox's
   100 MiB — and it is a *rate limit for fairness*, not a burst-survival
   mechanism. The two systems that must survive a guest burst (Xen
   self-ballooning, MoM) deliberately leave grow *unbounded*.
3. **Noise is damped on the input.** MoM's `StatAvg`, VPA's p95-over-history,
   Xen's inherently smooth `Committed_AS`. None of them limits the output step to
   compensate for a jumpy reading.
4. **The reserve everyone converges on is 15–25%:** MoM 20%, Hyper-V 20%,
   VPA 15%, Proxmox's comfort test 25% of `balloon_min`. virtui's 65% trigger
   implies 35% — more conservative than any of them.
5. **Both demand-driven targeters use a forward-looking metric** — `Committed_AS`
   and Windows commit charge, both counting memory the guest has *promised
   itself*. virtui's `MemAvailable` trails demand instead of leading it.
6. **Two mechanisms virtui lacks entirely:** a "change big enough to bother" gate
   (MoM 0.25%, Proxmox 10 MiB), and a balloon **liveness check** (`squeezed`
   declares a domain inactive after 5 s of no progress; virtui assumes the
   balloon obeyed).
7. **Cadence is not virtui's problem.** 5 s (Xen), 10 s (Proxmox, `squeezed`),
   60 s (ESXi sampling) — virtui's ~5 s effective rate is at the fast end already.

## Provenance

Primary sources — actual code or design docs, quoted above:

- [`PVE/AutoBalloon.pm`](https://github.com/proxmox/pve-manager/blob/master/PVE/AutoBalloon.pm)
  and [`PVE/Service/pvestatd.pm`](https://github.com/proxmox/pve-manager/blob/master/PVE/Service/pvestatd.pm)
- [oVirt MoM `doc/balloon.rules`](https://github.com/oVirt/mom/blob/master/doc/balloon.rules)
- [`squeezed` design doc](https://github.com/xapi-project/xenopsd/blob/master/squeezed/doc/design/README.md)
- `drivers/xen/xen-selfballoon.c` (pre-removal Linux tree)
- [Kubernetes VPA recommender](https://github.com/kubernetes/autoscaler/blob/master/vertical-pod-autoscaler/pkg/recommender/logic/recommender.go)

Vendor documentation:

- [Hyper-V Dynamic Memory](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/dynamic-memory)
  — the buffer formula and the commit-charge input are documented; **the 20%
  default and the 5–200% range are from secondary sources**, as is the derived
  83% target pressure.
- [Memory tax for idle VMs](https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere/7-0/vsphere-resource-management/administering-memory-resources/how-esxi-hosts-allocate-memory/memory-tax-for-idle-virtual-machines.html)
  (`Mem.IdleTax` 75%) and *Understanding Memory Resource Management in VMware ESX
  Server*. The 6/4/2/1% free-memory states are the classic published values;
  current releases derive them from `minFree`, so treat them as illustrative of
  the shape rather than as today's numbers.

Everything in this file describes other people's systems at a point in time.
Re-check before leaning on a specific constant.
