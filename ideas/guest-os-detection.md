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

The id is a URI, and the key is its **host plus first path segment** — not the
host alone, and not a glob:

| key | family | |
|---|---|---|
| `microsoft.com/win` | `:windows` | measured (`…/win/11`) |
| `ubuntu.com/ubuntu` | `:linux` | measured (`…/ubuntu/25.10`) |
| `debian.org/debian`, `redhat.com/rhel`, `fedoraproject.org/fedora`, `opensuse.org/opensuse`, `archlinux.org/archlinux`, … | `:linux` | from osinfo-db |
| `freebsd.org/freebsd` | `:freebsd` | from osinfo-db |
| anything unrecognised, and a definition with no metadata | `:unknown` | |

**Why host *plus* segment, when the host alone reads simpler.** Some vendors ship
more than one family: `microsoft.com/msdos` against `microsoft.com/win`,
`oracle.com/solaris` against `oracle.com/linux`. A host-only map needs a second
special-case structure for exactly those; host+segment handles every vendor with
one flat Hash and no wildcard matching — parse the URI, take
`"#{host}/#{path_segments.first}"`, look it up. The redundancy in
`ubuntu.com/ubuntu` is the price of not having two lookup paths.

**Not osinfo-db, just a table.** ~15 hand-written entries covering what people
actually run; there is no need to vendor the database, and no wildcards to match.
It lives as a frozen constant with a `GuestOS.from_osinfo_id` factory **on
`Virt::GuestOS`** — the value object owning its own classification. A separate
class earns its own file when the table is loaded from data or runs to hundreds of
rows; at this size it is one constant. Log the unrecognised id at `debug`, so the
table grows from real sightings instead of guesses.

Either way it is a table rather than the substring match over `os.pretty-name`
prose the agent draft was stuck with.

**`:unknown` is a real member, not an error.** It is what an unrecognised vendor
and a *missing* metadata element both produce, and it is a value rather than a
`nil` so the memo can cache it and the caller never nil-checks. Enumerate the
Linux vendors we know rather than treating "not Windows" as Linux, so an
unrecognised vendor is honestly unknown instead of being mislabelled — and note
that `:unknown` is on the *skip* side of the gate (§ *The gate*), which is what
makes keeping this table current load-bearing rather than cosmetic.

**FreeBSD folds in cleanly, and does gate.** FreeBSD's own `/proc` carries no
`meminfo`, and linprocfs is conventionally mounted at `/compat/linux/proc` — so
`/proc/meminfo` is absent there in practice too, and skipping loses nothing that
a plain path change would have recovered. (`microsoft.com/msdos`, `ibm.com/os2`
and friends are in osinfo-db too, but they are wave 2: nothing behaves differently
for them in wave 1, since anything not-Linux already skips.)

## Where it lives

Not on `{Virt::GuestAgent}` — this has nothing to do with the agent any more. It
is a `virsh` read, a classification, and a memo, and the three land in three
different places:

- **`Virt::GuestOS`** — a `Data.define(:family, :osinfo_id)`, the vendor table,
  the `from_osinfo_id` factory, and the family predicates (§ *The gate*). Keeping the raw `osinfo_id` alongside the family means
  wave 2 (and the log line) can say *what* was declared, not just which bucket it
  fell in. Needs an `inflector.inflect` line in `lib/virtui.rb` for `GuestOS`;
  `GuestOs` would need none but reads worse.
- **`Virt::Virsh#guest_os(domain_name)`** — the lookup, and **nothing else**: one
  `virsh metadata` call, one regex, `GuestOS.from_osinfo_id`. **Stateless**, like
  every other method on `Virsh`.
- **`Virt::Cache`** — the per-domain memo, and the carrier.

### The memo belongs to `Cache`, not `Virsh`

The first draft put the memo on `Virsh`, next to the lookup. That is the wrong
object, and the reason is the thread map. `Virsh` is *not* timer-thread-confined:
`{UI::VMWindow}` calls `start` / `shutdown` / `force_off` / `reboot` / `reset` on
it from the **UI thread**, and `{Virt::Ballooning}` calls `set_actual` there too.
Mutable state on `Virsh` is therefore state two threads can reach, and — worse —
a `Virsh#guest_os` that memoizes invites wave 2's OS column to call it from the
render path, taking `{Virt::VirshSession}`'s single mutex on the UI thread. That
is what CLAUDE.md's threading rule forbids, and no test would catch it.

