# A config file

virtui has no config file. Tuning means editing source: README's ballooning section says so
outright ("At the moment you need to edit virtui sources to configure this").

Config is what the **user** writes and virtui only reads — the opposite of state on every
point (`keeping-state.md`):

- **Validated, loudly.** A typo or a wrong type is the user's mistake and must be reported
  with the file and the key, never silently defaulted around.
- **Immutable.** Loaded once at startup; nothing in the app changes it.
- **Human-friendly format: TOML.** YAML is out for a hand-edited file: indentation is
  syntax, and YAML 1.1 typing turns `no`, `off` and `y` into booleans and `0755` into an
  octal number — the Norway problem. A validator would catch some of that, but TOML never
  produces it.

The aim is a design sound on its own merits, to be back-ported to the pikuri apps
afterwards — not a copy of what they do today (see *pikuri, as a data point*).

Superseded in part: the loader is now `settings-mapper.md` — our own mapper with types from
RBS, annotations or defaults; the first error raises; cross-field rules in the class's own
`validate`. That drops requirements 2 and 4 below and shapes A–C. The search path, what goes in
the file, the errors-before-the-screen rule and the open questions here still stand.

## What a good config loader does

1. **One declaration per key**: its type, its default and the reason for the default,
   together. The reason is the project rule ("a tuning constant carries its reason beside its
   value"); keeping it beside the declaration, not in the voter, keeps it from going stale.
2. **Every error at once**, each with its key path: `ballooning.raise_at_percent: must be an
   integer`, `ballooning.rasie_at: unknown key`. Fix-one-rerun-fix-the-next is the worst part of
   a strict config.
3. **Unknown keys are errors.** A misspelled key silently doing nothing is the classic config
   bug. The cost — an older virtui refusing a newer file — is the right failure: it names the
   key, and the user can see why.
4. **Rules across keys**: `MemLevelRaiseVoter`'s trigger must stay above
   `MemLevelShrinkVoter`'s (AGENTS.md, `D_ballooning_voters`). Per-key types cannot say that.
5. **A missing file or key is the default, silently.** Config is optional.
6. **Fails before the screen exists**: `bin/virtui` loads config before `Tuile::Screen.new`, and
   a bad file ends in the errors on stderr and a non-zero exit. The user just launched virtui
   and is looking at the terminal; starting on defaults would hide that their setting is not in
   effect.
7. **Components get their slice as data**, never the whole `Config` and never a global:
   `Virt::Ballooning` takes a `Config::Ballooning` value, and hands each VM what it needs. That
   is the `cop` rule "domain components take data", it keeps specs free to build a voter with
   any value, and it avoids a second global beside `$log`.
8. **Testable without the filesystem or the real environment**: `load(env: ENV)`, and the
   path is a method, not a constant frozen at `require` time.
9. **Discoverable**: a user can see every key, its default and why, without reading source —
   `Q_default_dump`.

## Candidate shapes

### A — dry-struct alone

```ruby
class Config < Dry::Struct
  transform_keys(&:to_sym)

  class Ballooning < Dry::Struct
    attribute :raise_at_percent, Types::Integer.default(65).meta(why: 'MemLevelRaiseVoter: …')
    attribute :shrink_at_percent, Types::Integer.default(55).meta(why: '…')
    attribute :min_actual_gib, Types::Integer.default(8).meta(why: 'a healthy desktop guest')
  end

  attribute :ballooning, Ballooning.default { Ballooning.new }
end
```

- Meets 1 (type, default and reason via `.meta` on one line), 3 (`schema schema.strict`), 5.
- Misses 2: construction raises on the **first** bad key, and `Dry::Struct::Error`'s message
  is written for a programmer (`"70" (String) has invalid type for :raise_at_percent violates
  constraints (type?(Integer, "70") failed)` — from memory, verify). Misses 4: needs a
  hand-written check after construction.

### B — dry-validation contract, then a value object

```ruby
class Config::Contract < Dry::Validation::Contract
  config.validate_keys = true                # unknown keys are errors
  params do
    optional(:ballooning).hash do
      optional(:raise_at_percent).filled(:integer, gteq?: 0, lteq?: 100)
      optional(:shrink_at_percent).filled(:integer, gteq?: 0, lteq?: 100)
    end
  end
  rule(ballooning: [:raise_at_percent, :shrink_at_percent]) { … }  # the cross-key rule
end
```

- Meets 2 (every error, by key path, in user-facing English: `result.errors.to_h`), 3, 4.
- Misses 1: the contract does not fill defaults, so defaults live in a second declaration (a
  dry-struct or `Data.define`) — every key spelled twice.

### C — dry-struct, plus a thin error collector

dry-struct for the declarations (1, 3, 5); a small loader that walks the schema
(`Config.schema.keys`, each with its type) against the parsed Hash, collecting every
mismatch and unknown key before constructing, then runs the cross-key rules (4). One
declaration, every error — at the price of owning maybe 40 lines that walk dry-types'
introspection API, which must be checked to be public and stable.

Leaning: **spike A first** and look at its real error text. If it reads acceptably once
wrapped as `config.toml: …`, A plus a hand-written cross-key check is the least machinery;
if not, C. B's double declaration is the problem this whole idea started from (state's
"every field listed three times").

## Search path

The XDG Base Directory spec has `$XDG_CONFIG_HOME` (default `~/.config`) and
`$XDG_CONFIG_DIRS` (default `/etc/xdg`), in order of importance. It does not say whether to
merge the files or take the first found; both are compliant.

- **First found wins** — one file is the whole config; "which file set this?" has a
  one-word answer. A user copies the system file and edits it.
