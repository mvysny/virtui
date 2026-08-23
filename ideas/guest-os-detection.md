# Detect the guest OS, so a Windows guest stops looking like a broken Linux one

**Status:** proposed, nothing built, but **measured and unblocked** (2026-08-23).
Brainstormed down to a shape, split into two waves, then pivoted from the guest
agent to the definition XML — and the host sweep confirmed the XML source works,
including on shut-off domains. Two minor unknowns left (§ *To check on a real
host*), neither blocking.

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

## Two waves

**Wave 1 — a negative gate, and nothing else.** Classify the guest from its
libvirt definition, and hang exactly one behaviour off it: **known-not-Linux →
skip the meminfo read**. No UI, no second source, no agent involvement.

**Wave 2 — the OS as data.** Showing it in the VM list, and corroborating the
declaration against the live guest. Deferred wholesale (§ *Wave 2's shopping
list*), and wave 1 must not half-build it.

## Why the XML, not the guest agent

The first draft of this note read the OS from `guest-get-osinfo` (`qemu-ga` ≥ 2.10)
— the live, truthful source. It was the wrong source, for one reason that decides
it: **`guest-get-osinfo` needs the agent up, and the Windows guest that causes
this whole problem usually has no agent.** `virtio-win` is a manual install, so an
agentless Windows guest is the *common* Windows guest — and it is precisely the one
agent-based detection can never classify. It would keep its three doomed RPCs per
tick and its write-off forever, which is the bug this was opened for.

Everything else follows from that:

| | agent (`guest-get-osinfo`) | definition XML |
|---|---|---|
| agentless guest | invisible | classified |
| guest mid-boot | 20–40s of nothing | classified at tick 1 |
| shut-off VM | invisible | classified |
| can wedge on a sick guest | yes → needs `--timeout 2` | no, local libvirtd call |
| truthful about what is *running* | **yes** | no — records what the creator *declared* |
| present for a hand-written definition | yes (if the agent is up) | **no** |

The two are complementary, not ranked: the XML wins on availability, the agent
wins on truth. Wave 1 takes availability, because the gate it feeds is an
optimisation — being wrong costs a swap gauge, not a wrong number.

**What the pivot deletes.** `{Virt::GuestAgent}` needs *no changes at all*. Gone
with it: the strike-counting question (does detection share `@failures`?), the
`backing_off?` interaction, the log-level argument (ERROR vs `debug` for a booting
guest that cannot answer yet), the "memoize but keep asking until it works" retry
loop, and the pre-2.10-agent fork where detection fails while the read succeeds.
The XML is available whenever the domain is defined, so **once per domain really is
once**, and none of that machinery has anything to bound.

## The mechanism

libosinfo metadata, written into the domain definition by virt-manager and by
`virt-install --os-variant`:

```xml
<metadata>
  <libosinfo:libosinfo xmlns:libosinfo="http://libosinfo.org/xmlns/libvirt/domain/1.0">
    <libosinfo:os id="http://microsoft.com/win/10"/>
  </libosinfo:libosinfo>
</metadata>
```

**`virsh metadata --uri` reads it directly** — measured on the author's host,
2026-08-23, over a four-VM fleet:

```
virsh metadata <dom> --uri http://libosinfo.org/xmlns/libvirt/domain/1.0
```

```
Flow     running     <libosinfo>  <os id="http://ubuntu.com/ubuntu/25.10"/>  </libosinfo>
Ayyah    shut off    <libosinfo>  <os id="http://ubuntu.com/ubuntu/25.10"/>  </libosinfo>
BASE     shut off    <libosinfo>  <os id="http://ubuntu.com/ubuntu/25.10"/>  </libosinfo>
win11    shut off    <libosinfo>  <os id="http://microsoft.com/win/11"/>     </libosinfo>
```

Four findings, all of which the design leans on:

- **It works on a shut-off domain** — three of the four were. So the source needs
  no running guest, which was the whole reason for the pivot.
- **The reply is the element alone**, so there is no XML document to parse: one
  regex over a three-line reply, the same shape as every other parser in
  `{Virt::Virsh}`. `dumpxml` + regex over a 60-line document — or a first XML
  parser in the project — is not needed.
