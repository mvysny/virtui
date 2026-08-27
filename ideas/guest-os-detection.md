# Guest OS detection, wave 3: corroborate the declaration with the agent

**Status:** waves 1 and 2 shipped (2026-08-23). The arguments, the roads not
taken, and every caveat this note used to restate about them now live in
**DECISIONS.md D_guest_os_from_xml** and **D_guest_os_glyph**. Nothing below is
decided.

## The agent as a corroborating second source

`guest-get-osinfo` (`qemu-ga` >= 2.10) observes what is *actually* booted, so it
outranks the declaration and fixes both of D_guest_os_from_xml's accepted costs
at once: the stale `--os-variant`, and the `:unknown` guest that now gets no swap
level at all. That entry's *guest-get-osinfo* rejected-alternative bullet says
why it can never be the **only** source and lists the questions it drags in;
what it does not carry are the design constraints for building it as a second
one, held here until there is code to hang them on:

- use the raw RPC, not `virsh guestinfo --os` (D_guest_os_from_xml says why),
  and reuse `{Virt::GuestAgent::TIMEOUT_SECONDS}` rather than adding a knob;
- never ERROR on a failure a *booting* guest produces — that is the
  D_guest_agent_backoff population, and at a 2s poll it is ~15 lines per VM start;
- a `nil` answer must not gate anything: absence of an observation is not
  evidence against the declaration;
- the one real trap — on a pre-2.10 agent `guest-get-osinfo` is refused while
  `guest-file-*` works fine, so corroboration must not cost such a guest its
  swap level.

## The SWAP row for a known non-Linux guest

It currently shows the rate half with an empty level. Knowing the family, it
could say *why* the level is missing instead of showing `-`. Which wording is
right depends on check 1 below.

## To check on a real host

1. `virsh domstats --balloon <a-windows-vm>`: does the virtio-win balloon driver
   populate `balloon.swap_in` / `swap_out`? If it does, the SWAP row's *rate*
   half already works on Windows and only the level is Linux-only — which decides
   whether that row should say "no level" or "not applicable".
2. **The exact `guest-file-open` error text for a missing path.**
   `no such file or directory` is in `{Virt::GuestAgent::EXPECTED_FAILURES}` on
   expectation, not measurement — no Windows guest with `qemu-guest-agent` was
   within reach. Booting `win11` with the agent installed settles this and item 1
   together.
