# A settings mapper: a Hash onto a class you already wrote

One small library that turns a parsed file (a Hash) into an instance of an ordinary Ruby class
and back, checking types on the way. It serves both `config-file.md` (TOML, read-only,
validated) and `keeping-state.md` (JSON, written by the app, mutable); once config is built on
it, state drops its hand-listed properties for it. Built here first, a gem once pikuri adopts it.

**Named `confect`** (free on rubygems, 2026-11-01): to confect is to prepare something from raw
ingredients — a raw file in, a checked Ruby object served out. Named for the config job rather
than the mapper, since a "mapper" competes with the mappers Ruby already has and a typed config
loader has no rival; `conf` in it says what it is without explanation. Passed over: `settle`
(not about config), `mogok` (the valley the finest rubies come from — poetic, but needs
explaining), `confcierge` (long, easy to misspell), `confirmed` (an everyday word, hard to
search). Taken: `confit`, `conferred`, `confection`, `confiture`, `bedrock`, `lapidary`.
The mapper is **`Confect::Mapper`**, which names what it does; the top-level `Confect` stays
free for the higher-level config loading (*Scope*'s locations layer).

Why not an existing gem: none fits (see *Compared*). The Ruby config gems target Rails-style
ENV + YAML, and the schema libraries (dry-*) bring 3–6 gems and their own class forms. Python
has pydantic, Rust serde, Java Jackson; Ruby has no equivalent of those.

## Scope: the mapper, and optionally where the files live

The gap is wider than the mapper: Ruby has no library that loads **typed config objects from
Linux's standard places** either (*Compared*). Python splits that job into pydantic and
pydantic-settings, Rust into serde, the `config` crate and `directories`; Go has viper. One
gem, two layers:

1. **The mapper, the core.** Hash ↔ object, no runtime dependencies, usable on its own; state
   needs only this.
2. **Locations, optional, built on the mapper**: where an app's files live. Config is read
   from `$XDG_CONFIG_HOME`, then each `$XDG_CONFIG_DIRS` entry, then `/etc/<app>/`; state is
   read from and written to `$XDG_STATE_HOME`; an explicit path always wins. The rules
   (first found or merge, which directories) are `config-file.md`'s; this layer implements
   them.

**Formats by file extension, required lazily**: `.toml` → `tomlrb`, `.json` → `json`, `.yaml` →
`psych`. The gemspec declares none of them; a missing one raises with a hint to add it. tomlrb
only reads, which suits config (read-only) and state (JSON); writing TOML comes in only with
`config-file.md`'s `Q_default_dump`.

**Scope creep is the risk**: config libraries grow env-var and CLI overrides, deep merge,
macOS and Windows paths, reloading on change. The first version holds to first found, XDG
plus `/etc`, Linux only — what virtui and pikuri need — and adds each extra only when a real
app asks for it.

## Settled

- **The mapper defines no class and no accessor.** It works with a data class and with an accessor
  class; mutability is the class's business, not the mapper's.
- **Strict types, no coercion.** `"70"` is not an Integer, `"70a"` is not 70, `70.0` is not 70.
  TOML, JSON and YAML already deliver typed values, so coercion would only hide mistakes.
- **The first error raises**, with its path: `config.toml: ballooning.raise_at_percent:
  expected Integer, got "70"`. Collecting all errors is not worth the machinery.
- **Cross-property rules and anything beyond simple constraints go in the class's own
  `validate`**, which the mapper calls after building the object and which raises on any
  problem. The mapper prefixes its message with the object's path.
- **The file never names a class.** The caller names the root class and the class side
  (`constrain type:` or the RBS strategy) names every nested one; no `json_class` / `!ruby/object` discriminator.
  A user should not have to write one, and a rogue file must not instantiate an arbitrary
  constant — the gadget class behind Psych's `safe_load` and JSON's `create_additions`. A
  property that can hold one of several classes takes a tag the class maps to a closed set of
  classes.
- **The mapper is Hash in, Hash out.** `Tomlrb.load_file`, `YAML.safe_load_file`,
  `JSON.load_file` all hand over a Hash; reading the file by its extension is the optional
  locations layer's job (*Scope*).

```ruby
mapper = Confect::Mapper.new                                          # the type strategy: see Types
config = mapper.load(Config, Tomlrb.load_file(path))                  # unknown keys raise
state  = mapper.load(State, JSON.load_file(path), unknown: :ignore)   # a newer virtui's keys are dropped
mapper.dump(state)                                                    # => plain Hash
```

## How the mapper reads a class

Terms: a class's **properties** are what the mapper loads and dumps, one per key. A **data
class** (`Data.define`) and an **accessor class** (mutable, built from reader + writer pairs)
are the two shapes a class can take; elsewhere it is just "the class".

- **Defaults: the class's own constructor, with no arguments.** `Klass.new` must work bare —
  an empty `initialize`, or a default for every parameter — and that instance is the default;
  each property's default is read back through its getter. Ruby's keyword defaults *are* the
  declaration — nothing is repeated for the mapper.
- **Two shapes, one internal strategy each.** A shape lists a class's properties, reads one off
  an instance, and builds an instance from values:

  | | properties | read | build |
  |---|---|---|---|
  | **data class** (immutable) | `members` | the getter | `new(**defaults.merge(loaded))` |
  | **accessor class** (mutable) | public reader + writer pairs | the getter | bare `new`, then `name=` per loaded key |

  The shape is picked per class, not per mapper — one tree can mix them, an accessor-class
  `State` holding a data-class `Window` — and by a fact, not a guess: `klass < Data`. Shapes are
  internal, with no `shapes:` option until a third one is needed. `Struct` is the likely
  third: its members have public readers and writers, so the accessor rule would find them, but
  their `source_location` is `nil`, so their order must come from `members`.
- **An accessor class's properties are its public reader + writer pairs** — the zero-argument
  Java bean, by Ruby's own means. Only methods are read, never ivars or what `initialize` does:
  a hand-written `def foo` / `def foo=(v)` counts like an `attr_accessor`, inherited and
  mixed-in pairs count, a reader or writer alone does not (`attr_reader :path` stays out), and
  only names matching `/\A[a-z_]\w*=\z/` are writers (not `==`, `[]=`, `<=`). The rule
  ActiveModel's `assign_attributes` already assumes: it `public_send`s `"#{key}="`. An immutable
  plain class with a keyword constructor has readers and no writers, so no properties:
  immutable means a data class.
- **An accessor that is not a setting is left out**: made `private` or `protected` — Ruby's
  own visibility — or, when it must stay public (a listener the app sets from outside),
  named with `ignore :on_change` from `Confect::Constrain`. `ignore` means what
  `unknown: :ignore` means on the file side: the mapper skips it. Not Java's `transient`, an
  abstraction a Rubyist has to look up. A public accessor neither hidden nor ignored has no
  declared type (or, from `sig/`, an unsupported one such as a proc), so the mapper raises when
  it first reads the class: loud, never serialized quietly.
- **No required keys.** A bare `new` means every property has a default, so a missing key is
  never an error — right for state and for an optional config file. (So a `Data` keyword
  without a default is not a way to make a key required: that class cannot be built bare.)
- **Dump order is declaration order.** A data class dumps in `members` order; an accessor class
  sorts by each reader's `instance_method(…).source_location`, which an `attr_accessor` reports
  as its own line. Ruby promises no order for `public_instance_methods` — Ruby 3.3 lists a class
  declaring `b`, `a`, `c` as `[:b, :b=, :a=, :c, :c=, :a]` — and `state.json` should come out
  stable for diffs. Accessors declared on one line tie; ties break by name.
- **Nested objects**: the mapper holds its type strategy, so `load` calls itself for each nested
  Hash whose property's type is a mappable class, handing down the path for error messages
  (`ballooning.raise_at_percent`); `validate` runs bottom-up, nested objects first.
- **Dump** walks the same properties through the getters; a nested object dumps to a Hash.
- **No custom types yet.** A type tells the mapper what a property is, not how a scalar in the
  file becomes that object: `"8 GiB"` is a String in the file and virtui's `Size` in Ruby. That
  needs a conversion (a class with `.load(raw)` and `#dump`, or a registry), and nothing needs
  one while settings carry their unit in the key (`min_actual_gib = 8`). Parked under
  `config-file.md`'s `Q_units`; until then a class that is not mappable raises "unsupported
  type", so nothing is converted quietly.

```ruby
Ballooning = Data.define(:raise_at_percent, :shrink_at_percent, :min_actual_gib) do
  def initialize(raise_at_percent: 65, shrink_at_percent: 55, min_actual_gib: 8) = super

  def validate
    raise 'raise_at_percent must be above shrink_at_percent' unless raise_at_percent > shrink_at_percent
  end
end

class State
  attr_accessor :system_pane_visible, :log_pane_visible

  def initialize
    @system_pane_visible = true
    @log_pane_visible = true
  end
end
```

## Types: declared once, by `constrain` or by the strategy

The mapper takes a **type strategy**, chosen explicitly and never detected: a generic component
takes a strategy. The strategy has two jobs, parsing a `constrain type:` string and supplying a
type that `constrain` does not give:

| strategy | `constrain type:` given | no `constrain type:` |
|---|---|---|
| **no RBS** (`Confect::Mapper::BasicTypes`, the default) | the mapper's own small parser | raises |
| **RBS** (`Confect::Mapper::RBSTypes`, opted into) | `RBS::Parser.parse_type`, translated to the subset | looked up in `sig/*.rbs` |

```ruby
Confect::Mapper.new                                             # no RBS: every property carries constrain type:
Confect::Mapper.new(types: Confect::Mapper::RBSTypes.new)       # sig/*.rbs found from the class's own file
Confect::Mapper.new(types: Confect::Mapper::RBSTypes.new(sig: ['sig/virtui.rbs']))
```

- **The `rbs` gem is optional.** Only `RBSTypes` requires it; choosing it without the gem raises
  with a hint to add it. Without RBS, every type and limit is given through `constrain`.
- **Both strategies accept the same types**, the subset under *What the mapper needs from the
  `rbs` gem*. `RBSTypes` parses full RBS syntax and then rejects what is outside the subset
  with "unsupported type"; `BasicTypes` rejects it while parsing. A spec feeds the same type
  strings to both whenever `rbs` is installed, so the two parsers cannot drift.
- **The default does not supply a type.** `65` is not read as `Integer`: with strict types the
  guess has consequences (a `65` default would reject `65.5` from the file, which the author may
  never have meant), and it could not type `nil`, `[]` or `{}` anyway. Without RBS, `State` then
  needs `constrain :system_pane_visible, :log_pane_visible, type: 'bool'`; with RBS it costs
  nothing, since sord's gate demands a YARD type on every property. The default is still checked
  against the type.

Beyond `type:`, `constrain` only narrows a type (`in:`, `format:`); it never restates it. So the
mapper never has to judge whether `Integer` is "compatible" with `Integer?`. All of these raise
when the mapper first reads the class, not when the key first shows up in a file, since
otherwise the gap hides until some user sets that property:

- **no type**: no `constrain type:`, and the strategy has none either (`BasicTypes` never has);
- **declared twice**: under `RBSTypes`, `sig/` has the property and `constrain` passes `type:` too,
  even when the two match, since a duplicate drifts sooner or later;
- **a default the type rejects**: `String` with default `65`, or `Integer` with default `nil`;
- **a limit the type cannot take**: `in: 1..100` on a `String`.

These can be relaxed once a real use case runs into them, and not before.

**Nil is spelled out, as in RBS.** `type: 'Integer'` does not allow `nil`; `type: 'Integer?'`
does. The type is always an RBS string, never a Ruby class: `type: Integer` would leave a reader
asking whether nil is allowed, and `T.nilable`-style wrappers would be a second type language.
A wrongly non-nil type with a `nil` default raises (*a default the type rejects*), so the slip
shows up at once.

**No `not_nil:` or `required:` yet.** TOML has no null, so a TOML file can only leave a key out,
which means the default. In JSON, `not_nil:` would forbid an explicit `null` on a property whose
type and default both allow it — no known use case. "The file must give this key" would be
`required:`; the bare `new` rules out getting it from a keyword without a default. virtui has
no required key; pikuri has some (`config-file.md`), so `required:` comes with pikuri.

### The RBS strategy: a `sig/*.rbs` file, not inline

RBS is Ruby's own type-signature language; the `rbs` gem ships with Ruby (3.4.0 bundled with
Ruby 3.3; 4.2.0 is current, released 2026-08, 98M downloads, depends on prism, tsort, logger).
virtui would still need a `gem 'rbs'` line in its Gemfile, like `racc` today; it has a native
extension. Ruby 3.3's bundled 3.4 may be enough, if its `parse_signature` matches 4.2's —
unverified. `RBSTypes` reads only signature files. RBS 4.0's **inline** declarations (`attr_accessor :last_vm #: String?`)
are left out. They are still marked experimental, and they are awkward for a `Data` class:
`Ballooning = Data.define(…)` is a constant to the inline parser, not a class with attributes.

