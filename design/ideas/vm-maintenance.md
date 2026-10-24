# VM maintenance under `M`: grow a running VM's root filesystem

**Status:** item 1, **Resize disk image**, shipped 2026-10-24 (`UI::DiskResizeWindow`,
`D_disk_resize`, `R_volume_resize`). Item 2 below is designed, not built. Every command was
run by hand on the `vt-*` VMs on 2026-10-24 (libvirt 12.0.0, QEMU 10.2.1, guest Ubuntu 26.04
cloud image, util-linux 2.41.3, e2fsprogs 1.47.2) unless marked otherwise.

**Grow root filesystem** joins `M`'s menu for a running VM: it grows the partition holding `/`
and the filesystem on it into the free space a disk image resize left at the end of the disk.
A separate item because it needs the VM running where the resize needs it off, and it also
serves a disk someone grew by other means.

## Decided

- **Grow only.**
- **Not cancelable**: `BackgroundTask.new(…, cancelable: false)`, as the resize is
  (`D_disk_resize`). The agent runs a `guest-exec` child to its end whatever virtui does, so a
  cancel would lie.
- **The demo pretends every Linux VM is the easy case**: `VMEmulator#guest_storage` already
  leaves room after `/`, growing with `VMEmulator::VM#disk_capacity`.
- **ext4 and btrfs** roots, directly on a partition. Ubuntu Desktop VMs (ext4, root partition
  last, swap in a file) are the target; that alone justifies the item.

## The checks — reads only

All through what the agent already allows, so the item can show *why* it is disabled.
Checks 1 and 2 are `Virsh#guest_storage` as the `i` window already uses it: the root
partition is the last of `GuestStorage::Disk#partitions`, its room is `#free_tail`, and the
filesystem name tells LVM (`dm-*`) from a plain partition. The details:

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

## The grow — `guest-exec`

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

## Lifting the `guest-exec` ban

The ban came from `D_no_force_drain`, a decision about forcing swap back into RAM;
`guest-exec` got one clause there, "a remote-root *write* where everything shipped reads a
file", and the AGENTS.md invariant generalized it. What the rule actually protects is that the
**poll loop** cannot change a guest, and `D_no_force_drain` itself names the shape an
exception takes: an operator keypress. The item is that: asked for, confirmed, fixed argv.

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
the item runs; `bin/test-vms.sh down && up` loses that. Its image is now 14 GiB, `/` 13G.
Re-test: stop, `M` → Resize disk image `+1G`, start, grow.
