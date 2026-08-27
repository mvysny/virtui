# Guest OS detection, wave 3: don't ask the agent — let the read be the probe

**Status:** waves 1 and 2 shipped (2026-08-23); their arguments, roads not taken
and caveats live in **DECISIONS.md D_guest_os_from_xml** and
**D_guest_os_glyph**. Wave 3 is *decided but unimplemented* (2026-08-27): the
agent is **not** getting `guest-get-osinfo`, and the gate widens by one `&&`
instead. Nothing here has been written to DECISIONS.md yet — see *Graduation*.

## What killed the corroborating-agent plan

D_guest_os_from_xml's *Consequences* called `guest-get-osinfo` "the right
*second* source". Counting the consumers is what reversed that. `Virt::GuestOS`
feeds exactly two places and nothing else:

| consumer | what a wrong answer costs |
|---|---|
| `Virt::Cache#update`'s gate on the swap read (`cache.rb:244`) | a missing swap gauge, or doomed agent RPCs |
| `UI::VMWindow`'s per-row glyph (`vm_window.rb:379`, D_guest_os_glyph) | the wrong flag emoji on one row |

The glyph is chrome — nowhere near worth an RPC per domain plus new machinery.
And the gate doesn't need a classification *at all*, because **the read is its
own test**: `guest-file-open /proc/meminfo` succeeding or failing observes
exactly the capability the gate is trying to predict, and it already happens.

The bills `guest-get-osinfo` would have run up, kept here because they are the
argument against re-proposing it:

- **a second classifier vocabulary.** The reply is a `GuestOSInfo` struct
  carrying the guest's `/etc/os-release` `id` (`fedora`, `ubuntu`) and
  `mswindows` on Windows — *not* an osinfo-db URL. `GuestOS::VENDORS` cannot
  consume it, so a second table has to be built and kept honest beside the
  first, with its own notion of *complete* and its own way of drifting.
  (Unverified: the exact field names, and that Windows reports `mswindows`.)
- **its own failure bookkeeping.** A pre-2.10 `qemu-ga` refuses
  `guest-get-osinfo` while `guest-file-*` works fine, so sharing
  D_guest_agent_backoff's strike count would cost such a guest the very swap
  level detection was meant to protect. Plus its own answer to what log level a
  guest that cannot answer *yet* deserves — at a 2s poll that is ~15 lines per
  VM start.
- **a sticky-observation question.** An observation must never be demoted by a
  later `nil` (shut-off VM, agent gone), so it has to persist per domain — and
  then decide whether it survives a shutdown, a reinstall, an edited definition.
- Against all that: a correct flag emoji, plus the `:unknown` Linux guest that
  the one-line change below fixes for free.

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
- `GuestAgent::EXPECTED_FAILURES`'s comment (`guest_agent.rb:66-69`) already
  describes the guest that declared nothing "so `GuestOS` could not spare it
  this read" — a path `!linux?` had made **unreachable**. This change is what
  reaches it, so that clause stops being wrong. (One of the two comments is
  stale today either way.)
- `README.md` prerequisite 2 (line 123) tells the user the swap level needs the
  domain to declare its OS. After this the level needs only
  `qemu-guest-agent`; the declaration is what the *glyph* needs.

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
an observed source could recover that, and that is the source being declined.
Fix is to correct the definition.

## Also considered

- *Probe `/proc/meminfo` once, feed the result back to the glyph.* Fixes the
  stale-declaration glyph with no new RPC — the observation is free, already
  being made. Rejected: makes the glyph two-sourced (declared vs observed) for a
  cosmetic gain, and drags in the sticky-observation question above, which was
  most of what made the agent route expensive.
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

On implementing the one-liner, write a new DECISIONS.md entry — *"a guest that
declares no OS is asked for `/proc/meminfo` rather than classified first, and
`guest-get-osinfo` is not added"*, slug suggestion **read-is-the-probe** —
carrying the consumer table, the four bills, and the two *Also considered*
bullets. (Written without the `D_` prefix on purpose: CLAUDE.md's grep tripwire
treats every `D_`-prefixed token in the repo as a citation that must already have
a heading, and this one does not yet.) Then amend the guest-OS-from-XML entry:
its "declares no OS → no swap level" consequence is
reversed, its "both of those are what the agent would fix" consequence is now
"the agent is not the fix", and its `windows? || freebsd?` rejection keeps its
own form rejected while noting the `:unknown` fall-through arrived by another
route. Cut everything above *The SWAP row* from this note at that point; the
last two sections keep it alive.
