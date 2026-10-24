# VM maintenance under `M`: grow a VM's disk, then its root filesystem

**Status:** designed (2026-10-24), nothing built. Every command below was run by hand on the
`vt-*` VMs on 2026-10-24 (libvirt 12.0.0, QEMU 10.2.1, guest Ubuntu 26.04 cloud image,
util-linux 2.41.3, e2fsprogs 1.47.2) unless marked otherwise.

`M` opens a maintenance menu for the selected VM: a menu, not a direct key, because more items
come later (snapshots, sparsify). Two items to start, each disabled with its reason when it
does not apply:

1. **Resize disk image…** — a stopped VM only: grows a qcow2 or raw image on the host.
2. **Grow root filesystem** — a running VM only: grows the partition holding `/` and the
   filesystem on it into the free space item 1 left at the end of the disk.

Two items because they need opposite VM states, and each is worth having alone: item 1 on a
cloud image is all the job (cloud-init grows `/` at the next boot), item 2 also serves a disk
someone grew by other means.

## Decided

- **Grow only, never shrink**, in both items.
- **Both operations cannot be canceled.** `UI::BackgroundTask` grows a flag (e.g.
  `cancelable: false`): its `ProgressWindow` swallows ESC and `q` instead of closing and drops
  the "ESC to cancel" footer. The popup is modal and gets every key first (tuile's
  `Popup#handle_key?` is what closes on ESC/`q` today), and Ctrl+C in raw mode is just byte
  `\x03`, which nothing binds, so the user cannot quit virtui mid-operation either. The honest
  reason is not that a cancel would corrupt the image — a cancel kills nothing (the task's doc
  comment), libvirtd runs `qemu-img` to its end whatever its client does, and the agent runs a
  `guest-exec` child to its end — but that a cancel which cannot stop the work would lie.
- **The demo pretends every VM is the easy case**: `VMEmulator` keeps a disk capacity item 1
  grows and a root filesystem item 2 grows into it.
- **ext4 and btrfs** roots are supported, directly on a partition. Ubuntu Desktop VMs (ext4,
  root partition last, swap in a file) are the target; that alone justifies item 2.

## Item 1: resize the disk image (stopped VM)

The image belongs to root while the VM is stopped (the user cannot even list
`/var/lib/libvirt/images`), but virtui never opens it: the user is in the `libvirt` group,
libvirtd runs as root, and its storage driver runs `qemu-img resize` itself.

```
virsh -q domblklist <vm> --details        # `file disk` rows; CD-ROMs are not offered
virsh -q vol-pool  <path>                 # → default
virsh -q vol-info  <path>                 # capacity, allocation
virsh -q pool-info <pool>                 # Available
virsh -q vol-resize <path> <bytes>        # spawned, through Run (D_virsh_session)
```

