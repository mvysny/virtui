# A nested VM to develop against

**Status:** proposal, nothing installed (2026-10-24). The draft script below has never been run.

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
- `mavi` is not in the `libvirt` or `kvm` groups yet.
- All of these are in the distro repo, none installed: `qemu-system-x86`,
  `libvirt-daemon-system`, `libvirt-clients` (12.0.0), `virtinst` (5.1.0), `ovmf`, `swtpm`.
  `virtiofsd` is already installed. `/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg` is
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

### 2. The guest image: an Ubuntu 26.04 cloud image, not the desktop ISO

| | Desktop ISO + autoinstall | Server cloud image + cloud-init |
|---|---|---|
| Download | ~6 GB | ~600 MB |
| First boot | 15–30 min unattended install, nested | ~30 s; nothing to install |
| RAM | 4 GiB+ to install, ~1.5 GiB idle (affordable, since this box is ballooned) | 512 MiB is enough; ~200 MiB idle |
| Reproducible | the autoinstall YAML plus the installer's mood | one qcow2 overlay plus one user-data file; delete and recreate in a minute |
| Memory pressure for ballooning | a browser, roughly | `stress-ng --vm 1 --vm-bytes 3G`, exact and scriptable |

RAM no longer rules the desktop out, but it still loses on the other rows. A desktop session does
not help with balloon tests: a controllable `stress-ng` load is better because the same command
gives the same curve every time. And virt-manager's console (the `v` key) works on a text console
just as well. So: **the cloud image**, with the desktop as `Q_desktop` if a GUI guest is ever
really needed.

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
- osinfo `ubuntu26.04` if this box's osinfo-db knows it, else `ubuntu24.04` (`Q_osinfo`);
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
ssh dev@192.168.122.x                             # password dev, or the key
ssh dev@… 'stress-ng --vm 1 --vm-bytes 3G --vm-keep -t 120s'   # push it, watch the RAM row grow
```

An `~/.ssh/config` entry `Host vt-ubuntu` would save looking up the IP, but the lease address can
change between recreations, so the script prints the address instead (`Q_ssh_alias`).

## The script (draft, never run)

It lives in a new `dev/` folder: `dev/test-vms.sh` with `up` and `down` subcommands. It is
idempotent, so `up` skips a VM that is already defined. It is bash, like
`design/verify_design_tripwires.sh`.

```bash
#!/usr/bin/env bash
# Creates / destroys the nested vt-* VMs virtui is developed against.
# See design/ideas/nested-vm-dev-env.md. Touches nothing outside the vt- prefix.
set -euo pipefail
export LIBVIRT_DEFAULT_URI=qemu:///system

POOL=default
RELEASE=resolute
BASE=vt-base-${RELEASE}.img
IMG_URL=https://cloud-images.ubuntu.com/${RELEASE}/current
IMG_FILE=${RELEASE}-server-cloudimg-amd64.img
KEYRING=/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg
SHARE=$HOME/vt-share

pool_path() { virsh -q pool-dumpxml "$POOL" | sed -n 's:.*<path>\(.*\)</path>.*:\1:p'; }
defined()   { virsh -q dominfo "$1" >/dev/null 2>&1; }

fetch_base() {
  virsh -q vol-info "$BASE" --pool "$POOL" >/dev/null 2>&1 && return
  read -rp "Download ${IMG_URL}/${IMG_FILE} (~600 MB)? [y/N] " ok
  [[ $ok == y ]] || exit 1
  local tmp; tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/SHA256SUMS"     "$IMG_URL/SHA256SUMS"
  curl -fsSL -o "$tmp/SHA256SUMS.gpg" "$IMG_URL/SHA256SUMS.gpg"
  gpgv --keyring "$KEYRING" "$tmp/SHA256SUMS.gpg" "$tmp/SHA256SUMS"
  curl -fL   -o "$tmp/$IMG_FILE"      "$IMG_URL/$IMG_FILE"
  (cd "$tmp" && grep " \*\?$IMG_FILE\$" SHA256SUMS | sha256sum -c -)
  virsh -q vol-create-as "$POOL" "$BASE" 0 --format qcow2
  virsh -q vol-upload "$BASE" "$tmp/$IMG_FILE" --pool "$POOL"
  rm -rf "$tmp"
}

user_data() {
  cat <<EOF
#cloud-config
hostname: vt-ubuntu
users:
  - name: dev
    plain_text_passwd: dev
    lock_passwd: false
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat "$HOME/.ssh/id_ed25519.pub")
ssh_pwauth: true
packages: [qemu-guest-agent, stress-ng]
swap: { filename: /swapfile, size: 1G }
runcmd:
  - [systemctl, enable, --now, qemu-guest-agent]
EOF
}

