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
- **The file never names a class.** The caller names the root class and the class side (RBS,
  annotation, default) names every nested one; no `json_class` / `!ruby/object` discriminator.
  A user should not have to write one, and a rogue file must not instantiate an arbitrary
  constant — the gadget class behind Psych's `safe_load` and JSON's `create_additions`. A field
  with several shapes takes a tag the class maps to a closed set of classes.
- **Hash in, Hash out.** The file format is the caller's: `Tomlrb.load_file`,
  `YAML.safe_load_file`, `JSON.load_file` all hand over a Hash.

```ruby
config = Mapper.load(Config, Tomlrb.load_file(path))                   # unknown keys raise
state  = Mapper.load(State, JSON.load_file(path), unknown: :ignore)       # a newer virtui's keys are dropped
Mapper.dump(state)                                                     # => plain Hash
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

## Types: three sources, first found wins

1. **RBS**, when the class has it.
2. **A `constrain` annotation** on the field (*Annotations* below).
3. **The default's class**: `65` → `Integer`, `true`/`false` → `bool`, an instance of a
   mappable class → that class. It cannot tell the type of `nil`, `[]` or `{}`; such a field
   needs 1 or 2. If it has neither, the mapper raises when it first reads the class, not when
   the key first shows up in a file: otherwise the gap hides until some user sets that field.

### RBS

RBS is Ruby's own type-signature language; the `rbs` gem ships with Ruby (3.4.0 bundled with
Ruby 3.3; 4.2.0 is current, released 2026-08, 98M downloads, depends on prism, tsort, logger).
Since 4.0 it has **inline** declarations in `.rb` comments — still marked experimental:

```ruby
class State
  attr_accessor :system_pane_visible, :log_pane_visible #: bool
  attr_accessor :last_vm #: String?             -- nil until the user picks one

  # @rbs @window: State::Window
end
```

What the mapper needs from it, read in `rbs-4.2.0`'s source:

- **The types, without loading the RBS environment.** `RBS::Parser.parse_type("Integer?")`
  and `RBS::Parser.parse_signature(source)` parse on their own. `RBS::InlineParser.parse(buffer,
  prism)` reads inline annotations from a Ruby file; `Module.const_source_location` finds the
  class's file.
- **Not RBS's own runtime checker.** `RBS::Test::TypeCheck#value(val, type)` exists, but its
  constructor wants a `DefinitionBuilder`, i.e. the whole environment, core signatures
  included. The mapper interprets a small subset of the type AST itself instead:
  `Integer`, `Float`, `String`, `bool`, `T?` (nil allowed), `Array[T]`, `Hash[String, T]`,
  literal unions (`"short" | "verbose"`, which give enums for free), and mappable classes.
  Anything else raises "unsupported type".
- **Data classes are awkward inline**: `Ballooning = Data.define(…)` is a constant to the
  inline parser, not a class with attributes. The type then rides the constructor:
  `# @rbs (?raise_at_percent: Integer, ?min_actual_gib: Integer) -> void` above
  `def initialize(…) = super`. Or a `sig/*.rbs` file declares it — `Q_rbs_source`.

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

  constrain :raise_at_percent, :shrink_at_percent, in: 1..100
  constrain :min_actual_gib, in: 1..
  constrain :pinned_vms, 'Array[String]'      # a type, because the default [] says nothing

  def initialize(raise_at_percent: 65, shrink_at_percent: 55, min_actual_gib: 8, pinned_vms: []) = super
end
```

- **The type is an RBS type string** (or a Ruby class as shorthand), so the mapper speaks one
  type language whether the type came from RBS or from an annotation.
- **Constraints, a deliberately small set**: `in:` (a Range — `0..` is "0 or greater" — or an
  Array of allowed values) and `format:` (a Regexp, for strings). Everything else is
  `validate`.
- Only fields that need one get an annotation; the rest are fully described by their default.
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

The alternative is a plain constant the mapper reads — `CONSTRAINTS = { min_actual_gib: { in:
1.. } }` — so the class does not reference the mapper at all — `Q_annotation_shape`.

### Later, perhaps: JSON Schema as an alternative to `constrain`

Settled: the mapper starts with `constrain`. A JSON Schema may come later as a second way to
give the same types and limits; it is not the first one built.

A JSON Schema file beside the `Data` classes, checked with **json_schemer** before the mapper
runs. The classes stay as they are, with their YARD and `validate`. The mapper still turns the
Hash into objects, nested ones included. It only stops reading types, because the schema has
already checked them: the class of a nested object comes from the default's class (source 3).
A nested object whose default is `nil` has no such class, so the schema must name it: a custom
keyword (`"x-ruby-class": "Ballooning"`) or a convention mapping `$defs/Ballooning` to
`Ballooning`. The schema ships with the app, not with the user's file, so this keeps *the file
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
  verbose to write by hand for what a keyword default already says. The cross-field rule and
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

- `Q_rbs_source` — inline RBS in the class's file, a `sig/*.rbs` file, or both? Inline keeps
  the type on the field but is experimental and awkward for `Data`; `sig/` is stable but a
  second file to keep in step (and a new practice for this project — Steep could then check
  it).
- `Q_rbs_optional` — is the `rbs` gem a hard dependency, or does the mapper use RBS only when
  it is loaded? virtui would need `gem 'rbs', '~> 4.2'` in the Gemfile either way (inline
  needs 4.x; Ruby 3.3 bundles 3.4), like `racc` today. It has a native extension.
- `Q_annotation_shape` — the `constrain` macro (`extend Mapper::Annotations`, Rails-like) or a
  plain `CONSTRAINTS` constant (no reference to the mapper)?
- `Q_type_conflict` — RBS says `Integer?`, the annotation says `Integer`: an error, or the
  first source wins silently?
- `Q_custom_types` — a protocol class (`.load` / `#dump`), or a registry
  (`Mapper.type('Size') { … }`) that RBS type names resolve through?
- `Q_mutable_fields` — for a setter class, fields from the ivars a bare `new` sets, or from its
  public writers? Ivars match `keeping-state.md`; writers would also pick up a writer that is
  not meant as a setting.
- `Q_sorbet_from_hash` — does `T::Struct.from_hash` type-check values, or assign blindly? Only
  matters if `T::Struct` comes back as a candidate.
- `Q_name` — a name, once it is a gem.
