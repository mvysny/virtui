# A config file: what comes after the first step

The first step has landed: `Config` / `Config::Ballooning` (`lib/config.rb`), mapped by
Typemap from `~/.config/virtui/config.toml`, with `raise_at_percent`, `shrink_at_percent` and
`min_actual_gib`. Why it is shaped so is `D_config_file`; how it is wired, `design/architecture.md`
(*Wiring*); what a user writes, README's ballooning section. What is left:

## Later keys

The remaining ballooning tunables README still sends a user to the source for:

- the swap noise floor in `SwapOutRaiseVoter` / `SwapOutShrinkVetoer` (`1.MiB`) and the
  latter's `@veto_seconds = 60`;
- `Virt::BallooningVM`: `@increase_memory_by = 30`, `@decrease_memory_by = 10`,
  `@back_off_seconds = 10`.

Each is one more member of `Config::Ballooning`, unit in the key (`swap_floor_mib`,
`veto_seconds`), its reason moving from the ivar's comment to the `@!attribute` tag, its
value reaching the input as a constructor keyword the way `trigger_at:` does. Not candidates:
the 2 s poll (`bin/virtui`, tied to libvirt's ~5 s balloon refresh), the timeouts in
`VirshSession` / `GuestAgent` / `GuestRootGrow`, and layout constants in `lib/ui/`: internal
mechanics, not user preferences.

## Back-port to pikuri

`../pikuri-tui/lib/shared/config.rb` and `../pikuri-web/lib/pikuri_web/config.rb` each load
`~/.config/pikuri/config.toml` (one file shared by every pikuri app) with `tomlrb` into
`Data.define` value objects, validated by hand: about 850–900 lines each, largely the same
code twice. Typemap would replace the hand-written checks. What differs in situation, not
design: pikuri deep-merges `/etc/xdg` and `~/.config` (a system file holding API keys), has
required keys (Typemap's keyword-without-default), and its sibling apps' tables are
shape-only (`unknown: :ignore` on those). Its schema is shared by three apps, so its classes
would live in a shared gem.

## Open questions

- `Q_default_dump`: how a user sees every key, its default and why without reading source.
  README's commented example is the answer for now, and drifts. `bin/virtui --print-config`
  generating commented TOML would need the reasons at runtime, but they live in YARD, which
  is not loaded then.
- `Q_config_vs_state`: if a key is ever both config (the default) and state (the last
  choice), the state wins, and config only matters on a first run or after clearing state.
  Keep each key in exactly one of the two?