**Where the file comes from is the project's business.** tuile writes its `sig/tuile.rbs`
with **sord** (7.1.0), which turns YARD tags into RBS; a project that already has YARD on every
public symbol, as virtui does, gets the file almost for free. tuile's machinery:

- `rake sig:generate` runs `sord gen sig/tuile.rbs --rbs --regenerate` and fails on any
  `[OMIT|INFER|WARN|ERROR]` line, so a missing YARD type breaks the build instead of becoming
  `untyped`;
- `rake sig:validate` runs `rbs validate`;
- CI fails on `git diff --exit-code sig/`, so a stale file cannot be merged.

A `Data` class is typed with YARD's `@!attribute` directive; sord turns tuile's

```ruby
# @!attribute [r] width
#   @return [Integer] width.
class Size < Data.define(:width, :height)
```

into `attr_reader width: Integer`. A `Data.define` member without `@!attribute` never reaches
the file. sord and YARD are dev dependencies of the project, never of the mapper.

#### Producing `sig/virtui.rbs`

tuile's machinery, copied:

1. **Dev gems**: `sord` (`~> 7.1`, as tuile) and `rbs`.
2. **Rake**: `sig:generate` runs `sord gen sig/virtui.rbs --rbs --regenerate`; `sig` joins
   `rake check`.
