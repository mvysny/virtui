# VM info window: the guest's partitions and filesystems

**Status:** idea (2026-10-24). Nothing built.

The `i` window (`UI::VMInfoWindow`) lists the disks as the host defines them — `vda virtio
qcow2 40G` and the image path. It cannot answer what the user actually asks when a disk fills
up: *which filesystem, how full, and is there room left on the disk to grow it?* The guest
agent answers all of it with reads, the same ones `design/ideas/vm-maintenance.md`'s item 2
needs for its checks, so the two share a parser.

## What it would show

Under each disk, its partitions in disk order, and the mounted filesystems with their usage:

```
│ Disks                                                  │
│   vda  virtio  qcow2  14G  (600M on host)              │
│        /var/lib/libvirt/images/vt-ubuntu.qcow2         │
│        vda13  1023M  ext4  /boot      108M / 921M  12% │
│        vda14     4M                                    │
│        vda15   106M  vfat  /boot/efi  6.3M / 104M   6% │
│        vda1   12.9G  ext4  /          3.2G / 12.4G 26% │
│        free      0                                     │
```

- **Partitions in start-sector order**, not by number: on an Ubuntu cloud image `vda1` (`/`)
  sits after 13, 14 and 15, and that order is what decides whether `/` can grow.
- **A trailing `free` row** when the tail after the last partition is worth mentioning — right
  after an image resize it says how much a "Grow root filesystem" would add.
- **Usage per mounted filesystem**, used / total and a percentage.
- **Host allocation beside the capacity** (`domblkinfo`'s Allocation): how much the sparse
  image really takes on the host.

## Where each fact comes from

All observed on `vt-ubuntu` on 2026-10-24.

- `virsh guestinfo <vm> --filesystem --disk` — one libvirt call. Per filesystem: `name`,
  `mountpoint`, `fstype`, `total-bytes`, `used-bytes`, and libvirt's own mapping to the host
  disk (`fs.0.disk.0.alias: vda`, `fs.0.disk.0.device: /dev/vda1`). Per guest block device:
  `name`, `partition: yes|no`, dependencies, and for whole disks the host `alias` and
  `guest_bus`. Mapping guest `/dev/vda` to host target `vda` is not a matter of equal names —
  the guest kernel names disks by probe order — and libvirt does it for us here.
- `guest-file-read` of `/sys/block/<disk>/size` and `/sys/block/<disk>/<part>/{start,size}`:
  partition geometry, which `guestinfo` lacks. One read per file; a disk with four partitions
  is nine reads.
- `virsh domblkinfo <vm> --all`: host capacity and allocation per target, no agent needed.

Unmounted partitions (`vda14`, the BIOS boot one) appear with their size only; swap partitions
are not in `guestinfo`'s filesystem list either, so they look the same.

## Fit with what exists

- The window is a snapshot opened through `BackgroundTask` (`vm_pane.rb`'s
  `show_info_popup`); these reads join `domain_config` in the same task. Spawned processes, as
  today.
- **A stopped VM, or one without an answering agent, shows the window as it is now**: the
  guest half is optional, like the swap level (`D_guest_agent_backoff` is the precedent for
  a guest read allowed to go quiet). The `Agent` line already says when there is no channel.
- `VMEmulator` needs a fake layout for demo mode — the same easy-case layout the maintenance
  demo grows.

## Open questions

- `Q_read_cost`: nine or more round trips through the agent for one `i`, on top of
  `dumpxml`. Each is fast locally, but a sluggish guest multiplies it. Read all `/sys` files in
  one `guest-exec cat` instead? No: that would put `guest-exec` back on a read path, which the
  maintenance idea keeps off. Measure first.
- `Q_lvm_luks`: an LVM or LUKS root shows `dm-*` in `guestinfo`. Show the chain
  (`vda3 → dm-0 → /`) or just the filesystem under the disk with "(LVM)"? No such VM here
  to see what the agent reports.
- `Q_other_os`: a Windows guest's agent reports volumes (`C:\`) with no partition geometry in
  `/sys`. Show the `guestinfo` half only?
