# Research — the stack virtui drives (libvirt/`virsh`, the QEMU guest agent, the Linux guest kernel, the ruby-libvirt binding) and the hypervisors surveyed for prior art

What the things we don't own actually do. About *them*, never us: a sentence starting "we chose"
is a `D_`. `## R_<slug> — <title>`, one claim per bullet, one provenance marker per claim —
**[docs]**, **[src]**, **[verified <date>, <version>]**, **[unverified]** (a hypothesis; a design
built on it says so). A claim is earned by its provenance, or by having cost real work to find
out. Checked against the author's Ubuntu KVM host on the dates each claim names; the hypervisor
survey against each project's `master` on 2026-08-21. Cite by slug, `R_<slug>`, never
by position; `grep '^## R_' design/research.md` is the index. The first entry is the ruler: every
later one trims to its length.

---

## R_ruby_libvirt_gvl — ruby-libvirt holds the GVL for the whole of every call

- The extension imports no `rb_thread_*` symbol at all, so no libvirt call releases Ruby's
  GVL for its duration. **[src, ruby-libvirt 0.8.4]**
- Measured with a blocking `Libvirt::open` to an unroutable address: a ticker thread stopped
  dead for the whole ~10 s hang. A slow or wedged libvirtd therefore freezes every Ruby
  thread, not one. **[verified 2026-08-21, ruby-libvirt 0.8.4]**
- `Process.wait` on a child process does release the GVL, so a `virsh` subprocess that hangs
  costs one late update on its own thread. **[docs]**
