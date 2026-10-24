# VM info window: `i` shows what the domain is configured as

**Status:** proposal, nothing built (2026-10-24). Partly checked against the `vt-*` VMs
(`bin/test-vms.sh`); the rest of what `virsh dumpxml` prints is from libvirt's domain-XML format
docs and wants recording into `spec/virt/` before it is relied on (see *To check on a real
host*). The read runs in a `UI::BackgroundTask` (`D_background_task`).

## The ask

Select a VM, press `i`, get a read-only popup with the static facts of its definition: configured
RAM, vCPUs and topology, UEFI or BIOS boot, where the disk images are, which disks are shared, and
devices worth knowing about (TPM, passthrough, shared folders). The only thing it does is close
(`q` / `ESC`), like `CpuFlagsWindow`.

The VM pane already shows the *live* figures (CPU %, the balloon's `actual`, disk fill, the IP).
This window shows the rest: what the domain is *defined* as, the things you would otherwise open
virt-manager's details page or run `virsh dumpxml | less` to find.

## What it looks like

A `Tuile::Component::Window` subclass framing a `TextView`, as `CpuFlagsWindow` does: titled with
the VM name, word-wrapped and scrollable, `q/ESC to close` in the footer. Captions are in the
theme's hint colour, values in the default colour, and section headings use the accent colour.

A Linux guest with most features turned on:

```
┌─ web01 ─────────────────────────────────────────────────────────────────┐
│ OS        Ubuntu 24.04 — http://ubuntu.com/ubuntu/24.04                 │
│ Machine   x86_64, pc-q35-8.2, KVM                                       │
│ UUID      8f3c2a1e-5b7d-4c0a-9e61-2d4f8b3a7c90                          │
│                                                                         │
│ CPU       4 vCPUs — 1 socket × 4 cores × 1 thread, host-passthrough     │
│ Memory    8 GiB max (the balloon's ceiling), hugepages                  │
│ Balloon   virtio, free page reporting, deflate on OOM                   │
│ Agent     qemu-guest-agent channel (connected)                          │
│                                                                         │
│ Firmware  UEFI, Secure Boot                                             │
│           /usr/share/OVMF/OVMF_CODE_4M.ms.fd                            │
│ NVRAM     /var/lib/libvirt/qemu/nvram/web01_VARS.fd                     │
│ Boot      hd, cdrom                                                     │
│ TPM       2.0, emulated, tpm-crb                                        │
│                                                                         │
│ Disks                                                                   │
│   vda  virtio  qcow2   40 GiB  /var/lib/libvirt/images/web01.qcow2      │
│   vdb  virtio  raw    200 GiB  /dev/vg0/shared          shared          │
│   sda  sata    cdrom           (no media)               read-only       │
│ Shared folders                                                          │
│   virtiofs  /home/mavi/shared  as tag "shared"                          │
│ Network                                                                 │
│   virtio  network "default"  52:54:00:12:34:56                          │
│ Display                                                                 │
│   spice on 127.0.0.1:5900, video virtio                                 │
│ Passthrough                                                             │
│   PCI 0000:01:00.0                                                      │
│   USB 046d:c52b                                                         │
└───────────────────────────────────────────────── q/ESC to close ────────┘
```

A legacy BIOS guest with no agent and no balloon, shut off:

```
┌─ dos622 ────────────────────────────────────────────────────────────────┐
│ OS        unknown — no osinfo declaration                               │
│ Machine   i686, pc-i440fx-8.2, KVM                                      │
│ …                                                                       │
│ CPU       1 vCPU                                                        │
│ Memory    32 MiB max                                                    │
│ Balloon   none — virtui cannot resize this VM                           │
│ Agent     no channel — no swap level for this VM                        │
│                                                                         │
│ Firmware  BIOS                                                          │
│ Boot      fd, hd                                                        │
│ …                                                                       │
└─────────────────────────────────────────────────────────────────────────┘
```

Rules for the content:

- **A section a VM has nothing for is left out.** No `Passthrough: none` and no empty `Shared
  folders`. The window should be as short as the definition is plain.
- **The exceptions are virtui's own prerequisites: `Balloon` and `Agent` always show,** and when
  either is missing the line says what that costs in virtui ("cannot resize", "no swap level").
  This is the one place the user can learn *why* a VM's row looks different from the others. The
  README's ballooning guide already lists these prerequisites; this window applies the list to one
  VM.
- **Paths are shown in full.** "Where do the images live" is the question, so a truncated path
  answers nothing. Wrapping comes free with `TextView`; see `Q_column_wrap`.
- **Sizes use `format_byte_size`**, the same as the rest of the UI.
- **Only facts, no advice.** No "consider virtio instead of sata"; this is not a linter.

### The sections, and which XML they come from

| Line | Source in `dumpxml` |
|---|---|
| OS | `GuestOS` as today (the libosinfo `<os id>` in `<metadata>`); see `Q_guest_os_merge` |
| Machine | `<os><type arch= machine=>`, `<domain type=>` (kvm / qemu) |
| CPU | `<vcpu current=>` text, `<cpu mode=>` + `<model>`, `<topology sockets= cores= threads=>` |
| Memory | `<memory>` (the balloon ceiling, the same figure as `balloon.maximum`), `<memoryBacking>` (hugepages / `memfd` / shared, only if present) |
| Balloon | `<devices><memballoon model=>`, `autodeflate=`, `freePageReporting=`; `model='none'` or no element at all means no balloon |
| Agent | `<channel type='unix'><target type='virtio' name='org.qemu.guest_agent.0' state=>`; the live XML's `state='connected'` is a free "agent is up" bit |
| Firmware | `<os firmware='efi'>` (auto-selected) or `<loader type='pflash'>` (explicit) means UEFI; `<firmware><feature name='secure-boot' enabled=>` or `<loader secure='yes'>` means Secure Boot; neither is BIOS |
| NVRAM | `<os><nvram>` |
| Boot | `<os><boot dev=>` in document order, else the per-device `<boot order=>` |
| TPM | `<tpm model=><backend type= version=>` |
| Disks | `<disk type= device=>`: `<target dev= bus=>`, `<driver type= cache=>`, `<source file= / dev= / pool=+volume= / protocol=+name=>`, `<shareable/>`, `<readonly/>`. The capacity comes from `domstats` (see below) |
| Shared folders | `<filesystem type='mount'>`: `<driver type='virtiofs'>` or 9p, `<source dir=>`, `<target dir=>` (the mount tag) |
| Network | `<interface type=>`: `<source network= / bridge= / dev= mode=>`, `<model type=>`, `<mac address=>` |
| Display | `<graphics type= port= listen=>`, `<video><model type=>` |
| Passthrough | `<hostdev mode='subsystem' type='pci'>` source address, and `type='usb'` vendor:product |

**A disk's capacity is already in the cache.** `DiskStat` carries `capacity` per `block.N.name`
(`vda`), so the window joins the two by target name and spends no extra read. A shut-off VM's
disks may not appear in `domstats` at all (`Q_offline_capacity`), and then the size column is
blank.

**Never pass `--security-info`.** Without that flag `dumpxml` omits the VNC/SPICE `passwd=`
attribute. Once this ships, that rule belongs in the doc comment of the method that runs
`dumpxml`.

## How it is built

### Where the read happens: fresh, when `i` is pressed

**Decided 2026-10-24: read `dumpxml` fresh on every `i`,** so the window can never show a
definition older than the keypress. The UI thread cannot run the read itself (the first
invariant), so `i` hands it to `UI::BackgroundTask`:

```ruby
BackgroundTask.new("Reading #{vm}'s definition") { @virt_cache.virt.domain_config(vm) }
              .run { |config| VMInfoWindow.open(config, @virt_cache.get(vm)) }
```

The helper shows a progress popup while the read runs. If the read fails it shows an error
dialog and never opens the info window.

Rejected alternatives:
- **A memo on `Virt::Cache`,** re-read on every power transition. It opens instantly, but a
  definition edited while the domain stays in one state (for example in virt-manager while it is
  shut off) would go unseen until the next start or stop.
- **A "wanted" flag read by the next tick.** Up to 2 s of waiting, plus a path from
  `AppLayout#update_data` into an open popup.

**The read spawns its own process; it does not go through the session.** A read waiting on the
session mutex would queue behind the tick's guest-agent RPCs, up to the session's read timeout.
So `Virsh#domain_config` needs to run its read through a process of its own even though it is a
read (`Q_spawned_read`).

### Pieces

- **`Virt::DomainConfig`**, a `Data.define` built by `DomainConfig.from_xml(xml)`, with small
  nested `Data`s for `Disk`, `Filesystem`, `Interface`, `Hostdev`, `Graphics`, `Tpm`. It is
  immutable because `Cache` hands it across threads. It holds the parsed values (bytes, symbols,
  paths), not display strings, and has no `UI::` in it.
- **The XML parser is `rexml`.** In Ruby 3.3 it is a bundled gem, not a default one, so it needs a
  `Gemfile` line. It is pure Ruby, ubiquitous, and has no native extension (unlike Nokogiri), and a
  definition is a few KB. Parse failures raise with the domain name, because errors are loud.
- **`Virsh#domain_config(name, xml = nil)`** follows the fixture-parameter pattern and runs
  `dumpxml` in a spawned process (see above). **`VMEmulator#domain_config(name)`** builds a small
  XML from the VM's name, vCPUs and memory and runs it through the *same* `from_xml`, so demo mode
  exercises the parser. The demo's `win11` gets UEFI + Secure Boot + TPM, and `BASE` gets BIOS and
  no agent channel. It is called from the task's worker thread, which only reads the emulated
  VM's attributes, so a benign race with the tick is acceptable.
- **`Cache`** is untouched. Nothing is memoized.
- **`UI::VMInfoWindow < Tuile::Component::Window`** takes data, not text (COP rule 4):
  `VMInfoWindow.open(config, vm_cache)`. The `VMCache` supplies the disk sizes
  (`data.disk_stat`) and the OS line (`guest_os`). It rebuilds on `handle_theme_changed`. It does
  not follow later ticks: it is a snapshot of the moment `i` was pressed (`Q_live_refresh`).
- **`VMPane#handle_key?`** binds `i` next to `p` / `v` / `m` / `d`, and the footer hint gains
  `i Info`. `i` is unbound today.

### Tests

- `spec/virt/domain_config_spec.rb`: fed recorded `dumpxml` fixtures, never the live host. At
  least one UEFI + Secure Boot + TPM guest, one BIOS guest, one with virtiofs and a shareable raw
  disk, and one with a `pool`/`volume` disk.
- `spec/ui/vm_info_window_spec.rb`, and a `VMPane` spec that presses `i` over the emulator and
  asserts the popup's text, the same way the `CpuFlagsWindow` spec does.

## Open questions

- `Q_guest_os_merge`: should the window take its OS line from the fresh XML's `<metadata>`, which
  is newer than `Cache`'s guest-OS value? That value is never refreshed. The two could then
  disagree on screen until a restart. I lean towards the fresh one in this window, plus a
  separate follow-up asking whether the tick's `virsh metadata --uri` should go away. The "no XML
  dependency" half of D_guest_os_from_xml's "why not `dumpxml`" stops holding once `rexml` is in.
- `Q_spawned_read`: how does `Virsh#domain_config` get a process of its own when `Virsh` holds a
  single runner, a `VirshSession`? The options:
  - `@runner.sync('dumpxml', …)`: `sync` spawns in both transports, but the name says "mutating
    command";
  - a second `spawn:` runner on `Virsh`;
  - a fourth runner verb, `spawned_query`.

  I lean towards a short comment on `sync`'s doc ("a process of its own, also for a read that
  must not queue behind the session") over a new verb.
- `Q_live_or_inactive`: plain `dumpxml` gives the *live* definition of a running domain, which is
  what is actually in effect, including assigned ports and the agent `state`. `--inactive` gives
  what the next boot will be. I lean towards live only. Showing a "changed, takes effect on next
  boot" marker would need both XMLs and a diff, which is not worth it yet.
- `Q_autostart`: "starts with the host" is a useful static fact, but it is not in the XML. It is
  `virsh dominfo` (`Autostart:`, `Persistent:`), one more spawned read inside the same background
  task. Worth it?
- `Q_column_wrap`: with a long path, a `TextView` wraps under the caption column and breaks the
  alignment. Options: put the path on its own indented line under each disk, write a hanging-indent
  wrapper, or accept it. Putting the path on its own line is the simplest and reads fine.
- `Q_window_size`: use a fixed `Fraction.new(0.7, 0.7)` like `CpuFlagsWindow`, or fit the height
  to the content (a plain VM is about 15 lines)? Tuile's `Popup` `declared_size` decides; check
  whether it can shrink to fit.
- `Q_offline_capacity`: answered 2026-10-24 on a shut-off `vt-bios`. Yes: `domstats --block`
  still lists `block.N.name`, `path`, `allocation`, `capacity` and `physical`, but none of the
  `rd`/`wr`/`fl` counters. `physical` (196616) can be smaller than `allocation` (200704). No
  `domblkinfo` is needed.
- `Q_hostdev_names`: show `PCI 0000:01:00.0` as is, or resolve it to "NVIDIA RTX 3060" through
  `/sys/bus/pci/devices/*/` or `lspci`? Resolving is more useful, but it is a host read in
  `lib/system/` and a second source. Raw IDs first.
- `Q_other_devices`: are RNG, watchdog, sound, serial console and USB redirection worth an
  `Other` line (`rng virtio, watchdog i6300esb, sound ich9`), or are they noise? I lean towards one
  terse line, shown only if non-empty.

## To check on a real host

Partly done 2026-10-24 against the `vt-*` VMs (`bin/test-vms.sh`):

- An auto-selected UEFI keeps `<os firmware='efi'>` **and** gains the expanded explicit
  `<loader readonly='yes' secure='yes' type='pflash'>…OVMF_CODE_4M.ms.fd</loader>` and
  `<nvram template=…>`. Both forms are in the live XML and in `--inactive`, with
  `<firmware><feature enabled='yes' name='secure-boot'/>` (and `enrolled-keys`). Either form is
  enough to detect Secure Boot.
- The agent channel's live `<target … name='org.qemu.guest_agent.0' state='connected'/>`.
  A domain with no agent has no such channel at all (`vt-bios`).
- `dumpxml --security-info` of a SPICE guest with no password has no `passwd=`.
- `vt-bios`, created with `--osinfo detect=off,require=off`, has no `<libosinfo:os>` in its
  `<metadata>`, so it is a real `:unknown` case.
- Not done: recording the fixtures into `spec/virt/`. That belongs to implementing this idea.

```fish
for d in (virsh list --all --name); virsh -q dumpxml $d > spec/virt/dumpxml_$d.xml; end
virsh -q domstats --block <a-shut-off-vm>      # Q_offline_capacity
```

Prune the fixtures to a representative set. Check each that they contain no `passwd=`, which
proves the `--security-info` rule. Also check what an auto-selected UEFI (`firmware='efi'`) looks
like in the *live* XML: libvirt is said to expand it to an explicit `<loader>`, and the Secure Boot
detection depends on which form arrives.

## Where the nuggets land when this graduates

- What `dumpxml` prints (firmware forms, the agent channel `state`, `--security-info`, the
  offline-`domstats` answer) goes to **design/research.md** as `R_domain_xml`, with the facts
  marked verified.
- The fresh-read-on-`i` choice and the rejected `Cache` memo go to **design/decisions.md**, as a
  new `D_domain_config_fresh` or a paragraph of `D_background_task`.
- An *info key* flow beside *a power key*, and `domain_config` in the backend role's call list,
  go to **design/architecture.md**.
- The `i` key goes to the **README** key list.
