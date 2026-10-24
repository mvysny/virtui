# VM IP address: the bridged guest, still unchecked

**Status:** the address shipped 2026-09-21. `Virt::Virsh#ip_address` reads `lease`, then `arp`,
and `UI::VMPane#header` shows it; the recorded `virsh domifaddr` facts are in `R_virsh_domifaddr`.
It was built and tested against one NAT guest (`Flow` on `default`) only. What is left is
checking the arp path on a real host, and fixing anything that turns up.

## To check on a real host

1. **A bridged guest** (not on `default`): `lease` should come back empty and `arp` should find
   it. Also check whether `arp` is still empty right after boot, before the host has exchanged a
   packet with it.
2. ~~An empty `lease` table~~. Done 2026-10-24 on `vt-bios`: it prints nothing and exits 0, so
   the spec's assumed empty-string fixture is the real output and stays. Recorded in
   `R_virsh_domifaddr`.
3. ~~A shut-off domain~~. Done 2026-10-24: it is an `error:` with exit 1. Recorded in
   `R_virsh_domifaddr`.

Item 1 is still open, because this dev box has no bridge. The `vt-*` VMs sit on libvirt's
`default` NAT network, where `lease` always answers first.

```fish
for d in (virsh list --all --name); echo "== $d"; for s in lease arp; echo "-- $s"; virsh -q domifaddr $d --source $s; end; end
```

Graduate by recording the outcomes in `R_virsh_domifaddr` (flip *[unverified]*), replacing the
synthesised fixture, then deleting this file.
