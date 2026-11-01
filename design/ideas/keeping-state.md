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

Where it stands: the working tree has a hand-rolled TOML `State` (`lib/state.rb`, `tomlrb` 2.0 +
a `racc` Gemfile line) that lists every field in `load` and `save`. The `UI::AppLayout` wiring
(load on build, save on every show/hide) and `spec_helper`'s per-example `XDG_STATE_HOME`
tmpdir stay; only `State`'s insides change.

## What goes in it

- The System and log panes' visibility (`AppLayout`, the `2 2` / `3 3` keys) — the reason it
  exists.
- Candidate: the per-VM ballooning switch (`mb`, `Virt::Ballooning#enabled`), held in memory
  today and lost on restart. A VM whose guest swaps for reasons memory cannot fix gets `mb`
  every run. That makes `State` reachable from `lib/virt/` — see `Q_thread_guard_home`.

## Proposal — YAML via Psych's object mode (stdlib)

```ruby
class State
  attr_accessor :system_pane_visible, :log_pane_visible

  # The defaults; every instance variable set here is a saved field.
  def initialize
    @system_pane_visible = true
    @log_pane_visible = true
  end

  def self.load
    return new unless File.exist?(path)

    YAML.safe_load_file(path, permitted_classes: [State])
  end

  # Psych calls this instead of setting the ivars itself, which would skip initialize and
  # leave a field missing from the file nil.
  def init_with(coder)
    initialize
    coder.map.each do |key, value|
      name = :"@#{key}"
      instance_variable_set(name, value) if instance_variable_defined?(name)  # else: a removed field
    end
  end

  def save
    Tuile::Screen.instance.check_locked
    write_atomically(YAML.dump(self))
  end
end
```

```yaml
--- !ruby/object:State
system_pane_visible: true
log_pane_visible: false
```

- **No gems**: `tomlrb` and the `racc` line go away (unless `config-file.md` brings `tomlrb` back).
- **Nested objects and collections cost nothing**: a nested object is revived by its own
  class, with its own `init_with` if it has defaults. Each class in the file must be in
  `permitted_classes`; leaving one out raises `Psych::DisallowedClass`, loudly.
- **The class tag in the file** is acceptable: these classes live under `State::` and do not
  get renamed. A rename would make old files unloadable.
- **Every ivar is saved**: a cached value added to `State` lands in the file. Say so in the
  constructor's doc.
- Symbols need `Symbol` in `permitted_classes` too; keep values plain.
- Path: `$XDG_STATE_HOME/virtui/state.yaml`, falling back to `~/.local/state` when the
  variable is unset, empty or relative (the XDG spec calls a relative one invalid) — as the
  current `State.path` does.

## Thread guard

`State` is UI-thread-confined: the app mutates it freely, from the UI thread only. `save`
checks with `Tuile::Screen#check_locked`, which raises `Tuile::Error` off the event-loop thread
(and, before the loop starts, off the thread that built the screen). The `AppLayout` spec's
`Screen.fake` already passes it, as `update_data`'s own `check_locked` shows.

The guard sits on `save`, not on each setter: a setter is one line per field and guarding each
would bring the field list back. Every mutation is followed by a `save`, so an off-thread one
is caught there. See `Q_update_block` for closing that gap.

## Rejected

- **Marshal** — binary, and its format is tied to the Ruby version and the class's shape; a
  state file unreadable after a Ruby upgrade is no better than none.
- **Hand-rolled ivar ↔ Hash over JSON** — fine for flat primitives; nested objects are exactly
  the per-class parsing this avoids.
- **dry-struct** — immutable, and its validation buys nothing for a file only the app writes.
  It is the proposal for config instead.
- The hand-rolled TOML now in the working tree — every field listed three times.

## Open questions

- `Q_bad_file` — a state file that fails to parse: log a warning and start from the defaults?
  State only holds remembered preferences, so losing it is harmless, and refusing to start
  over it is the worse failure. This is the one place "errors are loud" should yield; the log
  line keeps it from being silent.
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
- `Q_save_cost` — `save` writes a file on the UI thread, on a keypress. Two lines of YAML is
  nothing; would only matter if state grows large or saves become frequent (a resize drag).
