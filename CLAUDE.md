# CLAUDE.md

This file is the pointer-level orientation map for Claude Code
(claude.ai/code). Rationale and per-file purpose live in YARD headers on
the classes/modules themselves — when a section here says "see
`{ClassName}`", that yardoc is the source of truth and this file just
records the invariant.

- **Read the `cop` and `tuile` skills before designing components or app
  architecture.** VirTUI is a component-oriented Tuile TUI; those skills carry
  the architecture (self-sufficient components, the composition-over-inheritance
  UI carve-out, the model/view seam, and Tuile's UI-thread rendering rule). Not
  conditional — nearly every task here is component/UI work.

## Commands

```bash
bundle exec rake spec             # Run all tests
bundle exec rspec spec/path/to_spec.rb          # Run a single spec file
bundle exec rspec spec/path/to_spec.rb:LINE     # Run a specific test by line number
bundle exec rubocop               # Lint
```

## Autoloading (Zeitwerk)

`lib/virtui.rb` is the entry point: it requires external gems, loads the core
extensions, and configures a [Zeitwerk](https://github.com/fxn/zeitwerk) loader
over `lib/`. Both `bin/virtui` and `spec/spec_helper.rb` just `require 'virtui'`;
everything else autoloads. Conventions to keep the loader happy:

- **One constant per file**, named after the path (`lib/virt/virsh.rb` → `Virt::Virsh`,
  `lib/ui/vm_window.rb` → `UI::VMWindow`). Don't add `require`/`require_relative`
  for sibling classes — reference the constant and it autoloads.
- **Three namespaces map to directories:** `lib/virt/` → `Virt::` (libvirt backend
  domain model + clients), `lib/ui/` → `UI::` (tuile presentation), and
  `lib/system/` → `System::` (host-OS metrics: `System::Info`, `System::CpuStat`,
  `System::MemoryStat`, `System::DiskUsage`, …). The shared byte-usage value object
  `ResourceUsage` and generic helpers (`Run`, `Interpolator`) stay top-level.
  `lib/virt.rb` / `lib/ui.rb` / `lib/system.rb` define+document the modules.
- **`lib/core_ext/` is ignored** by the loader and required manually: it holds the
  `Numeric` byte-unit monkey-patch and the top-level `format_byte_size` helper —
  things that don't define a matching constant.
- Acronym casing (`UI`, `VMWindow`, `VMEmulator`, `VM`, `BallooningVM`) is set via
  `inflector.inflect` in `lib/virtui.rb`; add an entry there for new ones.

## Architecture

VirTUI is a terminal UI for managing KVM/QEMU VMs via libvirt, organized into three namespaces:

**UI layer (`lib/ui/`, `UI::`):** built on the [tuile](https://github.com/mvysny/tuile) TUI gem.
- `UI::AppLayout`: orchestrates three windows — `UI::VMWindow` (VM list/controls), `UI::SystemWindow` (host CPU/RAM/disk), and a log window
- `Virt::Ballooning`: auto-scales VM memory (increases by 30% at ≥65% usage, decreases by 10% at ≤55%); runs on the UI thread, must not be called from a background thread

**Libvirt backend (`lib/virt/`, `Virt::`):**
- `Virt::Virsh`: wraps `virsh` CLI commands
- `Virt::Cache`: thread-safe cache of VM runtime data; `update` is called from a background timer thread
- `Virt::VMEmulator`: demo/test mode that simulates VMs without libvirt

**Host metrics (`lib/system/`, `System::`):**
- `System::Info`: reads the host's CPU/memory/disk usage from `/proc` and `df` (`System::Emulator` is the test double)

**Update flow:** `bin/virtui` runs a `Concurrent::TimerTask` every 2s on a background thread → calls `Virt::Cache#update` → submits a block to tuile's `EventQueue` → UI thread runs `Virt::Ballooning#update` then `layout.update_data` → dirty components repaint.

## Documentation kinds

Each kind of doc has a distinct audience and *what it is allowed to own*.
Match the kind before writing. VirTUI is a small app, so the set is
deliberately short — there is no book, no CHANGELOG, no per-package
`DESIGN.md`; if a fact doesn't fit one of these five, it probably belongs
in a yardoc.

| Kind | Audience | Owns |
|---|---|---|
| **YARD** (source headers) | someone at the API | the per-symbol technical truth **and its rationale** — the source of truth |
| **README.md** | a user running VirTUI | positioning + install/run + the ballooning guide (prerequisites, guest config, how the auto-scaling behaves); doubles as the teaching doc, since there is no book |
| **CLAUDE.md** (this) | contributor / coding agent | invariants ("what you must not break") + pointers to the owning yardoc |
| `ideas/*.md` | you + the author | design rationale *in flight*: open topics, measurements, candidate fixes; transient (trimmed as pieces graduate) |
| `DECISIONS.md` | a contributor asking "why this way?" | the *why-we-chose*, incl. the **roads not taken**; one mutable entry per live decision |

Rules:

- **Single source of truth per fact.** One home; others link. Yardoc owns
  per-symbol truth + rationale; README owns the user-facing concept;
  DECISIONS.md owns the rejected alternative; CLAUDE.md owns invariants
  and points (`see {ClassName}`). Tempted to explain twice → link
  instead. A tiny load-bearing restatement is fine when it saves a jump
  (repeat the *one-line fact*, defer the *explanation*).
- **README stays user-facing.** It explains what a user must do and what
  they will observe (`virsh` prerequisites, the balloon thresholds as
  behaviour); *why* a threshold is 65 and not 50 is yardoc + a
  DECISIONS.md entry, not README prose.
- **The contract lives in the yardoc; the *argument* lives where length is
  affordable.** The `writing-rdoc` skill keeps a doc comment punchy on
  purpose — a wall of grey at the point of *use* is worse than no doc,
  because the reader bounces off it and never reaches the nugget. So a
  yardoc carries the contract, the gotcha, and at most a **one-line**
  why-not-the-obvious note ending in `see DECISIONS.md D-<slug>`; the
  measurement, the analysis and the rejected options go in the entry,
  which is read on demand by someone who came asking. This makes yardoc
  *smaller*, not bigger: a citation passes the regression-guard gate that
  a convincing paragraph would have to fight for.
- **Numbers carry their provenance.** A tuning constant (a threshold, a
  poll interval, a staleness tolerance) never sits bare: the yardoc next
  to it says what it is defending against, in a line, or cites the entry
  that argues it. Never a formula that no longer holds.

### Ideas & their graduation

`ideas/*.md` is transient — a one-file-per-idea scratchpad where rationale
is born, not held to the yardoc quality rules, because it is going to be
deleted. `ls ideas/` is the index; don't add a README or ToC there. See
the `ideas-folder` skill for the procedure; this section is the authority
on *where nuggets land in VirTUI*:

- user-facing concept or setup step → **README.md**
- per-symbol truth or rationale (incl. why a constant has that value) →
  **the yardoc on that class/method**
- cross-cutting invariant ("don't call this from the timer thread") →
  **CLAUDE.md** (a Conventions / Working-on-this-codebase entry)
- the choice made + the alternatives rejected → **DECISIONS.md**
- work deferred *as a consequence of a logged decision* → that entry's
  *Consequences*

As pieces land, cut them from the note; a fully-graduated note is
*deleted*, not left as a stub. Only a standalone open topic with no
decision yet keeps a note alive (`ideas/swap-despite-ballooning.md` is
that case: a measurement plus candidate fixes, nothing decided).

### DECISIONS.md

The home for **roads not taken**, and the only doc that is never
context-loaded — that's why rejection rationale goes there instead of
into a yardoc (read by someone at the API, who gains nothing from an
argument against a design that never shipped) or here (loaded every
session). Cite entries by slug (`D-` plus a 1–4-word kebab hint at the
subject); `grep '^## D-' DECISIONS.md` is the index, so no ToC. Entries are
mutable — a refined decision is edited in place, a *shipped-then-reversed*
one gets a tombstone + a fresh entry. **No entry without a real fork:** if
nothing was seriously considered and rejected, it isn't a decision, it's
how the thing works → yardoc. But note what *does* clear that bar: **a
measurement that rules out the obvious approach is a rejected
alternative** — "tuning this threshold cannot work, here is the proof" is
a fork, and its evidence is the entry's `Context`. Grep tripwire: every
`D-<slug>` cited in the repo exists as a `^## D-` heading in
`DECISIONS.md`. Full format rules live in that file's preamble.

## Conventions

- **Ruby, no Rails.** Plain classes, `Data.define` for value objects
  (`ResourceUsage`, `System::CpuUsage`, …), Open3 for subprocesses (via
  `Run`), tuile for the TUI.
- **Composition over inheritance.** When two classes share mechanics,
  extract a concrete helper they construct with explicit keyword
  parameters — not a base class with template methods.
- **`# frozen_string_literal: true`** at the top of every Ruby file
  (`lib/`, `spec/`, `bin/`). Add it to any new file.
- **YARD docs on every public module, class, and method.** Use concrete
  types in `@param`/`@return` (`Integer`, `Array<String>`, `String, nil`)
  — never bare `Object`. One-line summary first, then tags; document
  expected exceptions with `@raise`. **Rationale belongs in the yardoc,
  not CLAUDE.md** — reference it from here only if it's a cross-cutting
  invariant.
- **Errors are loud.** On unexpected internal state, raise with the
  offending data included (see `Run.sync`). Don't swallow failures from
  `virsh` or `/proc` parsing.
- **Diagnostics go through `$log`** (the `TTY::Logger` set up in
  `bin/virtui`, the one allowed global). Use it instead of `puts` /
  `warn` / `$stderr.puts` for log lines.
- **Tests: rspec-core with minitest-style asserts.** Use `describe` /
  `it` but write `assert_equal` / `assert` / `refute` rather than RSpec
  matchers. Parser specs feed recorded fixtures (`spec/**/*.txt` —
  `/proc` snapshots, `domstats`, `df`) rather than touching the live
  host. See `spec/system/info_spec.rb`.
- **Readable, not obfuscated.** Prefer the simplest implementation that
  does the job. Don't add abstraction layers, plugin systems, or config
  knobs that aren't needed for the next concrete step.

## Working on this codebase

- **Grow by adding a class under the right namespace, not by widening
  the loop.** New backend data → `lib/virt/`; new host metric →
  `lib/system/` (with an `System::Emulator` counterpart for tests); new
  widget → `lib/ui/`. One constant per file (see Autoloading above).
- **Threading.** `Virt::Cache#update` and `System::Info` reads run on the
  background timer thread; everything that touches tuile components
  (`Virt::Ballooning`, `layout.update_data`) runs on the UI thread via
  the `EventQueue`. Don't call UI code from the timer thread.
