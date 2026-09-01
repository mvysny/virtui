# A UTM backend for macOS (`utmctl`)

**Status:** brainstorm from 2026-09-01, nothing decided, nothing tested against a
real Mac. Everything below is desk research on UTM's published CLI surface —
treat the ✅/❌ table as a hypothesis to verify, not as measurement.

The question that started it: *"I have a MacBook with UTM installed; what else do
I need to control those VMs?"* Answer for a human at a terminal: nothing —
`utmctl` ships inside the app bundle. Answer for VirTUI: a new backend class, and
two of the three things VirTUI actually *is* would have to come from somewhere
other than `utmctl`.

## The host shopping list (verified only against docs)

`utmctl` ships with UTM 4.1+ at
`/Applications/UTM.app/Contents/MacOS/utmctl`; symlink it onto `PATH` and it
works. It drives the **running UTM.app** over Apple's scripting bridge, so:

- UTM must be installed *and running*; the first call raises a macOS Automation
  consent prompt (System Settings → Privacy & Security → Automation).
- `utmctl ip-address` / `utmctl exec` need `qemu-guest-agent` **inside the
  guest** — the only thing actually installed, and it is installed in the VM,
  not on the host.
- The AppleScript/JXA dictionary is the same surface; `utmctl` is a thin wrapper
  over it. Worth opening in Script Editor (Open Dictionary → UTM) before ruling
  anything out, but don't expect memory stats to be hiding there.

### Why not libvirt on macOS

`brew install libvirt qemu` + `virsh -c qemu:///session` does work, but it is a
*second, parallel stack*: libvirt manages only domains it defined itself. UTM
launches and supervises its own `qemu-system-*` from `.utm` bundles with no
libvirt integration, so `virsh list` never shows a UTM VM. Adopting one would
mean hand-writing domain XML against the disk inside the bundle
(`Data/*.qcow2`) and abandoning UTM for that VM. Two hard blockers on top:
Apple Silicon's fast **Apple Virtualization** backend isn't QEMU at all, and
libvirt's `domstats`/ballooning story on macOS is much weaker than on Linux.

So the libvirt path is out; the fork is `utmctl` + host-side reads, or nothing.

## What `utmctl` covers, against what `Virt::Virsh` asks of a backend

| `Virt::Virsh` needs | utmctl |
|---|---|
| enumerate domains | ✅ `utmctl list` (UUID, status, name) |
| state | ✅ `utmctl status` — but 7 states (`stopped/starting/started/pausing/paused/resuming/stopping`), so `@@states` needs a second map |
| `start` | ✅ `utmctl start` (+ `--disposable`, `--recovery`) |
| `shutdown` | ✅ `utmctl stop --request` |
| `force_off` (destroy) | ✅ `utmctl stop --force` / `--kill` |
| `reboot` | ❌ — compose stop+start |
| `reset` | ❌ |
| guest `/proc/meminfo` swap read | ✅ `utmctl file pull /proc/meminfo` — *simpler* than `Virt::GuestAgent`'s three-RPC open/read/close dance |
| `domstats`: `cpu.time` | ❌ |
| `domstats`: `balloon.current/rss/unused/usable/available/swap_in/swap_out` | ❌ |
| `domstats`: `block.N.allocation/capacity/physical` | ❌ |
| `setmem` | ❌ **no balloon control of any kind** |
| `dommemstat --period` | ❌ (nothing to arm) |
| `nodeinfo` | ❌ — irrelevant; that's `System::Info`'s job and macOS has `sysctl` |
| `metadata --uri libosinfo` (guest OS) | ❌ from utmctl; the `.utm` bundle's `config.plist` carries an OS hint |

Shape of the gap: **lifecycle + guest interaction, no runtime-metrics surface at
all.** The UTM source is explicit about this.

## Sketch of a `Virt::UTMCtl` backend

Day one it would give the VM list, the states and the power keys. The usage bars
and ballooning are the real work.

**Metrics — recoverable, host-side, but not in one call.** UTM runs a real
`qemu-system-*` child per VM:

- per-VM CPU time and RSS from `ps -o time=,rss=` given the PID — note this is
  the *hypervisor footprint*, the same quantity `Virt::Cache#total_vm_rss_usage`
  already feeds to `UI::SystemPane`, not guest-internal usage;
- disk allocation/capacity from `stat` / `qemu-img info` on
  `.utm/Data/*.qcow2`;
- guest-internal memory for Linux guests from `utmctl file pull /proc/meminfo`
  straight into `System::MemoryStat.parse`, which already parses a *guest's*
  meminfo.

The catch: this is **N calls per tick instead of one `domstats`**, which changes
the timer-thread cost model that the 2s `Concurrent::TimerTask` is sized for. How
badly is unmeasured.

**Ballooning — the open question.** Not reachable through `utmctl` at all.

1. **QMP directly** — UTM's per-VM settings have a QEMU → Additional Arguments
   field; adding `-qmp unix:/tmp/vm.qmp,server,nowait` would let us issue
   `balloon <MiB>` / `query-balloon` ourselves, bypassing `utmctl`. This is the
   only real path and it is **untested**: unknown whether UTM passes those args
   through unmolested, and it's per-VM manual setup VirTUI cannot arrange for the
   user.
2. **Apple Virtualization backend (Apple Silicon's fast path) — dead end.** No
   balloon device; guest memory is fixed at boot. If the VMs use that backend,
   ballooning is off the table regardless of which CLI drives them.

So a plausible first cut is: power keys + list working, usage bars fed from
`ps`+`stat`, ballooning **disabled unless** a QMP socket is configured for that
VM.

## Open topics, in the order they gate each other

1. Does UTM actually pass `-qmp …` through Additional Arguments? Everything
   about ballooning-on-macOS hangs off this one experiment.
2. Is the per-tick cost of N × (`ps` + `stat` + `utmctl file pull`) acceptable at
   2s, and does it need its own transport the way `Virt::VirshSession` is a
   long-lived REPL for `virsh`?
3. What does the AppleScript dictionary expose that the CLI doesn't (if
   anything)?
4. Does the backend seam live at `Virt::Virsh`'s level (a sibling class the
   `Virt::Cache` picks between) or lower? Nothing here has looked at what that
   costs — `Virt::Cache` currently assumes a single `domstats` shaped read.
5. Is this even wanted? VirTUI's identity is the ballooning controller, and on
   Apple Silicon that is the piece least likely to work.

## Sources (all secondary, none re-verified)

- [UTMCtl.swift](https://github.com/utmapp/UTM/blob/main/utmctl/UTMCtl.swift) — the CLI's command set
- [UTM scripting cheat sheet](https://docs.getutm.app/scripting/cheat-sheet/)
- [Nearly headless VMs using utmctl](https://ryan.himmelwright.net/post/utmctl-nearly-headless-vms/)
- [utmctl path restriction (issue #7094)](https://github.com/utmapp/UTM/issues/7094)