`{Virt::Cache}` already is the timer-thread-owned object with the write lock, and
it already is the only thing the UI reads. So:

```ruby
# in Cache#update, per domain — outside the `if data.running?` branch
guest_os = (@guest_os[did] ||= @virt.guest_os(did))
cache[did] = VMCache.diff(old_cache[did], data, guest_swap, guest_os)
```

Three things fall out of that placement:

- **`||=` is the whole memo.** No "have we seen this domain before" edge to detect
  — which matters, because `DomainInfo` is `Data.define(:name, :cpus,
  :max_memory)` rebuilt by the domstats parser on *every* tick, so there is no
  new-domain event to hang the read on. `||=` also self-heals a first read that
  failed, which an explicit first-sighting hook would not. It is safe only because
  `guest_os` never answers `nil` (§ *Error handling*) — one more reason `:unknown`
  is a member rather than an absence.
- **Outside the `running?` branch**, unlike `guest_swap`. The XML answers for a
  shut-off domain, which is the entire point of the pivot, and reading it for
  stopped VMs hands wave 2 their OS for free.
- **The field rides on `VMCache`**, exactly as `guest_swap` already does — so the
  UI reads `cache.guest_os` as a plain field, never calls into `Virsh`, and never
  blocks. `VMCache.diff` gains one parameter; nothing else in the class changes.

**And the gate moves with the memo.** An earlier draft put it in
`Virsh#guest_swap`, one line above the delegation to the agent — but `Virsh` no
longer holds the memo, so it cannot ask. `Cache#update` can, because it already
has both values in hand:

```ruby
guest_swap = data.running? && !guest_os.no_proc_meminfo? ? @virt.guest_swap(did) : nil
```

Which is arguably where it belonged anyway: the one place that knows both the OS
and the running state is the one place that decides, `Virsh#guest_swap` stays the
dumb delegation it is today, and `{Virt::GuestAgent}` is still untouched.
`{Virt::VMEmulator}` needs a `guest_os` answering `:linux` to stay
`Cache`-compatible — one line, since the emulated fleet is Linux by construction.

### Lifetime

A static fact, read once, no expiry, no `forget` interaction
(`{Virt::GuestAgent#forget}` stays about failure state and never sees this).
Documented limit: edit a domain's definition while virtui runs and it needs a
restart to notice. Entries for undefined domains linger, which is one small object
per domain ever seen — prune with `@guest_os.select! { |k, _| domain_data.key?(k) }`
if it ever looks untidy, but it is not a leak worth code today.

## The gate

**Decided.** All three family predicates are honest — `:unknown` answers **false**
to `windows?`, `freebsd?` *and* `linux?`, because unknown is unknown — and the
gate is the plain negation:

```ruby
def windows? = family == :windows
def freebsd? = family == :freebsd
def linux?   = family == :linux

# Only a guest we positively know to be Linux is worth asking for /proc/meminfo.
def no_proc_meminfo? = !linux?
```

So **`:unknown` skips the read**, alongside `:windows` and `:freebsd`. Author's
call, taken with the alternative on the table (`windows? || freebsd?`, which lets
`:unknown` fall through to the read), because one negation beats a family list
that grows with every wave-2 addition.

What that buys and what it costs:

| family | read attempted? | |
|---|---|---|
| `:linux` | yes | unchanged from today |
| `:windows`, `:freebsd` | no | the win — 3 doomed RPCs/tick → none |
| `:unknown` | **no** | **the cost — see below** |

The `:unknown` row is the trade. A guest whose definition carries no libosinfo
metadata — hand-written XML, `virsh define` of a hand-rolled file, older tooling —
is never asked for its swap level, so **it loses the swap gauge it has today**.
Zero of the author's four VMs are in that state, so this is invisible here; on a
host built without virt-manager it would be the whole fleet.

That makes it the one part of wave 1 a *user* can notice, which has consequences
for where it gets written down:

- it is a documented behaviour, not a bug to be surprised by later — so the
  DECISIONS.md entry carries it as the accepted cost, and `no_proc_meminfo?`'s
  yardoc says in a line that `:unknown` deliberately falls on the skip side;
