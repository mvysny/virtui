# Keeping state between runs

State is what virtui remembers for itself: written by the app, never edited by the user.
That decides everything below.

- **No validation.** The app is the only writer, so the file holds what the app wrote. The
  format does not matter either; nobody reads it.
- **Mutable.** The app changes it freely and saves; no copy per change.
- **Fields declared once.** A field and its default live in the constructor and nowhere
  else; `load` and `save` never list them.
- **Version skew is the one thing to handle**, and it is not validation: a newer virtui adds a
  field (missing from an old file → its default), an older one removed a field (in the file,
  no longer in the class → dropped).

Config, which the user does write, is the opposite on every point: `config-file.md`.

## Where it stands

Committed: `lib/state.rb` keeps the System and log panes' visibility as JSON in
`$XDG_STATE_HOME/virtui/state.json` (falling back to `~/.local/state` when the variable is
unset, empty or relative — the XDG spec calls a relative one invalid). `UI::AppLayout` loads it
as it is built and saves it on every show or hide; `spec_helper` points `XDG_STATE_HOME` at a
fresh tmpdir per example. A broken file, or a value not of its type, raises naming the path.
Typemap maps it (`State::MAPPER`), its types read from `sig/virtui.rbs` (`D_types_from_yard`),
so a field is an `attr_accessor`, its YARD `@return` and its default, listed nowhere else.

Still missing against the list above:

- **No thread guard yet** — see *Thread guard*.

**Why JSON:** in the standard library, nothing to add to the Gemfile, and none of YAML's parsing
quirks (YAML 1.1 reads `no` as `false`, `0755` as octal). For a file only the app writes, that
is all the format needs to be.

## What goes in it

- The System and log panes' visibility (`AppLayout`, the `2 2` / `3 3` keys) — the reason it
  exists.
- Candidate: the per-VM ballooning switch (`mb`, `Virt::Ballooning#enabled`), held in memory
  today and lost on restart. A VM whose guest swaps for reasons memory cannot fix gets `mb`
  every run. That makes `State` reachable from `lib/virt/` — see `Q_thread_guard_home`.

## Thread guard

`State` is UI-thread-confined: the app mutates it freely, from the UI thread only. `save`
should check with `Tuile::Screen#check_locked`, which raises `Tuile::Error` off the event-loop
thread (and, before the loop starts, off the thread that built the screen). The `AppLayout`
spec's `Screen.fake` already passes it, as `update_data`'s own `check_locked` shows.

The guard sits on `save`, not on each setter: a setter is one line per field and guarding each
would bring the field list back. Every mutation is followed by a `save`, so an off-thread one
is caught there. See `Q_update_block` for closing that gap.

## Rejected

- **YAML via Psych's object mode** (`YAML.dump(state)`, revived through `init_with`) — no
  gems and nested objects for free, but it still needs hand-written `init_with` code for the
  defaults, writes the class name into the file (`--- !ruby/object:State`), needs
  `permitted_classes` kept in step, and brings YAML's quirks. Typemap does the
  mapping instead, over JSON.
- **TOML** (`tomlrb`, the first version) — needed a gem plus a `racc` Gemfile line (tomlrb 2.0
  depends on racc without saying so), and only parses, so `save` wrote TOML by hand. TOML is
  for files people edit; that is config, not state.
- **Marshal** — binary, and its format is tied to the Ruby version and the class's shape; a
  state file unreadable after a Ruby upgrade is no better than none.
- **dry-struct** — immutable, and its validation buys nothing for a file only the app writes.

## Open questions

- `Q_bad_file` — a state file that fails to parse: log a warning and start from the defaults?
  State only holds remembered preferences, so losing it is harmless, and refusing to start
  over it is the worse failure. This is the one place "errors are loud" should yield; the log
  line keeps it from being silent. Today it raises.
- `Q_update_block` — guard the mutation itself rather than the save:
  `state.update { |s| s.log_pane_visible = false }` checks the thread, yields and saves in one
  call, so a mutation can neither run off-thread nor forget its `save`. Worth it, or is
  `save`'s check enough?
- `Q_thread_guard_home` — `check_locked` makes `State` reference Tuile. Fine while only
  `lib/ui/` uses it (then it could move to `UI::State`). If `Virt::Ballooning` keeps the `mb`
  switch in it, `lib/virt/` would reach Tuile through `State`; the invariant forbids only
  `UI::`, but the backend would no longer be UI-free in spirit. Options: `Virt::Ballooning`
  reports changes through a listener and `lib/ui/` writes them to `State`; or the guard is a
  thread captured at construction rather than Tuile's.
- `Q_save_cost` — `save` writes a file on the UI thread, on a keypress. A few lines of JSON is
  nothing; would only matter if state grows large or saves become frequent (a resize drag).