- **Deep merge** — a system file sets the host's policy, a user file overrides one key.
  Needs rules for arrays (replace or append?) and for per-VM tables, and a way to tell the
  user which file a value came from.

Leaning: **first found**, `$XDG_CONFIG_HOME` then each `$XDG_CONFIG_DIRS` entry, with the
relative-path rule `State.path` already applies (a relative entry is invalid and skipped).
virtui runs on one person's host; merging earns its rules only once two people configure one
machine — `Q_layers`. Log which file was read, either way.

## What goes in it

The README names the ballooning tunables as what users would change:

- `MemLevelRaiseVoter` `@trigger_at = 65`, `MemLevelShrinkVoter` `@trigger_at = 55`;
- the swap noise floor in `SwapOutRaiseVoter` / `SwapOutShrinkVetoer` (`1.MiB`) and the
  latter's `@veto_seconds = 60`;
- `Virt::BallooningVM`: `@min_actual = 8.GiB`, `@increase_memory_by = 30`,
  `@decrease_memory_by = 10`, the back-off seconds.

Not candidates: the 2 s poll (`bin/virtui`, tied to libvirt's ~5 s balloon refresh), the
timeouts in `VirshSession` / `GuestAgent` / `GuestRootGrow`, and layout constants in
`lib/ui/` — internal mechanics, not user preferences.

## Gems

rubygems.org, 2026-11-01:

- **tomlrb 3.0.0** (2026-10-15) — parse-only, which is all a file the app never writes needs.
  3.0 replaced its Racc grammar with a hand-written parser, so it also drops the `racc`
  Gemfile line the current `State` needs. **toml-rb 6.0.0** (zero dependencies since 6.0)
  writes TOML too, and is needed only if `Q_default_dump` generates a file.
- **dry-struct 1.8.1** (63M downloads, 2026-03) brings dry-types 1.9.1, dry-core, dry-logic,
  dry-inflector, ice_nine, bigdecimal; zeitwerk and concurrent-ruby are already here.
  **dry-validation** (shape B) adds dry-schema, dry-initializer, dry-configurable on top.

Rejected: **YAML** (above). **shale** 1.2.2 — typed mapper with TOML, but 447k downloads in
all and quiet since 2025-03. **activemodel** — drags in activesupport; "Ruby, no Rails".
**json_schemer** — a JSON Schema is a second list of keys beside the code; reopened as a
type source in `settings-mapper.md` (`Q_json_schema`). **representable**
— keys listed again in a decorator. **virtus** — abandoned 2021. **kwalify** — dead since 2011.

## pikuri, as a data point

`../pikuri-tui/lib/shared/config.rb` and `../pikuri-web/lib/pikuri_web/config.rb` each load
`~/.config/pikuri/config.toml` — one file shared by every pikuri app — with `tomlrb` into
`Data.define` value objects, validated by hand: about 850–900 lines each, largely the same
code twice. What it does, set against the list above:

| pikuri today | here | why |
|---|---|---|
| hand-written checks, per key | a declared schema | the 900 lines, twice, are the cost |
| raises on the first error | every error at once (2) | one rerun per typo |
| unknown keys rejected in its own tables, shape-only in a sibling app's | rejected everywhere (3) | virtui shares its file with no one — a difference in situation, not a flaw |
| deep merge of `/etc/xdg` and `~/.config`, arrays replace | first found | merge rules are real complexity; pikuri has a case (a system file holding API keys), virtui does not yet |
| `Config::Error`, rescued by the bin into `warn` + `exit` before the screen | the same (6) | sound as it is |
| resolved values handed to components | a slice as data (7) | the same idea |
| `env:` injectable, paths as methods | the same (8) | sound |
| `EXAMPLE_CONFIG` quoted in the "nothing configured" error | `Q_default_dump` | pikuri has required keys; virtui has none |
| a `[ui]` key sets a toggle's starting value, never written back | `Q_config_vs_state` | — |
| loose-permissions warning for files holding secrets | — | virtui's config holds none |

**For the back-port:** pikuri's config is one schema shared by three apps, so the schema
classes would live in a shared gem, and its sibling-tables-are-shape-only rule stays.

## Open questions

- `Q_needed` — is the ballooning set worth a config file now, or only once a second user
  asks? The README's "edit the sources" line is the case for it.
- `Q_per_vm` — global values only, or per-VM overrides (`[vm."win11".ballooning]`), e.g. a
  lower floor for a small VM? Per-VM is what makes a file beat a constant; resolving a VM's
  values (global merged with its table) then happens once, where `Virt::BallooningVM` is
  built.
- `Q_units` — `min_actual_gib = 8` and `veto_seconds = 60` (unit in the key, plain TOML
  integers), or `min_actual = "8 GiB"` and `veto = "60s"` (a custom dry-types constructor
  parsing units)? The first needs no parser and cannot be misread; the second reads better
  and allows `512 MiB`.
- `Q_error_quality` — spike: what does `Dry::Struct::Error` actually say for a wrong type, a
  nested one, and an unknown key under `schema schema.strict`? Decides A vs C.
- `Q_layers` — first found (leaning) or deep merge?
- `Q_default_dump` — how a user sees every key, default and reason: `bin/virtui
  --print-config` generating commented TOML from the schema's `.meta(why:)` (one source for
  default, reason and documentation; needs `toml-rb` or a hand-written emitter for the
  comments), or a commented example in the README (drifts).
- `Q_config_vs_state` — if a key is ever both config (the default) and state (the last
  choice), the state wins, and config only matters on a first run or after clearing state.
  Keep each key in exactly one of the two?
- `Q_reload` — read once at startup, or reload on a key / file change? Startup-only is the
  simple start; reloading means every component re-reads its slice, which (7) makes harder.
