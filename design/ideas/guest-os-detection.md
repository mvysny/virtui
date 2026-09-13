# Guest OS detection, wave 3: let `:unknown` fall through to the read

**Status:** waves 1 and 2 shipped (2026-08-23); their arguments, roads not taken and caveats
live in **design/decisions.md D_guest_os_from_xml** and the yardoc of
`UI::VMPane::GUEST_OS_GLYPHS`. Wave 3 was decided (2026-08-27) and is still unimplemented; its
*"don't add `guest-get-osinfo`, not even as a second source"* half graduated into
D_guest_os_from_xml on 2026-09-13. What is left here is the one-liner, the SWAP row wording,
and two things to check on a real host.

## The change to make

Split the two meanings `GuestOS#no_proc_meminfo?` conflates today — *known to
lack `/proc/meminfo`* vs *no idea*:

```ruby
def no_proc_meminfo? = !linux? && family != :unknown
```

`:linux` asked, every other **known** family skipped, `:unknown` asked — absence
of a declaration is not a claim about the guest. Call site unchanged.

This recovers the first of D_guest_os_from_xml's two accepted costs (the
undeclared Linux guest gets its swap gauge back) and pays in doomed RPCs on a
guest that declares nothing and is not Linux — already bounded: three strikes
then one probe a minute (D_guest_agent_backoff), and `guest agent is not
responding` (the *common* `:unknown` case, a VM with no agent) is already in
`EXPECTED_FAILURES`, so it stays at `debug`.

Not to be confused with the `windows? || freebsd?` gate D_guest_os_from_xml
rejected: that one needed editing once per family added to `FAMILIES`;
`family != :unknown` is closed under new families by construction.

### Doc sweep the change drags along

- `GuestOS#no_proc_meminfo?`'s yardoc — it currently argues *for* `!linux?` and
  for `:unknown` being skipped. New meaning: *the declaration positively says
  asking is pointless*; `:unknown` answers `false`. Without that, the next
  reader re-derives `!linux?` as an obvious simplification.
- `GuestAgent::EXPECTED_FAILURES`'s comment already describes the guest that
  declared nothing "so `GuestOS` could not spare it this read" — a path `!linux?`
  had made **unreachable**. This change is what reaches it, so that clause stops
  being wrong. (One of the two comments is stale today either way.)
- `README.md` prerequisite 2 tells the user the swap level needs the domain to
  declare its OS. After this the level needs only `qemu-guest-agent`; the
  declaration is what the *glyph* needs.

### The risk it creates

`'no such file or directory'` in `EXPECTED_FAILURES` is an expectation, not a
measurement (check 2 below). Under `!linux?` nothing reachable produced it;
under the new gate an `:unknown`-but-not-Linux guest **with a working agent**
produces it once a minute. A wrong phrase costs one `warn` a minute for that
guest. Rare intersection — agent installed, no libosinfo metadata — but no
longer theoretical.

### What stays broken, on purpose

The **stale declaration**: `--os-variant win10` then used to install Linux still
skips a read that would work, because it declares a known non-Linux family. Only
an observed source could recover that, and that is the source D_guest_os_from_xml
declines.

## Also considered

- *Drop the gate entirely, ask every running guest.* Less code, and it throws
  away what the declaration is genuinely good at: a virt-manager Windows guest
  with `virtio-win` has a *working* agent and no `/proc/meminfo`, so it would pay
  three doomed RPCs a minute forever on a question the declaration answers. Keep
  the cheap veto; widen only the don't-know case.

## The SWAP row for a known non-Linux guest

Independent of everything above. It currently shows the rate half with an empty
level. Knowing the family, it could say *why* the level is missing instead of
showing `-`. Which wording is right depends on check 1.

## To check on a real host

1. `virsh domstats --balloon <a-windows-vm>`: does the virtio-win balloon driver
   populate `balloon.swap_in` / `swap_out`? If it does, the SWAP row's *rate*
   half already works on Windows and only the level is Linux-only — which decides
   whether that row should say "no level" or "not applicable".
2. **The exact `guest-file-open` error text for a missing path.**
   `no such file or directory` is in `GuestAgent::EXPECTED_FAILURES` on
   expectation, not measurement — no Windows guest with `qemu-guest-agent` was
   within reach. Booting `win11` with the agent installed settles this and item 1
   together. Now load-bearing, per *The risk it creates*.

## Graduation

On implementing the one-liner, rewrite D_guest_os_from_xml rather than add an entry — it
already carries *the read is its own test*, and three of its sentences are what the change
moves: the `no_proc_meminfo?` is the plain `!linux?` clause, the `windows? || freebsd?`
rejection (its own form stays rejected; note that the `:unknown` fall-through arrived by
another route), and the "declares no OS → no swap level" consequence, which reverses. Carry
the risk above into that entry as its new cost. Then cut everything above *The SWAP row* from
this note; the last two sections keep it alive.
