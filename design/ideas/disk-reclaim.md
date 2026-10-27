# Disk reclaim: give a guest's freed space back to the host

**On hold (2026-10-24)** behind the health check (`D_health_check`, shipped): whether discard is
wired comes first.

A qcow2 image only grows: a block the guest writes is allocated on the host, and a file the
guest deletes leaves it allocated unless the discard reaches the host. The ask was an offline
`qemu-img convert -O qcow2 old new`, which writes a fresh, compact image.

## What the experiment on vt-ubuntu showed (`R_discard_reclaim`)

- The guest *thinks* discard works: virtio-blk advertises it, `/` is mounted `discard`,
  `fstrim.timer` is on. Without `discard='unmap'` in the domain XML, QEMU drops every discard
  on the floor; the image kept a deleted 1 GiB.
- With `discard='unmap'` (and a cold restart), `virsh domfstrim` reclaimed it in 1.5 s, on a
  running VM, and went past it: 618 MB before the test → 536 MB after. A live trim also gets
  whatever accumulated while discard was off, since ext4 forgets on mount what it had trimmed.
- What a live trim does **not** shrink is the file's length (`Physical`): the holes are
  punched, `du` drops, `ls -l` doesn't. Only a rewrite shrinks that.

## So what is `convert` still good for?

Once discard reaches the host, the host's disk space is already back. A convert then gains:

- the file's length: matters to a backup tool that copies without `--sparse`, not to the disk;
- defragmentation of the image;
- compression, with `-c`.

And when discard is broken, a convert reclaims only the blocks that read as zeros. A deleted
ext4 file still holds its old data, so nothing comes back unless the guest zeroed it first
(`zerofree`, or an `fstrim` after enabling discard, which needs no convert anyway). Under
dm-crypt with no `allow-discards`, free space reads as ciphertext: never zeros, so nothing comes
back at all. **[unverified, reasoned from convert's zero detection]**

Its costs:

- **The VM must be off.** QEMU holds the image's write lock (`R_volume_resize`).
- **It flattens a backing chain.** `vol-create-from`, libvirtd's convert, turned a 200 KB overlay
  into 2.24 GB (`R_discard_reclaim`). By hand, `qemu-img convert -B <backing> -F qcow2` keeps
  the chain. vt-ubuntu itself is such an overlay.
- **It drops internal snapshots**: convert copies the active layer. **[docs, unverified here]**
- **Root, and a swap.** The image is root's. `vol-create-from` works without sudo but writes a
  new volume; libvirt has no rename, so either the domain is repointed at the new path
  (`define`, a config write) or the copy is made twice.
- **Twice the space while it runs, and no cancel** (the same libvirtd-owns-`qemu-img` argument as
  `D_disk_resize`).

## Where I lean

The value is the **live trim**, not the convert: `discard='unmap'` in the XML, then `domfstrim`.
No downtime, no copy, no root, and it gets the space back. That makes the
health check (`D_health_check`: is discard wired end to end?) the main feature, plus
an `M` → "Trim free space" item that runs `virsh domfstrim`. That is one agent command,
`guest-fstrim`, which only discards free blocks. It belongs with `GuestRootGrow`'s
operator-confirmed writes, not with `GuestAgent`'s reads.

Offline compaction is a later item, if ever. If it comes, it should refuse a disk with a backing
chain or internal snapshots rather than handle them.

## Open questions

- `Q_what_shrank`: when convert "shrank the image considerably", was that `ls -l` or `du` /
  `qemu-img info`'s "disk size"? If it was the length only, the live trim already gave back the
  space and the convert was cosmetic. If `du` dropped a lot, discard was broken *and* the
  free space was zero-filled, which is worth understanding before building anything.
- `Q_trim_where`: `M` → Trim, or a key of its own? Or automatic, a `domfstrim` after a big
  balloon shrink? I'd keep it manual: trimming is cheap, but the poll loop never writes to a
  guest (`D_guest_root_grow`).
- `Q_trim_refusal`: when `discard='unmap'` is missing, `domfstrim` "succeeds" and changes
  nothing. Refuse with the reason (and the fix), or run it anyway?
- `Q_convert_tool`: if offline compaction ever comes: `vol-create-from` (no sudo, flattens),
  `qemu-img convert -B` by hand, or libguestfs' `virt-sparsify --in-place`, which trims inside
  an appliance and so works even where the guest never discarded? Which is in Ubuntu's repo?
- `Q_test_vms`: `bin/test-vms.sh` builds vt-ubuntu without `discard=unmap`. This session set it
  with `virt-xml`, so vt-ubuntu now has it until it is rebuilt. Should the script build it that
  way, leaving vt-bios (sata, no discard) as the broken specimen?
