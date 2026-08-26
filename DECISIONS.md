# DECISIONS.md

A living record of the design decisions behind VirTUI — especially the
*roads not taken*. It exists because one fact class has nowhere else to
live: a rejected alternative. Both candidate homes refuse it on their own
terms — a yardoc is read by someone at the API, who gains nothing from an
argument against a design that never shipped; and `CLAUDE.md` is loaded
into *every* session's context, so rationale there is paid for on every
turn. This file is the lazy side of that split: **never context-loaded**,
read only when someone asks "why this way?".

It is the *why-we-chose* record. It is not the *how-it-works* reference
(yardoc), the *what-a-user-must-do* guide (`README.md`), or the
*what-you-must-not-break* list (`CLAUDE.md`). An entry links out rather
than restating — see `CLAUDE.md` § *Documentation kinds* for the full
split.

**Length is affordable here — this is the file that may be long.** A
yardoc must stay punchy (see the `writing-rdoc` skill): it is read at the
point of *use*, where a wall of grey means the reader bounces off and
never reaches the nugget. This file is read *on demand*, by someone who
came asking why, so an entry may carry the measurement table, the analysis
and the full argument. The division of labour that follows: the yardoc
keeps the contract plus at most a **one-line** why-not-the-obvious note
ending in `see DECISIONS.md D-<slug>`, and the argument lives here. That
makes yardoc smaller, not bigger — a citation earns its line where a
convincing paragraph would have to fight for five.

**No entry without a real fork.** If nothing was seriously considered and
rejected, it isn't a decision — it's how the thing works, and that's
yardoc. This is the guard against a diary. A tuning constant whose value
was simply picked is likewise yardoc (with its reasoning next to it); it
earns an entry here only once a *rejected* alternative exists.

What *does* clear that bar, and is easy to mistake for a bare
characterization: **a measurement that rules out the obvious approach is a
rejected alternative.** "Tuning this threshold cannot work, and here is
the kernel behaviour that proves it" is a fork — the evidence is the
entry's `Context`, the ruled-out approach is a bullet under *Alternatives
rejected*, named as the trap it is so nobody re-derives it.

**Format.** One entry per decision, headed
`## D-<slug> — <one-line what-was-chosen> (YYYY-MM-DD)` and made of these
bold-led paragraphs:

- **Status:** Accepted / Proposed / Superseded by D-\<slug\>. Name where
  it shipped (a commit, a release) once it did.
- **Context.** What forced the choice.
- **Decision.** What we do, in a few sentences. Link the owning yardoc
  (`{Virt::Ballooning}`) rather than restating it.
- **Alternatives rejected.** One bullet each: the option, and *why not* —
  this is the most valuable part of the file. Where re-trying it is a real
  temptation, say so in as many words ("**Don't re-add …**").
- **Consequences.** What a future contributor would trip over: a follow-up
  this defers, an invariant it creates, a caveat still open.

Entries are separated by a `---` rule.

The ID is a slug, not a number: `D-` plus a 1–4-word kebab hint at the
subject, so a citation carries meaning on its own. The `(date)` is
*decided* provenance, not a log position — git owns the edit history, so
don't narrate how an entry used to read. A decision is worth logging the
moment it's *made*; implementation can lag, and the `Status:` line says
which.

**Entries are mutable — edit in place, don't append addendums.** Each
entry is the single coherent home for one *live* decision; keep it current
as the decision is refined or extended. Two things that does *not*
license:

- **The roads-not-taken stay.** "We chose X, rejected Y because Z" is live
  content of the current decision, not stale history — never edit it away.
- **A reversed *shipped* decision forks a tombstone, it is not
  overwritten.** When a design was tried, shipped, and then thrown away,
  leave the old entry as the scar, set its `Status:` to **Superseded by
  D-\<slug\>**, and write the replacement fresh. The line: *refined or
  extended* → edit in place; *reversed after shipping* → tombstone + new
  entry.

**Newest first.** Entries run reverse-chronologically by decided date, so
a scan hits recent decisions first.

**Never read wholesale.** `grep '^## D-' DECISIONS.md` is the index; there
is no ToC (same discipline as `ls ideas/`). Cite an entry by slug. Grep
tripwire: every `D-<slug>` referenced anywhere in the repo must exist as a
`^## D-` heading here.

**Backfill is opportunistic.** Rejection rationale that already sits
inline in a yardoc stays put — this file is the home going *forward*. Move
an old one only when you're already editing that doc and the inline
rejection is crowding out the live design.

---

## D-virsh-own-pgroup — the session child runs in its own process group, so a terminal resize cannot reach it (2026-08-23)

