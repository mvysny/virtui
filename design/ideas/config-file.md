# A config file

virtui has no config file. Tuning means editing source: README's ballooning section says so
outright ("At the moment you need to edit virtui sources to configure this").

Config is what the **user** writes and virtui only reads, the opposite of state on every
point (`keeping-state.md`):

- **Validated, loudly.** A typo or a wrong type is the user's mistake and must be reported
  with the file and the key, never silently defaulted around.
- **Immutable.** Loaded once at startup; nothing in the app changes it.
- **Human-friendly format: TOML.** YAML is out for a hand-edited file: indentation is
  syntax, and YAML 1.1 typing turns `no`, `off` and `y` into booleans and `0755` into an
  octal number (the Norway problem). A validator would catch some of that, but TOML never
  produces it.

The aim is a design sound on its own merits, to be back-ported to the pikuri apps
afterwards, not a copy of what they do today (see *pikuri, as a data point*).

## Decided (2026-11-01)

- **Needed now**, starting small: the infrastructure plus three keys, `raise_at_percent`,
  `shrink_at_percent` and `min_actual_gib`. The rest of the tunables follow once it stands.
- **The mapping is Typemap** (`../typemap`, its README), the gem `State` already uses; types
  come from RBS (`sig/virtui.rbs`, written by `rake sig` from the YARD tags), limits from
  `constrain`, the cross-key rule from the class's own `validate`. Finding and reading the
  file stay virtui's.
- **Global values only**, no per-VM tables (`Q_per_vm`: no). Reopen when one VM needs a
  different floor or trigger than the rest.
- **Plain integers, the unit in the key** (`Q_units`): `min_actual_gib = 8`, later
  `veto_seconds = 60`. No unit parser, nothing to misread; Typemap's custom types
  (`../typemap/design/ideas/custom-types.md`) stay parked.
- **First found wins** (`Q_layers`): `$XDG_CONFIG_HOME/virtui/config.toml`, then each
  `$XDG_CONFIG_DIRS` entry's (default `/etc/xdg`), skipping a relative entry as `State.path`
  does. One file is the whole config, so "which file set this?" has a one-word answer. Merging
  earns its rules (arrays, per-VM tables, where a value came from) only once two people
  configure one machine.
- **Read once at startup** (`Q_reload`). Reloading would mean every component re-reads its
  slice, which handing slices out as data (below) makes harder, for little gain on a tool
  that restarts in a second.
- **The first error raises; one fix per run** (`Q_error_quality`). Typemap's messages carry
  the key path and the offending value (*Error quality*, below), which is enough for a file
  of a few keys.

## The first step

### The class

`lib/config.rb` and `lib/config/ballooning.rb`, top-level beside `State` (one constant per
file, as Zeitwerk wants):

```ruby
# @!attribute [r] ballooning
#   @return [Config::Ballooning]
class Config < Data.define(:ballooning)
  def initialize(ballooning: Ballooning.new) = super
end

# @!attribute [r] raise_at_percent
#   @return [Integer] guest memory use, in percent, at or above which the guest grows. 65
#     leaves a 35% reserve, where MoM, Hyper-V and K8s VPA all use 15-20%; …
# @!attribute [r] shrink_at_percent
#   @return [Integer] … at or below which it shrinks
# @!attribute [r] min_actual_gib
#   @return [Integer] the floor a guest is never shrunk below, in GiB; 8 is a healthy
#     desktop guest. A smaller VM floors at half its maximum instead.
class Config::Ballooning < Data.define(:raise_at_percent, :shrink_at_percent, :min_actual_gib)
  extend Typemap::Constrain

  constrain :raise_at_percent, :shrink_at_percent, in: 1..100
  constrain :min_actual_gib, in: (1..)

  def initialize(raise_at_percent: 65, shrink_at_percent: 55, min_actual_gib: 8) = super

  # Both voters firing on one sample makes the VM hunt (D_ballooning_voters).
  def validate
    return if raise_at_percent > shrink_at_percent

    raise "raise_at_percent (#{raise_at_percent}) must be above shrink_at_percent (#{shrink_at_percent})"
  end
end
```

- **One place per key**: type and reason in the `@!attribute` tag, default in `initialize`,
  limits in `constrain`, all in the one class. The reasons now beside `@trigger_at = 65`,
  `@trigger_at = 55` and `@min_actual = 8.GiB` move here, so they stay next to the value they
  justify.
- **The AGENTS.md invariant becomes enforced**: "`MemLevelRaiseVoter`'s trigger stays above
  `MemLevelShrinkVoter`'s" is today kept by a comment ("nothing enforces that but this line");
  `validate` makes a file that breaks it fail to load. The invariant's line then cites
  `Config::Ballooning#validate`.
- Check that sord types a `class X < Data.define(…)` from `@!attribute` as Typemap's README
  says; `rake sig` fails loudly if not.

### Loading

`Config.load(env = ENV)`, shaped like `State.load`:

- `Config.path(env)`: the first existing file on the search path above, or `nil`. A method
  taking `env`, not a constant frozen at `require` time, so specs point it at a temp dir.
- No file: `Config.new`, the defaults, silently. Config is optional.
- A file: `MAPPER.load(Config, Tomlrb.load_file(path))` with the default `unknown: :raise`,
  so a misspelled key fails instead of silently doing nothing. The cost, an older virtui
  refusing a newer file, is the right failure: it names the key.
- `Tomlrb::ParseError` and `Typemap::DataError` become a `Config::Error` prefixed with the
  path: `~/.config/virtui/config.toml: ballooning.raise_at_percent: expected Integer, got "70"`.
