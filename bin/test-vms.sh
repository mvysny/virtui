#!/usr/bin/env bash
# Creates / destroys the nested vt-* VMs virtui is developed against, on qemu:///system:
#   vt-ubuntu  Ubuntu 26.04 cloud image, UEFI + Secure Boot, TPM 2.0, virtiofs share ~/vt-share,
#              a shareable raw disk, a CD-ROM holding the cloud-init seed,
#              a free-page-reporting balloon (1 of 4 GiB),
#              qemu-guest-agent, stress-ng, `memramp` (a repeatable memory load), a swap file;
#              user dev / password dev plus your key.
#   vt-bios    legacy BIOS, no OS, no agent; sits at "No bootable device".
# The base image is downloaded once into the default pool and kept on `down`.
# Touches nothing outside the vt- prefix.
set -euo pipefail
export LIBVIRT_DEFAULT_URI=qemu:///system

POOL=default
RELEASE=resolute
BASE=vt-base-${RELEASE}.img
IMG_URL=https://cloud-images.ubuntu.com/${RELEASE}/current
IMG_FILE=${RELEASE}-server-cloudimg-amd64.img
KEYRING=/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg
SHARE=$HOME/vt-share

defined() { virsh -q dominfo "$1" >/dev/null 2>&1; }
lease()   { virsh -q domifaddr vt-ubuntu --source lease 2>/dev/null | awk '{print $4}' | cut -d/ -f1; }

# A fresh libvirt has no pool until virt-manager's first launch makes one.
ensure_pool() {
  virsh -q pool-info "$POOL" >/dev/null 2>&1 && return
  virsh -q pool-define-as "$POOL" dir --target /var/lib/libvirt/images
  virsh -q pool-build "$POOL"
  virsh -q pool-start "$POOL"
  virsh -q pool-autostart "$POOL"
}

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
write_files:
  # A repeatable memory load. stress-ng --vm sizes itself to what is free when it starts, so on a
  # ballooned guest it never holds what it was asked for.
  - path: /usr/local/bin/memramp
    permissions: '0755'
    content: |
      #!/usr/bin/env python3
      """memramp MIB [MIB_PER_S [HOLD_S]]: touch MIB of RAM at MIB_PER_S, hold it, then exit."""
      import sys, time
      target = int(sys.argv[1])
      rate = int(sys.argv[2]) if len(sys.argv) > 2 else 200
      hold = int(sys.argv[3]) if len(sys.argv) > 3 else 60
      chunks = []
      while len(chunks) < target:
          chunks.append(bytearray(1 << 20))   # zero-filled, so every page is touched
          if len(chunks) % rate == 0:
              time.sleep(1)
      time.sleep(hold)
runcmd:
  - [systemctl, enable, --now, qemu-guest-agent]
  # The first boot has grown / to the disk already; from the next one on cloud-init leaves it,
  # so the room a disk image resize adds waits for virtui's M → Grow root filesystem.
  - [sh, -c, 'printf "growpart: {mode: \"off\"}\nresize_rootfs: false\n" > /etc/cloud/cloud.cfg.d/99-no-growpart.cfg']
EOF
}

# The NoCloud seed stays in the CD-ROM for good. virt-install's own --cloud-init attaches it for
# the first boot only, which shim's first-boot reset turns into a shutdown, so the guest comes up
# seedless (design/research.md R_uefi_cloud_image_first_boot). cloud-init runs once per
# instance-id, so a seed left in place is harmless.
make_seed() {
  local dir; dir=$(mktemp -d)
  user_data > "$dir/user-data"
  printf 'instance-id: vt-ubuntu\nlocal-hostname: vt-ubuntu\n' > "$dir/meta-data"
  xorrisofs -quiet -output "$dir/seed.iso" -volid CIDATA -joliet -rock \
            "$dir/user-data" "$dir/meta-data"
  virsh -q vol-create-as "$POOL" vt-seed.iso "$(stat -c %s "$dir/seed.iso")" --format raw
  virsh -q vol-upload vt-seed.iso "$dir/seed.iso" --pool "$POOL"
  rm -rf "$dir"
}

up_ubuntu() {
  defined vt-ubuntu && return
  mkdir -p "$SHARE"
  virsh -q vol-create-as "$POOL" vt-ubuntu.qcow2 12G --format qcow2 \
        --backing-vol "$BASE" --backing-vol-format qcow2
  virsh -q vol-create-as "$POOL" vt-shared.raw 1G --format raw
  make_seed
  # ubuntu24.04: the distro's osinfo-db has no 26.04 (design/research.md R_osinfo_db).
  virt-install --name vt-ubuntu --osinfo ubuntu24.04 \
    --memory memory=4096,currentMemory=1024 --vcpus 2 \
    --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=yes \
    --tpm emulator,model=tpm-crb,backend.version=2.0 \
    --memorybacking source.type=memfd,access.mode=shared \
    --filesystem "$SHARE",share,driver.type=virtiofs \
    --disk vol=$POOL/vt-ubuntu.qcow2,bus=virtio \
    --disk vol=$POOL/vt-shared.raw,bus=virtio,shareable=on,cache=none \
    --disk vol=$POOL/vt-seed.iso,device=cdrom,bus=sata \
    --memballoon virtio,freePageReporting=on \
    --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
    --network network=default,model=virtio \
    --graphics spice --import --noautoconsole
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
  for v in vt-shared.raw vt-seed.iso; do
    virsh -q vol-delete "$v" --pool "$POOL" 2>/dev/null || true
  done
}

case ${1:-} in
  up)   virsh -q net-start default 2>/dev/null || true; ensure_pool; fetch_base; up_ubuntu; up_bios
        for _ in {1..60}; do [[ -n $(lease) ]] && break; sleep 2; done
        echo "vt-ubuntu: ssh dev@$(lease)  (cloud-init needs another minute or two on first boot)" ;;
  down) down ;;
  *)    echo "usage: $0 up|down" >&2; exit 2 ;;
esac
