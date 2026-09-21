# VM IP address: the bridged guest, still unchecked

**Status:** the address shipped 2026-09-21. `Virt::Virsh#ip_address` reads `lease`, then `arp`,
and `UI::VMPane#header` shows it; the recorded `virsh domifaddr` facts are in `R_virsh_domifaddr`.
It was built and tested against one NAT guest (`Flow` on `default`) only. What is left is
checking the arp path on a real host, and fixing anything that turns up.

## To check on a real host

1. **A bridged guest** (not on `default`): `lease` should come back empty and `arp` should find
   it. Also check whether `arp` is still empty right after boot, before the host has exchanged a
   packet with it.
2. **An empty `lease` table**, e.g. a guest just started or one on a bridge: confirm it prints
   the header and rule with no rows, and no `error:`. `R_virsh_domifaddr` marks this
   *[unverified]*, and `ip_address`'s fallback depends on it: an `error:` there would raise and
   take the whole poll down. The spec's "no row" fixture is synthesised from the header; record
   the real one into `spec/virt/`.
3. **A shut-off domain**: `virsh domifaddr <off-vm> --source lease`. It's probably an error, and
   virtui won't ask, but record what it says.

```fish
for d in (virsh list --all --name); echo "== $d"; for s in lease arp; echo "-- $s"; virsh domifaddr $d --source $s; end; end
```

Graduate by recording the outcomes in `R_virsh_domifaddr` (flip *[unverified]*), replacing the
synthesised fixture, then deleting this file.