3. **CI**: `git diff --exit-code sig/`.

Spiked 2026-11-01, tuile's sord over virtui, written outside the repo: it exits 0 and writes a
250 KB file, but tuile's no-warnings gate would fail it:

- **88 `[OMIT]`, missing YARD types**: 77 `@return`s, mostly on constants (`UI::Tint::DELTA`),
  and 11 `@param` types (`text:`, `severity:`, …). Real gaps; fill them.
- **77 `[WARN]`, constants sord cannot resolve.** 72 name other gems (`Tuile::Color` ×28,
  `REXML::Element` ×18, `Tuile::StyledString` ×7, …): sord sees only this project's YARD, and
  writes the names out correctly anyway. 5 are virtui's own `Size` and `Fraction`, not yet looked
  into.

So virtui's gate fails on any `OMIT`, and on an unresolved name unless it lies in another gem's
namespace. Some of virtui's 37 `Data.define` classes may still lack `@!attribute` (22 files have
it); each shows up as a missing property in the file. **`rbs validate` waits**: it would need the
other gems' signatures (`rbs collection` for tuile and REXML), and the mapper only parses the
file, it never validates it.

#### Reading it: `Klass#property` → a type

1. **Find the files.** Start from the file that defines the class (`Module.const_source_location
   (klass.name)`), walk up to the first directory holding `sig/`, read its `sig/**/*.rbs`. That
   is the standard place, works for an app and for an installed gem (tuile's gemspec ships
   `sig/tuile.rbs`), and does not depend on the directory `bin/virtui` is started from. A list
   of paths handed to `RBSTypes` overrides it. No `sig/` found raises: the project asked for
   RBS.
