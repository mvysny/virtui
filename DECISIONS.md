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

## D-virsh-session — a persistent `virsh` REPL as an opt-in transport for reads (2026-08-21)

**Status:** On trial. {Virt::VirshSession} is opt-in behind
`VIRTUI_VIRSH_SESSION=1`; {Virt::VirshSpawn} remains the default. Revisit
after a few days of real-host observation.

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
command keeps its own process and its own exit status. Reads are opt-in for
now.

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
  guest-agent reads — which does not exist yet. The fleet-wide `domstats`
  poll needs exactly one child. Conflating the two is what made this look
  more expensive than it is.
- *The `ruby-libvirt` binding, to avoid subprocesses altogether.* Rejected
  separately and for a harder reason — see D-virsh-cli, plus the GVL
  measurement in `ideas/swap-via-qemu-guest-agent.md`: the gem never
  releases the GVL, so an in-process libvirt call freezes the UI thread. A
  subprocess cannot.
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
  reason the unclassified remainder is logged at `warn` rather than `debug`
  during the trial.
- Still unmeasured, and the thing that should decide whether this becomes
  the default: the *daemon-side* cost of the connect/disconnect the current
  path pays every 2s. `test:///default` has no daemon, so the dev box cannot
  see it.

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

**Consequences.** Every read is a text parse, which is why the parsers take
a fixture parameter and the specs feed recorded `virsh` output
(`spec/virt/domstats*.txt`) instead of touching a live host. Every call
costs a process spawn, so anything slow or failure-prone goes through
{Run.async} (`start`, `shutdown`, `set_mem_stats_period`) rather than
{Run.sync}. And `virsh` is a hard runtime prerequisite, documented in the
README's *Setup*.
