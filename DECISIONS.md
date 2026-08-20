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