- **The namespace prefix is stripped in the output.** It comes back as
  `<libosinfo>` / `<os id=…>`, *not* the `<libosinfo:libosinfo>` /
  `<libosinfo:os>` the stored definition holds. So the regex must not anchor on
  the prefix: `/<os id="([^"]*)"/` is the parser. (Reply is multi-line — the
  single-space rendering above is the sweep's `\s+` collapsing.)
- **4/4 VMs carry the metadata**, which is what takes the heuristic tier off
  wave 1's table (see § *Wave 2's shopping list*).

No timeout of its own, and that is the point: this is a local libvirtd read that
cannot block on a sick guest, so `{Virt::VirshSession::READ_TIMEOUT_SECONDS}` is
already the right and only backstop. Nothing new to tune.

## Classification: the vendor host of the osinfo URI

The id is a URI whose host is the vendor:

| URI | family | |
|---|---|---|
| `microsoft.com/win/11` | `:windows` | measured |
| `ubuntu.com/ubuntu/25.10` | `:linux` | measured |
| `debian.org/…`, `redhat.com/…`, `fedoraproject.org/…`, `opensuse.org/…`, `archlinux.org/…`, … | `:linux` | from osinfo-db |
| `freebsd.org/freebsd/14.0` | `:freebsd` | from osinfo-db |
| anything unrecognised, and a definition with no metadata | `:unknown` | |

The vendor host is the key — `ubuntu.com`, `microsoft.com` — not the path. That
is what makes this a table rather than the substring match over
`os.pretty-name` prose the agent draft was stuck with.

**`:unknown` is a real member, not an error.** It is what an unrecognised vendor
and a *missing* metadata element both produce, and it means "attempt the read" —
which keeps the negative-gate principle intact: only a *positive* not-Linux answer
skips anything. Enumerate the Linux vendors we know rather than treating
"not Windows" as Linux; an unrecognised vendor is then honestly unknown instead of
being mislabelled, and it costs nothing, because unknown behaves exactly like
Linux at the gate.

**FreeBSD folds in cleanly, and does gate.** FreeBSD's own `/proc` carries no
`meminfo`, and linprocfs is conventionally mounted at `/compat/linux/proc` — so
`/proc/meminfo` is absent there in practice too, and skipping loses nothing that
a plain path change would have recovered. (`microsoft.com/msdos`, `ibm.com/os2`
and friends are in osinfo-db too, but they are wave 2: nothing behaves differently
for them in wave 1, since anything not-Linux already skips.)

## Where it lives

Not on `{Virt::GuestAgent}` — this has nothing to do with the agent any more. It
is a `virsh` read plus a classification, so:

- **`Virt::GuestOS`** — a `Data.define(:family, :osinfo_id)`, plus the one
  behavioural predicate the gate reads (§ *The gate must not ask `linux?`*).
  Keeping the raw `osinfo_id` alongside the family means wave 2 (and the log
  line) can say *what* was declared, not just which bucket it fell in. Needs an
  `inflector.inflect` line in `lib/virtui.rb` for `GuestOS`; `GuestOs` would need
  none but reads worse.
- **`Virt::Virsh`** — owns the lookup and the per-domain memo, because it already
  owns both the transport and `#guest_swap`. So the gate lands exactly where the
  delegation already is:

  ```ruby
  def guest_swap(domain_name)
    return nil if guest_os(domain_name).no_proc_meminfo?
    @guest_agent&.swap(domain_name)
  end
  ```

  `Cache#update` does not change; neither does `GuestAgent`.

The memo is a plain `Hash{String => GuestOS}` — a static fact, read once, no
expiry, no `forget` interaction (`{Virt::GuestAgent#forget}` stays about failure
state and never sees this). Documented limit: edit a domain's definition while
virtui runs and it needs a restart to notice.

## The gate must not ask `linux?`

The natural reading is that the swap code asks `linux?(domain)`. It is the one
mistake in this design that testing on a well-tooled host cannot catch, so it gets
its own section.

With a four-member family, **`linux?` is not a lie** — `:unknown` answers `false`,
which is accurate: we do not know it is Linux. (The earlier agent draft *did* need
a lie, because a nullable boolean had nowhere to put "unknown"; the family symbol
removed that, so there is no wave-1 fib and no TODO to carry.) The problem is not
honesty, it is which question the gate is asking:

```ruby
return nil unless os.linux?           # WRONG — :unknown skips the read
return nil if     os.no_proc_meminfo? # right — only :windows / :freebsd skip
```

