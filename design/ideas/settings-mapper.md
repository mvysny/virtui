# A settings mapper: a Hash onto a class you already wrote

One small library that turns a parsed file (a Hash) into an instance of an ordinary Ruby class
and back, checking types on the way. It serves both `config-file.md` (TOML, read-only,
validated) and `keeping-state.md` (JSON, written by the app, mutable); once config is built on
it, state drops its hand-listed fields for it. Built here first, a gem once pikuri adopts it.

Why not an existing gem: none fits (see *Compared*). The Ruby config gems target Rails-style
ENV + YAML, and the schema libraries (dry-*) bring 3–6 gems and their own class shapes. Python
has pydantic, Rust serde, Java Jackson; Ruby has no equivalent of those.

## Settled

- **The mapper defines no class and no accessor.** It works with a `Data` class and with a plain
  class with `attr_accessor`s; mutability is the class's business, not the mapper's.
- **Strict types, no coercion.** `"70"` is not an Integer, `"70a"` is not 70, `70.0` is not 70.
  TOML, JSON and YAML already deliver typed values, so coercion would only hide mistakes.
- **The first error raises**, with its path: `config.toml: ballooning.raise_at_percent:
  expected Integer, got "70"`. Collecting all errors is not worth the machinery.
- **Cross-field rules and anything beyond simple constraints go in the class's own
  `validate`**, which the mapper calls after building the object and which raises on any
  problem. The mapper prefixes its message with the object's path.
- **The file never names a class.** The caller names the root class and the class side
  (`constrain type:` or the RBS strategy) names every nested one; no `json_class` / `!ruby/object` discriminator.
  A user should not have to write one, and a rogue file must not instantiate an arbitrary
  constant — the gadget class behind Psych's `safe_load` and JSON's `create_additions`. A field
  with several shapes takes a tag the class maps to a closed set of classes.
- **Hash in, Hash out.** The file format is the caller's: `Tomlrb.load_file`,
  `YAML.safe_load_file`, `JSON.load_file` all hand over a Hash.

```ruby
mapper = Mapper.new                                                   # the type strategy: see Types
config = mapper.load(Config, Tomlrb.load_file(path))                  # unknown keys raise
state  = mapper.load(State, JSON.load_file(path), unknown: :ignore)   # a newer virtui's keys are dropped
mapper.dump(state)                                                    # => plain Hash
```

## How the mapper reads a class

- **Defaults: the class's own constructor.** `Klass.new` with no arguments is the default
  instance; each field's default is read back through its getter. Ruby's keyword defaults *are*
  the declaration — nothing is repeated for the mapper.
- **Fields:** a `Data` class's `members`; otherwise the constructor's keyword parameters; and
  for a class whose `initialize` takes none, the instance variables a bare `new` sets (the rule
  `keeping-state.md` already uses: every ivar set in `initialize` is a setting).
- **Building the result**, by what the class offers:
  - keyword constructor (`Data`, or an immutable plain class): `new(**defaults.merge(loaded))`;
  - setters (a mutable class): `new`, then `field=` for each loaded key.
- **Nested objects** are mapped recursively when a field's type is itself a mappable class;
  `validate` runs bottom-up, nested objects first.
