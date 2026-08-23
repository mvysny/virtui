# Guest OS detection, wave 3: corroborate the declaration with the agent

**Status:** waves 1 and 2 shipped (2026-08-23). Wave 1: `{Virt::GuestOS}`
classifies what a domain's definition *declares*, gating the `/proc/meminfo` swap
read. Wave 2: the family list is now the complete osinfo-db extraction (76 keys,
12 families) and every family draws a marker in the VM list. The arguments and
the roads not taken are in **DECISIONS.md D-guest-os-from-xml** and
**D-guest-os-glyph**.

Nothing below is decided. The live topic is the agent as a *second* source —
everything the declaration cannot fix (a stale `--os-variant`, a guest that
declares nothing) needs an observation of what is actually booted.

## What is still open

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
3. ~~A FreeBSD osinfo id.~~ Settled by wave 2 without a host: every key now comes
   from osinfo-db's own `<os id>` elements, so `freebsd.org/freebsd` is measured,
   not guessed. (Three wave-1 guesses were not so lucky — see D-guest-os-from-xml.)

## What wave 2 did *not* verify, and can't be

Ten of the twelve markers have never rendered on a real host, because the author
has no macOS/Haiku/DOS/NetWare/BSD guest and is not going to install one to check
a mascot. The layout-breaking half is covered by specs (every glyph's width is
measured; every family is reachable from a real osinfo id). What is *not* covered
is whether a given terminal font actually has 🐡 or 💾 — a missing glyph draws
tofu at one cell and shifts that row's name a column. If that ever shows up, the
fix is a padded two-cell ASCII string in that one
`{UI::VMWindow::GUEST_OS_GLYPHS}` row; nothing else changes.