`linux?` gates on *proof of Linux*; the read needs *absence of proof against it*.
The two differ exactly on `:unknown` — which is 0/4 VMs on the author's host and
**every VM** on a host whose definitions are hand-written or built by tooling that
writes no libosinfo metadata. There, `linux?`-gating silently removes the swap
gauge from the entire fleet, and nothing local would ever show it.

So:

```ruby
# Families known to have no /proc/meminfo, so no point asking the agent for one.
WITHOUT_PROC_MEMINFO = %i[windows freebsd].freeze

# @return [Boolean] true only for a family we *know* has none; an unrecognised or
#   undeclared guest answers false, so it is still attempted.
def no_proc_meminfo? = WITHOUT_PROC_MEMINFO.include?(family)
```

`:unknown` lands on the safe side by construction, wave 2 adds OS/2 and DOS to one
constant, and the double negative is confined to the single call site above.

**`windows?` / `linux?` / `freebsd?` wait for a caller.** `family` is public, so
`os.family == :windows` already serves anyone who needs it, and nothing in wave 1
does. They are one line each the moment wave 2's UI wants them — shipping three
unused predicates now is the abstraction CLAUDE.md's *Readable, not obfuscated*
rule is aimed at. What must **not** happen is `linux?` existing with no caller and
then being reached for by the gate later, which is the whole hazard above.

## The cost of trusting a declaration

The one thing the XML is worse at, stated plainly so it is not discovered later:
it records what the *creator* declared. Two ways to be wrong —

- a definition created `--os-variant win10` and then used to install Linux;
- a guest reinstalled into a different OS under an unchanged definition.

Both make virtui skip a read that would have worked, so the symptom is a **missing
swap gauge on a VM whose XML claims Windows** — silent, where today there would be
a gauge. Discoverable (the family is in the log line, and wave 2 would show it),
rare, and the fix is wave 2's agent corroboration: when the agent *is* up it
outranks the declaration. Accepted as a wave-1 limit.

The much more common wrongness is benign: **no metadata at all** (hand-written
XML, `virsh define` of a hand-rolled file, older tooling) → `:unknown` → behave
exactly as today. Zero of the author's four VMs are in that state, which is
precisely why the `:unknown` path needs deciding on paper rather than by testing
(§ *The gate must not ask `linux?`*).

## The `EXPECTED_FAILURES` addition still ships in wave 1

One string, and detection does not make it redundant: every `:unknown` guest that
is in fact Windows still reaches `guest-file-open` on a path that isn't there, and
`:unknown` is exactly the population whose definitions carry no metadata. Add the
missing-file phrase so that stays out of `warn`. It amends D-guest-agent-backoff,
which owns that list.

Which means the log fix and the RPC saving stay **separate wins** — the Windows
skip is an optimisation, not the thing keeping the log honest. (With the agent
draft this was nearly redundant; with the XML draft it is load-bearing again,
because a metadata-less Windows guest is a normal thing to have.)

## Wave 1 cost

One `virsh metadata` per domain, once per process, serialized through the session
alongside everything else. Then:

| | today | after wave 1 |
|---|---|---|
| Linux guest, agent up | 3 RPCs/tick | unchanged (+1 virsh read once) |
| Windows guest **with** metadata | 3 RPCs/tick → 1 probe/min, 1 `warn`/boot | **nothing**, from tick 1 |
| Windows guest **without** metadata | as above | unchanged, minus the `warn` |
| FreeBSD guest with metadata | 1 probe/min | nothing |
| booting guest | 3 RPCs/tick for 3 ticks | unchanged — no boot window to wait out |
| RHEL blocked-`guest-file-*` guest | 1 probe/min | unchanged (classified `:linux`, read still blocked) |
| agentless guest, unknown OS | 1 probe/min | unchanged |

Note what is *not* in this table any more: no row gets *worse*. The agent draft
charged every booting guest an extra RPC per tick for its first three ticks, and
charged a pre-2.10 agent one per tick forever.

## Error handling

`virsh metadata` can fail two ways, and only one is interesting:

- **metadata not present** — the normal state for a hand-written definition. Not a
  failure: `:unknown`, memoized, silent (or `debug`). Depends on the exact error
  text, hence the measurement.
- **the domain is gone** — the `list`→`metadata` race, on a VM shutting down.
  Rescue, do **not** memoize (so the next tick re-asks), `debug`.