- **Dump** walks the same fields through the getters; a nested object dumps to a Hash.
- **Custom types** (virtui's `Size` for `"8 GiB"`, a `Duration` for `"60s"`) are any class with
  `.load(raw)` and `#dump` — `Q_custom_types`.

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
| **no RBS** (`Mapper::BasicTypes`, the default) | the mapper's own small parser | raises |
| **RBS** (`Mapper::RBSTypes`, opted into) | `RBS::Parser.parse_type`, translated to the subset | looked up in `sig/*.rbs` |

```ruby
Mapper.new                                     # no RBS: every field carries constrain type:
Mapper.new(types: Mapper::RBSTypes.new)        # sig/*.rbs found from the class's own file
Mapper.new(types: Mapper::RBSTypes.new(sig: ['sig/virtui.rbs']))
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
  nothing, since sord's gate demands a YARD type on every field. The default is still checked
  against the type.

Beyond `type:`, `constrain` only narrows a type (`in:`, `format:`); it never restates it. So the
mapper never has to judge whether `Integer` is "compatible" with `Integer?`. All of these raise
when the mapper first reads the class, not when the key first shows up in a file, since
otherwise the gap hides until some user sets that field:

- **no type**: no `constrain type:`, and the strategy has none either (`BasicTypes` never has);
- **declared twice**: under `RBSTypes`, `sig/` has the field and `constrain` passes `type:` too,
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
which means the default. In JSON, `not_nil:` would forbid an explicit `null` on a field whose
type and default both allow it — no known use case. "The file must give this key" is
`required:`, but a `Data` class already does it: a keyword with no default is required, so a
missing key raises. Only a setter class whose ivar starts as `nil` would need it; nothing in
virtui is shaped like that yet.

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
it); each shows up as a missing field in the file. **`rbs validate` waits**: it would need the
other gems' signatures (`rbs collection` for tuile and REXML), and the mapper only parses the
file, it never validates it.

#### Reading it: `Klass#field` → a type

1. **Find the files.** Start from the file that defines the class (`Module.const_source_location
   (klass.name)`), walk up to the first directory holding `sig/`, read its `sig/**/*.rbs`. That
   is the standard place, works for an app and for an installed gem (tuile's gemspec ships
   `sig/tuile.rbs`), and does not depend on the directory `bin/virtui` is started from. A list
   of paths handed to `RBSTypes` overrides it. No `sig/` found raises: the project asked for
   RBS.
2. **Parse and index.** Each file is parsed once per process with
   `RBS::Parser.parse_signature`; the declarations are walked recursively and indexed by full
   name (`UI::CpuFlagsDialog`). A class declared in several places keeps all its declarations.
3. **Find the field.** Walk `klass.ancestors`; in each one's declarations, look for
   `attr_reader` / `attr_accessor <field>`, or a zero-argument `def <field>: () -> T`. The first
   hit is the RBS type. The getter is what counts, since the mapper reads fields through
   getters; `initialize`'s keyword types are ignored. Two different types for one field raise
   (*declared twice*).
4. **Resolve the names in the type.** `::Set` is absolute: `Object.const_get`. A relative `Size`
   follows Ruby's lexical lookup from the declaring namespace outward (`UI::Foo::Size`,
   `UI::Size`, `Size`). Built-ins go to the mapper's own checks; any other class must be mappable
   or a custom type, or it raises `unsupported type at sig/virtui.rbs:LINE`.
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
  extend Mapper::Annotations

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
- Without RBS every field gets a `constrain` line, for its type at least; under `RBSTypes`
  only a field with limits does.
- **Named `constrain`**: the line adds limits to a field the class already declares, and a type
  is the strictest limit. Not `setting`, since every field is a setting, annotated or not.
  Not `property`, since sorbet's `prop` and Rails' `attribute` both define the accessor. Not
  `validate`, since that is the class's own cross-field hook, and Rails' `validate :foo`
  registers the method `foo`.
- **`constrain` does not define the accessor**, though Rails' `attribute` does. On a `Data` class
  the reader exists and the instance is frozen, so a generated writer would raise
  `FrozenError`. Once the macro owns the field, `default:` follows, then a generated
  `initialize`, and it has become dry-struct or `T::Struct`: a class shape the mapper imposes. A
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
  verbose to write by hand for what one `constrain` line says. The cross-field rule and
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
  But it *is* the class shape (`< T::Struct` or `include T::Props`), so no `Data`, no plain
  class; a required prop missing from the Hash is not an error but recorded and left `nil`
  (`required_prop_missing_from_deserialize`), which config cannot accept; and it carries
  Stripe's ODM history (`dont_store`, `redaction`, `chalk-odm` warnings). Whether `from_hash`
  type-checks the values at all is unverified — `Q_sorbet_from_hash`.
- **dry-struct / dry-validation / dry-configurable, hashie, anyway_config, shale,
  activemodel** — weighed in `config-file.md`: each either brings its own class shape, gem
  family or lenient casting.

## Open questions

- `Q_custom_types` — a protocol class (`.load` / `#dump`), or a registry
  (`Mapper.type('Size') { … }`) that RBS type names resolve through?
- `Q_mutable_fields` — for a setter class, fields from the ivars a bare `new` sets, or from its
  public writers? Ivars match `keeping-state.md`; writers would also pick up a writer that is
  not meant as a setting.
- `Q_sorbet_from_hash` — does `T::Struct.from_hash` type-check values, or assign blindly? Only
  matters if `T::Struct` comes back as a candidate.
- `Q_name` — a name, once it is a gem.
