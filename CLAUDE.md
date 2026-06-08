# CLAUDE.md

This file is the pointer-level orientation map for Claude Code
(claude.ai/code). Rationale and per-file purpose live in YARD headers on
the classes/modules themselves — when a section here says "see
`{ClassName}`", that yardoc is the source of truth and this file just
records the invariant.

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

- **One constant per file**, named after the path (`lib/virt/cmd.rb` → `Virt::Cmd`,
  `lib/ui/vm_window.rb` → `UI::VMWindow`). Don't add `require`/`require_relative`
  for sibling classes — reference the constant and it autoloads.
- **Three namespaces map to directories:** `lib/virt/` → `Virt::` (libvirt backend
  domain model + clients), `lib/ui/` → `UI::` (tuile presentation), and
  `lib/system/` → `System::` (host-OS metrics: `System::Info`, `System::CpuStat`,
  `System::MemoryStat`, `System::DiskUsage`, …). The shared byte-usage value object
  `MemoryUsage` and generic helpers (`Run`, `Interpolator`) stay top-level.
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
- `Virt::Cmd`: wraps `virsh` CLI commands (`Virt::LibVirtClient` is an unused, faster alternative)
- `Virt::Cache`: thread-safe cache of VM runtime data; `update` is called from a background timer thread
- `Virt::VMEmulator`: demo/test mode that simulates VMs without libvirt

**Host metrics (`lib/system/`, `System::`):**
- `System::Info`: reads the host's CPU/memory/disk usage from `/proc` and `df` (`System::Emulator` is the test double)

**Update flow:** `bin/virtui` runs a `Concurrent::TimerTask` every 2s on a background thread → calls `Virt::Cache#update` → submits a block to tuile's `EventQueue` → UI thread runs `Virt::Ballooning#update` then `layout.update_data` → dirty components repaint.

## Conventions

- **Ruby, no Rails.** Plain classes, `Data.define` for value objects
  (`MemoryUsage`, `System::CpuUsage`, …), Open3 for subprocesses (via
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