2. **Parse and index.** Each file is parsed once per process with
   `RBS::Parser.parse_signature`; the declarations are walked recursively and indexed by full
   name (`UI::CpuFlagsDialog`). A class declared in several places keeps all its declarations.
3. **Find the property.** Walk `klass.ancestors`; in each one's declarations, look for
   `attr_reader` / `attr_accessor <property>`, or a zero-argument `def <property>: () -> T`. The first
   hit is the RBS type. The getter is what counts, since the mapper reads properties through
   getters; `initialize`'s keyword types are ignored. Two different types for one property raise
   (*declared twice*).
4. **Resolve the names in the type.** `::Set` is absolute: `Object.const_get`. A relative `Size`
   follows Ruby's lexical lookup from the declaring namespace outward (`UI::Foo::Size`,
   `UI::Size`, `Size`). Built-ins go to the mapper's own checks; any other class must be
   mappable, or it raises `unsupported type at sig/virtui.rbs:LINE`. **Qualified names are
   allowed, not required**: `Integer` and `String` are relative too, and sord writes names as
   YARD has them (`Size`, `Tuile::Color`, `::Set`). The lookup is the one Ruby itself does in the
   code beside it, so the mapper never resolves a name differently: a bare `Size` inside `UI`
   means what it means there, virtui's byte `Size` or tuile's width × height `Tuile::Size`, and
   `Tuile::Size` or `::Size` makes the choice explicit.
