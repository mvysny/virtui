# VM health check: is this VM set up the way virtui (and the host's disk) needs?

A list of misconfigurations that each cost something quietly. Every check is a read: the
domain XML, `domstats`, and guest files through the agent's `guest-file-read`, as
`Virt::GuestStorage` already does. Nothing here runs `guest-exec`.

## Candidate checks

### Disk discard, end to end (`R_discard_reclaim`, `R_guestinfo`)

The research settled the shape: **the host is the switch, and only the host can see it.**
Every bus (virtio-blk, virtio-scsi, SATA) tells the guest it can discard, and the guest's
`fstrim` reports the same "trimmed" whether or not anything reached the image. So:

1. **Host, per disk:** `discard='unmap'` on the `<driver>`. A pure XML read: no guest, works
   for a shut-off VM and a guest without an agent. This is the check that matters most.
   Compare live and `--inactive`: set but not yet applied is "needs a power-off".
   Fix: `virt-xml <vm> --edit target=<t> --disk discard=unmap`, then power off and on.
   Only for writable `device='disk'`s: no `cdrom`, `lun` or `readonly`.
2. **Guest block stack, per mounted filesystem:** guestinfo gives the chain with no directory
   listing: `fs.N.name` (`vda1`, `dm-1`), the host `alias`, and `disk.N.dependency`
   `dm-1` → `dm-0` → `/dev/vdc`. For each `dm-*` on the way read
   `/sys/class/block/<dm>/queue/discard_max_bytes`; 0 means a layer blocks it (dm-crypt
   without `allow-discards`). The disk's own value is always > 0, and a partition has no
   `queue/`, so neither needs a read. Plain-partition guests cost zero extra reads.
   Fix for dm-crypt: `discard` in `/etc/crypttab` (or `rd.luks.options=discard`) and a
   reboot. The live fix exists (`cryptsetup refresh` + a dm reload of every LV above) but is
   too fiddly to hand a user.
3. **Guest actually trims:** `/` mounted `discard` (in `/proc/self/mounts`), or
   `/etc/systemd/system/timers.target.wants/fstrim.timer` opens (the agent follows the
   symlink). Neither: freed space waits for a manual trim. A warning only when (1) passes;
   with the host switch off it doesn't matter yet.

### Unused space after an image grow

`GuestStorage::Disk#free_tail` ≥ `MIN_FREE_TAIL`, already computed for `M`: "vda has 2 GiB
after its last partition → `M` grow root".

### Ballooning prerequisites (XML only)

