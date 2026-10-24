# A nested VM to develop against

**Status:** the environment is built and understood (2026-10-24). `bin/test-vms.sh` builds both
VMs, virtui has been run against them, and the full balloon cycle and the two-level chain have
been watched. The two virtui problems that turned up (*What virtui did*) are fixed:
`Q_min_actual` and `Q_disk_overhead`. Two items of `vm-ip-address.md`
and `vm-info-window.md` were checked off here; the rest of those lists stays with them.

#### The environment, as built and checked 2026-10-24

- The cloud image is 819 MB, not ~600. `gpgv` and `sha256sum` both passed.
- Checked inside `vt-ubuntu`: `cloud-init status: done`, hostname `vt-ubuntu`, `SecureBoot
  enabled`, `/dev/tpm0`, the virtiofs tag `share` mounts, a 1 GiB `/swapfile`, `memramp`, and
  `qemu-guest-agent` active (`guest-get-osinfo` answers from the host with `version-id 26.04`).
  SSH with your key works.
- `down`, then `up`, works in about two minutes. The base volume survives.
- **virt-install's own `--cloud-init` cannot work with this image.** On an empty NVRAM, shim's
  `fallback.efi` writes the boot entry and resets the VM. libvirt emitted a `reboot` event 5.8 s
  into the first boot, while the screen was still black at 640×480 firmware resolution. During
  virt-install's install phase `on_reboot` is `destroy`, so that reset ends as `shut off
  (shutdown)` and the one-shot seed is gone. With `--noautoconsole` and no `--wait`, nobody
  restarts the VM. Hence the script's own NoCloud seed (`vt-seed.iso`), left in the CD-ROM for good.
- **The guest boots with all of `<memory>`.** The balloon inflates down to `<currentMemory>` only
  once the guest's balloon driver loads, about 20 s in. The 1 s `balloon-change` events step
  4 GiB → 3.6 GiB → … → 1 GiB. Stats collected before then describe a 4 GiB guest, which is the
  `balloon.unused=3790380` KiB seen against `current=1048576`. That stale snapshot is also what
  `D_mem_stats_self_armed` is about: with no stats period set, the numbers never move again, and
  virtui arms the period itself.
- **`stress-ng --vm` is not a repeatable memory load on a ballooned guest.** It sizes itself to
  what is free when it starts. Asked for 3.5 GiB at a 0.8 GiB actual, it mapped 2.6 GiB and kept
  0.9 GiB resident. The guest therefore carries `memramp MIB [MIB/s [hold s]]`, which touches
  every page of a `bytearray` at a set rate (default 200 MiB/s, hold 60 s).

#### What virtui did, 2026-10-24

Run from tmux (`tmux new -d -s vt -x 170 -y 50 bin/virtui`, read with `tmux capture-pane -p`).

- Both VMs show up correctly. `vt-ubuntu` has 🐧, its IP, the swap row and 🎈. `vt-bios` has
  `?` (no osinfo) and 🐢: its balloon stats never refresh, because it has no guest balloon driver.
- **Stock virtui never balloons `vt-ubuntu` (`Q_min_actual`).** `BallooningVM`'s `@min_actual`
  is 8 GiB. A VM whose `<memory>` is below that gets "VM max memory … is below min_actual,
  doing nothing" on every tick. That status only reaches `$log.debug`, so nothing on screen says
  why. In that first run, a guest at 95% RAM with 600 MiB swapped had `stress-ng` OOM-killed
  while virtui watched.
- **With the floor at 512 MiB, the controller works as designed.** The floor was lowered by a
  throwaway `prepend` wrapper, not a code change. Ramping 3.5 GiB: 0.8 → 1.1 → 1.4 → 1.8 →
  2.3 → 3.0 → 3.9 GiB in 22 s, one +30% step per fresh sample, with no OOM kill. The
  swap vetoer then held for 60 s ("the guest swapped recently"), and the guest stepped down 10%
  every ~12 s to 0.82 GiB, where it settled at ~51% used. Load and swap rate were both
  given as reasons, as `D_swap_raise_vote` predicts.
- **The two-level chain works.** With `vt-ubuntu` grown to 4 GiB and 3.7 GiB resident, the host's
  virtui grew this box 7.1 → 9.5 → 11.3 GiB, then shrank it to 10 GiB as it idled.
  `Q_outer_ceiling` is therefore moot for one guest: 16 GiB has room.
- **The host-usage disk column shows a red `999%`** for the raw `vt-shared.raw`, the seed ISO
  and `vt-bios`'s disk. `DiskStat#overhead_percent` divides `physical` by `allocation`.
  `allocation` is 0 for a disk nothing has written to, raw or not, so the division gives
  Infinity, clamped to 999. The qcow2 overlay (`vda`) reads a sane `0%`
  (`Q_backing_chain`'s other half: the overlay is fine).

## Why

virtui is developed on a box with no libvirt. Every `virsh` fact therefore comes from docs or
from fixtures you recorded by hand on another host. Each idea file ends with a *To check on a real
host* list (`vm-ip-address.md`, `vm-info-window.md`), and the ballooning controller has only ever
run against the emulator here. Claude also cannot check its own work. A real libvirt on this box,
with one or two disposable guests, would make all of that something Claude can run itself:

- record `dumpxml`, `domstats`, `domifaddr` and guest-agent replies as fixtures;
- run `bin/virtui` against real domains, not demo mode;
- SSH into a guest, load its memory, and watch virtui grow it, then let it idle and watch the
  balloon come back down.

## What this box can do

This box is itself a VM, so the guests are **nested VMs**. Checked on 2026-10-24:

- Ubuntu 26.04.1 LTS, running under KVM (`systemd-detect-virt`: `kvm`).
- **`/dev/kvm` is present and the CPU shows `vmx`/`svm`**, so the parent host passes nested
  virtualization through, and nested VMs run with hardware acceleration rather than TCG.
- 8 vCPUs, 4 GiB swap, 86 GB free on `/`. RAM read 7.1 GiB at the time, but **that is only
  where the balloon happened to be.** The box is itself ballooned by virtui on the real host, with
  a ceiling of 16 GiB, and the owner can raise it to 32 GiB.
- The libvirt stack and the groups are now in place; *Step 1 done* below has the details.
  `virtiofsd` was installed already. `/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg` is
  present, so a downloaded cloud image can be verified against a key the distro already ships.

**RAM is therefore elastic, not a fixed 7 GiB.** When a nested VM grows, this box comes under
pressure, and the host's virtui grows this box in turn. That is two levels of virtui ballooning
in a chain, which is a test in its own right:

1. `memramp` in `vt-ubuntu` creates pressure;
2. this box's virtui grows `vt-ubuntu`;
3. this box's available memory falls;
4. the host's virtui grows this box.

Watching both virtuis side by side shows the whole chain. The reverse direction (idle, then
free page reporting returns pages, then both balloons shrink slowly) is the half that is hard to
see anywhere else.

The ceilings below still stay modest, a few GiB per nested VM. They are not tight, but the host's
growth step is a reaction, not a reservation: a nested VM that asks for memory faster than the
outer balloon grows pushes this box into swap first. That is realistic, but it is not what a
first test should measure.

## The plan

### 1. Host packages: you run this

Everything comes from the Ubuntu archive. Per your rules, Claude does not run this:

```fish
sudo apt install qemu-system-x86 libvirt-daemon-system libvirt-clients virtinst ovmf swtpm
sudo usermod -aG libvirt,kvm mavi
```

Then log out and back in, or at least restart Claude Code. A group change only reaches processes
started after it, and Claude's shell is one of them.

**virtui runs `virsh` without `-c`.** As a non-root user that connects to `qemu:///session`,
which sees no system VMs. To make the system instance the default for this user:

```fish
mkdir -p ~/.config/libvirt
echo 'uri_default = "qemu:///system"' > ~/.config/libvirt/libvirt.conf
```

That `uri_default` setting is probably what your real host already has, or an
`LIBVIRT_DEFAULT_URI`. It belongs in the README's install section either way (`Q_default_uri`).

#### Step 1 done: what the box looks like now (2026-10-24)

- Installed: `virt-manager` 5.1.0, `qemu-system-x86` 10.2.1, `libvirt-daemon-system` and
  `libvirt-clients` 12.0.0, `ovmf`, `swtpm`, `swtpm-tools`. On 26.04, `virt-install` is its own
  package (`virtinst` shows as not installed). `mavi` is in `libvirt` and `kvm`, and Claude's
  shell already has both groups.
- `libvirtd` (monolithic, not `virtqemud`) is active. `virt-host-validate qemu` passes: SVM,
  `/dev/kvm` accessible, vhost-net, cgroups.
- **`virsh` with no `-c` already reaches `qemu:///system` as `mavi`.** No
  `~/.config/libvirt/libvirt.conf` exists, no `LIBVIRT_DEFAULT_URI` is set, and the
  `uri_default` line in `/etc/libvirt/libvirt.conf` is commented out. Even so, `LIBVIRT_DEBUG=1
  virsh uri` logs `Using config file uri 'qemu:///system'`. The mechanism is unknown (an Ubuntu
  patch?), but the `mkdir`/`echo` above is not needed on this box. It is still a step for the
  README, because another distro may behave differently.
- The `default` network is active and autostarts. **Its subnet is `192.168.123.0/24`, not
  `.122`.**
- **A fresh install has no storage pool, not even `default`.** virt-manager's first launch then
  created `default`, a `dir` pool at `/var/lib/libvirt/images` that is running, autostarts and
  has 91 GiB free. The script keeps `ensure_pool` for a box where virt-manager has never run,
  and it makes the same pool.
- UEFI: `domcapabilities` offers `efi` with `/usr/share/OVMF/OVMF_CODE_4M.fd`.
- `Q_osinfo` answered: osinfo-db stops at `ubuntu25.10`. Use `ubuntu24.04`.
- virt-install 5.1.0 knows `--memory currentMemory=`, `--boot uefi,firmware.featureN.name/enabled`,
  `--memballoon freePageReporting=`, `--memorybacking source.type/access.mode`,
  `--filesystem driver.type`, and `--disk shareable/cache`. **`--tpm` has `backend.version`, not
  `version`**, so the script now uses the former.

### 2. The guest image: an Ubuntu 26.04 cloud image, no desktop

**Decided 2026-10-24: the server cloud image, and no Ubuntu Desktop guest at all.** A GUI adds
nothing to balloon tests. Those want a load that gives the same curve every time, and
`memramp 3500` does exactly that. virt-manager's console (the `v` key) works
on a text console just as well. Next to the desktop ISO, the cloud image is also a ~600 MB download
instead of ~6 GB. It boots in ~30 s, where the desktop needs a 15–30 min nested install. And
deleting the qcow2 overlay plus one user-data file recreates it in a minute.

The image comes from `cloud-images.ubuntu.com/resolute/current/`. The script verifies
`SHA256SUMS.gpg` against the distro's `ubuntu-cloudimage-keyring.gpg` and then the checksum. It
is a guest OS image, not software for this box, but it is still a download, so the script stops
and asks first.

The image is downloaded once into libvirt's `default` pool as a read-only base. Each nested VM
gets its own small qcow2 **overlay** that uses the base as its backing file. Recreating a VM means
throwing away its overlay, and the 600 MB download never repeats. It also gives virtui a backing
chain to cope with in `domstats` (`block.N.backingIndex`), which is worth seeing for real
(`Q_backing_chain`).

### 3. Two nested VMs, named `vt-*`

Everything the script creates has a `vt-` prefix ("virtui test"), so the teardown script can
touch nothing else, and so can Claude. Graduating this idea puts that rule in AGENTS.md.

**`vt-ubuntu`** is the real guest, the one you SSH into:

- memory ceiling 4 GiB (`<memory>`), boot size 1 GiB (`<currentMemory>`). virtui grows it from
  there. A 3.5 GiB `memramp` then pushes it most of the way to the ceiling, and pushes this
  box past its current balloon;
- 2 vCPUs;
- UEFI with Secure Boot, and an emulated TPM 2.0 (`ovmf`, `swtpm`). That covers the info
  window's firmware and TPM lines;
- a virtiofs share of a host directory (`~/vt-share` → tag `share`), which needs shared memory
  backing (`memfd`). That covers the *Shared folders* line;
- a 1 GiB raw disk marked `shareable` with `cache=none`, plus an empty CD-ROM;
- a virtio balloon with `freePageReporting`, and the qemu-guest-agent channel;
- osinfo `ubuntu24.04`, because this box's osinfo-db has no `ubuntu26.04` (`Q_osinfo`);
- cloud-init:
  - a user `dev` with password `dev` (simple on purpose: this guest is reachable only from this
    box, on libvirt's NAT network), SSH password logins enabled, and your
    `~/.ssh/id_ed25519.pub` authorized, so Claude can SSH in with no password prompt and no
    `sshpass`;
  - packages `qemu-guest-agent` and `stress-ng` (CPU load), with the agent enabled, plus
    `/usr/local/bin/memramp` (memory load);
  - a swap file, because a guest with no swap never exercises the swap voters
    (`SwapOutRaiseVoter`, `SwapOutShrinkVetoer`).

**`vt-bios`** is the plain one, which never needs to boot an OS:

- legacy BIOS, 1 vCPU, 256 MiB, a tiny empty disk, no agent channel, `--osinfo
  detect=off,require=off` so it declares no OS;
- it sits at SeaBIOS' "No bootable device" forever, which costs almost nothing.

It covers what `vt-ubuntu` cannot: the info window's "no channel" and "BIOS" lines, an
`:unknown` guest OS, a guest whose agent never answers (`D_guest_agent_backoff`'s write-off), and
a VM that can be started and stopped freely to test the power keys.

### 4. How it is used afterwards

```fish
virsh -q domifaddr vt-ubuntu --source lease       # or read it off virtui's VM header
ssh dev@192.168.123.x                             # password dev, or the key
ssh dev@… 'memramp 3500 200 90'                   # push it, watch the RAM row grow
```

An `~/.ssh/config` entry `Host vt-ubuntu` would save looking up the IP, but the lease address can
change between recreations, so the script prints the address instead (`Q_ssh_alias`).

## The script

It is `bin/test-vms.sh up|down`, in bash like `design/verify_design_tripwires.sh`. It is
idempotent, so `up` skips a VM that is already defined. Its header says what it creates.

Every flag was accepted together on the first run, including Secure Boot with the 4M OVMF and
memfd with virtiofs. `--remove-all-storage` deletes every volume the domain references,
including the shared raw disk and the seed. The base image is kept on `down`; deleting it is a
manual `virsh vol-delete`.

## Still open

- Showing *why* the controller is doing nothing ("ballooning unsupported", "stale data", …)
  somewhere in the UI. Today that status only reaches `$log.debug`. Suggested while
  `Q_min_actual` was being settled, but not decided.

## Answered

- `Q_min_actual`: decided 2026-10-24. The floor is the smaller of 8 GiB and half the VM's
  maximum (`BallooningVM#floor`). A shrink never raises a VM that booted below its floor. Checked
  with stock virtui on `vt-ubuntu` (floor 2 GiB): idle at 1 GiB it is left alone, and
  `memramp 3000` raises it 1 → 2 → 2.6 → 3.4 → 4 GiB, and as it idles it steps back down
  and stops at exactly 2 GiB.
- `Q_disk_overhead`: decided 2026-10-24. `0%` for a disk with `allocation` 0, for consistency.
- `Q_default_uri`: decided 2026-10-24. virtui passes no `-c`; README *Setup* says how to check
  with `virsh uri`. A remote host runs its own virtui over ssh, so there is no list of URIs.
  Measured here: libvirt 12.0's client, as a non-root user with no config and no
  `LIBVIRT_DEFAULT_URI`, probes the system sockets (`virtqemud-sock`, then `libvirt-sock`) and
  connects to `qemu:///system`. Whether only Ubuntu does this is not known.

- `Q_outer_ceiling`: 16 GiB is enough. The chain test grew this box to 11.3 GiB with one 4 GiB
  guest. 32 only matters for several stressed guests at once.
- `Q_osinfo`: no `ubuntu26.04` in the osinfo-db (it stops at 25.10), so the script uses `ubuntu24.04`.
- `Q_backing_chain`: no double count. Plain `domstats --block` (no `--backing`, as virtui runs it)
  lists only the attached disks, and the overlay's host column reads a sane 0%.
- `Q_ssh_alias`: the script prints the address once the lease appears; no `~/.ssh/config`.
- `Q_claude_power`: the `vt-*` VMs are Claude's to drive. The rule is in AGENTS.md *Commands*.

## Where the nuggets land when this graduates

- Landed already: `bin/test-vms.sh`, and the `vt-*` rule in AGENTS.md *Commands*.
- Landed already: the `domifaddr` facts in `R_virsh_domifaddr`, the dumpxml and offline-domstats
  facts in `vm-info-window.md`.
- `design/research.md`: the boot-time balloon inflation, the shim fallback reset, and
  `stress-ng`'s self-sizing, each **[verified 2026-10-24]**. `Q_min_actual`, `Q_disk_overhead`
  and `Q_default_uri` have landed already, in doc comments and the README.
- AGENTS.md *Commands*: how to drive virtui from tmux, if that keeps being useful.