5. **`constrain type:`** strings go through `RBS::Parser.parse_type` and the same lookup, from
   the class's own namespace. `BasicTypes` resolves names in its own parsed strings the same
   way.

Spiked 2026-11-01, steps 2–3 in 30 lines, each result with its line for the error message:

```
UI::CpuFlagsDialog#flags: ::Set[String]   virtui's generated file, line 1612
Tuile::Size#width:        Integer         sig/tuile.rbs, line 299
Tuile::Size#empty?:       bool            sig/tuile.rbs, line 281
```

What the mapper needs from the `rbs` gem, read in `rbs-4.2.0`'s source:

- **The types, without loading the RBS environment.** `RBS::Parser.parse_signature(source)`
  parses on its own, and `RBS::Parser.parse_type("Integer?")` parses a `constrain` type string.
  Measured: tuile's 870 KB `sig/tuile.rbs` parses in about 58 ms.
- **Not RBS's own runtime checker.** `RBS::Test::TypeCheck#value(val, type)` exists, but its
  constructor wants a `DefinitionBuilder`, i.e. the whole environment, core signatures
  included. The mapper translates RBS's type AST into its own type objects instead, for a
  small subset — the same subset `BasicTypes` parses with a few dozen lines of recursive
  descent: `Integer`, `Float`, `String`, `bool`, `T?` (nil allowed), `Array[T]`,
  `Hash[String, T]`, literal unions (`"short" | "verbose"`, which give enums for free), and
  mappable classes. Anything else raises "unsupported type".

### Annotations

What Rails does, for inspiration:

- **ActiveModel::Attributes**: `attribute :age, :integer, default: 0` — a type from a symbol
  registry (`:string`, `:boolean`, `:decimal`, `:datetime`), and *lenient* casting: `"70"`
  becomes 70. The opposite of what we want.