Anything else is a genuine surprise and can be loud, since unlike the agent path
there is no recurring expected-failure population to drown the log in. Whether
that is worth distinguishing in wave 1, or whether one rescue at `debug` covers
it, is a five-line decision to take with the real error strings in hand.

## Wave 2's shopping list

Explicitly not wave 1. Recorded so wave 1 does not accidentally half-build it.

- **The agent as a corroborating second source.** `guest-get-osinfo` when the
  agent is up: outranks the declaration, fixes the reinstalled-guest case, and
  classifies the metadata-less guest. This is where the whole first draft of this
  note belongs — including its findings, which stay valid as *agent* findings:
  use the raw RPC not `virsh guestinfo` (no `--timeout`), reuse
  `{Virt::GuestAgent::TIMEOUT_SECONDS}`, never ERROR on a failure a booting guest
  produces, and remember `nil` must not gate.
- **The full family list** — OS/2, DOS, macOS, Solaris, Haiku; osinfo-db has them
  all and the vendor-host table just grows rows.
- **Shown in the VM list**, which is where the XML source pays off twice: it works
  with the VM off, so there is no blank cell on a shut-off VM.
- **The SWAP row for a known non-Linux guest.** It currently shows the rate half
  with an empty level; knowing the OS it could say why.
- **A heuristic tier — probably never.** `<clock offset='localtime'>` and the
  `<hyperv>` enlightenment block are what virt-manager writes for Windows
  specifically, so a metadata-less guest could still be guessed at. The sweep
  found 4/4 VMs carrying metadata, so there is nothing to fix and this stays
  unbuilt unless a real host turns up where `:unknown` dominates. Guessing from
  device config would need its own justification anyway.

## To check on a real host

**Done** (2026-08-23, author's host — see § *The mechanism*): `virsh metadata
--uri` works and works shut-off; the reply is the bare element with the namespace
prefix stripped; 4/4 VMs carry metadata; `microsoft.com/win/11` is a measured
Windows id.

Left, neither blocking:

1. **The exact reply when the metadata is absent** — every VM on the host has it,
   so this one cannot be measured here. Whether it is an error exit or empty
   output decides how the `:unknown` path is written; both must land on
   `:unknown` rather than raising, so a wrong guess is a small correction, not a
   redesign. Easiest capture: `virsh metadata <dom> --uri http://example.com/nope`.
2. The exact `guest-file-open` error text for a missing path — the phrase that goes
   into `EXPECTED_FAILURES` (`No such file or directory` is the expectation,
   unverified). Needs a running Windows guest with the agent installed.
3. A FreeBSD osinfo id (`freebsd.org/freebsd/…` expected) — from osinfo-db, not
   measured. Only affects one table row.
4. `virsh domstats --balloon <a-windows-vm>`: does the virtio-win balloon driver
   populate `balloon.swap_in` / `swap_out`? If it does, the SWAP row's *rate* half
   already works on Windows today and only the level is Linux-only. A wave-2
   question, but the measurement can be taken any time.

## Where wave 1's pieces land when it graduates

- the mechanism + the contract (one `virsh metadata` per domain, memoized
  forever, vendor-host classification, only not-Linux gates) → yardoc on
  `Virt::GuestOS` and on `Virsh#guest_os`, including the stripped-prefix note next
  to the regex, since that is the thing a reader would "fix" back;
- **why the gate asks `no_proc_meminfo?` and not `linux?`** → the yardoc on
  `WITHOUT_PROC_MEMINFO`, in a line: `:unknown` must be attempted, because a host
  whose definitions carry no libosinfo metadata would otherwise lose every swap
  gauge. This is the one invariant a later refactor could undo without any test
  failing, so it also earns a line in the DECISIONS.md entry below;
- **why the XML and not the agent** — the agentless Windows guest, the boot
  window, and what it deletes — plus the cost accepted in return (a declaration
  can be stale) and why `:unknown` must not gate → one new `DECISIONS.md` entry
  (pick the slug when writing it — don't cite one from here, the grep tripwire
  wants every cited `D-` slug to exist). The agent is the road not taken, and its
  table above is the argument;
- the `EXPECTED_FAILURES` addition → amends D-guest-agent-backoff;
- `Virt::GuestOS` → one line in CLAUDE.md's class index, plus the
  `inflector.inflect` entry;
- **nothing user-facing** — wave 1 changes no pixel. README waits for wave 2.
- this note survives wave 1, trimmed to § *Wave 2's shopping list* and the
  unchecked measurements.
