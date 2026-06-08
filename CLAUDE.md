# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

- **One constant per file**, named after the path (`lib/virt/virt_cmd.rb` → `VirtCmd`).
  Don't add `require`/`require_relative` for sibling classes — reference the constant and it autoloads.
- **`lib/virt/` is collapsed**, so its files define top-level constants (`VirtCmd`,
  `VirtCache`, `Ballooning`, …) rather than a `Virt::` namespace.
- **`lib/core_ext/` is ignored** by the loader and required manually: it holds the
  `Numeric` byte-unit monkey-patch and the top-level `format_byte_size` helper —
  things that don't define a matching constant.
- Acronym casing (`VMWindow`, `VMEmulator`, `VirTUITheme`, `BallooningVM`) is set
  via `inflector.inflect` in `lib/virtui.rb`; add an entry there for new ones.

## Architecture

VirTUI is a terminal UI for managing KVM/QEMU VMs via libvirt. It has two layers:

**Application layer (`lib/`):** built on the [tuile](https://github.com/mvysny/tuile) TUI gem.
- `AppLayout`: orchestrates three windows — `VMWindow` (VM list/controls), `SystemWindow` (host CPU/RAM/disk), and a log window
- `Ballooning`: auto-scales VM memory (increases by 30% at ≥65% usage, decreases by 10% at ≤55%); runs on the UI thread, must not be called from a background thread

**Libvirt backend (`lib/virt/`):**
- `Virt`/`VirtCmd`: wraps `virsh` CLI commands
- `VirtCache`: thread-safe cache of VM runtime data; `update` is called from a background timer thread
- `VMEmulator`: demo/test mode that simulates VMs without libvirt

**Update flow:** `bin/virtui` runs a `Concurrent::TimerTask` every 2s on a background thread → calls `VirtCache#update` → submits a block to tuile's `EventQueue` → UI thread runs `Ballooning#update` then `layout.update_data` → dirty components repaint.