- **wave 1 is no longer "changes no pixel"** — README's ballooning guide gains a
  line: the guest swap level needs the domain to declare its OS (libosinfo
  metadata, which virt-manager and `virt-install --os-variant` write), not just
  `qemu-guest-agent`;
- and it gives wave 2's agent corroboration a second job it did not have before:
  an `:unknown` guest whose agent *is* up can still be classified live, which
  recovers the gauge for exactly the guests this trade gave up.

Wave 2 adding `:os2` / `:dos` needs no change here — they are already not
`:linux`.

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

`virsh metadata` can fail two ways: **metadata not present** (the normal state for
a hand-written definition) and **the domain is gone** (the `list`→`metadata` race,
on a VM shutting down). The exact reply for the first is unmeasured — every VM on
the author's host has metadata — so an earlier draft of this section wanted the
strings before deciding.

It does not need them. **One rescue, `:unknown`, memoized, `debug`** covers both,
because the worst case is benign: a domain raced during shutdown is memoized
`:unknown` for the rest of the process, and `:unknown` behaves *exactly as virtui
does today* — attempt the read, let the write-off bound it. So the cost of not
distinguishing is that one VM keeps today's behaviour after a shutdown race.
Compare the alternative, which is a fragile match on libvirt prose deciding
whether to memoize — the same licence-spending `EXPECTED_FAILURES` is careful not
to do (see D-guest-agent-backoff).

This is the last thing that looked like a blocker and is not one. Loud failure is
not wanted here either: unlike the agent path, being unable to classify costs
nothing a user can see.

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

Left, none of it blocking:

1. The exact `guest-file-open` error text for a missing path — the phrase that goes
   into `EXPECTED_FAILURES` (`No such file or directory` is the expectation,
   unverified). Needs a **running Windows guest with `qemu-ga` installed**, which
   is the one capture that would sharpen wave 1; guessing wrong costs one `warn`
   per boot of that specific guest, i.e. today's bug persisting in a narrower
   case. Booting `win11` with the agent would also settle item 3 below.
2. A FreeBSD osinfo id (`freebsd.org/freebsd/…` expected) — from osinfo-db, not
   measured. Only affects one table row, and a wrong host string degrades to
   `:unknown`, which is today's behaviour.
3. `virsh domstats --balloon <a-windows-vm>`: does the virtio-win balloon driver
   populate `balloon.swap_in` / `swap_out`? If it does, the SWAP row's *rate* half
   already works on Windows today and only the level is Linux-only. A wave-2
   question, but the measurement can be taken any time.

## Where wave 1's pieces land when it graduates

- the mechanism + the contract (one `virsh metadata` per domain, memoized
  forever, vendor-host classification, only not-Linux gates) → yardoc on
  `Virt::GuestOS` and on `Virsh#guest_os`, including the stripped-prefix note next
  to the regex, since that is the thing a reader would "fix" back;
- **that `no_proc_meminfo?` is `!linux?`, so `:unknown` skips the read** → the
  yardoc on that method, plus the accepted cost in the DECISIONS.md entry: a
  domain with no libosinfo metadata gets no swap level (§ *The gate*);
- **the memo lives on `Cache`, not `Virsh`, because `Virsh` is reachable from the
  UI thread** → CLAUDE.md's *Threading* bullet already owns this rule; a clause
  naming `guest_os` keeps the next person from memoizing on `Virsh` for
  convenience;
- **why the XML and not the agent** — the agentless Windows guest, the boot
  window, and what it deletes — plus the cost accepted in return (a declaration
  can be stale) and why `:unknown` must not gate → one new `DECISIONS.md` entry
  (pick the slug when writing it — don't cite one from here, the grep tripwire
  wants every cited `D-` slug to exist). The agent is the road not taken, and its
  table above is the argument;
- the `EXPECTED_FAILURES` addition → amends D-guest-agent-backoff;
- `Virt::GuestOS` → one line in CLAUDE.md's class index, plus the
  `inflector.inflect` entry;
- **one user-facing line** — README's ballooning guide notes that the guest swap
  level needs the domain to declare its OS, not just `qemu-guest-agent` (§ *The
  gate*). Everything else waits for wave 2.
- this note survives wave 1, trimmed to § *Wave 2's shopping list* and the
  unchecked measurements.
