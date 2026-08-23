# Detect the guest OS, so a Windows guest stops looking like a broken Linux one

**Status:** proposed, nothing built (2026-08-23). Brainstormed down to a shape;
two forks still open (§ *Open questions*), and one assumption nobody here can
verify (§ *The Windows rule is an assumption*).

The trigger: `{Virt::GuestAgent}` reads `/proc/meminfo`, so the swap *level* is
Linux-only, and virtui has no idea which of its guests are Linux. Two costs,
one of which arrived with D-guest-agent-backoff:

1. **A Windows guest now emits a `warn`.** `guest-file-open` on a path that does
   not exist comes back as a `GenericError` — expected shape `failed to open file
   '/proc/meminfo': No such file or directory` — and that matches none of the four
   phrases in `{Virt::GuestAgent::EXPECTED_FAILURES}`. So the channel built for
   "your agent is misconfigured" fires once per Windows VM per boot, for a guest
   that is merely not Linux.
2. **Three doomed RPCs per tick**, until the write-off bounds it to one probe a
   minute. Small, but it is pure waste and it never stops.

Plus the thing that might actually be worth having: virtui could *show* the OS.

## The mechanism

`guest-get-osinfo`, in `qemu-ga` since 2.10 (2017). Real output from the author's
Ubuntu guest, through libvirt's wrapper:

```
mavi@mavi-fw ~> virsh guestinfo Flow --os
os.id               : ubuntu
os.name             : Ubuntu
os.pretty-name      : Ubuntu 26.04 LTS
os.version          : 26.04 LTS (Resolute Raccoon)
os.version-id       : 26.04
os.machine          : x86_64
os.kernel-release   : 7.0.0-30-generic
os.kernel-version   : #30-Ubuntu SMP PREEMPT_DYNAMIC Fri Jul 31 18:22:54 UTC 2026
```

**Use the raw RPC, not `guestinfo`.** `virsh guestinfo` is prettier — key=value
text in exactly the shape `{Virt::Virsh}` already parses — but look at its
synopsis: `[--user] [--os] [--timezone] [--hostname] [--filesystem] [--disk]
[--interface] [--load]`. No `--timeout`. The whole safety story for agent calls is
`--timeout 2` bounding a wedged guest and staying under
`{Virt::VirshSession::READ_TIMEOUT_SECONDS}`, so a wedged `qemu-ga` surfaces as a
virsh error instead of a read timeout that kills and respawns the session child.
`guestinfo` gives that up.

```
virsh qemu-agent-command <dom> '{"execute":"guest-get-osinfo"}' --timeout 2
```

One RPC (against three for the meminfo read), reuses `GuestAgent#agent_command`
unchanged, returns the same fields as a JSON hash — same keys, minus the `os.`
prefix. No new parser, no new door into the guest: `guest-get-osinfo` is a read of
a fact, not `guest-exec` (see D-guest-swap-level for why that door stays shut).

## "Once per domain" really means "once *successfully*"

The author's framing was: ask once when virtui learns about a domain — at startup
for the existing fleet, and on creation for a VM defined later — since the OS does
not change under us. Right instinct, but the moment virtui learns about a domain
is the worst moment to ask:

- the VM may be **shut off** → no agent → no answer;
- it may be **running but booting** → agent not up for another 20–40s → no answer.

A literal once-per-domain read answers `nil` for exactly the guests we care about
and never tries again. So: **memoize the answer, keep asking until there is one**,
and let the existing strike/backoff machinery bound the asking — otherwise an
agentless guest gets an extra RPC every tick forever.

Which settles *where the memo lives*: in `{Virt::GuestAgent}` beside `@failures` /
`@retry_at`, not on a "new domain" edge in `{Virt::Cache}`. The memo **is** the
"have we learned it yet" state, so there is no edge to detect, and `Cache#update`
does not change at all.

One ordering rule: `#swap` detects first and, if detection fails, returns `nil`
**without** attempting the meminfo read — so a booting guest burns one strike per
tick, not two.

## The OS can only be a *negative* gate

The author's rule — case-insensitive `windows` anywhere in `os.id` / `os.name` /
`os.pretty-name` — is fine as far as it goes (see below). What it cannot be is the
thing that decides we *can* read the file. Two cases:

- **Non-Linux, non-Windows.** `qemu-ga` builds on FreeBSD (`id: "freebsd"`), which
  has no `/proc/meminfo` by default. A Windows-only test sends it down the Linux
  path to fail forever, warn included.
- **RHEL / Fedora.** Detection cheerfully reports Linux — and the read still
  fails, because `guest-file-*` sits in the agent's `BLOCK_RPCS` there.
  `guest-get-osinfo` is *not* in that list, so this is the case where we know the
  OS perfectly and still get nothing.

