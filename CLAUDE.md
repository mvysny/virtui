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
- `Window`: bordered widget with a caption; uses `Component::List` as its default content
- `Component::List`: scrollable list of text lines with optional cursor support (arrows, jk, Home/End, Ctrl+U/D, Page Up/Down, mouse); cursor is `Cursor::None` by default, `Cursor::Limited` restricts movement to specific positions
- `EventQueue`: async event handling (keyboard, mouse, TTY resize); background threads submit tasks to the UI thread via `screen.event_queue.submit {}`

**Application layer (`lib/`):**
- `AppLayout`: orchestrates three windows — `VMWindow` (VM list/controls), `SystemWindow` (host CPU/RAM/disk), and a log window
- `Ballooning`: auto-scales VM memory (increases by 30% at ≥65% usage, decreases by 10% at ≤55%); runs on the UI thread, must not be called from a background thread

**Libvirt backend (`lib/virt/`):**
- `Virt`/`VirtCmd`: wraps `virsh` CLI commands
- `VirtCache`: thread-safe cache of VM runtime data; `update` is called from a background timer thread
- `VMEmulator`: demo/test mode that simulates VMs without libvirt

**Update flow:** `bin/virtui` runs a `Concurrent::TimerTask` every 2s on a background thread → calls `VirtCache#update` → submits a block to `EventQueue` → UI thread runs `Ballooning#update` then `layout.update_data` → dirty components repaint.