- **ActiveModel::Validations**, kept apart from the types:
  `validates :age, numericality: { only_integer: true, greater_than_or_equal_to: 0 }`,
  `inclusion: { in: %w[short verbose] }`, `format: { with: /\A…\z/ }`, `length: { maximum: 20 }`,
  `presence: true`, `allow_nil: true`; and `validate :method_name` for the rest. One macro can
  name several fields: `validates :a, :b, numericality: true`.
- **ActiveRecord `enum`** — a fixed set of values.
- And sorbet-runtime's `T::Struct`: `prop :count, Integer, default: 0` (mutable),
  `const :name, String` (immutable), `T.nilable(Integer)`, `T::Array[String]` — the type
  beside the field, with mutability chosen per field.

Proposal — a macro that records metadata only, defining no accessor:

```ruby
Ballooning = Data.define(:raise_at_percent, :shrink_at_percent, :min_actual_gib, :pinned_vms) do
  extend Confect::Constrain

  # without RBS; under RBSTypes the type: arguments move to sig/ and only the limits stay
  constrain :raise_at_percent, :shrink_at_percent, type: 'Integer', in: 1..100
  constrain :min_actual_gib, type: 'Integer', in: 1..
  constrain :pinned_vms, type: 'Array[String]'

  def initialize(raise_at_percent: 65, shrink_at_percent: 55, min_actual_gib: 8, pinned_vms: []) = super
end
```

- **`type:` is an RBS type string**, so the mapper speaks one type language whether the type
  came from RBS or from an annotation; the strategy parses it.
- **Constraints, a deliberately small set**: `in:` (a Range — `0..` is "0 or greater" — or an
  Array of allowed values) and `format:` (a Regexp, for strings). Everything else is
  `validate`.
- Without RBS every property gets a `constrain` line, for its type at least; under `RBSTypes`
  only a property with limits does.
- **Named `constrain`**: the line adds limits to a property the class already declares, and a type
  is the strictest limit. Not `setting`, since every property is a setting, annotated or not.
  Not a macro named `property`, since sorbet's `prop` and Rails' `attribute` both define the
  accessor; the noun stays for what the mapper loads and dumps. Not
  `validate`, since that is the class's own cross-property hook, and Rails' `validate :foo`
  registers the method `foo`.
- **`constrain` does not define the accessor**, though Rails' `attribute` does. On a `Data` class
  the reader exists and the instance is frozen, so a generated writer would raise
  `FrozenError`. Once the macro owns the property, `default:` follows, then a generated
  `initialize`, and it has become dry-struct or `T::Struct`: a class form the mapper imposes. A
  metaprogrammed accessor is also invisible to RBS, Steep, the IDE and YARD; this project wants
  YARD on every public method. The one-line form already exists in standard Ruby:
  `attr_accessor :last_vm #: String?`.

Settled: the `constrain` macro, not a plain constant the mapper reads (`CONSTRAINTS = {
min_actual_gib: { type: 'Integer', in: 1.. } }`). A map of maps has no type safety. The macro
carries YARD a reader or an LLM agent follows, and it rejects an unknown option (`in_:`) the
moment the class loads. It also works in both `Data` styles: a constant written inside a
`X = Data.define(…) do … end` block lands in the enclosing scope, not in `X`, silently even
under `-W`, so the constant would only work with `class X < Data.define(…)`. The macro's cost
is that the class references the mapper.

### Later, perhaps: JSON Schema as an alternative to `constrain`

Settled: the mapper starts with `constrain`. A JSON Schema may come later as a second way to
give the same types and limits; it is not the first one built.

A JSON Schema file beside the `Data` classes, checked with **json_schemer** before the mapper
runs — a third type strategy. The classes stay as they are, with their YARD and `validate`.
The mapper still turns the Hash into objects, nested ones included. It only stops checking
types, because the schema has already checked them. JSON Schema has no notion of a Ruby class,
so the schema must name the class of each nested object: a custom keyword (`"x-ruby-class":
"Ballooning"`) or a convention mapping `$defs/Ballooning` to `Ballooning`. The schema ships with the app, not with the user's file, so this keeps *the file
never names a class*.

