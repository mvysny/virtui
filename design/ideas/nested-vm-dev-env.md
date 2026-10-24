# A nested VM to develop against

**Status:** both VMs are up (2026-10-24), built by `bin/test-vms.sh`. Every feature in the
`vt-ubuntu` list below was checked from inside the guest. Not done yet: virtui itself against
them, and the other ideas' *To check on a real host* lists.

#### First run, 2026-10-24

- The cloud image is 819 MB, not ~600. `gpgv` and `sha256sum` both passed.
- virt-install's `--cloud-init` failed. The guest shut down during its first boot (reason
  `shutdown`), the one-shot seed ISO went with it, and the next boot came up as hostname `ubuntu`
  with no `dev` user. The cause is not known: after the fix the guest boots only once and nothing
  resets it. The script now builds its own NoCloud seed (`xorrisofs`, volume `vt-seed.iso`) and
  leaves it in the CD-ROM, so the info window shows a CD-ROM with media, not an empty one.
- Checked inside `vt-ubuntu`: `cloud-init status: done`, hostname `vt-ubuntu`, `SecureBoot
  enabled`, `/dev/tpm0`, the virtiofs tag `share` mounts, 1 GiB `/swapfile`, `stress-ng`, and
  `qemu-guest-agent` active (`guest-get-osinfo` answers from the host with `version-id 26.04`).
  SSH with your key works.
- `down`, then `up`, works. The base volume survives.
- `domstats --balloon` for `vt-ubuntu` reports `balloon.unused=3790380` KiB with
  `balloon.current=1048576` KiB. Unused is larger than current. Worth a look before the balloon
  tests trust `unused`. `vt-bios`, which has no agent, reports only `current`, `maximum`,
  `last-update=0` and `rss`.

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

1. `stress-ng` in `vt-ubuntu` creates pressure;
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
`stress-ng --vm 1 --vm-bytes 3G` does exactly that. virt-manager's console (the `v` key) works
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
  there. A 3 GiB `stress-ng` run then pushes it most of the way to the ceiling, and pushes this
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
  - packages `qemu-guest-agent` and `stress-ng`, with the agent enabled;
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
ssh dev@… 'stress-ng --vm 1 --vm-bytes 3G --vm-keep -t 120s'   # push it, watch the RAM row grow
```

An `~/.ssh/config` entry `Host vt-ubuntu` would save looking up the IP, but the lease address can
change between recreations, so the script prints the address instead (`Q_ssh_alias`).

## The script

It is `bin/test-vms.sh up|down`, in bash like `design/verify_design_tripwires.sh`. It is
idempotent, so `up` skips a VM that is already defined. Its header says what it creates.

The flag names are now confirmed (*Step 1 done*). Still unknown until the first run: whether
the values are accepted together (Secure Boot with the 4M OVMF, memfd with virtiofs), and whether
`--remove-all-storage` deletes the shared raw volume too. Each one fails loudly. The base image is kept on
`down`; deleting it is a manual `virsh vol-delete`.

## Open questions

- `Q_outer_ceiling`: is 16 GiB enough for this box, or worth raising to 32 GiB? With
  `vt-ubuntu` at 4 GiB, `vt-bios` at 256 MiB and the box's own ~1.5 GiB, 16 GiB is plenty. 32
  only matters if a test wants several stressed guests at once to see the controller under
  contention.
- `Q_default_uri`: should virtui pass `-c qemu:///system` itself, as the `v` key's `virt-manager`
  call already does, rather than rely on the user's `uri_default`? That is a product question
  this setup brings up but does not answer. The virt-manager line suggests the system instance is
  the assumption anyway.
- `Q_osinfo`: answered 2026-10-24. No, the osinfo-db stops at 25.10, so the script uses
  `ubuntu24.04`.
- `Q_backing_chain`: half answered on 2026-10-24. Plain `domstats --block`, which is what
  virtui runs (no `--backing`), lists only `vda`, `vdb` and `sda`, so `block.count=3` and there
  is no entry for the backing file. Each entry carries a `block.N.backingIndex` (3, 2, 1). Still
  open: whether the qcow2 `df` lookup copes with an overlay, which the first virtui tick will show.
- `Q_ssh_alias`: add an `~/.ssh/config` `Host vt-ubuntu` block that the script keeps updated, or
  print the address and stop there? I lean towards printing it.
- `Q_claude_power`: answered 2026-10-24. Yes, the `vt-*` VMs are Claude's to test with as
  needed. The rule is now in AGENTS.md *Commands*.

## Where the nuggets land when this graduates

- Landed already: `bin/test-vms.sh`, and the `vt-*` rule in AGENTS.md *Commands*.
- README install section: the `uri_default` line, if `Q_default_uri` keeps it the user's job.
- Every *To check on a real host* list in the other ideas gets worked off against `vt-*`, and the
  facts land in `design/research.md` as **[verified]** with the date.
