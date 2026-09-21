# VirTUI — AGENTS.md

## What this is

A terminal UI for the KVM/QEMU virtual machines on a Linux host, driven through `virsh`: one
screen with every VM's CPU, RAM, disk and swap next to the host's own, the power keys, and an
automatic memory balloon that grows a guest the moment it is short and shrinks it slowly as it
idles. libvirt owns the VMs and the balloon device; virtui owns the polling, the display and
the decision of how much memory to move. Requires Ruby 3.3+; tested on Linux only.

## Promises

- **A guest short of memory gets it now; memory is released slowly.** Why virtui exists: bare libvirt has the `setmem` mechanism and nothing that decides when to call it.
- **Nothing is installed in the guest beyond stock `qemu-guest-agent`**, and virtui only ever reads through it.
- **TUI, native to the terminal it runs in.** The VM pane keeps the terminal's own background and the screen needs no special font.

## Design docs

| File | Owns | Loaded |
|---|---|---|
| `README.md` | the pitch, install, how to run, the ballooning guide a user reads | — |
| `AGENTS.md` (this) | promises, invariants, the module map, conventions, commands | every turn |
| `design/architecture.md` | how the pieces compose — wiring, dependency direction, threads, the flows; normative | lazy |
| `design/decisions.md` | why this and not that — `D_` entries, FAQ-shaped | lazy |
| `design/research.md` | what libvirt, QEMU, the guest kernel and other hypervisors actually do — `R_` entries, each claim with provenance | lazy |
| `design/ideas/*.md` | one scratchpad per idea in flight; deleted once its nuggets land in a row above | lazy |
| doc comments | what one symbol does, why it is shaped so, why a constant has its value | at the symbol |

Every fact lives in exactly one of these; the others link to it.

## Invariants

- **Backend reads run on the timer thread; components are touched on the UI thread only, through the event queue.** A read from the UI thread blocks behind the `virsh` session's one mutex and one child; the hand-off is in architecture.md.
- **Per-domain memos of backend reads live on `Virt::Cache`, never on `Virt::Virsh`.** The UI thread reaches `Virsh` for the power keys, so state there is state two threads share. See `D_guest_os_from_xml`.
- **Every subprocess goes through `Run`, one argument per word.** A single string goes through `/bin/sh` and breaks on a VM named `it's`. See `D_argv_not_shell`.
- **Only reads (`query`) are served by the long-lived `virsh` session; every mutating command spawns its own process** and keeps its own exit status. See `D_virsh_session`.
- **`Virt::GuestAgent` only reads files; `guest-exec` has no sanctioned use.** See `D_no_force_drain`.
- **Nothing under `lib/virt/` or `lib/system/` references `UI::`.** Data flows up through `Virt::Cache`; glyphs and colors stay in `lib/ui/`.
- **`MemLevelRaiseVoter`'s trigger stays above `MemLevelShrinkVoter`'s.** Otherwise both vote on one sample and the VM hunts. See `D_ballooning_voters`.
- **Durations run on the uptime clock (`Cooldown`); specs move them with `Uptime.travel`, never Timecop.** Timecop leaves `CLOCK_MONOTONIC` where it is, so a Timecop'd cooldown test passes vacuously. See `D_cooldown_monotonic`.
- **The guest swap level is the one read allowed to go quiet.** A guest that cannot answer is written off and the poll goes on; every other backend failure raises. See `D_guest_agent_backoff`.

## Module map

- `bin/virtui` — constructs every object, starts the 2 s timer and tuile's event loop.
- `lib/virt/` → `Virt::` — the libvirt backend: `virsh` transports and parsers, the runtime cache, the ballooning controller, the demo emulator.
- `lib/virt/ballooning_vm/` — the ballooning inputs, one voter or vetoer per class.
- `lib/system/` → `System::` — host CPU, RAM and disk from `/proc` and `df`, with an emulator double.
- `lib/ui/` → `UI::` — the tuile panes, theme and tint; reads only `Virt::Cache`.
- `lib/*.rb` — shared top-level value objects and helpers, deliberately namespace-free.
- `lib/core_ext/` — the byte-unit monkey-patches; required by hand, ignored by Zeitwerk.
- `spec/` — rspec; parser specs feed the recorded `/proc`, `domstats` and `df` fixtures beside them.
- `design/` — the lazy docs above, the tripwire script and `design/ideas/`.

## Conventions

- **Ruby, no Rails.** Plain classes, `Data.define` for value objects, Open3 for subprocesses via `Run`, tuile for the TUI.
- **Zeitwerk: one constant per file, named after its path**; no `require_relative` between siblings; acronym casing (`UI`, `VMPane`) is an `inflector.inflect` entry in `lib/virtui.rb`.
- **`# frozen_string_literal: true`** atop every Ruby file.
- **YARD on every public module, class and method**, concrete types in every tag, `@raise` for expected exceptions; the contract and at most a one-line why-not live there, the argument in `design/`.
- **Errors are loud.** Unexpected state raises with the offending data; `virsh` and `/proc` parse failures are never swallowed.
- **Diagnostics go through `$log`**, the one allowed global; never `puts` / `warn`.
- **Tests: rspec-core with minitest-style asserts.** `describe` / `it`, but `assert_equal` / `refute`; parsers are fed recorded fixtures, never the live host.
- **Composition over inheritance.** Shared mechanics become a concrete helper taking keyword parameters, not a base class with template methods.
- **Readable, not obfuscated.** The simplest implementation that does the job; no abstraction layers or knobs ahead of the next concrete step.
- **A tuning constant carries its reason beside its value**, or cites the `D_` that argues it; never a bare number.
- **Grow by adding a class under the right namespace**: new backend data → `lib/virt/`, new host metric → `lib/system/` with a `System::Emulator` counterpart, new widget → `lib/ui/`.

## Commands

```bash
bundle exec rake                  # the gate: specs, rubocop, design tripwires — what CI runs (.github/workflows/ci.yaml)
bundle exec rake check            # the same, spelled out
bundle exec rake spec             # just the tests
bundle exec rspec spec/path/to_spec.rb:LINE     # one test
bundle exec rubocop               # just the lint
design/verify_design_tripwires.sh # the doc-layer checks alone
bin/virtui                        # run; demo mode when no virsh is on the PATH
```

A `virsh` command handed to the user to run on the host carries `-q`, as both runners do: without
it the output differs from what virtui parses (a table's header and rule, a trailing blank line).
See `R_virsh_repl`.

## Skills this project follows

- **Component-oriented:** self-sufficient tuile components that read `Virt::Cache` directly, no MVC layers; the `cop` skill has the rules and `tuile` the UI-thread rendering rule.
- **Doc comments carry the contract, the gotcha and a one-line why-not**; the argument goes to `design/` — the `writing-rdoc` skill.
- **An idea is one file under `design/ideas/`, deleted once its nuggets land in the Design docs table** — the `ideas-folder` skill.

## Maintenance of this file

Loaded every turn; cap 34 KB, a module's own `AGENTS.md` 10 KB. Over it, in this order:
delete what has no home — status, history, class lists, what the code already says; trim
each line to its fact plus one clause and send the explanation home — why →
`design/decisions.md`, how across symbols → `design/architecture.md`, how in one symbol →
its doc comment, what upstream does → `design/research.md`; only then a module's own
`AGENTS.md`, peripheral modules first, never the core. Never paraphrase a lazy entry into a
line here. `design/verify_design_tripwires.sh` checks the caps and the cites.