The dialog: pick the disk (skipped when there is one), then a tuile text field taking `+10G`
(grow by) or `20G` (new capacity), binary units as everywhere on screen (`G` = GiB, as in
virsh's own scaled integers). virtui parses it and passes virsh plain bytes; a size at or below
the current capacity is rejected before any `virsh` call. The dialog shows the pool's available
space, and warns — does not refuse — when the growth exceeds it: qcow2 is sparse, so growing
costs nothing now, but the disk could no longer fill up.

Observed:

- `vol-pool` and `vol-info` find a volume by its path, though its directory is unreadable.
- Growing `vt-ubuntu.qcow2` by 2 GiB took **37 ms**: qcow2 growth only rewrites the header.
- `vol-resize <path> 1G` on the 14 GiB image is refused: `Can't shrink capacity below current
  capacity unless shrink flag explicitly specified`. virtui checks anyway, for the message.
- `vol-resize` on a **running** VM's image fails: `qemu-img: … Failed to get "write" lock`. A
  VM started between virtui's state check and the resize makes the resize fail, not corrupt.
- Why not `blockresize` for running VMs too: it grew `vt-bios` live, then **shrank it back,
  exit 0, no warning**. One path, stopped only.

Refused, with the reason on screen: a disk in no storage pool (`vol-pool` fails) gets the
command to run by hand instead, `sudo qemu-img resize <path> <size>` with the VM stopped, and
virtui does not escalate; network disks and block devices outside a logical pool are not
offered; whatever `qemu-img` refuses is shown as it is.

## Item 2: grow the root filesystem (running VM)

### The checks — reads only

All through what the agent already allows, so the item can show *why* it is disabled:

1. `virsh guestinfo <vm> --filesystem --disk` (one libvirt call): `/` has fstype `ext4` or
   `btrfs`, sits on exactly one disk, and libvirt names that disk's host side for us —
   `fs.0.disk.0.alias: vda`, `fs.0.disk.0.device: /dev/vda1`. The `disk.*` half lists every
   guest block device with `partition: yes|no` and its dependencies: `/` must be on an entry
   with `partition: yes` whose dependency is the disk itself. LVM or LUKS put a
   `partition: no` `dm-*` device between them (expected from the agent's own docs, not
   observed: no such VM here).
2. `guest-file-read` of `/sys/block/vda/size` and `/sys/block/vda/vda*/{start,size,partition}`:
   the root partition must be the **physically** last one, not the highest-numbered. On
   `vt-ubuntu` `/` is `vda1` at sector 2324480, behind `vda13`, `vda14` and `vda15`. The free
   tail is `disk size − (start + size)` sectors; under a few MiB means "nothing to grow" (a GPT
   disk always keeps 33 sectors at its end for the backup table).
3. `guest-file-read` of `/run/udev/data/b<major>:<minor>`, the numbers from
   `/sys/block/vda/dev`: `E:ID_PART_TABLE_TYPE=gpt` (or `dos`). An MBR partition numbered over
   4 is a logical one inside an extended partition, which would need growing first: refused.
   (MBR not observed: no MBR VM here.)
4. `guest-info`: `guest-exec` and `guest-exec-status` are `enabled` (RHEL-family agents ship
   with `guest-exec` blocked).

### The grow — `guest-exec`

Three commands, a fixed argv, the agent running them as root (`USER=root`, `LANG=C.UTF-8`,
`PATH` with both `sbin`s, so bare names resolve). Each is one `guest-exec` with
`capture-output`, polled through `guest-exec-status` until it exits; a non-zero exit stops the
sequence and puts its stderr in the failure alert.

```
sfdisk -N <n> --no-reread --no-tell-kernel /dev/vda     # stdin ", +": grow partition n to the end
partx -u /dev/vda                                       # the kernel learns the new size
resize2fs /dev/vda<n>                                   # ext4, online, mounted
btrfs filesystem resize max /                           # btrfs instead (not observed)
```

`guest-exec` takes the stdin as `input-data`, base64. On `vt-ubuntu` after a 2 GiB image grow:
`/` went from 11G to 13G mounted, `sfdisk --verify` then said "No errors detected". sfdisk's
write moved the backup GPT and fixed the protective MBR on its own (stderr: "The backup GPT
table is not on the end of the device. This problem will be corrected by write."), so no
separate relocation step: `sfdisk --relocate gpt-bk-std` is not even accepted by this version.

The tools are util-linux (`sfdisk`, `partx`) and the root filesystem's own (`e2fsprogs`,
`btrfs-progs`), present wherever that root is. Why not `growpart`: cloud-guest-utils is stock
on cloud images only, and those run it themselves at every boot.

### Lifting the `guest-exec` ban

The ban came from `D_no_force_drain`, a decision about forcing swap back into RAM;
`guest-exec` got one clause there, "a remote-root *write* where everything shipped reads a
file", and the AGENTS.md invariant generalized it. What the rule actually protects is that the
**poll loop** cannot change a guest, and `D_no_force_drain` itself names the shape an
exception takes: an operator keypress. Item 2 is that: asked for, confirmed, fixed argv.

So on implementation:

- `guest-exec` lives in its own class (e.g. `Virt::GuestRootGrow`), so `Virt::GuestAgent` —
  the channel the loop polls — stays read-only by construction, not by discipline.
- The invariant becomes: "`Virt::GuestAgent` only reads files; `guest-exec` is used only by
  `Virt::GuestRootGrow`, from an operator-confirmed `M` item, with a fixed argv — never from the
  loop."
- A new `D_` argues it, citing `D_no_force_drain`.
- The `guest-exec` call is mutating, so its `virsh qemu-agent-command` spawns its own process,
  not the session (`D_virsh_session`).

## Testing on the dev box

`vt-ubuntu` has cloud-init's growpart and resize_rootfs turned off since 2026-10-24
(`/etc/cloud/cloud.cfg.d/99-no-growpart.cfg`), so a grown image stays un-grown inside until
item 2 runs; `bin/test-vms.sh down && up` loses that. Its image is now 14 GiB, `/` 13G.
Re-test: stop, `vol-resize --delta 1G`, start, grow.