up_ubuntu() {
  defined vt-ubuntu && return
  mkdir -p "$SHARE"
  virsh -q vol-create-as "$POOL" vt-ubuntu.qcow2 12G --format qcow2 \
        --backing-vol "$BASE" --backing-vol-format qcow2
  virsh -q vol-create-as "$POOL" vt-shared.raw 1G --format raw
  local ud; ud=$(mktemp); user_data > "$ud"
  virt-install --name vt-ubuntu --osinfo ubuntu24.04 \
    --memory memory=4096,currentMemory=1024 --vcpus 2 \
    --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=yes \
    --tpm emulator,model=tpm-crb,version=2.0 \
    --memorybacking source.type=memfd,access.mode=shared \
    --filesystem "$SHARE",share,driver.type=virtiofs \
    --disk vol=$POOL/vt-ubuntu.qcow2,bus=virtio \
    --disk vol=$POOL/vt-shared.raw,bus=virtio,shareable=on,cache=none \
    --disk device=cdrom,bus=sata \
    --memballoon virtio,freePageReporting=on \
    --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
    --network network=default,model=virtio \
    --graphics spice --import --noautoconsole \
    --cloud-init user-data="$ud"
  rm -f "$ud"
}

up_bios() {
  defined vt-bios && return
  virsh -q vol-create-as "$POOL" vt-bios.qcow2 64M --format qcow2
  virt-install --name vt-bios --osinfo detect=off,require=off \
    --memory 256 --vcpus 1 --boot hd \
    --disk vol=$POOL/vt-bios.qcow2,bus=sata \
    --network network=default --graphics vnc --import --noautoconsole
}

down() {
  for d in vt-ubuntu vt-bios; do
    defined "$d" || continue
    virsh -q destroy "$d" 2>/dev/null || true
    virsh -q undefine "$d" --nvram --tpm --remove-all-storage
  done
  virsh -q vol-delete vt-shared.raw --pool "$POOL" 2>/dev/null || true
}

case ${1:-} in
  up)   virsh -q net-start default 2>/dev/null || true; fetch_base; up_ubuntu; up_bios
        echo "vt-ubuntu: ssh dev@\$(virsh -q domifaddr vt-ubuntu --source lease | awk '{print \$4}' | cut -d/ -f1)" ;;
  down) down ;;
  *)    echo "usage: $0 up|down" >&2; exit 2 ;;
esac
```

Things in it most likely to be wrong on the first run, all virt-install flag spellings: the
`--boot uefi,firmware.feature…` syntax, `currentMemory=` as a `--memory` sub-option,
`--memballoon freePageReporting=`, and whether `--remove-all-storage` deletes the shared raw
volume too. Each one fails loudly, so the first run is the check. The base image is kept on
`down`; deleting it is a manual `virsh vol-delete`.

## Open questions

- `Q_desktop`: is a GUI guest ever needed, for example to see the `v` viewer show something
  graphical? If so, a third VM `vt-desktop` from the desktop ISO's autoinstall, created only on
  request (`up desktop`). It needs 4 GiB+ for the install, which the outer balloon can now absorb.
  What remains against it is the 6 GB download and a 15–30 min nested install.
- `Q_outer_ceiling`: is 16 GiB enough for this box, or worth raising to 32 GiB? With
  `vt-ubuntu` at 4 GiB, `vt-bios` at 256 MiB and the box's own ~1.5 GiB, 16 GiB is plenty. 32
  only matters if `Q_desktop` happens, or if a test wants several stressed guests at once to see
  the controller under contention.
- `Q_default_uri`: should virtui pass `-c qemu:///system` itself, as the `v` key's `virt-manager`
  call already does, rather than rely on the user's `uri_default`? That is a product question
  this setup brings up but does not answer. The virt-manager line suggests the system instance is
  the assumption anyway.
- `Q_osinfo`: does this box's osinfo-db know `ubuntu26.04` yet? `virt-install --osinfo list | grep
  ubuntu26`. Use it if so, because it also gives a real `http://ubuntu.com/ubuntu/26.04` id.
- `Q_backing_chain`: with an overlay, `domstats` may report the backing file as an extra
  `block.N` entry. Does `Virsh#parse_disk_data` or the qcow2 `df` lookup double-count it? That is
  a bug to find with the first real tick, and a reason in favour of the overlay.
- `Q_ssh_alias`: add an `~/.ssh/config` `Host vt-ubuntu` block that the script keeps updated, or
  print the address and stop there? I lean towards printing it.
- `Q_claude_power`: once Claude has a working `virsh`, should AGENTS.md say outright that Claude
  may start, stop and `setmem` the `vt-*` domains without asking, and nothing else? That is a
  durable authorization, so it is yours to grant.

## Where the nuggets land when this graduates

- The script itself at `dev/test-vms.sh`, its header comment saying what it creates.
- AGENTS.md *Commands*: `dev/test-vms.sh up|down`, plus the rule that the `vt-*` domains are
  the only ones a session touches.
- README install section: the `uri_default` line, if `Q_default_uri` keeps it the user's job.
- Every *To check on a real host* list in the other ideas gets worked off against `vt-*`, and the
  facts land in `design/research.md` as **[verified]** with the date.