So: known-not-Linux → skip the read entirely; everything else → try it and let the
write-off sort it out. Which means the *log* fix is separate and still needed —
**add the missing-file phrase to `EXPECTED_FAILURES`** so a FreeBSD guest, or one
we mis-classify, stays out of `warn`. The Windows skip is then an optimization
(0 RPCs/tick rather than one probe a minute), not the thing keeping the log honest.

## The Windows rule is an assumption

Neither the author nor Claude has a Windows guest to sample. What `qemu-ga` is
documented to report:

```
os.id          : mswindows
os.name        : Microsoft Windows
os.pretty-name : Microsoft Windows Server 2019
os.variant     : server          # or "client"; Windows-only field
```

All three of the tested fields carry the substring, so the rule holds *if the docs
are right*. Agreed to ship on that assumption — but whatever carries the test must
say in its yardoc that it is unverified, and the spec fixture for it must be
labelled hand-built rather than captured. The Ubuntu fixture should be a real
capture of the **raw JSON reply**, not the `guestinfo` text above.

## Memo lifetime vs `#forget`

`Cache#update` calls `{Virt::GuestAgent#forget}` for every VM that is not running.
Fork: does that drop the OS memo too?

- **Drop it** — simple ("forget everything about this domain"), correct if someone
  reinstalls a guest into a different OS, costs one RPC per boot.
- **Keep it** — the OS is a *fact* about the guest, not failure state; a Windows
  guest then costs **zero** agent calls per tick for the rest of the process.

Leaning: keep it, i.e. `forget` stays about failures only. The documented limit is
"reinstall a guest into a different OS and virtui needs a restart", which beats a
`forget_os` hook for a case that rare — unless a hook is wanted anyway.

## Cost

| | today | after |
|---|---|---|
| Linux guest, agent up | 3 RPCs/tick | 3 RPCs/tick, + 1 once |
| Windows guest | 3 RPCs/tick → 1 probe/min, 1 `warn`/boot | 1 RPC once, then nothing |
| RHEL blocked-RPC guest | 1 probe/min | unchanged (+1 once) |
| agentless guest | 1 probe/min | unchanged |

First tick after startup gains one round-trip per VM, serialized through the one
session. The write-off bounds the pathological case as before.

## Open questions

1. **UI or internal-only?** The one that changes the scope.
   - *Internal* — the OS only gates the read; `Virt::GuestOs` stays a two-field
     value object nobody renders.
   - *Shown in the VM list* — then note that agent-only detection leaves **stopped
     VMs blank**, since virtui never asks a VM that is not running. Filling those
     needs the libosinfo metadata in `virsh dumpxml`
     (`<libosinfo:os id="http://microsoft.com/win/10"/>`, present for anything
     created by virt-manager or `virt-install --os-variant`) — a second source,
     static, works with the VM off, but it records what the *creator declared* and
     is absent for hand-written XML. Worth it only if a blank OS cell on every
     shut-off VM would read as broken.
   - Related: a Windows guest's SWAP row currently shows the rate half with an
     empty level. Knowing the OS, it could say so instead — but that is UI work
     that only makes sense under "shown".
2. **`forget_os` hook or documented limit?** (§ *Memo lifetime*.)
3. **Naming.** `Virt::GuestOs` needs no Zeitwerk inflection; `Virt::GuestOS` reads
   better and costs one `inflector.inflect` line in `lib/virtui.rb`.

## To check on a real host

- The exact `guest-file-open` error text for a missing path — the phrase that goes
  into `EXPECTED_FAILURES` depends on it (`No such file or directory` is the
  expectation, unverified).
- A real Windows `guest-get-osinfo` reply, whenever one is within reach.
- `virsh domstats --balloon <a-windows-vm>`: does the virtio-win balloon driver
  populate `balloon.swap_in` / `swap_out`? If it does, the SWAP row's *rate* half
  already works on Windows today and only the level is Linux-only. Unknown, and it
  decides whether a Windows guest's row should say "no level" or "not applicable".

## Where the pieces land when this graduates

- the mechanism + the contract (one RPC, memoized, `--timeout 2`) → yardoc on the
  new class/method;
- why the raw RPC over `virsh guestinfo`, and why the OS is a negative gate only →
  a new `DECISIONS.md` entry (pick the slug when writing it — don't cite one from
  here, the grep tripwire wants every cited `D-` slug to exist), with the FreeBSD
  and RHEL-blocked-RPC cases as the argument;
- the `EXPECTED_FAILURES` addition → amends D-guest-agent-backoff, which already
  owns that list's rationale;
- the new class → `CLAUDE.md`'s class index, one line;
- nothing user-facing unless the UI fork goes that way — then README gains a line
  about what the OS column needs (`qemu-guest-agent`, again).