What virtui itself needs, which today shows up only as odd behaviour:
- a `memballoon` device whose model is not `none`; `freePageReporting` on helps;
- an agent channel, and connected (the swap read, the `i` window's guest half).

Dropped while sketching: "`memory` above `currentMemory`". With the two equal the VM boots
with all of it, ballooning shrinks it when idle and grows it back up to `memory`, so nothing is
broken.

### Dropped: image cruft

`physical` far above `allocation` only hints at a convert, which is on hold
([disk-reclaim](disk-reclaim.md)). Not a health problem.

## Where it lives: `M` → Health check (decided 2026-10-24)

An item in the Maintenance menu (`VMPane#show_maintenance_popup`), not a section of `i`:
- `i` shows neutral facts, mostly parsed from the XML; health is a judgement, and the full
  scan needs the guest running.
- A warning's fix is usually another Maintenance item: "2 GiB unused after vda1 → Grow root
  filesystem". The user is already in the menu that fixes it.

Runs in a `BackgroundTask` like Grow root, and shows its findings in a window of its own.

- **A stopped VM gets the XML half** (host discard switch, balloon prerequisites); the guest
  checks are listed as "skipped: VM not running". Unlike the other items, no wrong-state
  alert: the most important check needs no guest. Menu label: `Health check… (full scan: VM running)`.
- **v1 is a read-only list.** v2: the findings window is a picker, and a finding whose fix is
  a Maintenance item opens that item directly.
- **No marker on the VM's row**, ever: health is checked a few times while a VM is being set
  up, and a configured VM rarely drifts. Not worth a per-poll check.

## Class sketch

Shaped like Grow root: a pure judgement over data in `lib/virt/`, `Virsh` doing the reads,
`VMPane` running it in a `BackgroundTask`, a read-only window rendering the result. All open
questions above were answered (2026-10-24) as the sketch below has it.

```
lib/virt/domain_config.rb  Disk + :discard           <driver discard=>: "unmap", "ignore", nil
lib/virt/guest_storage.rb  Filesystem + :mappers     dm devices beneath it, top first
lib/virt/guest_agent.rb    #exist?(domain, path)
lib/virt/health.rb         Virt::Health, Health::Finding, Health.assess   (new, pure)
lib/virt/virsh.rb          #health(domain_name)      the reads, then assess
lib/virt/vm_emulator.rb    #health(name)             same assess over its own XML/guestinfo
lib/ui/health_window.rb    UI::HealthWindow          (new) read-only list of findings
lib/ui/vm_pane.rb          M → ['h', 'Health check… (full scan: VM running)'] → #check_health
```

**`DomainConfig::Disk#discard`**: `String, nil`, the `<driver discard=>` attribute verbatim, as
`format` is. `i` may show it too, as a neutral fact.

**`GuestStorage::Filesystem#mappers`**: `Array<Mapper>`, the `dm-*` devices between the
filesystem and its partition or disk, top first; `Mapper = Data.define(:device, :name)`, e.g.
`dm-1`/`hcvg-hclv`, `dm-0`/`hccrypt` for LVM on LUKS; empty for a plain partition. `parse` already reads every `disk.N` and drops the non-partitions without an
alias. It now follows `dependency.0.name` from `fs.N.name` down while the name is a `dm-*`
(`R_guestinfo`). Today an fs on dm lands in `Disk#filesystems`, since its `disk.0.device` is
the whole disk (`/dev/vdc`). It stays there.

**`GuestAgent#exist?(domain, path) → Boolean`**: `guest-file-open`, then close; `false` on
"No such file or directory" only. Everything else raises as before, `Unavailable` included.
`EXPECTED_FAILURES` keeps the phrase, so `read_file` of a missing file is still `Unavailable`.

**`Virt::Health`**: `Data.define(:findings)`, the result. Like `GuestRootGrow::Refused`, its
text is words for the user. Glyphs and colours stay in `UI::`.

```ruby
# @!attribute severity  [Symbol] :ok, :note, :warning, or :skipped (VM stopped, agent gone)
# @!attribute subject   [String] what it is about: "vda", "/mnt/hc", "balloon", "agent"
# @!attribute text      [String] the finding: "the host drops this disk's discards"
# @!attribute fix       [String, nil] free-form: what needs doing, a command or
#                       "M → Grow root filesystem"
Finding = Data.define(:severity, :subject, :text, :fix)
# v2 adds `remedy` [Symbol, nil], e.g. :grow_root: HealthWindow maps it to the existing UI
# flow and shows a Button("Fix") when it knows one. Not a block on Finding: the fixes are UI
# flows (confirm, progress), which lib/virt/ may not reach; a backend block would still need a
# BackgroundTask from the UI; and a Proc breaks the Data value's equality in specs.

# @param live [DomainConfig] `dumpxml`; on a stopped VM, the persistent definition
# @param inactive [DomainConfig] `dumpxml --inactive`: what the next power-on brings
# @param guest [GuestStorage, String, nil] the guest's disks; a String says why it could
#   not answer, nil means the VM is not running
# @param read_file [#call] path → String, a guest file (only called when guest is a GuestStorage)
# @param file_exist [#call] path → Boolean
# @return [Health]
def self.assess(live, inactive, guest, read_file:, file_exist:)
```

The checks `assess` runs, in window order:

| subject | ok | note | warning | needs |
|---|---|---|---|---|
| balloon | device present | no free page reporting | no device (or `none`) | XML |
| agent | channel connected | — | no channel; channel not connected while running → guest checks `:skipped` | XML |
| each `disk` device, not readonly | live `discard='unmap'` | shareable without it; set in inactive only, "takes effect after a power-off" | without it, fix `virt-xml <vm> --edit target=<t> --disk discard=unmap` | XML |
| each fs with mappers | every mapper's `discard_max_bytes` > 0 | — | a mapper at 0, named by its `guest_alias`, fix: `discard` in `/etc/crypttab`, reboot | guest |
| periodic trim | `fstrim.timer` symlink exists, or every fs on a discarding disk is mounted `discard` | neither (only when a disk passes the host check) | — | guest |
| each guest disk | — | `free_tail` ≥ `MIN_FREE_TAIL`, fix "M → Grow root filesystem" | — | guest |

On a stopped VM the guest rows are one `:skipped` finding: "start the VM for the guest checks".

**`Virsh#health(domain_name)`**: `domain_config` twice (live, and with the new keyword
`inactive: true` → `dumpxml --inactive`; the canned-xml positional parameter stays), `guest_storage` when running and the agent is connected (rescuing `Unavailable`
into the String, as `show_info_popup` does), then `Health.assess` with `@spawned_agent`'s
`read_file` and `exist?`. All spawned; ~0.5 s on vt-ubuntu by `guest_storage`'s ~0.25 s.
A finding names a mapper as `hccrypt (dm-0)`, so `Filesystem#mappers` holds `Mapper =
Data.define(:device, :name)` pairs: `dm-0` and its `guest_alias`.

**`VMEmulator#health(name)`**: the same `assess` over `domain_config`, `guest_storage` and a
canned file hash. One demo VM gets a warning (a disk without `discard`) so demo mode shows the
window's colours.

**`UI::HealthWindow < Tuile::Component::Window`**: takes `(vm, health)`, `.open` as a
modal popup like `VMInfoWindow`. Data API in domain terms, so the v2 picker can swap the
`TextView` for a list without touching `VMPane`.

```
┌─ vt-ubuntu health ────────────────────────────────────────────────┐
│ ✓ balloon   virtio, free page reporting                           │
│ ✓ agent     connected                                             │
│ ✓ vda       discards reach the image                              │
│ ! vdb       the host drops this disk's discards                   │
│             virt-xml vt-ubuntu --edit target=vdb --disk discard=unmap │
│ ! /mnt/hc   hccrypt (dm-0) blocks discard                         │
│             add `discard` to its /etc/crypttab line, then reboot  │
│ ✓ trim      fstrim.timer enabled                                  │
│ · vda       2.0G unused after vda1                                │
│             M → Grow root filesystem                              │
└─────────────────────────────────────────────── q/ESC to close ────┘
```

**`VMPane#check_health(vm)`**: `BackgroundTask.new("Checking #{vm}'s health") { virt.health(vm) }`,
then `HealthWindow.open`. No wrong-state alert.

**Specs**: `Health.assess` gets most of them, fed recorded fixtures:
`spec/virt/dumpxml_vt-ubuntu.xml` exists; add a `--inactive` one and a guestinfo with the
LVM-on-LUKS chain, recorded from vt-ubuntu as in `R_guestinfo`. `GuestStorage` gets a
`mappers` spec on that fixture. The window and the menu item get one spec each.

## Open questions

None. Answered 2026-10-24, and folded into the sketch: the mapper's name shown beside its
`dm-*`; `inactive:` as a keyword; `fix` a free-form String, a v2 Fix button through `remedy`; `GuestAgent#exist?` for a missing file;
every writable `disk` checked, a shared one only a note; the `/etc` `.wants/` symlink is enough
for `fstrim.timer`; three severities plus `:skipped`; fixes are named, never applied in v1;
the scope is the checks table.
