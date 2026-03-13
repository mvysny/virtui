# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
bundle exec rake spec             # Run all tests
bundle exec rspec spec/path/to_spec.rb          # Run a single spec file
bundle exec rspec spec/path/to_spec.rb:LINE     # Run a specific test by line number
bundle exec rubocop               # Lint
```

## Architecture

VirTUI is a terminal UI for managing KVM/QEMU VMs via libvirt. It has three layers:

**TUI Framework (`lib/ttyui/`)** — a custom terminal UI toolkit:
- `Screen`: main event loop, window management, rendering
- `Component`: base class for all UI elements; forms a tree hierarchy with parent/child relationships and an invalidation model (mark dirty → batched repaint)
- `Window`: scrollable bordered widget with captions and cursor support
- `EventQueue`: async event handling (keyboard, mouse, TTY resize); background threads submit tasks to the UI thread via `screen.event_queue.submit {}`

**Application layer (`lib/`):**
- `AppLayout`: orchestrates three windows — `VMWindow` (VM list/controls), `SystemWindow` (host CPU/RAM/disk), and a log window
- `Ballooning`: background thread that auto-scales VM memory (increases by 30% at >70% usage, decreases by 10% below 60%)

**Libvirt backend (`lib/virt/`):**
- `Virt`/`VirtCmd`: wraps `virsh` CLI commands
- `VirtCache`: thread-safe cache that refreshes VM data every 2 seconds; updates are pushed to UI via `event_queue.submit`
- `VMEmulator`: demo/test mode that simulates VMs without libvirt

**Update flow:** `VirtCache` polls libvirt every 2s → `Ballooning` adjusts memory → submits a block to `EventQueue` → UI thread calls `layout.update_data` → dirty components repaint.