- Logs which file it read, at info.

### Failing before the screen

`bin/virtui` loads config right after `$log` exists, before the `virsh` session and
`Tuile::Screen.new`. A `Config::Error` ends in `$log.fatal(e.message)` (stderr while there is
no screen) and `exit 1`. The user just launched virtui and is looking at the terminal;
starting on defaults would hide that their setting is not in effect.

### Components get their slice as data

Never the whole `Config`, never a global beside `$log`: `Virt::Ballooning.new(virt_cache,
config.ballooning)` hands the slice to each `BallooningVM`, which sets `@min_actual =
config.min_actual_gib.GiB` and builds `MemLevelRaiseVoter.new(trigger_at:
config.raise_at_percent)` and its shrink twin. That is the `cop` rule "domain components take
data", and it keeps specs free to build a voter with any value.

### Gem

**tomlrb 3.0.0** (2026-10-15), parse-only, which is all a file the app never writes needs.
3.0 replaced its Racc grammar with a hand-written parser; check its `ParseError` text when
adding it (only 2.0.4 is installed locally). **toml-rb** writes TOML too, and is needed only
if `Q_default_dump` generates a file.

### Specs and docs

- `spec/config_spec.rb`: no file gives the defaults; first found wins; a relative
  `XDG_CONFIG_DIRS` entry is skipped; a wrong type, an out-of-range value, an unknown key, the
  cross-key rule and a TOML syntax error each raise `Config::Error` naming the file and the key.
- README: the "edit virtui sources" line becomes a short config section listing the three
  keys, their defaults and the search path.
- Graduation lands in `design/decisions.md` (TOML over YAML, first found, startup-only, the
  slice as data) and `design/architecture.md` (where config is loaded and how it flows).

## Error quality

The spike (2026-11-01: `Config` / `Config::Ballooning` as above, typed from RBS, loaded from
Hashes) gave:

```
ballooning.raise_at_percent: expected Integer, got "70"
ballooning.raise_at_percent: expected Integer, got 70.5
ballooning.raise_at_percent: 170 is not in 1..100
ballooning.min_actual_gib: 0 is not in 1..
ballooning.rasie_at_percent: unknown key; Config::Ballooning has raise_at_percent, shrink_at_percent, min_actual_gib
balooning: unknown key; Config has ballooning
ballooning: expected Config::Ballooning, got 5
ballooning: raise_at_percent (50) must be above shrink_at_percent (55)
```

Every message names the key path and the value, so this is good enough to ship. Three
things fall short of top notch: Ruby class names where the file needs a table, Ruby range
syntax (`1..`), and no "did you mean" for a misspelled key. They are Typemap's to fix, filed as
`../typemap/design/ideas/error-messages.md`; virtui needs no change when they land, beyond
whatever its specs match on.

## Later keys

The README names the remaining ballooning tunables as what users would change:

- the swap noise floor in `SwapOutRaiseVoter` / `SwapOutShrinkVetoer` (`1.MiB`) and the
  latter's `@veto_seconds = 60`;
- `Virt::BallooningVM`: `@increase_memory_by = 30`, `@decrease_memory_by = 10`,
  `@back_off_seconds = 10`.

Each is one more member of `Config::Ballooning`, unit in the key. Not candidates: the 2 s poll
(`bin/virtui`, tied to libvirt's ~5 s balloon refresh), the timeouts in `VirshSession` /
`GuestAgent` / `GuestRootGrow`, and layout constants in `lib/ui/`: internal mechanics, not
user preferences.

## pikuri, as a data point

`../pikuri-tui/lib/shared/config.rb` and `../pikuri-web/lib/pikuri_web/config.rb` each load
`~/.config/pikuri/config.toml` (one file shared by every pikuri app) with `tomlrb` into
`Data.define` value objects, validated by hand: about 850–900 lines each, largely the same
code twice.

| pikuri today | here | why |
|---|---|---|
| hand-written checks, per key | Typemap, types from RBS | the 900 lines, twice, are the cost |
| raises on the first error | the same | one rerun per typo is fine for a few keys |
| unknown keys rejected in its own tables, shape-only in a sibling app's | rejected everywhere | virtui shares its file with no one: a difference in situation, not a flaw |
| deep merge of `/etc/xdg` and `~/.config`, arrays replace | first found | pikuri has a case (a system file holding API keys), virtui does not |
| `Config::Error`, rescued by the bin before the screen | the same | sound as it is |
| resolved values handed to components | a slice as data | the same idea |
| `env:` injectable, paths as methods | the same | sound |
| `EXAMPLE_CONFIG` quoted in the "nothing configured" error | `Q_default_dump` | pikuri has required keys; virtui has none |
| a `[ui]` key sets a toggle's starting value, never written back | `Q_config_vs_state` | n/a |
| loose-permissions warning for files holding secrets | none | virtui's config holds none |

**For the back-port:** pikuri's config is one schema shared by three apps, so its classes
would live in a shared gem, and its sibling-tables-are-shape-only rule (`unknown: :ignore` on
the sibling's tables) stays.

## Open questions

- `Q_default_dump`: how a user sees every key, its default and why without reading source.
  `bin/virtui --print-config` generating commented TOML from the YARD text (one source, but
  YARD is not loaded at runtime and the emitter is ours), or the README's list (drifts, but
  is the first step's answer anyway).
- `Q_config_vs_state`: if a key is ever both config (the default) and state (the last
  choice), the state wins, and config only matters on a first run or after clearing state.
  Keep each key in exactly one of the two?