Spiked with json_schemer 2.5.0 (2026-11-01):

```
"70"                    → value at `/ballooning/raise_at_percent` is not an integer
170                     → number at `/ballooning/raise_at_percent` is greater than: 100
mode: "x"               → value at `/ballooning/mode` is not one of: ["short", "verbose"]
rasie: 1                → object property at `/ballooning/rasie` is a disallowed additional property
70.0                    → passes: JSON Schema's `integer` is any number with no fraction (draft-06 on)
```

- **For:** it reports every error at once (requirement 2 of `config-file.md`, which this mapper
  drops). Types, ranges, enums, nullable fields, arrays and unknown keys are standard keywords,
  so RBS, `constrain` and our own type-AST subset go away. TOML editors get completion
  and checking from it: Taplo and Tombi validate TOML against a JSON Schema named in a top
  `#:schema ./virtui.schema.json` comment, or found through SchemaStore.
- **Against:** every key is listed twice, once in the class and once in the schema; a spec
  comparing `members` with `properties` catches drift, but cannot stop it. A JSON Schema is
  verbose to write by hand for what one `constrain` line says. The cross-property rule and
  custom types (`"8 GiB"`) stay in `validate` and the mapper either way. `70.0` passes as an
  Integer, which needs a check of our own. It adds four runtime gems: hana, regexp_parser,
  simpleidn and bigdecimal.
- **TOML:** JSON Schema checks the parsed data model, not the syntax, so a `Tomlrb` Hash is
  checked like a JSON one. TOML's date and time values have no JSON type; what json_schemer does
  with a Ruby `Time` is unverified. A TOML-native schema exists only as a proposal:
  [toml-schema.org](https://github.com/brunoborges/toml-schema), with the schema itself written in
  TOML. toml-lang has not adopted it (toml-lang#116, #792), and no Ruby implementation is known.

## Compared

- **sorbet-runtime `T::Struct`** (0.6.13612, 158M downloads, no runtime dependencies, released
  2026-10-31): the closest existing thing — typed fields, defaults, per-field mutability,
  nested structs, `from_hash` / `from_hash!` (the bang raises on unknown keys) and `serialize`.
  But it *is* the class form (`< T::Struct` or `include T::Props`), so no `Data`, no plain
  class; a required prop missing from the Hash is not an error but recorded and left `nil`
  (`required_prop_missing_from_deserialize`), which config cannot accept; and it carries
  Stripe's ODM history (`dont_store`, `redaction`, `chalk-odm` warnings). Whether `from_hash`
  type-checks the values at all is unverified — `Q_sorbet_from_hash`.
- **dry-struct / dry-validation / dry-configurable, hashie, anyway_config, shale,
  activemodel** — weighed in `config-file.md`: each either brings its own class form, gem
  family or lenient casting.

For the locations layer, from rubygems on 2026-11-01:

- **tty-config** (0.6.0, last released 2022-06-18, 0.9M downloads, no runtime dependencies):
  the closest prior art — YAML, JSON, TOML, INI, a search path, env vars, read and write, built
  for terminal tools. But Hash-based (`config.fetch('a', 'b')`), no typed objects, no XDG
  unless the app appends the paths itself, and dormant.
- **anyway_config** (2.9.1, 36M downloads, depends on ruby-next-core): twelve-factor, env
  first, YAML under `config/`; shaped for Rails apps.
- **config** (5.6.1, 60M downloads, depends on deep_merge, ostruct): multi-environment
  `settings.yml`, Rails conventions, untyped.
- **xdg** (10.4.0, 2.2M downloads, no runtime dependencies): the XDG Base Directory paths only,
  no loading, no types. A dependency the locations layer could take rather than re-derive the
  spec.

## Open questions

- `Q_sorbet_from_hash` — does `T::Struct.from_hash` type-check values, or assign blindly? Only
  matters if `T::Struct` comes back as a candidate.