**Status:** Accepted; the `pgroup: true` on {Virt::VirshSession#start}'s
`popen3`.

**Context.** A rare `expected an echo of "'domstats'"; respawning` in the
wild became attributable once the message carried the bytes that did
arrive (commit 8820f6c): the reply began with a carriage return followed
by a long run of spaces, which is not a `virsh` reply at all — it is GNU
readline repainting its input line.

The child was spawned into virtui's process group, and the kernel sends a
terminal-generated signal to the whole *foreground* process group. So
every time the user resized their window, the `virsh` child got a
`SIGWINCH` it had no business receiving. readline catches that signal even
though its streams are pipes, and reacted on the dev box with 521 bytes
into stdout — `"\r"`, 513 spaces (clear-to-end-of-line the hard way,
because `TERM=dumb` has no `ce`), `"\r"`, then a fresh prompt. Nobody was
reading at that moment, so the repaint sat in the pipe and arrived as the
prefix of the *next* reply, where the echo assertion caught it. Recovery
worked as designed — one respawn, one lost read — but the read that was
lost is a whole fleet poll, and the log line accused the wrong thing.

The signal also does quieter damage, which is the reason not to just
tolerate the bytes. On `SIGWINCH` readline re-derives its width from the
terminal and **does not consult `COLUMNS` again**, so
{Virt::VirshSession::CHILD_ENV}'s line-length guard silently expires: the
dev box measured the width dropping to ~512, after which any command line
longer than that is echoed in horizontal-scroll mode (`"\r<…"`) and
desynchronises *every* read until a respawn. Today's longest line — the
{Virt::GuestAgent} JSON, ~130 bytes — sits under that, so this half was a
landmine rather than a live bug.

**Decision.** `pgroup: true`. The child leads a process group of its own
and no terminal-generated signal — `SIGWINCH` on a resize, `SIGINT` on a
`^C`, `SIGTSTP` on a `^Z`, each of which makes readline repaint — can
reach it. Losing those signals costs nothing: the child has no terminal,
and it is shut down explicitly by {Virt::VirshSession#close}, or by its
stdin closing when virtui dies, which was measured to leave no orphan
(`virsh` reads EOF and exits 0).

**Alternatives rejected.**

- *Drain the stdout pipe before writing each command, discarding whatever
  is there.* Tolerates the stray bytes without knowing where they came
  from — and that is the objection: the only *other* thing that leaves
  bytes in the pipe is a frame abandoned mid-read, which is exactly the
  condition {Virt::VirshSession::Desync} exists to shout about. Swapping a
  loud respawn for a quiet discard buys nothing here (the respawn already
  recovers) and blunts the guard that keeps one VM's numbers from being
  reported as another's. It also leaves the width collapse in place.
- *Accept a leading repaint in the echo assertion* (strip a `\r`-and-spaces
  prefix). Cheapest patch, and it hard-codes one readline version's
  repaint shape into our framing. The bytes are a redisplay, so their
  shape is a function of the terminfo entry and readline's optimiser, not
  a contract.
- *Ignore `SIGWINCH` in the child via a shell wrapper* (`sh -c 'trap ""
  WINCH; exec virsh …'`). Fixes only the signal we happened to see, and
  pays for it with a `/bin/sh` in the middle of the one transport that
  must not re-learn quoting — see D-argv-not-shell.
- *Drop `TERM=dumb` for a terminfo entry with a real `ce`, so the repaint
  is short.* Makes the symptom smaller and the reply stream worse: the
  point of `dumb` is that readline cannot emit ANSI escapes into the
  bytes the parser reads.

**Consequences.**

- {Virt::VirshSession::CHILD_ENV}'s `COLUMNS` cap is only as good as this:
  anything that puts the child back in virtui's process group re-arms both
  failure modes, and the second one is silent. The pair is one mechanism,
  which is why each side's yardoc points at the other.
- `^C` no longer reaches the child. Nothing depended on it — tuile holds
  the terminal in raw mode, so an interactive `^C` never became a signal —
  but a future non-TUI entry point that expects `^C` to clean up must kill
  the child itself.
- {Virt::VirshSpawn} needs none of this: its children are non-interactive
  and start no readline, so a resize mid-command is nothing to them.

---

## D-guest-os-glyph — the guest-OS marker is a two-cell emoji, and an undeclared OS draws a dim `?` rather than a blank (2026-08-23)

**Status:** Accepted; implemented in {UI::VMWindow#format_guest_os}.

**Context.** Once {Virt::GuestOS} shipped (D-guest-os-from-xml), every VM
carried a declared OS family that nothing on screen showed — while that
same declaration silently decides whether the VM is asked for a swap level
at all. The VM list's overview line is one row of glyphs and a name in a
20-to-200-column window, so the marker had a budget of two or three cells.

**Decision.** The family is drawn between the state glyph and the name, one
glyph per {Virt::GuestOS::FAMILIES} key, with a `?` in the frame (dim) color
for `:unknown`. Every marker is padded to {UI::VMWindow::GUEST_OS_WIDTH} = 2
cells, which is what the emoji measure under `unicode/display_width` — the
same measure tuile lays rows out with.

Where a project has a mascot, the mascot wins — 🐧 Tux, 😈 Beastie, 🐡 Puffy,
🚩 NetBSD's flag, 🍎 Apple, 🌞 Sun, 🍃 Haiku's leaf — because those are
the marks their users already recognise. 🐉, 💡, 💾 and 🌐 are stand-ins:
Unicode has no dragonfly, and illumos/DOS/NetWare have no mascot to draw.
The glyph set was chosen *after* the family list, not alongside it: the list
comes from osinfo-db (D-guest-os-from-xml), so there is exactly one row to
fill per family a definition can express, and a spec asserts
{UI::VMWindow::GUEST_OS_GLYPHS} covers {Virt::GuestOS::FAMILIES} exactly.

Placement follows a rule worth keeping in the row: **left of the name is
what the VM *is*, right of it is what it is *doing*.** The OS declaration
never changes while virtui runs, so it can sit left of the name without the
name column moving; the balloon, its direction arrow and the staleness
turtle stay on the right, where a tick-by-tick change costs nothing.

**Alternatives rejected.**

- *A blank cell for `:unknown`.* The original proposal, and the tidier
  list. Rejected because `:unknown` is not a neutral state here:
  {Virt::GuestOS#no_proc_meminfo?} is `!linux?`, so an undeclared VM is
  never asked for its swap level and shows the same `-` as a guest with no
  agent. Blank in the marker column reads as *nothing to say* when it means
  *nobody asked* — the identical argument that made
  {UI::VMWindow#swap_level_bar} draw dashes instead of spaces. A dim `?`
  costs one cell already reserved by the padding and is the only thing on
  screen that explains the missing level. It also keeps Windows and
  undeclared visually distinct, which a blank would not.
- *Mixed-width glyphs — e.g. ⊞ (1 cell) for Windows next to 🐧 (2).* Every
  such row pulls its VM name one column left, and the name column is what
  the eye scans down. Uniform width is the constraint, not the glyph set:
  **don't add a marker without padding it to `GUEST_OS_WIDTH`.** The trap
  this rule catches is not exotic — the *obvious* pick for two families was
  a variation sequence that measures **1**: ☀️ (U+2600 U+FE0F) for Solaris
  and 🕸️ (U+1F578 U+FE0F) for NetWare. 🌞 and 🌐 replace them, and the
  width spec now walks the whole family list rather than a sample of it, so
  the next such glyph fails a test instead of shifting a name column.
- *Letters instead of emoji (`L`/`W`/`B`).* Renders in any font, which is
  the one real argument for it (see Consequences). Rejected because the
  overview line is already an emoji vocabulary — ▶/⏹/🎈/🐢 — and a
  bare letter next to them reads as a truncated word, not a marker.
- *A `guest_os.glyph` method on {Virt::GuestOS}.* Would spare
  {UI::VMWindow} a lookup table, at the price of a presentation decision
  living in `Virt::`. Dependencies point toward data, never toward UI; the
  table stays in the window.

**Consequences.** 🪟 is the font-coverage risk of the set, and the only
one: every other glyph is Emoji 1.0 (2015), while 🪟 is Emoji 13 (2020). A
terminal font without it draws a tofu box, and a tofu box is usually one
cell, so that row's name shifts a column — the failure is cosmetic but it is
exactly the misalignment the padding exists to prevent. Accepted knowingly;
the fallback if it bites is a padded `W ` in that one entry of
{UI::VMWindow::GUEST_OS_GLYPHS}, no other change.

Ten of the twelve glyphs are unseen in demo mode, which declares only Linux,
Windows and nothing — and unseen on a real host too: the author has no
macOS, Haiku, DOS or NetWare guest to boot, and said so. What *is* verified
is the half that can break the layout: a spec measures every glyph's width,
and every family is reachable from an id read out of osinfo-db. A
wrong-looking mascot is a one-character fix; a wrong-width one silently
shifts a name column, which is why the testing effort went there.

---

## D-guest-os-from-xml — the guest OS comes from the domain's libosinfo declaration, not from the running guest (2026-08-23)

**Status:** Accepted; implemented as {Virt::GuestOS} and {Virt::Virsh#guest_os},
memoized and gated in {Virt::Cache#update}.

**Context.** {Virt::GuestAgent} reads the guest's swap level out of its
`/proc/meminfo`, so the read is Linux-only — and virtui had no idea which of its
guests were Linux. Two costs, the first of which arrived with
D-guest-agent-backoff: a Windows guest's `guest-file-open` fails with a phrase
matching none of {Virt::GuestAgent::EXPECTED_FAILURES}, so it produced one
`warn` per VM boot for a guest that is merely not Linux; and it spent three
doomed agent RPCs per tick until the write-off bounded it to one probe a minute,
forever.

**Decision.** Read what the domain *declares*. virt-manager and `virt-install
--os-variant` write libosinfo metadata into the definition, and `virsh metadata
--uri http://libosinfo.org/xmlns/libvirt/domain/1.0 <dom>` returns just that
element:

```
Flow     running     <libosinfo>  <os id="http://ubuntu.com/ubuntu/25.10"/>  </libosinfo>
Ayyah    shut off    <libosinfo>  <os id="http://ubuntu.com/ubuntu/25.10"/>  </libosinfo>
BASE     shut off    <libosinfo>  <os id="http://ubuntu.com/ubuntu/25.10"/>  </libosinfo>
win11    shut off    <libosinfo>  <os id="http://microsoft.com/win/11"/>     </libosinfo>
```

(Author's host, 2026-08-23, whitespace collapsed. Note the stripped
`libosinfo:` prefix — the stored definition carries it, the reply does not.)

{Virt::GuestOS} classifies the id by vendor host plus first path segment; the
family gates the agent read, and {Virt::Cache} memoizes one lookup per domain.

**Alternatives rejected.**

- ***`guest-get-osinfo` through the guest agent*** — the live, *truthful*
  source, and the first design. **Don't re-add it as the only source.** It needs
  the agent up, and the agentless Windows guest is the *common* Windows guest:
  `virtio-win` is a manual install, so the guest that caused this whole problem
  is precisely the one an agent-based detector can never classify — it would
  keep its three doomed RPCs per tick and its write-off forever. Beside that:
  invisible for the 20–40s a guest takes to boot, invisible for a shut-off VM,
  needs its own `--timeout` because it *can* wedge on a sick guest, and it drags
  in the whole D-guest-agent-backoff machinery (does detection share the strike
  count? what log level for a guest that cannot answer *yet*? what happens on a
  pre-2.10 `qemu-ga` that refuses the RPC while the file read works fine?). The
  XML answers with none of that. It remains the right *second* source — see
  *Consequences*.
- *`virsh guestinfo <dom> --os`.* Prettier output, in exactly the key=value shape
  {Virt::Virsh} already parses — and no `--timeout` flag, which is the one thing
  keeping a wedged agent from becoming a {Virt::VirshSession} read timeout that
  kills and respawns the child. Moot now that the source is not the agent, but
  it is the obvious command to reach for.
- *`virsh dumpxml` plus a regex, or a real XML parser.* `metadata --uri` returns
  the element alone, so there is no document to parse: one regex over three lines
  rather than over sixty, and no first XML dependency in the project.
- *Vendoring osinfo-db, or shelling out to `osinfo-query`.* What virtui needs
  is a family, not a version tree, and not a build-time dependency on a
  database that ships separately from libvirt. {Virt::GuestOS::FAMILIES}
  instead holds a *one-time extraction* of it: every `<os id>` in
  `gitlab.com/libosinfo/osinfo-db` reduced to its `vendor-host/short-id` key
  and tagged with that entry's own `<family>` — 980 entries collapsing to 76
  keys and 12 families (`main`, 2026-08-23). The whole point of the reduction
  is that the part virtui reads barely moves: osinfo-db gains OS *versions*
  constantly and OS *vendors* rarely, and a new vendor costs one row plus a
  `debug` line that names the id nobody matched.

  It is worth saying what the first table cost by *not* doing this. Wave 1
  hand-wrote ~15 rows from the osinfo-db naming scheme, and three of them were
  wrong in ways nothing on the author's host could reveal:
  `alpinelinux.org/alpine` (the real short-id is `alpinelinux`, so every Alpine
  guest silently fell to `:unknown` and lost its swap level), plus
  `linuxmint.com/linuxmint` and `kali.org/kali` — vendors osinfo-db has never
  had. That is a 3-in-15 error rate on rows that *looked* obvious, which is the
  argument for extracting the set rather than pattern-matching it. Two smaller
  facts the extraction settled at the same time: **OS/2 is not in osinfo-db at
  all** (there is no `ibm.com` vendor, so it cannot be declared and cannot be
  detected — an earlier note claiming otherwise was wrong), and
  `libosinfo.org/unknown` is a real declarable id meaning *unknown*, deliberately
  left out of {Virt::GuestOS::FAMILIES} so it lands where an undeclared domain
  lands.
- *Keying {Virt::GuestOS::VENDORS} on the vendor host alone.* Reads simpler and
  is wrong: `microsoft.com` ships both `win/*` and `msdos/*`, so it needs a
  second special-case structure for exactly those vendors. Every entry pays one
  redundant-looking segment instead.
- *A heuristic tier for definitions carrying no metadata* — `<clock
  offset='localtime'>` and the `<hyperv>` enlightenment block are what
  virt-manager writes for a Windows guest specifically. Not built: 4/4 VMs on the
  measured host carry real metadata, so there was nothing to fix, and guessing a
  family from device config would need its own justification.
- *Gating on `windows? || freebsd?`, letting `:unknown` fall through to the read.*
  Preserves today's behaviour exactly for a guest that declares nothing, at the
  price of a family list that grows with every family added.
  {Virt::GuestOS#no_proc_meminfo?} is the plain `!linux?` instead — see
  *Consequences* for what that costs.
- *Memoizing on {Virt::Virsh}, next to the lookup.* The natural place, and the
  wrong thread: `Virsh` is reachable from the UI thread ({UI::VMWindow}'s power
  keys, {Virt::Ballooning}'s `set_actual`), so mutable state there is state two
  threads can reach — and a memoizing `Virsh#guest_os` invites a future OS column
  to call it from the render path, taking {Virt::VirshSession}'s single mutex on
  the UI thread. The memo lives in {Virt::Cache}, which already owns the timer
  thread and is already the only thing the UI reads.

**Consequences.**

- **A domain that declares no OS reports no swap level.** `!linux?` puts
  `:unknown` on the skip side, so a hand-written definition — or one from tooling
  that writes no libosinfo metadata — loses a gauge it used to have. Invisible on
  a virt-manager fleet, where nothing is `:unknown`; on a hand-rolled fleet it is
  every VM. Hence the `README.md` line saying the swap level needs the domain to
  declare its OS, not just `qemu-guest-agent`.
- **The declaration can be stale.** It records what the *creator* said, so a
  definition made `--os-variant win10` and then used to install Linux skips a
  read that would have worked. Symptom: a missing swap gauge on a VM whose
  declared family is wrong.
- **Both of those are what the agent would fix**, which is the case for adding
  `guest-get-osinfo` later as a *corroborating* source: when the agent is up it
  outranks the declaration and can classify an `:unknown` guest live.
- **{Virt::GuestAgent::EXPECTED_FAILURES} gained `no such file or directory`**,
  amending D-guest-agent-backoff: a non-Linux guest that declared nothing still
  reaches `guest-file-open` on a path that is not there, and that must not be a
  `warn`. The exact libvirt phrasing is unverified — no Windows guest with
  `qemu-guest-agent` was within reach to capture it — so the phrase is an
  expectation, and a miss costs one `warn` line per boot of such a guest.
- **The memo never expires.** Editing a domain's definition while virtui runs
  takes a restart to notice. `Virt::GuestAgent#forget` stays about failure state
  and does not touch it.
- **`:unknown` now means what it says.** With the table complete, an id reaching
  `:unknown` is a definition declaring something outside osinfo-db — not a gap in
  virtui's list. That is what makes the `debug` log for an unmatched id a signal
  worth acting on rather than routine noise, and it is the premise the dim `?`
  marker leans on (D-guest-os-glyph).
- **Growing {Virt::GuestOS::FAMILIES} is free** precisely because
  {Virt::GuestOS#no_proc_meminfo?} is `!linux?`: nine families were added without
  touching the gate, the cache or the agent. A `windows? || freebsd?` gate would
  have needed editing once per family — the rejected alternative above, and the
  bill it would have run up.

---

## D-guest-agent-backoff — a mute guest is written off for 60s, probed once a minute, and logged only when the failure is one we did not foresee (2026-08-23)

**Status:** Accepted; implemented as {Virt::GuestAgent::BACKOFF_SECONDS} and
{Virt::GuestAgent::EXPECTED_FAILURES}, plus {Virt::GuestAgent#forget}, called
from {Virt::Cache#update}.

**Context.** The write-off added with D-guest-swap-level shipped as three
strikes then 300 seconds, announced with a `$log.info` line. Both numbers were
picked against the guest that will *never* answer — no agent, or `guest-file-*`
blocked — and both are wrong for the guest that simply cannot answer *yet*. At a
2s poll the three strikes are spent 6 seconds after libvirt calls a domain
running, and no guest gets `qemu-ga` connected within 6 seconds of `virsh
start`. So every VM start wrote its own guest off, blanked the swap gauge for
the next five minutes on a perfectly healthy VM, and announced it in the log —
which is how this was noticed. Shutdown produced the same line from the other
side, as the agent goes down before libvirt calls the domain stopped.

**Decision.** Three parts, all aimed at the boot case:

- **60 seconds, flat.** A booting guest is retried a minute later, by which
  point its agent is up. The other side of the trade — the guest that never
  answers now costs a probe a minute instead of one per five — is accepted
  rather than optimized: its `guest-file-open` is refused immediately (no agent
  connected is not a timeout), and a well-maintained fleet has the agent
  installed, so it is the special case.
- **`$log.debug` for the failures a healthy host produces on its own.** A
  missing swap level is an enhancement declining, not a fault. There is no
  phrasing that stays useful at `info`, because the two moments it fires are
  boot and shutdown.
- **`$log.warn`, once, for anything else.** Silence is right for the guest that
  is booting, shutting down, has no agent, or ships `guest-file-*` blocked —
  and wrong for an agent installed incorrectly, a reply we cannot parse, or a
  libvirt error nobody foresaw, which would otherwise be swallowed with the
  rest. {Virt::GuestAgent::EXPECTED_FAILURES} draws the line, matched against
  the error text; the warn fires exactly at the write-off, so one broken guest
  costs one line per episode rather than one a minute.
- **The strike count survives a lapse.** Only a successful sample clears it, so
  a still-mute guest re-arms on the one probe rather than spending a fresh
  three. Without this the "one probe a minute" above is really three, and the
  attempt rate against a *wedged* agent — the case that costs a full
  {Virt::GuestAgent::TIMEOUT_SECONDS} of the timer thread, unlike a mute one —
  would rise 4.5x over what D-virsh-session assumed.

{Virt::Cache#update} additionally calls {Virt::GuestAgent#forget} for every VM
it sees not running, so strikes burned during a shutdown do not greet the next
boot.

**Alternatives rejected.**

- *Escalating backoff — 60s doubling to a 300s cap.* Serves both guests
  exactly: a minute for the booting one, five for the one that never answers.
  Rejected as tuning for the special case. The cost it saves is a refused RPC
  per minute per agent-less VM, which is not worth a second constant and a
  doubling rule that has to be reasoned about at every read.
- *Suppress logging and backoff entirely for 1–2 minutes after a VM starts.*
  The most direct reading of the symptom, and the first proposal. It needs a
  boot clock virtui does not have: libvirt's state stays `running` across a
  guest-induced reboot, so the grace period never re-arms for the case that
  most needs it, and a shutdown falls outside it altogether. It is also the
  expensive answer — it keeps polling a *wedged* agent for the whole window,
  2s of timer thread per tick, which is precisely what the write-off exists to
  bound. The state-transition half of the idea survives as
  {Virt::GuestAgent#forget}.
- *Keying the write-off itself on the error text* (`is not connected` =
  transient, everything else = permanent). Would separate the two guests
  exactly, at the price of hanging virtui's *behaviour* on libvirt's error
  strings, which are not an API: a rephrasing upstream silently changes how
  long a guest is skipped, and no test goes red. Keying the **log level** on
  the same strings is what shipped instead, and it is a different bet — a miss
  there costs one line in the log or one line missing from it, never a change
  in what virtui does. Don't promote the match from the level to the backoff.
- *Warning on every unexpected failure, not just the write-off.* Louder, and
  for a persistent fault it is the same line repeated every 60s forever. The
  cost of the once-per-episode rule is an *intermittent* unexpected error that
  never lands three consecutive strikes: it stays at `debug`. Accepted —
  anything genuinely misconfigured is persistent and surfaces within 6s.
- *Dropping {Virt::GuestAgent::FAILURES_BEFORE_BACKOFF} to 1*, since a 60s
  write-off is itself blip tolerance. Cheaper against a wedged agent, but a
  single hiccup then blanks the gauge of a healthy guest for a minute.

**Consequences.**

- Nothing in the UI says a guest has been written off, and for an expected
  failure nothing in the log does either: `bin/virtui` pins `$log` at `:info`,
  so seeing those means lowering the level by hand. That is the intended trade —
  the swap level is the only read in the project allowed to go quiet (see
  {Virt::GuestAgent}). An *unforeseen* failure is the exception and still
  announces itself once.
- {Virt::GuestAgent::EXPECTED_FAILURES} is a list of substrings from another
  project's error messages, so it rots by definition. The failure mode is
  benign and self-announcing — a phrase libvirt has renamed shows up as a
  `warn` line on a healthy host — which is the reason the list is allowed to
  exist at all.
- A guest-induced reboot is still not detected: `forget` cannot fire, because
  the domain never leaves `running`. It heals within the 60s instead, which is
  what makes the short backoff load-bearing and `forget` mere hygiene.
- D-virsh-session's "revisit only if a wedged guest is measured delaying the
  fleet poll" bullet stays live, and this moves that dial: a wedged guest now
  stalls one tick a minute rather than one per five.

---

## D-cooldown-monotonic — {Cooldown} counts uptime, and exposes a writable clock so specs can travel it (2026-08-26)

**Status:** Accepted, shipped in {Cooldown}.

**Context.** {Cooldown} holds the suppression deadlines in the ballooning controller:
{Virt::BallooningVM}'s back-off (10 s after a resize, 20 s after a VM starts) and
{Virt::BallooningVM::SwapOutShrinkVetoer}'s 60 s veto. What those mean is a *duration*
— ten seconds is ten elapsed seconds — and nothing about them refers to a calendar.
Measured on `Time.now` they would not deliver that: NTP correcting a large offset, the
first sync after boot, or a manual `date` moves every live deadline with it.

The complication is that the project's time-travel tool is Timecop, which patches
`Time.now` and — verified in this repo — moves
`Process.clock_gettime(CLOCK_MONOTONIC)` by exactly zero. So the clock that is correct
is the clock no spec can move, and the deadlines needing tests are 10–60 s long inside
callers whose own specs travel 20–80 s.

**Decision.** {Cooldown} measures on `CLOCK_MONOTONIC`, and reads it through
`Cooldown.clock` — a writable class-level callable, defaulting to the real thing.
Production never assigns it. Specs travel time through `Uptime.travel`
(`spec/spec_helper.rb`), which swaps in an offset clock and restores the default in an
`ensure`, so a failing example cannot leak the shift.

An explicit, documented seam rather than a spec reaching in to redefine a method:
the writability is then part of the class's contract, where the yardoc can say who may
use it, instead of a monkey-patch that a later `private_class_method` would silently
break. {Virt::GuestAgent} already runs the same clock for its per-guest write-offs, so
this makes the two agree rather than adding a second convention.

**Alternatives rejected.**

- **Measure on the wall clock and accept what a step does.** Briefly taken, and wrong:
  it quietly redefines the contract from "ten seconds" to "until this wall-clock
  instant", which is not what any caller means. The damage is admittedly bounded — one
  premature 10% shrink or one veto lapsing early, re-decided on the next 2 s poll — but
  a bounded wrong answer is still a wrong answer, and the only thing it bought was not
  having to write `Uptime.travel`. Its one genuine argument is worth recording, because
  it will come up again: for **suspend/resume**, the jump a desktop KVM host actually
  sees, `CLOCK_MONOTONIC` excludes suspended time, so a 60 s veto armed before an
  8-hour sleep still has 60 s to run on wake against a guest whose state has nothing to
  do with what armed it. `CLOCK_BOOTTIME` is the clock that would fix that specific
  case without reintroducing the NTP exposure; it is not worth the divergence from
  {Virt::GuestAgent} today, and the cost is at most one stale decision on resume.
- **Real `sleep`s in the specs.** Fine for {Cooldown}'s own sub-second boundaries,
  impossible for the callers: `BallooningVM`'s specs travel 20–80 s.
- **Make every duration a constructor parameter, so specs pass 0.** The
  {Virt::GuestAgent} idiom (`backoff_seconds: 0`), and it does not reach: it needs five
  new parameters across two classes, it stops the real 10/20/60 s values from being
  exercised at all, and "does it lapse at 60 s" is precisely the assertion that would
  be lost. Injecting the *clock* tests the shipped constants; injecting the
  *constants* tests numbers no user will run.
- **Store both a wall and an uptime deadline and require both.** Makes the Timecop path
  diverge from production — the uptime half never moves under Timecop — so the specs
  would exercise a path production never takes. A test that lies is worse than the bug.
**Consequences.**

- A writable class attribute in production code, load-bearing for tests only. The
  yardoc names its one legitimate caller; anything in `lib/` assigning `Cooldown.clock`
  is a bug.
- {Virt::GuestAgent} was ported onto {Cooldown} once the clocks agreed, so there is one
  implementation of "suppressed until it lapses" in the tree rather than two. Its
  deadlines stay per-domain in a `Hash{String => Cooldown}`, which the value object
  models fine; what looked like an obstacle — `backing_off?` deleting the entry on lapse
  — turned out to be bookkeeping, since a lapsed {Cooldown} answers `false` for ever.
  The load-bearing half is that the *strike count* is untouched there
  (D-guest-agent-backoff), and that is unchanged.
- {Virt::VirshSession}'s read deadline is on it too, which is the one consumer not
  confined to a single thread. `Uptime.travel` swaps a process-global, so it must not be
  used while another thread holds a live {Cooldown}; its yardoc says so. No spec wants to
  anyway — a deadline enforced by a blocking `wait_readable` can only be tested by waiting,
  which is why those specs inject a short `read_timeout` and always did.
- Injecting the clock rather than the durations paid off immediately: the write-off's
  shipped `BACKOFF_SECONDS` now has a spec that watches it lapse, which the
  `backoff_seconds: 0` injection it was tested with could never assert.
- `Uptime.travel` and `Timecop.freeze` now both exist and mean different things. Which
  one a spec wants is decided by what it needs to move: a cooldown, or an
  {Interpolator} ramp (the emulator, wall clock by design — animation follows the clock
  a human is watching). `spec/virt/ballooning_vm_spec.rb` uses both, a few lines apart,
  and says so at the call site.
- {Cooldown#remaining} and the never-shorten rule in {Cooldown#extended_by} are
  clock-agnostic: both compare two readings of the same clock.

---

## D-swap-shrink-veto — a guest seen writing to swap has its memory frozen for 60s, on the rate rather than the level (2026-08-26)

**Status:** Accepted, shipped in {Virt::BallooningVM::SwapOutShrinkVetoer}, consulted
from {Virt::BallooningVM#update}.

**Context.** `BallooningVM` steers by
`percent_used = (MemTotal - MemAvailable) / MemTotal`, and evicting anon pages to
swap *raises* `MemAvailable`. So the controller's one input falls exactly when the
guest is suffering, and swap is an unmodelled second actuator competing with the
balloon for the same variable. Two failures follow, and both were measured:

- **Invisibility.** A guest sat at 61% used — mid-deadband, controller idle — with
  2 GiB parked in swap. Under this metric a swapping VM and an idle VM are the same
  VM.
- **Inversion.** Watched live on 2026-08-26 while IntelliJ IDEA started, the figure
  did not merely fall, it sat *pinned* at 55% — allocation and eviction cancelling —
  for the whole ramp, while swap climbed ~2.5 GiB. 55% is `@trigger_decrease_at`
  exactly: one percentage point more eviction and virtui would have **shrunk the VM
  mid-burst**, taking memory from a guest that was already paying disk I/O for the
  lack of it.

Both measurements, and the three root causes behind them, are in
`ideas/swap-despite-ballooning.md`.

**Decision.** While the guest is seen writing to swap, the decrease branch is
vetoed outright — the increase branch is untouched, so a swapping guest still
grows. "Seen writing" means `Cache::VMCache#swap_out_rate` at or above a 1 MiB/s
noise floor on any *guest sample* (not any poll: libvirt refreshes balloon data
every ~5s while we poll every ~2s, so one sample arms the veto once), and it holds
for 60 s from that sample. Both constants are documented next to their values on the
vetoer, which is where a decision of this kind keeps its state and thresholds — see
*Consequences*. A guest whose balloon reports no swap counters at all balloons exactly
as before.

The choice of *rate* is what makes the veto finite, and that is the whole design:
swap-used is a high-water scar, not a pressure gauge.

**Alternatives rejected.**

- **Veto while the swap *level* is non-zero.** The obvious reading of "don't shrink
  a swapping guest", and newly implementable since D-guest-swap-level put the real
  level on screen. Rejected because the level is a scar: swap slots are freed by
  write faults and process exit with no `swap_in`, and a page swapped out at boot can
  sit there for hours. Gating on it means a VM that swapped once is never shrunk
  again — a permanent ratchet dressed up as a safety check. **Don't re-add it when
  the guest-agent level is right there in `VMCache#guest_swap`;** it answers "what
  did this guest already pay?", not "is it paying now?".
- **Veto only while the rate is non-zero this sample** (the shape first proposed).
  Rejected on evidence: `swap-via-qemu-guest-agent.md` caught a shrink firing with
  853 MiB in swap and `pswpout` flat. A guest that just swapped and went quiet is the
  one that *least* wants shrinking — it has not yet faulted its working set back, so
  its usage figure is still deflated by exactly the pages it is about to want. The
  cooldown is the level-free proxy for the question the level would have answered:
  when is it safe to shrink again.
- **Use `swap_in` too, as "swap activity".** Inverted: `swap_in` advancing means
  pages are being faulted *back*, i.e. the guest healing. A controller watching
  activity in general would freeze — or grow — a VM in response to its recovery.
- **Reuse the existing `back_off` timer** instead of a second clock. Mechanically
  identical (it already suppresses decreases only, and extends rather than shortens),
  but it would merge two unrelated reasons into one: `back_off` means "we just moved
  this VM's memory, let it settle", the veto means "the guest is telling us it is
  short". The status line is the maintainer's only window into the decision, and it
  has to say which.
- **Keep the state on `BallooningVM`** — where every other threshold lives — rather
  than extracting a class for one veto. Rejected on trajectory rather than on this
  change's own merits: the open work in `ideas/swap-despite-ballooning.md` is a queue
  of further inputs (a grow trigger on the same signal, a shrink gate on
  `pgsteal_*` deltas, a `disk_caches` floor), each with its own thresholds and its own
  timer. Folded into one constructor those become a field soup where nothing says
  which ivar belongs to which rule. One class per input, each owning its constants and
  answering one question, keeps `update` a reader of opinions instead of a holder of
  state.
- **Tune `@trigger_decrease_at` down instead.** Doesn't touch the defect: the
  measured guest was pinned *at* 55% with swap climbing, so any threshold has a
  usage figure that satisfies it while the guest swaps. Prior art also says this knob
  is already over-tightened — MoM, Hyper-V and K8s VPA all reserve 15–20% where our
  65% trigger reserves 35%, and the guest swapped anyway.

**Consequences.**

- **This fixes the inversion, not the invisibility, and the difference matters.**
  The measured state — 61% used, controller idle, 2 GiB swapped — had no shrink in
  flight at all, so the veto would never have fired. Veto-only leaves a stable bad
  equilibrium: the guest trickles to disk, `percent_used` sits mid-deadband, nothing
  is attempted, the trickle continues. **Only a grow trigger on `swap_out` closes
  that half**, and its response shape (how far the swap signal alone may grow a VM,
  and how to check the growth helped) is still open in
  `ideas/swap-despite-ballooning.md`.
- The 60 s cooldown costs density: a VM that swaps once an hour holds its memory a
  minute longer each time. Deliberate, and bounded by being finite.
- The noise floor is uncritical *on these guests* — Ubuntu desktop-ish,
  `vm.swappiness=1`, disk swap, no zram — where the rate is exactly 0 at rest, so
  non-zero is the event. A guest with zram, MGLRU or a systemd `MemoryHigh=` slice
  may trickle benignly, and would need the floor raised; on such a guest a floor high
  enough to filter the trickle is also high enough to blind a *grow* trigger, which
  is why the grow half cannot simply reuse this constant.
- **The shape this sets for what follows.** A veto is a small stateful object under
  `lib/virt/ballooning_vm/` that is fed every sample via `observe` and answers
  `veto_reason` — a `String` phrased to follow a "but", or `nil` for no objection. The
  `nil`-or-reason return is deliberate: it makes the maintainer-facing status line fall
  out of the same call that makes the decision, and it is what a future *collection* of
  vetoers reduces over. There is one today, held in a plain ivar; the array arrives with
  the second, not before.
- `swap_out_rate` now has a second consumer (the first is the SWAP row,
  D-swap-row-two-cells), so its carry-forward-when-the-sample-is-stale behaviour is
  now load-bearing for a control decision, not just for a readable display.

---

## D-swap-row-two-cells — the SWAP row splits into guest occupancy and host I/O (2026-08-21)

**Status:** Accepted, shipped in {UI::VMWindow#format_swap_line}.

**Context.** Until now the row carried one figure — the swap-out *rate* —
in the guest cell, with the two since-boot counters as a tail and the host
cell left empty on the grounds that swap is a guest-only concern
(D-swap-row-always-on). D-guest-swap-level then produced a second figure,
the swap *level*, and it does not fit beside the rate: at a ~100-column
terminal one cell is ~42 characters, and three figures plus two bars in
that space shrinks the level bar to ~10 characters, which is exactly the
comparison against the RAM bar above it that makes the level worth
showing.

**Decision.** Two cells, two questions. The guest cell shows **occupancy** —
the level, rendered by the same `usage_bar` the RAM row uses, so the two
stack and can be read against each other. The host cell shows **I/O** — the
rate gauge, then the lifetime traffic as one summed `↕` figure.

The rate moved to the host side on the merits, not for the room: a guest's
swap writes *are* host disk writes, which is what that column means
everywhere else on the screen. The same argument sums the two lifetime
counters — `swap_out + swap_in` is the total traffic the host paid for, and
which direction it went is already answered by the rate (out, now) and the
level (parked, now).

A guest that cannot report a level gets a dashed placeholder with a `-`
caption, not blank space.

**Alternatives rejected.**

- **Blank guest cell when the level is unavailable.** Blank reads as *an
  empty swap device*, when it means *nobody could ask* — and that is an
  ordinary configuration, since the level needs an agent running in the
  guest. The dashed cell says unknown in the same
  idiom the row already uses for an unknown rate (`-/s`) on a first sample.
- **Fall back to the old layout when there is no level** (rate in the guest
  cell, host cell empty). Denser, and it changes nothing for today's users
  — but the rate would then sit in a different column depending on the
  guest, so a fleet could no longer be scanned by running one eye down one
  column. Column stability beat row density.
- **Keep swap strictly guest-side** — level and rate both in the guest
  cell, host cell always empty, preserving the old "swap is a guest-only
  counter" framing. Rejected on the width arithmetic above, and because the
  framing turned out to be wrong: the I/O half is not guest-only.
- **Keep `↑written ↓read-back` as two figures.** 13 characters of tail for
  a distinction that the rate and the level now make better, and it costs
  the gauge 7 characters of resolution (the first bar character now lights
  at ~0.8 MiB/s instead of ~1.2). The one thing lost is spotting a guest
  that is *draining* swap — visible instead as a falling level.

**Consequences.**

- The row is now the one place on screen where the two cells are not the
  same quantity from two viewpoints (guest RAM vs host RAM); they are two
  different quantities. The captions carry that (`1.8G` of `4G` vs `3M/s`),
  and the yardoc says it in a line.
- A guest reporting a level but no swap counters still gets *no row*: the
  gate is unchanged (D-swap-row-always-on), and the host cell needs the
  counters. No distro kernel builds without `CONFIG_VM_EVENT_COUNTERS`, so
  this stays theoretical.
- The rate gauge got wider, so D-swap-rate-full-scale's sensitivity figure
  moved with it; the constant itself is unchanged.

---

## D-guest-swap-level — read the guest's swap level from its own `/proc/meminfo`, through the QEMU guest agent (2026-08-21)

**Status:** Accepted, shipped: {Virt::GuestAgent} reads it,
{Virt::Cache#update} samples one level per running VM into
{Virt::Cache::VMCache}, and the `SWAP` row shows it (D-swap-row-two-cells).

**Context.** `domstats` gives `balloon.swap_in`/`swap_out`, which are
since-boot *I/O counters*: they never fall when swap slots are freed, so a
level cannot be derived from them at any sampling rate — measured in
`ideas/swap-despite-ballooning.md`, where a guest drained 1.14 GiB of swap
with `pswpout` flat. The level is the number an operator wants ("how much
is this ballooned guest still paying?") and the one the controller would
need to close root cause 3 (swapping erases its own evidence: evicting N
bytes raises `MemAvailable` by ~N). Only the guest knows it, and
`qemu-guest-agent` — a `virt-manager` default, already running in the
managed VMs — turns out to be a channel to it that needs nothing installed
in the guest.

**Decision.** {Virt::GuestAgent} reads the guest's `/proc/meminfo` with the
agent's `guest-file-open`/`read`/`close` trio and parses it through
{System::MemoryStat.parse} — the same parser the host's copy goes through,
since it is the same file format. Any failure answers `nil`, and a guest
that fails repeatedly is written off for five minutes: no agent, or an
agent with the RPC blocked, is a normal state and must never break the
poll.

Paired with {Virt::VirshSession}, not offered on {Virt::VirshSpawn}: three
agent calls per VM per tick is where the ~18 ms process spawn stops being
noise (~120 ms per VM per tick at N=3 files-worth of calls, against a 2 s
tick), while the session removes it and leaves only the ~13 ms of
irreducible libvirtd+QMP+virtio-serial round-trip. The transports needed no
new code for this — `query` carries the payload and
{Virt::VirshSession.quote}'s single quotes were already what keeps virsh's
tokenizer off JSON's backslashes.

**Alternatives rejected.**

- **`guest-exec` + `guest-exec-status`.** Two calls instead of three, and
  one `sh -c` could cat several files at once — but it is remote *root
  exec* made a hard dependency of monitoring, it spawns a process in the
  guest on every tick, and it is asynchronous: the first reply carries only
  a PID, so the output needs a second round-trip that cannot be issued
  until the guest process has exited (amortizing that means carrying a PID
  across ticks). Reading a world-readable file earns none of that.
  Reconsider only if PSI, `vmstat` and meminfo are all wanted per tick,
  where one exec beats three `guest-file-*` trios.
- **Reconstruct the level from the counters (`swap_debt`).** The candidate
  in `ideas/swap-despite-ballooning.md`: decay-weighted `Δswap_out −
  Δswap_in`, no guest channel needed. It is an *estimate* with a known bias
  (slots freed with no fault-in inflate it, which is what forces a decay
  half-life nobody has a number for), and this reads the real figure. It
  stays the fallback for guests with no agent, and its own note says the
  estimate wanted validating against exactly this number.
- **Ship a virtui agent into the guest.** Ruled out before and still out:
  the whole appeal here is that the channel already exists, unmaintained by
  us.
- **`Libvirt::Domain#qemu_agent_command` via ruby-libvirt.** Saves the
  spawn, but ruby-libvirt 0.8.4 never releases the GVL, so one wedged
  `qemu-ga` freezes the entire TUI rather than one thread — see D-virsh-cli.

**Consequences.**

- Two figures now describe guest swap and they answer different questions:
  the *rate* ({Virt::Cache::VMCache#swap_out_rate}, from the counters, every
  guest) and the *level* (here, agent-capable guests only). Whatever shows
  them has to survive the level being absent — this is an enhancement path,
  never the primary one.
- `qemu-guest-agent` becomes an optional prerequisite worth documenting in
  README, alongside the balloon device and the stats period.
- The guest-side channel is now open in code. It is deliberately narrow —
  {Virt::GuestAgent#read_file} reads a file and cannot execute anything —
  and widening it to `guest-exec` (a swap *drain*, `swapoff -a`) is a
  separate decision, not an extension of this one.
- Sampling belongs on the timer thread inside {Virt::Cache#update}, not
  inside `Virsh#domain_data`: `domstats` is one O(1) call for the whole
  fleet, while this is O(running VMs) calls that fail per VM.

---

## D-swap-rate-full-scale — the swap gauge reads against a fixed 20 MiB/s, not a per-VM maximum (2026-08-21)

**Status:** Accepted; implemented as `UI::VMWindow::SWAP_RATE_FULL_SCALE`, read
by {UI::VMWindow#format_swap_line}.

**Context.** The SWAP row started as plain text and was reshaped to match the
CPU and RAM rows above it — caption cell, bar, figures — so the guest column
reads as one grid rather than one bar row and one sentence. A bar needs a
full-scale value, and this is the one metric in the window that has none:
CPU tops out at 100%, RAM at the guest's total, but a swap-out rate is bounded
only by the guest's swap device, which virtui cannot see and which differs per
host and per guest.

**Decision.** Full-scale is a fixed 20 MiB/s, clamped: an *alarm gauge*, not a
utilization ratio. The value trades sensitivity for headroom — it is set high
enough that a guest thrashing on an SSD-backed swap file still has bar left to
grow into, at the cost of the low end: on a ~100-column terminal the gauge is 17
characters, so its first character lights at ~1.2 MiB/s and a slower trickle
draws nothing. That is affordable because the trickle is not silent — the `SWAP`
label is warn-colored whenever the rate is positive at all, so the bar carries
"how bad", never "whether". The `↑`/`↓` since-boot totals beside it carry the
exact figures.

**Alternatives rejected.**

- *Self-scale to the VM's own observed peak rate.* No constant to justify, and
  every VM gets a full bar at its worst moment — but the bar then means
  something different per row *and per minute*. A guest that once burst to
  200 MiB/s renders a steady 5 MiB/s as a stub, while an idle guest's first
  100 KiB/s twitch fills the bar. Comparing two VMs down the list is most of
  what the column is for, so a per-VM denominator defeats it.
- *Scale to guest RAM per second* (full bar = 1% of the guest's RAM/s).
  Dimensionally tidy and self-adjusting, but it draws the same absolute rate
  differently on a 2 GiB and a 32 GiB guest, when the cost being shown — swap
  device I/O — is identical. And it is un-guessable: nobody reads a bar as
  "percent of RAM per second".
- *A log scale over a wide range* (64 KiB/s … 1 GiB/s). Never pins and keeps
  everything on-scale, but a log bar reads as linear to anyone who doesn't
  know it isn't, so a harmless trickle renders as an alarming half-full bar.
  Rejected as a lie the reader can't see.
- *No bar — keep the row textual.* What shipped first, and it was perfectly
  legible; the totals were even more precise than a gauge. Dropped because the
  row then sits outside the grid every other row obeys, and the one thing a
  reader wants at a glance — is this guest hurting *now* — was a number to
  parse rather than a shape to notice.

**Consequences.** Everything from 20 MiB/s upward looks identical (pinned), so
the rate caption and the `↑` total are what separate "bad" from "much worse".
At the other end a sub-1.2 MiB/s trickle renders as an empty bar on a typical
terminal (and the threshold rises as the window narrows, since the bar shrinks),
which is why the label's warn coloring — not the bar's emptiness — is what says
"not swapping". The constant is not derived from anything measured on the host,
so it must keep its reasoning next to its value (`CLAUDE.md` § *Numbers carry
their provenance*) if it is ever retuned — and nothing else needs to change
with it.

---

## D-swap-row-always-on — every running VM keeps its SWAP row, even at rest (2026-08-21)

**Status:** Accepted; implemented in {UI::VMWindow#format_swap_line}.

**Context.** The guest swap-out indicator shipped as a row that appeared
under a VM's RAM bar only while the rate was positive, on the reasoning that
a healthy fleet should not pay vertical space for a metric that is zero. In
use that inverted: swapping is bursty (the balloon refreshes its counters
every ~5 s, and a guest under pressure swaps in bursts), so rows kept
appearing and vanishing, and every VM *below* the one swapping shifted down
a row and back — while the reader was trying to read exactly those rows. The
list jitters worst precisely when something is going wrong.

**Decision.** A running VM gets its SWAP row whether or not it is swapping;
at rest the row reads `out 0/s` with the since-boot totals. What draws the
eye is the warn coloring on the `SWAP` label, applied only while the rate is
positive — the row's *presence* carries no signal, so nothing moves.

The one state that still hides the row is a guest whose balloon reports no
swap counters at all. The reason the criterion is different: "not swapping
right now" flips on every burst, while "cannot report swap" is fixed for the
life of the VM — hiding on a constant costs no stability, so the row is
spent only where it can say something.

**Alternatives rejected.**

- *Keep it hidden at rest.* The row-jumping above. The trigger to hide on
  has to be one that doesn't change while the user is reading.
- *Hide at rest, but reserve the row's height.* A blank line under every
  RAM bar costs the same space as the populated row and tells the reader
  less; there is nothing to buy with it.
- *Show the row only for VMs that have ever swapped this boot.* Stable per
  boot, but the flicker returns at the boundary (the first burst still
  inserts a row), and the interesting VM is often the one at `0/s` next to a
  neighbour that is swapping — being able to compare the two is the point.
- *Render `not reported by guest` in the row instead of hiding it.* Tried;
  it distinguishes "not swapping" from "can't tell", but it spends a line
  per such VM forever to say something that will never change, and on a
  fleet of guests without counters that is the whole screen.

**Consequences.** A running VM is 5 list lines where its guest reports swap
counters and 4 where it doesn't — which is what the cursor-position
expectations in `spec/ui/vm_window_spec.rb` encode. "No row" therefore means
"this guest doesn't report swap", not "this guest isn't swapping"; nothing on
screen says which, so the absence has to be read from the balloon indicators
already next to the VM name.

---

## D-mem-stats-self-armed — virtui arms guest mem-stat collection itself, on every VM start (2026-06-10)

**Status:** Accepted; shipped in 536b566.

**Context.** libvirt's guest memory-stat collection period defaults to `0`
(disabled). Until something sets it, the guest-reported balloon fields
(`balloon.usable`/`available`/`unused`/`last-update`) freeze at their
boot-time values while the host-sourced fields (`cpu.time`, `balloon.rss`)
keep moving — so a VM looks alive but its RAM looks stuck, and the
ballooning controller happily resizes a busy VM based on numbers taken
seconds after boot.

**Decision.** {Virt::Cache#update} arms the period itself
(`Virt::Cache::STATS_PERIOD_SECONDS`) the moment it first sees a VM
running, via {Virt::Virsh#set_mem_stats_period}. Fire-and-forget: the
command runs through {Run.async}, so a VM that rejects it cannot abort the
refresh loop.

**Alternatives rejected.**

- *Have the user add `<stats period='3'/>` to the `<memballoon>` device in
  the domain XML.* Works, and `README.md` still documents it as an optional
  way to make the period survive a power-off — but as the *only* mechanism
  it silently degrades every VM nobody remembered to edit, and leaves no way
  to distinguish "no balloon device" from "period never set": both present
  as frozen guest numbers.
- *Arm it synchronously.* A VM without a balloon device makes `virsh
  dommemstat --period` fail; raising there would abort the whole 2-second
  refresh for every other VM. Hence {Run.async} — failures are logged, not
  raised. **Don't "clean this up" into a `Run.sync`.**

**Consequences.** The period is a live property of the running QEMU process:
it survives a guest reboot but not a full power-off, which is why the arming
is keyed on the not-running → running transition rather than done once at
startup. A VM that still reports frozen data (no balloon device, no guest
tools) is caught downstream by the staleness check — see
`D-wall-clock-mem-age`.

---

## D-wall-clock-mem-age — balloon-data age is measured against the sample clock, not between polls (2026-06-10)

**Status:** Accepted; shipped in 536b566.

**Context.** Guest balloon data can freeze while everything else about the
VM keeps updating (see `D-mem-stats-self-armed`). The UI has to be able to
say so — that's the 🐢 next to the VM name — and {Virt::BallooningVM} has to
refuse to resize on frozen numbers.

**Decision.** {Virt::Cache::VMCache} carries `mem_data_age_seconds`: true
wall-clock age, the snapshot's own `sampled_at` minus the guest's
`balloon.last-update`. `VMCache#stale?` trips at 12 s.

**Alternatives rejected.**

- *Diff `last_updated` between two consecutive polls.* The obvious
  formulation, and it cannot work: the delta is `0` both when the data is
  perfectly fresh **and** when it is frozen, so it can never detect a stuck
  guest. This was the original implementation and it never fired. **Don't
  re-derive it.**
- *A tighter threshold than 12 s.* `virsh` refreshes balloon data only every
  ~5 s regardless of the period we ask for, and we poll every ~2 s on top of
  that, so perfectly healthy data is routinely 5–7 s old. Anything much below
  10 s turns the turtle into a flicker.

**Consequences.** The 12 s figure is tied to that ~5 s libvirt floor; if the
poll interval or the collection period changes, re-derive it rather than
nudging it. The check is a backstop, not a diagnosis: it says the guest
stopped reporting, not why (see the README's ballooning prerequisites).

---

## D-argv-not-shell — subprocesses take one argument per word, not a command string (2026-08-21)

**Status:** Accepted. {Run.sync} and {Run.async} take a splat; every call
site that interpolates a VM name or a file path passes it as its own
argument.

**Context.** {Run} originally took a single `String`, which Ruby hands to
`/bin/sh` whenever it contains shell metacharacters. Three call sites
interpolated user-controlled text into that string and hand-wrapped it in
single quotes:

```ruby
Run.sync("virsh setmem '#{domain_name}' '#{new_actual / 1024}'")
Run.async("virt-manager … --show-domain-console '#{current_vm}'")
qcow2_files.map { |it| "'#{it[0]}'" }.join(' ')     # into `df -P …`
```

Single quotes cannot contain a single quote, so all three broke on an
apostrophe — and libvirt permits one in a domain name, as does any
filesystem in a qcow2 path. A VM named `it's` produced:

```
$ virsh setmem 'it's' '262144'
sh: 1: Syntax error: Unterminated quoted string
```

Every VirTUI command that names a VM was affected: `setmem`, `dommemstat`,
`start`, `shutdown`, `reboot`, `reset`, `destroy`, the `virt-manager`
launch, and `df` on the disk images.

**Decision.** `Run.sync(*command)` / `Run.async(*command)`. With more than
one element `Open3` execs directly, no shell is involved, and an argument
containing quotes, spaces, `*` or `$HOME` arrives byte-for-byte. The
`virsh` runner role took the same shape — `query`/`sync`/`async` all splat
— so {Virt::Virsh} now writes `@runner.sync('setmem', domain_name, kib)`.
The single-string form still works and is kept for literal commands with
nothing interpolated.

**Alternatives rejected.**

- *Escape correctly instead, with `Shellwords.escape`.* Works, and it is
  what the first sketch of this fix did. Rejected because it keeps a shell
  in the path for no benefit: every future call site then has to remember
  to escape, and forgetting is silent until someone names a VM oddly. Argv
  removes the category rather than defending against it. It would also have
  been escaping for the *wrong target* half the time — see the next point.
- *One escaping helper shared by both transports.* Tempting, and wrong:
  {Virt::VirshSpawn} needs no escaping at all now, while
  {Virt::VirshSession} must quote for `virsh`'s own tokenizer, which is not
  the shell's. Structured arguments let each transport do its own thing —
  spawn passes argv, the session quotes with
  {Virt::VirshSession.quote} — from one call site that knows about neither.
  (They *are* near-identical grammars, which is exactly what would have
  made a single shared helper look right until it wasn't.)
- *Leave it; nobody names a VM `it'\''s`.* An apostrophe in a name is
  ordinary, and the failure is not graceful: `virsh setmem` dies in the
  shell with a syntax error nobody would connect to the VM's name. The same
  bug in `df -P` silently mis-reports disk usage for the affected image.

**Consequences.**

- `Run`'s error and log messages join the argv with spaces for readability,
  so a name containing a space is ambiguous *in the message*. Cosmetic, and
  the alternative (inspecting each element) is noisier for the common case.
- The runner role's methods take a splat, which cannot carry a yardoc
  `@param` if written as anonymous `*` forwarding — hence the documented
  `Style/ArgumentsForwarding` exclusion in `.rubocop.yml`.
- {Virt::VirshSession.quote} is now the only quoting code in the project,
  and it has exactly one target: `virsh`'s tokenizer.

## D-virsh-session — a persistent `virsh` REPL serves the reads (2026-08-21, default since 2026-08-23)

**Status:** Accepted. {Virt::VirshSession} is what `bin/virtui` builds;
{Virt::VirshSpawn} still serves every mutating command, and is the
fallback both the degrade path and a source edit reach for. The
`VIRTUI_VIRSH_SESSION=1` opt-in that gated the trial is gone — a fallback
that needs a one-line source edit is cheap enough to keep, an environment
variable that has to keep working is not.

The trial concluded on real-host observation rather than on the
daemon-side measurement this entry set as its deciding test (below). That
measurement was never a risk, only unbooked upside: the connect and
disconnect a spawn pays every 2s cost the *daemon* CPU too, so measuring
them can only widen the gap the dev box already showed. Days of a real
fleet not hitting the degrade path answered the question that was actually
open — whether the REPL holds outside the test driver.

**Context.** {Virt::Cache#update} polls `virsh domstats` every 2s for the
whole fleet, and each poll re-execs a binary that dynamically links 61
shared objects. Measured on the dev box against `test:///default` (libvirt's
in-process driver, so no hypervisor work is included and the figures are
pure per-call overhead), 200 iterations each way:

| per call | CPU (user+sys) | minor page faults |
|---|---|---|
| one process per command | 7.8 ms | 1065 |
| persistent session | 0.100 ms | 0.015 |

78x the CPU and ~70000x the page faults, all of it discarded milliseconds
later. Through the real {Virt::Virsh} parser the end-to-end read is 64x
faster (7.79 ms → 0.121 ms). At the 2s tick that is 0.39 % of one core held
continuously, for as long as the TUI is open, against 8.3 MB PSS to keep a
child resident instead.

**Decision.** Introduce a *runner* seam — `query`/`sync`/`async`, where a
subcommand excludes the word `virsh` — and give it two implementations.
Only `query`, the read path, may be served from a session; every mutating
command keeps its own process and its own exit status.

**Alternatives rejected.**

- *Leave it alone; 0.39 % of a core is noise.* True in the absolute, and it
  is why this stayed rejected through two rounds. What moved it was noticing
  the first verdict had been reached on the wrong axis entirely — latency
  (8 ms of a 2000 ms tick, invisible) rather than host load, which is the
  quantity that matters on a box whose job is running VMs.
- *A peer client class implementing the whole {Virt::Virsh} role.* Would
  have had to duplicate or inherit ~150 lines of `domstats`/`nodeinfo`
  parsing. Putting the seam *below* the parsing instead means the existing
  parser specs and recorded fixtures are untouched, because they bypass the
  runner entirely.
- *One session per VM, with per-VM fault isolation and circuit breakers.*
  That machinery is justified only by an O(running-VMs) workload — per-VM
  guest-agent reads. Those now exist (D-guest-swap-level) and one shared
  child still serves them: the reads are serialised behind this session's
  mutex, a per-call `--timeout` bounds the damage a wedged guest can do, and
  {Virt::GuestAgent}'s own write-off is the circuit breaker, at no
  multi-process cost. Revisit only if a wedged guest is measured delaying
  the fleet poll — the price of that revisit is measured: ~2.8 MB PSS per
  extra child (8.2 MB for one, 34.9 MB for ten), so quote PSS and not the
  ~6.5x larger summed RSS, almost all of which is shared pages. The fleet-wide `domstats` poll still needs exactly one
  child; conflating the two is what made this look more expensive than it is.
- *The `ruby-libvirt` binding, to avoid subprocesses altogether.* Rejected
  separately and for a harder reason — see D-virsh-cli, whose GVL paragraph
  is the argument: the gem never releases the GVL, so an in-process libvirt
  call freezes the UI thread. A subprocess cannot.
- *Merging the child's stderr into stdout* (as the idea note first
  proposed), so error text orders against the reply marker. It does order
  correctly — but the parser must receive stdout alone, exactly as
  {Run.sync} delivers it today. Keeping the streams split preserves that
  *and* {Run.sync}'s raise-with-stderr contract; `virsh` is strictly serial,
  so anything on stderr by the time the sentinel is read belongs to that
  frame.
- *Framing replies on the `virsh # ` prompt.* Looks free, since readline
  emits one after every command. It is not: readline also echoes the request,
  so a payload containing the prompt string terminates the read on its own
  echo and desynchronises every reply after it. Measured, not theorised. An
  asymmetric sentinel — a nonce split by a quote the tokenizer removes, so
  the bytes searched for cannot occur in the echoed input — is what actually
  holds.
- *Deciding a reply is complete when the pipe goes quiet.* Indistinguishable
  from latency, and the failure mode is one VM's numbers reported as
  another's. Completeness comes from ordering instead: `virsh` runs one
  command at a time, so a sentinel sent after the real command cannot answer
  until the real command has finished.

**Consequences.**

- A read deadline now exists where {Run.sync} would have blocked forever.
  It is a liveness backstop only; nothing about where a reply *ends* depends
  on it.
- Both transports pass `-q`. Without it `virsh` appends a blank line that an
  interactive session does not, and byte-identical output is the whole basis
  for calling the swap safe.
- Failure splits in two, and the split is load-bearing: a host with no
  libvirtd leaves `virsh` sitting happily in its REPL failing every command,
  so treating a *command* failure as a broken child would respawn forever.
- Without an exit status, deciding whether stderr means failure or chatter
  is a prefix test on `error:`. This is the design's weakest joint, and the
  reason the unclassified remainder stays at `warn` rather than `debug` now
  that every run is a session run: a misclassification must not be quiet.
- The *daemon-side* cost of the connect/disconnect a spawn pays every 2s is
  still unmeasured — `test:///default` has no daemon, so the dev box cannot
  see it. It stopped being the deciding measurement when the field trial
  answered the question (Status above); it is now only a number nobody has
  put on the win.
- Two gotchas the dev box could not reach remain unverified against a real
  host: a genuinely wedged `qemu-ga` under `qemu-agent-command --timeout`,
  and libvirtd restarting under a live session. Both land in the transport
  failure path, which degrades to spawning — the floor is today's
  behaviour, which is why they did not block the promotion.

## D-virsh-cli — drive libvirt by shelling out to `virsh`, not the ruby-libvirt binding (2025-11-11)

**Status:** Accepted. {Virt::Virsh} is the only real backend;
`Virt::LibVirtClient` was deleted in e3e0faa.

**Context.** VirTUI needs per-VM runtime data (state, CPU time, balloon
stats, per-disk sizes) and needs to issue power and memory commands. Two
ways in: the [ruby-libvirt](https://ruby.libvirt.org/) binding, or the
`virsh` CLI.

**Decision.** {Virt::Virsh} shells out to `virsh` and parses its text
output. `Virt::Virsh.available?` picks it when the binary is on the `PATH`;
otherwise `bin/virtui` falls back to {Virt::VMEmulator} demo mode.

**Alternatives rejected.**

- *The ruby-libvirt binding.* A `Virt::LibVirtClient` was written against it
  and then deleted: it doesn't expose everything VirTUI displays, and closing
  the gap is blocked by [bug #1](https://github.com/mvysny/virtui/issues/1).
  Still wanted — the README lists it under *Future plans* — so this entry is
  the thing to revisit, not re-litigate, once that bug moves.

  **A second, worse objection, found 2026-08-21 while designing
  D-guest-swap-level: ruby-libvirt 0.8.4 never releases the GVL.** The
  extension imports no `rb_thread_*` symbol at all, so every libvirt call
  holds the GVL for its full duration — measured with a blocking
  `Libvirt::open` to an unroutable address, which stopped a ticker thread
  dead for the whole ~10 s hang. Consequence: a slow or wedged libvirtd
  freezes the *entire* TUI — no repaint, no keyboard — where a `virsh` child
  costs one late update, because `Process.wait` releases the GVL. So the
  process spawn is not pure waste; it buys thread isolation. Anything built
  on the binding needs a short timeout plus a per-VM circuit breaker, or a
  separate process, before it is safe near the event loop.

**Consequences.** Every read is a text parse, which is why the parsers take
a fixture parameter and the specs feed recorded `virsh` output
(`spec/virt/domstats*.txt`) instead of touching a live host. Every call
costs a process spawn, so anything slow or failure-prone goes through
{Run.async} (`start`, `shutdown`, `set_mem_stats_period`) rather than
{Run.sync}. And `virsh` is a hard runtime prerequisite, documented in the
README's *Setup*.