- The binding does not expose everything `virsh domstats` reports; closing the gap is tracked
  as [virtui bug #1](https://github.com/mvysny/virtui/issues/1). **[verified 2025-11-11]**

## R_virsh_repl — `virsh` as a long-lived REPL: readline, `-q`, error framing

- Interactive `virsh` runs on GNU readline, which echoes every request line before the reply
  and emits a `virsh # ` prompt after it, so a payload containing the prompt string appears in
  the stream before the real prompt does. **[verified 2026-08-21]**
- readline handles `SIGWINCH` even when its streams are pipes: on a resize it repaints the
  input line — with `TERM=dumb` (no `ce` capability) that is `"\r"`, a run of spaces the width
  of the line, `"\r"`, then a fresh prompt; 521 bytes on the dev box. **[verified 2026-08-23]**
- After `SIGWINCH` readline re-derives its width from the terminal and does not consult
  `COLUMNS` again; the dev box measured the width dropping to ~512, after which longer command
  lines are echoed in horizontal-scroll mode (`"\r<…"`). **[verified 2026-08-23]**
- The kernel delivers terminal-generated signals (`SIGWINCH`, `SIGINT`, `SIGTSTP`) to the whole
  foreground process group; a child in its own group (`pgroup: true`) receives none. **[docs]**
- `virsh` exits 0 on EOF of its stdin, so closing the pipe leaves no orphan. **[verified 2026-08-21]**
- Without `-q`, a one-shot `virsh <cmd>` appends a blank line that the REPL does not; with
  `-q` the two produce byte-identical output. **[verified 2026-08-21]**
- The REPL executes commands strictly one at a time, so output for a later command cannot
  precede the end of an earlier one. **[src]**
- In the REPL a failed command prints `error: …` to stderr and the session stays alive; a
  host with no libvirtd leaves `virsh` failing every command in a healthy REPL. There is no
  per-command exit status. **[verified 2026-08-21]**
- `virsh`'s own tokenizer removes single quotes, and JSON backslashes inside single quotes
  reach the daemon untouched. **[verified 2026-08-21]**

## R_libvirt_balloon_stats — guest memory statistics: the collection period and its refresh rate

- The guest memory-stat collection period defaults to 0 (disabled); until `virsh dommemstat
  --period N` or `<stats period='N'/>` on the `<memballoon>` device sets it, the guest-reported
  fields (`balloon.usable`, `available`, `unused`, `last-update`) stay at their boot-time
  values while the host-sourced fields (`cpu.time`, `balloon.rss`) keep moving. **[docs]**
- The period is a live property of the running QEMU process: it survives a guest reboot but
  not a power-off. **[verified 2026-06-10]**
- `dommemstat --period` fails on a domain without a balloon device. **[verified 2026-06-10]**
- Regardless of the period requested, libvirt refreshes the guest balloon data only about
  every 5 s, so `balloon.last-update` on a healthy guest is routinely 5–7 s behind a 2 s
  poller. **[verified 2026-06-10]**
- `balloon.swap_in` / `balloon.swap_out` are since-boot I/O counters (the guest's `pswpin` /
  `pswpout`); they never fall when swap slots are freed. **[docs]**
- A guest boots with all of `<memory>`; the balloon inflates to `<currentMemory>` only once the
  guest's driver loads, ~20 s in, in 1 s `balloon-change` steps (4 → 3.6 → … → 1 GiB). Stats
  collected before then describe the full-size guest: `balloon.unused` 3.6 GiB against a
  `balloon.current` of 1 GiB. **[verified 2026-10-24, libvirt 12.0, Ubuntu 26.04 guest]**

## R_qemu_guest_agent — `qemu-guest-agent` through `virsh qemu-agent-command`

- `guest-file-open` / `guest-file-read` / `guest-file-close` read a guest file in three RPCs;
  the read comes back base64-encoded. Distros may block the `guest-file-*` commands via the
  agent's blacklist. **[docs]**
- `guest-exec` returns only a PID; the output needs a second `guest-exec-status` round-trip,
  which does not complete until the guest process has exited. It runs as root in the guest.
  **[docs]**
- With no agent connected, `qemu-agent-command` is refused immediately by libvirt
  (`… agent is not connected`) — not a timeout. A *wedged* agent is a timeout, bounded only by
  the command's `--timeout` flag. **[verified 2026-08-23]**
- No guest has its agent connected within 6 s of `virsh start`; 20–40 s is the normal window,
  and the agent goes down before libvirt calls the domain stopped. **[verified 2026-08-23]**
- `virsh guestinfo <dom> --os` has no `--timeout` flag. **[docs]**
- `guest-get-osinfo` exists from qemu-ga 2.10; older agents refuse it while `guest-file-*`
  works. **[docs]**
- Per-call latency of a `qemu-agent-command` round-trip (libvirtd + QMP + virtio-serial),
  session transport, dev box: ~13 ms; a one-shot `virsh` process adds ~18 ms on top.
  **[verified 2026-08-21]**
- The libvirt phrasing for a `guest-file-open` on a missing path in a non-Linux guest is
  assumed to contain `no such file or directory`; no such guest with an agent was at hand to
  capture it. **[unverified]**

## R_osinfo_db — libosinfo metadata in a domain definition, and what osinfo-db ships

- virt-manager and `virt-install --os-variant` write
  `<metadata><libosinfo:libosinfo><libosinfo:os id="http://ubuntu.com/ubuntu/25.10"/>…` into
  the domain XML. `virsh metadata <dom> --uri http://libosinfo.org/xmlns/libvirt/domain/1.0`
  returns just that element, with the `libosinfo:` prefix stripped. **[verified 2026-08-23]**
- Every `<os id>` in [osinfo-db](https://gitlab.com/libosinfo/osinfo-db) is
  `http://<vendor-host>/<short-id>/<version>`; reducing the 980 ids on `main` to
  `vendor-host/short-id` gives 76 keys, and each entry's own `<family>` puts them in 12
  families. **[src, osinfo-db main 2026-08-23]**
- Short-ids are not guessable from the vendor name: Alpine's is `alpinelinux` under
  `alpinelinux.org`, and `linuxmint.com` / `kali.org` are not vendors osinfo-db has ever had.
  **[src, osinfo-db main 2026-08-23]**
- `microsoft.com` hosts two short-ids, `win` and `msdos`, so the vendor host alone does not
  give a family. **[src]**
- OS/2 is not in osinfo-db at all (no `ibm.com` vendor), so it can be neither declared nor
  detected. **[src, osinfo-db main 2026-08-23]**
- `http://libosinfo.org/unknown` is a real, declarable id meaning "unknown". **[src]**
- A hand-written domain XML usually carries no libosinfo metadata; on the author's
  virt-manager fleet 4/4 domains did. **[verified 2026-08-23]**
- The osinfo-db Ubuntu 26.04 ships stops at `ubuntu25.10`, so `--osinfo ubuntu26.04` fails on
  the release's own host. **[verified 2026-10-24]**

## R_uefi_cloud_image_first_boot — virt-install's `--cloud-init` and shim's first-boot reset

- On an empty NVRAM, shim's `fallback.efi` writes the boot entry and then resets the machine.
  **[docs]**
- With the Ubuntu 26.04 cloud image under OVMF that reset is a libvirt `reboot` event 5.8 s in,
  still in firmware. **[verified 2026-10-24, libvirt 12.0]**
- During virt-install's install phase the domain has `on_reboot=destroy`, so that reset ends as
  `shut off (shutdown)`. With `--noautoconsole` and no `--wait` nothing restarts it.
  **[verified 2026-10-24, virt-install 5.1.0]**
- `--cloud-init` attaches its seed for that first boot only, so the guest next boots seedless.
  A NoCloud seed left in a CD-ROM is applied once per `instance-id`. **[verified 2026-10-24]**

## R_virsh_domifaddr — `virsh domifaddr` and its three address sources

- With no `--source`, `domifaddr` reads `lease`, byte-identical output. **[verified 2026-09-21]**
- One row per address: Name, MAC address, Protocol, Address, whitespace-separated; a further
  address of the same interface has `-` in Name and MAC. Without `-q` a header row and a `---`
  rule come first; `-q` drops both. **[verified 2026-09-21]**
- `lease` and `arp` name the host-side tap (`vnet0`); `agent` names the guest's own interface
  (`enp1s0`) and also lists `lo` (`127.0.0.1/8`, `::1/128`) and the link-local IPv6.
  **[verified 2026-09-21]**
- `arp` reports every address with prefix `/0`: a neighbour entry has no netmask.
  **[verified 2026-09-21]**
- `lease` knows only what libvirt's own dnsmasq handed out, so a bridged guest has none; `arp`
  knows only what is in the host's neighbour table. **[docs]**
- With `-q`, a running guest with no lease or neighbour entry prints nothing at all (not even a
  newline) and exits 0, not an `error:`; seen on `vt-bios`, which never sends a packet.
  **[verified 2026-10-24]**
- A shut-off domain is an error on every source: `error: Requested operation is not valid:
  domain is not running`, exit 1. `--source agent` on a domain with no agent channel is `error:
  argument unsupported: QEMU guest agent is not configured`, exit 1. **[verified 2026-10-24]**

## R_virsh_domstats_block — `virsh domstats --block`: which disks, and their three sizes

- Without `--backing`, one `block.N` per attached disk; a qcow2 overlay's backing image gets no
  entry of its own. **[verified 2026-10-24, libvirt 12.0]**
- `allocation` is 0 for a disk nothing has written to, raw or qcow2, while `physical` is not
  (seen on a fresh raw disk, a seed ISO and an empty 64 MiB qcow2). **[verified 2026-10-24]**
- A qcow2 overlay on a base image reports its own `allocation` and `physical`, about equal.
  **[verified 2026-10-24]**

- A shut-off domain still gets `block.N.name`, `path`, `allocation`, `capacity` and `physical`,
  but none of the `rd`/`wr`/`fl` counters; `physical` (196616) can be below `allocation`
  (200704). **[verified 2026-10-24, on `vt-bios`]**

## R_domain_xml — what `virsh dumpxml` prints

- An auto-selected UEFI keeps `<os firmware='efi'>` and gains the expanded
  `<loader readonly='yes' secure='yes' type='pflash'>…OVMF_CODE_4M.ms.fd</loader>`, `<nvram
  template=…>` and `<firmware><feature enabled='yes' name='secure-boot'/>`, in both the live and
  the `--inactive` XML. **[verified 2026-10-24, libvirt 12.0]**
- The live agent channel reads `<target type='virtio' name='org.qemu.guest_agent.0'
  state='connected'/>`; `state` is live-only. A domain with no agent has no such channel.
  **[verified 2026-10-24]** for the live half, **[docs]** for live-only
- Plain `dumpxml` leaves the VNC/SPICE `passwd=` out; `--security-info` prints it.
  **[verified 2026-10-24, a VNC domain defined with `passwd=`]**
- Every size comes out in KiB whatever unit it was defined in, and a shut-off domain's autoport
  graphics read `port='-1'`. **[verified 2026-10-24]**
- A live `type='network'` interface's `<source>` also carries the `bridge=` and `portid=` libvirt
  assigned. An empty CD-ROM drive has no `<source>`. **[verified 2026-10-24]**
- `virt-install --osinfo detect=off,require=off` writes no libosinfo metadata at all.
  **[verified 2026-10-24]**

## R_libvirt_default_uri — which libvirt `virsh` reaches with no `-c`

- As a non-root user with no `~/.config/libvirt/libvirt.conf`, no `LIBVIRT_DEFAULT_URI` and
  `uri_default` commented out in `/etc/libvirt/libvirt.conf`, `virsh` connects to
  `qemu:///system`: the client probes `virtqemud-sock`, then `libvirt-sock`.
  **[verified 2026-10-24, libvirt 12.0, Ubuntu 26.04, strace]**
- `LIBVIRT_DEBUG=1 virsh uri` still logs `Using config file uri 'qemu:///system'` there.
  **[verified 2026-10-24]**
- Whether other distros' builds probe the same way, or land on `qemu:///session`. **[unverified]**

## R_linux_swap — how the Linux guest kernel treats swapped pages

- Pages in swap are the tail of the anonymous LRU: everything still out there is out there
  because nobody has touched it since eviction. Swap readahead (`page-cluster`) batches the
  fault-back. **[docs]**
- Evicting N bytes of anon pages to swap raises `MemAvailable` by about N, so a guest that is
  swapping reads as *less* used, not more. **[docs]**
- Swap slots are freed by a write fault or by process exit with no `swap_in` event, so the
  swap *level* can fall while `pswpin` stays flat; a page swapped out at boot can sit for hours.
  Observed: a guest drained 1.14 GiB of swap with `pswpout` flat, ~515 MiB of it faulted back
  on demand. **[verified 2026-08-20]**
- Below roughly 50 % swap occupancy a read fault keeps the slot and the page lands in
  `SwapCached`, so a prefault does not lower the visible level. **[docs]**
- `swapoff` runs `try_to_unuse()`, which faults every swapped page back synchronously;
  during it the system has no swap, and if the swapped set exceeds `MemAvailable` the
  `swapoff` itself triggers the OOM killer. **[src]**
- `process_madvise(pidfd, MADV_WILLNEED)` can prefault another process's ranges, but no
  coreutils-level CLI exposes it. **[docs]**
- Distro kernels all build with `CONFIG_VM_EVENT_COUNTERS`, so a guest reporting a swap
  level but no `pswpin`/`pswpout` counters is theoretical. **[unverified]**

## R_timecop_monotonic — Timecop moves `Time.now`, not the monotonic clock

- Timecop patches `Time.now` (and `Date`/`DateTime`), and moves
  `Process.clock_gettime(Process::CLOCK_MONOTONIC)` by exactly zero. **[verified 2026-08-26,
  Timecop 0.9]**
- `CLOCK_MONOTONIC` excludes time the host spends suspended; `CLOCK_BOOTTIME` includes it.
  Neither is moved by NTP steps or a manual `date`. **[docs]**

## R_balloon_policy_survey — how the established hypervisors decide balloon size

Surveyed 2026-08-21; per-system detail in the entries below.

| System | Decision input | Target rule | Grow limit | Shrink limit | Cadence |
|---|---|---|---|---|---|
| **Xen self-ballooning** (guest-side) | `Committed_AS` | `Committed_AS + totalreserve_pages` | none — `up_hysteresis=1`, jump the whole gap | `down_hysteresis=8` → ⅛ of the gap | 5 s |
| **oVirt MoM** | `balloon_cur − mem_unused`, moving average | `used + 20% × cur` | none — target overrides the `+5%` floor | exactly `−5%` of cur | host-pressure driven |
| **Hyper-V Dynamic Memory** | commit charge ("pressure") | `needed × (1 + buffer)`, buffer 20% default | undisclosed | undisclosed | continuous |
| **Proxmox VE** | **host** used vs an 80% target | share-proportional | **100 MiB per VM per round** | same 100 MiB, symmetric | 10 s |
| **XenServer `squeezed`** | **host** free memory | every VM at the same fraction of its `dmin..dmax` range | none stated; 5 s no-progress ⇒ "inactive" | same | 10 s |
| **VMware ESXi** | **host** free state + *sampled* active memory | share-based entitlement, idle-taxed | never grows on guest demand | n/a | 60 s sample |

- Two axes separate them. *What drives the decision:* host pressure (Proxmox, `squeezed`,
  ESXi) — the input is how full the host is, and guest demand is at most a tie-breaker — versus
  guest demand (Xen self-ballooning, Hyper-V, MoM), where the input comes from inside the
  guest and the host budget is a constraint applied afterwards. **[src]**
- *Step or target:* every surveyed system computes a **target** and moves toward it; none
  grows by a fixed percentage step. Where a hop limit exists (Proxmox) it is absolute and a
  fairness rate limit, not a burst-survival mechanism; the two systems that must survive a
  guest burst (Xen self-ballooning, MoM) leave grow unbounded. **[src]**
- Noise is damped on the *input*: MoM's `StatAvg`, VPA's p95 over history, Xen's inherently
  smooth `Committed_AS`. None limits the output step to compensate for a jumpy reading. **[src]**
- The free reserve they converge on is 15–25 %: MoM 20 %, Hyper-V 20 %, VPA 15 %, Proxmox's
  comfort test 25 % of `balloon_min`. **[src]** (Hyper-V's figure **[unverified]**)
- Both demand-driven targeters use a forward-looking metric — `Committed_AS`, Windows commit
  charge — counting memory the guest has *promised itself*, where `MemAvailable` trails demand.
  **[docs]**
- Two mechanisms recur: a "change big enough to bother" gate (MoM 0.25 %, Proxmox 10 MiB) and
  a balloon liveness check (`squeezed` declares a domain inactive after 5 s of no progress).
  **[src]**
- Cadences: 5 s (Xen), 10 s (Proxmox, `squeezed`), 60 s sampling (ESXi). **[src]**

## R_proxmox_autoballoon — Proxmox VE: host-pressure redistribution with an absolute per-round cap

Source: [`PVE/AutoBalloon.pm`](https://github.com/proxmox/pve-manager/blob/master/PVE/AutoBalloon.pm)
(`compute_alg1`) and [`PVE/Service/pvestatd.pm`](https://github.com/proxmox/pve-manager/blob/master/PVE/Service/pvestatd.pm)
(`auto_ballooning`); KVM/QEMU driving `virtio-balloon`, so the most comparable toolstack.

```perl
# pvestatd.pm — once per $updatetime = 10 s
my $target = int($config->{'ballooning-target'} // 80);   # keep the HOST at 80%
my $goal   = int($memtotal * $target / 100 - $memused);   # bytes to hand out (or claw back)
my $maxchange = 100 * 1024 * 1024;                        # 100 MiB, per VM, per round
PVE::AutoBalloon::compute_alg1($vmstatus, $goal, $maxchange);
```

- Deadband on the goal in absolute bytes: grow only if `goal > 10 MiB`, shrink only if
  `goal < -10 MiB`, else nothing. **[src]**
- Per-VM desired size is share-proportional, not demand-proportional:
  `desired = balloon_min + int((alloc_new / shares_total) * shares)`, `shares` default 1000
  (0 opts out); VMs that hit `maxmem` or `balloon_min` are removed and the remainder
  redistributed in a `while ($rest && $repeat && $progress)` loop. **[src]**
- `maxchange` is a hard, symmetric, absolute per-round cap; with the 10 s cadence that is
  10 MiB/s per VM. A guest allocating faster reclaims locally instead. **[src]**
- Guest demand enters only as a priority split: a VM is comfortable if
  `freemem > balloon_min * 0.25`; grow requests go to the uncomfortable list first, shrink
  requests to the comfortable list first. **[src]**

## R_xenserver_squeezed — XenServer / XCP-ng `squeezed`: the admin declares a range, the host picks one fraction

Source: the [`squeezed` design doc](https://github.com/xapi-project/xenopsd/blob/master/squeezed/doc/design/README.md).
Uses no guest metric at all.

- Each domain has an admin-set `dynamic-min` / `dynamic-max`; the policy keeps every domain
  at the same `(target − dynamic-min) / (dynamic-max − dynamic-min)`. Memory plentiful ⇒
  everyone at `dynamic-max`; scarce ⇒ everyone at `dynamic-min`. **[docs]**
- Polled every 10 s, and also driven on demand by an allocation request such as a VM start.
  **[docs]**
- A domain that fails to make progress toward its target within 5 s is declared *inactive*,
  has `maxmem` pinned, and is excluded from that round — an explicit liveness check on the
  balloon driver. **[docs]**
- `maxmem` is used as a hard ceiling so a squeezed domain cannot allocate past the policy's
  intent. **[docs]**

## R_esxi_memory — VMware ESXi: sampled active memory, share-based entitlement, idle tax

- ESXi neither asks the guest nor trusts it: it statistically samples page accesses to
  estimate *active* memory (`Mem.SamplePeriod`, 60 s default). **[docs]**
- Entitlement derives from shares, discounted by the idle memory tax (`Mem.IdleTax`, default
  75 %) applied progressively as the idle/active ratio rises, so a VM hoarding untouched pages
  is reclaimed from first. **[docs]** — [Memory tax for idle VMs](https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere/7-0/vsphere-resource-management/administering-memory-resources/how-esxi-hosts-allocate-memory/memory-tax-for-idle-virtual-machines.html)
- Reclamation is gated by host free-memory states — classically 6 % / 4 % / 2 % / 1 %
  (high/soft/hard/low); newer releases derive them from `minFree`, so treat the figures as
  the shape, not today's numbers — and proceeds page sharing → ballooning → compression →
  host swapping. The balloon claims at most ~65 % of guest RAM. **[unverified]**
- There is no grow-on-demand path: a guest under pressure is not a signal it acts on; growth
  is the passive consequence of the host un-reclaiming when it has spare. **[docs]**

## R_xen_selfballoon — Xen self-ballooning: target-driven, gain 1 on the way up

Source: `drivers/xen/xen-selfballoon.c` in the pre-removal Linux tree. Runs *inside* the guest
(no host-side sampling lag), and was removed from mainline along with tmem.

```c
goal_pages = vm_committed_as + totalreserve_pages;
if (cur_pages > goal_pages)
    tgt_pages = cur_pages - ((cur_pages - goal_pages) / selfballoon_downhysteresis);  /* 8 */
else if (cur_pages < goal_pages)
    tgt_pages = cur_pages + ((goal_pages - cur_pages) / selfballoon_uphysteresis);    /* 1 */
```

- Defaults `uphysteresis = 1`, `downhysteresis = 8`, interval 5 s: jump the entire gap up in
  one step, give back an eighth of the excess per interval. **[src]**

## R_ovirt_mom — oVirt MoM: host-pressure outer loop, guest-demand per-VM target

Source: [`doc/balloon.rules`](https://github.com/oVirt/mom/blob/master/doc/balloon.rules);
KVM/libvirt, polling `virtio-balloon` stats from the host.

| Constant | Value | Meaning |
|---|---|---|
| `pressure_threshold` | 0.20 | host free below this ⇒ host under pressure |
| `pressure_critical` | 0.05 | ⇒ balloon aggressively, accept guest swapping |
| `min_guest_free_percent` | 0.20 | free memory an unconstrained guest should keep |
| `max_balloon_change_percent` | 0.05 | per-step change limit |
| `min_balloon_change_percent` | 0.0025 | below this, don't bother |

```lisp
;; grow
guest_used_mem = (StatAvg "balloon_cur") - (StatAvg "mem_unused")
balloon_min    = max(guest.balloon_min, guest_used_mem + 0.20 * balloon_cur)
balloon_size   = balloon_cur * (1 + 0.05)
if balloon_size < balloon_min: balloon_size = balloon_min      ;; target WINS
clamp to balloon_max; apply only if change_big_enough
```

- On grow the `+5 %` is a *floor*, not a cap: `balloon_min` (the target) overrides it upward
  with no upper limit; only shrink is rate-limited, at `−5 %`. **[src]**
- The input is damped with `StatAvg`, a moving average, rather than the latest sample. **[src]**
- `change_big_enough` (0.25 % of current) is the absolute-granularity gate. **[src]**

## R_hyperv_dynamic_memory — Hyper-V Dynamic Memory: the buffer as a product feature

Source: [Hyper-V Dynamic Memory](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/dynamic-memory).

- Hyper-V reads "performance counters in the virtual machine that identify committed memory"
  and sizes the VM as `memory buffer = needed × (buffer % / 100)`. **[docs]**
- The buffer defaults to 20 % over a 5–200 % range — a steady-state target of
  `100/(100+20) ≈ 83 %` used. **[unverified]** — secondary sources; Microsoft documents the
  formula and the input, not the default.
- `Startup` / `Minimum` / `Maximum RAM` bound it and `Memory Weight` arbitrates when the host
  cannot satisfy every buffer; the increment and rate are not published. **[docs]**

## R_adjacent_balloon_mechanisms — what sits beside the balloon in the stack

- Bare QEMU/KVM + libvirt has no policy at all: `virsh setmem` is a mechanism; nothing in the
  stack decides when to call it. **[docs]**
- virtio-mem replaces the balloon for resizing rather than steering it: the host sets a
  `requested-size` and the guest plugs/unplugs multi-MiB blocks — a target interface by
  construction. **[docs]**
- Free page reporting (`VIRTIO_BALLOON_F_PAGE_REPORTING`) is passive: the guest hints which
  pages are free and the host may reclaim them. No controller, no target. **[docs]**
- VirtualBox exposes the balloon as a manual operation (`VBoxManage controlvm …
  guestmemoryballoon`) with no automatic policy. **[docs]**
- Kubernetes VPA, the same control problem outside virtualization, targets the p95 of observed
  usage history plus a 15 % margin (`--recommendation-margin-fraction`). **[src]** —
  [recommender.go](https://github.com/kubernetes/autoscaler/blob/master/vertical-pod-autoscaler/pkg/recommender/logic/recommender.go)

## R_guestinfo — what `virsh guestinfo --filesystem --disk` reports, and what it leaves to guest files

- One `key : value` per line, keys padded to a column, a long key run straight into its `:`
  (`disk.0.dependency.count: 1`). **[verified 2026-10-24, libvirt 12.0.0, QEMU 10.2.1]**
- `fs.N.*`: `name` (`vda1`), `mountpoint`, `fstype`, `total-bytes`, `used-bytes`, and per disk
  under it `alias` — the *host* target, `vda` — and `device`, the guest's `/dev/vda1`. Mounted
  filesystems only: no swap, no unmounted partition. **[verified 2026-10-24]**
- `total-bytes` is `used-bytes` plus what an unprivileged user may still write, the base of
  `df`'s Use%; the agent's own `guest-get-fsinfo` also has `total-bytes-privileged`, which
  guestinfo does not print. **[verified 2026-10-24]**
- `disk.N.*`: every guest block device, `partition: yes|no`, its `dependency.M.name`s
  (`/dev/vda` for `/dev/vda1`), and for a whole disk `alias` and `guest_bus`. No sizes, no
  partition offsets. **[verified 2026-10-24]**
- The geometry lives in guest files the agent's `guest-file-read` reaches: `/proc/partitions`
  (sizes in KiB, whole disks included) and `/sys/class/block/<part>/start` (512-byte sectors,
  whatever the disk's sector size). On an Ubuntu cloud image `/` is `vda1` but starts after
  `vda13`–`vda15`. **[verified 2026-10-24, Ubuntu 26.04]**
- A GPT disk whose last partition fills it keeps 33 sectors (~17 KiB) after it, the backup
  table. **[verified 2026-10-24]**
- Without an agent channel: `error: argument unsupported: QEMU guest agent is not configured`,
  exit 1. **[verified 2026-10-24]** An LVM or LUKS root is reported through a `dm-*` device,
  and a Windows guest's devices are not `/dev/…` names. **[unverified]**

## R_volume_resize — `vol-resize`, `blockresize` and the image lock

- `vol-pool`, `vol-info` and `vol-resize` take a volume's path, and libvirtd looks it up, so
  they work on a directory the user cannot read. A path in no pool fails `vol-pool` with
  `error: Storage volume not found: no storage vol with matching path '…'`, exit 1.
  **[verified 2026-10-24, libvirt 12.0.0]**
- `vol-info --bytes` prints `Capacity:       15032385536 bytes`; `pool-info --bytes` prints the
  bare number. **[verified 2026-10-24]**
- `vol-resize <path> <bytes>` runs `qemu-img resize` as root; a 2 GiB grow of a qcow2 took
  37 ms, the header being all it rewrites. A smaller capacity is refused: `Can't shrink
  capacity below current capacity unless shrink flag explicitly specified`.
  **[verified 2026-10-24, QEMU 10.2.1]**
- On a running VM's image `vol-resize` fails: `qemu-img: Could not open '…': Failed to get
  "write" lock`, QEMU holding the image's lock. **[verified 2026-10-24]**
- `blockresize <vm> <target> <size>` on a running VM grows the disk live, and shrinks it just
  as readily: exit 0, no warning. **[verified 2026-10-24]**
