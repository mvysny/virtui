# Guest OS detection, wave 2: show it, and corroborate the declaration

**Status:** wave 1 shipped (2026-08-23) — `{Virt::GuestOS}` classifies what a
domain's definition *declares*, and that gates the `/proc/meminfo` swap read. The
argument, the measurements and the roads not taken are in **DECISIONS.md
D-guest-os-from-xml**; this note is only what wave 1 deliberately left out.

Nothing here is decided.

## Wave 2's shopping list

- **The agent as a corroborating second source.** `guest-get-osinfo` (`qemu-ga`
  >= 2.10) when the agent is up: it observes what is *actually* booted, so it
  outranks the declaration and fixes both of wave 1's accepted costs at once — the
  stale declaration (a definition made `--os-variant win10`, then used to install
  Linux) and the `:unknown` guest that now gets no swap level at all. Findings
  from the wave-1 brainstorm that stay valid *as agent findings*:
  - use the raw RPC, not `virsh guestinfo --os`: the latter has no `--timeout`,
    and `--timeout 2` is what keeps a wedged `qemu-ga` from becoming a
    `{Virt::VirshSession}` read timeout that kills and respawns the child;
  - reuse `{Virt::GuestAgent::TIMEOUT_SECONDS}` rather than adding a knob;
  - never ERROR on a failure a *booting* guest produces — that is the
    D-guest-agent-backoff population, and at a 2s poll it is ~15 lines per VM
    start;
  - a `nil` answer must not gate anything: absence of an observation is not
    evidence against the declaration;
  - the one real trap — on a pre-2.10 agent `guest-get-osinfo` is refused while
    `guest-file-*` works fine, so corroboration must not cost such a guest its
    swap level.
- **The full family list.** osinfo-db has OS/2, DOS, macOS, Solaris, Haiku;
  `{Virt::GuestOS::VENDORS}` just grows rows. Wave 1 stopped at the three families
  that change behaviour.
- **Shown in the VM list.** This is where the XML source pays off twice: it works
  with the VM shut off, so there is no blank cell on a stopped VM. Read
  `cache.guest_os` — already populated for every domain, running or not. Do **not**
  call `{Virt::Virsh#guest_os}` from the render path (CLAUDE.md § *Threading*).
  - Open: what to render for `:unknown`. Blank is honest; "Linux" would be a lie,
    since `:unknown` is exactly the guest nobody classified.
- **The SWAP row for a known non-Linux guest.** It currently shows the rate half
  with an empty level. Knowing the family, it could say *why* the level is missing
  instead of showing `-`.
- **A heuristic tier — probably never.** `<clock offset='localtime'>` and the
  `<hyperv>` enlightenment block are what virt-manager writes for a Windows guest
  specifically, so a metadata-less guest could still be guessed at. 4/4 VMs on the
  measured host carry real metadata, so there is nothing to fix; revisit only if a
  real host turns up where `:unknown` dominates.

## To check on a real host

1. **The exact `guest-file-open` error text for a missing path.** Wave 1 added
   `no such file or directory` to `{Virt::GuestAgent::EXPECTED_FAILURES}` on
   expectation, not measurement — no Windows guest with `qemu-guest-agent` was
   within reach. A miss costs one `warn` per boot of such a guest. Booting `win11`
   with the agent installed settles this and item 2 together.
2. `virsh domstats --balloon <a-windows-vm>`: does the virtio-win balloon driver
   populate `balloon.swap_in` / `swap_out`? If it does, the SWAP row's *rate* half
   already works on Windows and only the level is Linux-only — which decides
   whether that row should say "no level" or "not applicable".
3. A FreeBSD osinfo id (`freebsd.org/freebsd/...` expected). From osinfo-db's
   scheme, not measured; a wrong host string degrades to `:unknown`.
