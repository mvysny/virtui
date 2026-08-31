# Borderless panes: backgrounds differentiate, a chip + the cursor say focus

**Status: ready to implement** (2026-08-31). All three tuile items are done
upstream and virtui builds against the local checkout (Gemfile
`path: '../tuile'` until the release carrying them). No design decisions
left — the search field is a row in the pane's own layout, not an overlay;
every remaining open is an eyeball-at-prototype item. One non-blocking
upstream ask remains open (tuile#8, color-depth detection) with a workable
fallback. The look:
Catppuccin-Latte-in-LazyVim —
window frames go away (popups/dialogs keep theirs), panes are told apart by
background shade instead, and focus gets *labeled* indicators because the
frame's `active_border_color` flip dies with the frame.

## The layout

- The VM pane is the "editor": the primary pane, where all interaction lives
  (power/memory/search keys). It keeps the **terminal's default background**.
- The System + log panes are the "sidebar row": read-only telemetry, tinted
  one step darker/lighter than the terminal background, separated from each
  other by a one-cell `│` column in the existing `frame` token (placed in
  `AppLayout#rect=`).
- No horizontal separator between the VM pane and the bottom row — the
  background step *is* the separation.

**Why not full Catppuccin (paint every background explicitly):** virtui would
stop blending with the user's terminal theme and would own every
contrast pairing — including the LIGHT theme's deliberately *symbolic* ANSI
colors (green/red/magenta), which the terminal remaps to shades chosen
against *its* background, not ours. Tinting only the secondary panes keeps
that choice intact and is exactly the LazyVim editor-vs-explorer effect.
Revisited and re-rejected 2026-08-31: LazyVim itself *is* the full-paint
model — it draws its configured theme and ignores the terminal background
(observable under Alacritty transparency: LazyVim's painted cells are
opaque; virtui's and Claude CLI's default-bg cells shine through). It earns
that cost because an editor is a *destination* app rendering arbitrary
syntax palettes — it must own its ground; a VM dashboard is furniture and
should feel native to the terminal it's embedded in. Full paint would also
kill transparency everywhere and reverse the symbolic-ANSI choice, for
control that ~15 theme tokens don't need. This is a real fork → DECISIONS.md
entry on graduation (slug suggestion **tint_secondaries_only**, no `D_`
prefix here on purpose — the grep tripwire), carrying both rejected forms:
full-Catppuccin paint and the LazyVim own-theme model.

**The tint itself (decided 2026-08-31; direction revised same day, by
measurement):** fixed near-neutral per-variant tints are the floor — needed
regardless, since OSC 11 goes unanswered on some terminals and tmux setups.
When tuile#7 delivers the terminal's actual background RGB, *derive* the
tint from it instead: the value is **hue preservation**, because popular
terminal themes are rarely neutral (Catppuccin Mocha `#1e1e2e` is
purple-blue, Latte `#eff1f5` bluish, solarized teal) and a neutral-grey
sidebar next to a tinted primary pane looks dirty, where stepping the
actual background keeps the theme seamless. Concretely: an HSL round-trip
that holds hue+saturation and moves only lightness.

**Direction: toward mid-grey** — dark variant → lighter, light variant →
darker — by a slight step, ΔL ≈ 0.04 (exact value: eyeball, below). This
*revises* the first decision (step toward the theme's pole, argued from
contrast: the tokens were tuned against near-black/near-white, so the pole
strictly improves their ratios). The argument is mechanically true but the
measurement says it doesn't bind, and the slightness is why: the tinted
areas are large, and a big area shows a small tint. WCAG ratios computed
against the tokens the *System pane actually renders* (`cpu`, `ram`,
`swap`, `disk`, `disk_label`, `frame`, default fg — the VM-pane tokens
drop out, that pane stays untinted) over six representative backgrounds
(#000, Mocha, One Dark, #fff, Latte, Solarized Light):

- The foreground never matters — white-on-dark has 14–21:1 to burn.
- The binding constraint is **`cpu` DodgerBlue3 in the LIGHT theme**
  (5.8:1 on white, tuned with no headroom): on Latte it breaks at Δ=0.10
  (3.98:1), sits on the 4.5 line at 0.05, clears comfortably at 0.03–0.04.
- Dark caps in the same region (One Dark +0.10 → `cpu` 3.99:1; +0.05 →
  4.80:1). So **Δ ≈ 0.04 is safe everywhere measured**, both directions'
  budgets are ~0.05, and toward-grey's small contrast cost is affordable.
- The decider: the pole rule's *exception* (can't darken past `#000`,
  can't lighten past `#fff`) fires exactly at the two most common terminal
  backgrounds, where it degenerates to a step-the-other-way no-op —
  toward-grey's exception (a background already mid-grey) fires on no real
  terminal. A rule whose primary branch is dead on the most common input
  is the wrong primary branch.

The safety valve survives as a **contrast guard, not a direction rule**:
compute the System-pane tokens' ratios against the candidate tint; below
the floor, step the other way. ~10 lines, expected dead on every real
background, protects the ones never tested.

**Casualty found by the same arithmetic: `frame` cannot stay a fixed hex.**
Dark's `#333333` assumes a near-black terminal — on One Dark it is 1.11:1
*untinted*, and the toward-grey tint walks it through 1.00:1 (invisible)
at Δ=0.03, exactly where the System/log separator column is load-bearing;
it re-emerges from the other side at higher Δ, i.e. visibility
non-monotonic in the tint. Fix: `frame` joins the derived set — one or two
further steps in the same direction from the pane background — so the
hairline keeps a known distance from the ground it sits on.

**Tuning Δ:** eyeball, via a temporary `[`/`]` binding in demo mode
nudging Δ live; tune against real terminals, then hardcode. The floor
becomes a spec, not prose: every System-pane token ≥ 4.5:1 against the
derived tint for the representative-background table, driven through
`FakeScreen#background_color=`. Known approximation, eyes open: a fixed
ΔL in HSL isn't perceptually uniform, but the measured contrast deltas
come out comparable on both sides, so it's a good-enough proxy — OKLab is
the upgrade if the dark step reads weaker than the light one. The
fixed-tint floor values (the no-OSC-11 case — pane bg *and* its `frame`,
since a derived `frame` has no input there either) get picked in the same
eyeball session.

Staleness is solved upstream: on a mode-2031 flip the screen re-probes
OSC 11 itself, and a changed `Screen#background_color` fires
`Component#on_theme_changed` across the tree — the same hook a theme swap
uses. So the panes recompute their tint in `on_theme_changed` (which
VMWindow already overrides) and both the variant flip and the fresh RGB
funnel into it; no virtui-side staleness handling. A terminal that reports
2031 flips but never answers OSC 11 keeps its startup color by upstream
choice (tuile's D_background_rgb).

Transparency side-effect, eyes open: painted cells are opaque (per the
Alacritty observation above), so the tinted secondary panes go solid while
the primary pane keeps shining through — "translucent editor, solid
sidebar". Expected to read as intentional; eyeball at prototype time, and
if it bothers, the fix is a subtler tint, not abandoning the approach.

## Panes are Layouts, not frameless Windows

The first draft asked tuile for a `Window#frame = false` mode. Challenged and
dropped: once the border goes, `Window` earns nothing — bending a class whose
job is painting the border into not painting it keeps the class for its name.
Verified against tuile 0.13:

- **Scrolling and the scrollbar are the content's own.** `List` and
  `TextView` instantiate their `VerticalScrollBar` themselves (`list.rb:355`,
  `text_view.rb:394`); `Window#scrollbar=` is a one-line delegation to
  `content.scrollbar_visibility=`.
- **Focus-within is free.** `Screen#focused=` sets `active = true` on the
  focus target *and every ancestor* (`screen.rb`), so a `Layout` pane reads
  `active?` correctly even while its search field holds focus — exactly what
  the header chip needs.
- Caption → a header-row `Label`. Footer → a bottom row, or the search
  overlay (below). Click-to-focus: `List` paints its whole rect, so clicks on
  content already land focus (`component.rb:160`).

The pane shape: `Layout::Vertical` — header row (`Fixed[1]`: chip label,
plus the Guest/Host captions on the VM pane), the `List` (`Expand`), an
optional footer row.

Residuals, eyes open:

- **Search-close focus repair — decided: a row in the pane's layout.**
  `Window#footer=` repairs focus via `on_child_removed` when the removed
  footer held it (`window.rb:68`); a plain Layout doesn't, so `close_search`
  calls `content.focus` explicitly. That's the whole cost. The earlier
  overlay-first plan is dropped: it read as free ("the screen repairs focus
  when a popup closes") but isn't. `Popup` self-centers — `reposition`
  (`popup.rb:94`) resolves `declared_size` and calls `center` — so a search
  field would land mid-screen, which is precisely the "doesn't look attached
  to the VM pane" failure; anchoring it means a `Popup` subclass overriding
  `reposition`. And the lighter shape, a bare focusable `Overlay`, is
  forbidden upstream: `overlay.rb`'s implementation notes call a focusable
  non-modal overlay the one thing that must not appear ("every keystroke
  goes dead until Tab recovers"). So it's a modal `Popup` subclass or a
  one-line `focus` call. Also affected: `keyboard_hint`'s
  `return … if footer` (`vm_window.rb:196`) — `footer` stops being a
  `Window` concept, so the search-open state becomes the pane's own ivar.
- **The log pane.** `Component::LogWindow` is itself a `Window` subclass;
  its innards — the word-wrapping auto-scroll `TextView`, the any-thread
  self-marshaling `#log`, the `IO` adapter — are extracted upstream as
  `Component::LogTextView` (tuile#5, done); the pane composes it directly.
- **Naming.** Per the tuile widget-suffix rule the classes stop being
  `*Window`: `VMPane`, `SystemPane`. A cohesive `UI::Pane` base only if the
  shared header assembly actually grows — start by duplicating the two-line
  header build.
- The SystemWindow height math resolves favorably: the header row replaces
  the top border row and no bottom border returns, so the System pane nets
  +1 content row and the log pane +1..2.

## Focus indication — the decision tree

The frame currently carries focus (`active_border_color`); frameless needs a
replacement. Walked in order:

1. **Bg-lift of the focused pane — rejected.** A *relative* cue: you must
   remember the resting shade to read it. Passive; easy to forget what's
   selected.
2. **Powerline segment in the status line — accepted, then simplified.**
   `[1]-VMs ` inverted, then a space, then `q quit` + the focused window's
   `keyboard_hint`. An *absolute, labeled* cue in a fixed corner (the vim
   mode-indicator spot), and a semantic upgrade: today `AppLayout#refresh_status`
   shows hints without saying whose they are; the chip names the owner.
   - The full-height arrow terminator (``, U+E0B0) — **rejected**: a
     private-use Nerd Font glyph, tofu on stock terminals, and the client's
     font is undetectable server-side. Half-block `▐` — **rejected for
     simplicity**: looks near-identical to a plain hard edge. Plain inverted
     block it is; no special characters. (Fork → DECISIONS.md, slug
     suggestion **no_powerline_glyphs**.)
3. **A header row per pane**: the same chip, on the pane itself — the
   spatial anchor, lazygit's active-pane title. Inverted when focused, dim
   otherwise.
4. **The list cursor** — the strongest cue, because it's what the eye tracks
   anyway (`p`/`v`/`m`/`d` act on it). Tuile already hides it in inactive
   lists *by default* (tuile 0.13 `list.rb:838`: painted iff
   `active? || @show_cursor_when_inactive`); virtui opts out at
   `vm_window.rb:76` with a *permanent* `show_cursor_when_inactive = true`,
   which is what keeps the VM cursor lit while the log has focus. The flag
   exists for the search footer (focus sits in the field while incremental
   search moves the cursor), so **scope it**: `true` in `open_search`,
   `false` in `close_search`. Invariant after: *cursor visible ⟺ the VM pane
   owns the keyboard*.

The rule that makes 2+3 legible: **exactly one inverted element per pane** —
the chip. The Guest/Host captions do *not* also flip (see below).

### Guest/Host usage captions: stay, but stop signaling focus

They are load-bearing **column headers**, not chrome: every VM row renders
guest-side | host-side bar pairs, and the captions (centered at 1/4 and 3/4
width, `vm_window.rb:220`'s `repaint_border` override) are the only thing
saying which column is which — worst for the disk row, where guest fs usage
and qcow2 host allocation legitimately disagree. They move from the border
into the header row with the same centering math, restyled as **static dim
labels** (`hint`/`frame` treatment). Not flipping with focus, because:
(a) three inverted blocks in one row is noise that dilutes the chip;
(b) System/Log have no captions, so focus would *look different* per pane;
(c) a two-shade caption flip is the bg-lift objection in miniature. The
`tab_inactive` theme token dies with this.

### SystemWindow grows a cursor

`Cursor::None` there is a chrome choice, not a semantic one (`less`/`htop`
move highlights through non-actionable rows). Adding one buys two things:
focus indication consistent with the VM pane, and **keyboard scrolling when
the disk list overflows the fixed 13 rows** — that overflow currently has no
story. Use `Cursor::Limited` mirroring `vm_window.rb:149`: positions on the
meaningful rows (CPU, RAM, swap, each disk), skip headers/blanks (a plain
cursor parked on a blank row reads as a glitch), preserve `position:` across
the 2s rebuilds. Leaves the door open for row-scoped `h` help later; not
committing to that. The log pane stays cursor-less (its content is
deliberately a `TextView`, not a `List` — truncation) and is the one
absence case; the chip covers it.

### Known quirk, unchanged from today

While the search field is focused, the `1` in the chip won't focus the VM
pane (the field consumes digits first — the key bubble, `AppLayout#handle_key`).
The current `[1]-VMs` captions lie identically; this design neither fixes nor
worsens it.

## The tuile items (filed upstream; none blocking)

1. **Extract `LogTextView` out of `LogWindow`**
   ([tuile#5](https://github.com/mvysny/tuile/issues/5)) — **implemented
   upstream.** The view + the self-marshaling `#log` + the `IO` adapter,
   with `LogWindow` reduced to framing it; the frameless log pane composes
   the view directly.
2. **`inverse: true` on `StyledString::Style`** (SGR 7,
   [tuile#6](https://github.com/mvysny/tuile/issues/6)) — **implemented
   upstream.** The chip renders via SGR 7: swaps whatever colors are in
   effect, terminal-theme-proof, no `focus_segment` token pair needed.
3. **Expose the OSC-11 background RGB**
   ([tuile#7](https://github.com/mvysny/tuile/issues/7)) — **implemented
   upstream**, beyond the ask: `Screen#background_color` returns a `Color`
   (**nil is the normal case** — `COLORFGBG`-only or no answer — so the
   fixed-tint floor stays load-bearing), and it *stays current across OS
   appearance flips*: the screen re-probes on the 2031 report and a changed
   color fires `Component#on_theme_changed` tree-wide plus a full repaint.
   `FakeScreen#background_color=` plays the terminal in specs — the
   derivation is unit-testable. Consumption: see *The tint itself*.
4. **Detect the terminal's color depth**
   ([tuile#8](https://github.com/mvysny/tuile/issues/8)) — **open, not
   blocking.** #7 closes only half the loop: an app can read the background
   as RGB and derive a tint from it, but `Color#sgr_codes` emits
   `48;2;R;G;B` unconditionally, and nothing in tuile knows whether the
   terminal (or tmux without `terminal-features "*:RGB"`) understands it.
   Asked for `Screen#color_depth` plus `Color#quantize` — the RGB→256
   mapping is two formulas, not a table. Until it lands, virtui emits
   truecolor and accepts that a 256-only terminal approximates the tint;
   the fixed-tint floor already covers the terminals that answer no OSC 11
   at all, which correlate heavily with the ones that can't do 24-bit.

Unrelated API drift picked up with the switch to the local checkout:
`Popup.new(size:)` became `declared_size:` (the `size` reader now returns
the resolved cells) — `CpuFlagsWindow` and its spec adjusted.

Already there, no work needed: `Component#bg_color=` accepts a fixed color or
a `Theme::Ref`, children inherit via `effective_bg_color`, and the draw
helpers fill the background behind every span — background-differentiated
panes work today.

## The virtui-side change list

- `UI::Theme`: new tokens — secondary-pane bg (pair; the fixed-tint floor);
  delete `tab_inactive`; `frame` stops being a fixed hex and derives from
  the pane bg (see *The tint itself*). No chip colors — the chip uses
  tuile#6's `inverse`.
- The tint derivation itself (HSL step toward grey + contrast guard +
  the spec table): a small top-level or `UI::` helper, unit-tested via
  `FakeScreen#background_color=`.
- `UI::AppLayout`: the panes stop being Windows (no more caption mutation);
  separator column in `rect=`; `refresh_status` renders chip + `q quit` +
  hint (the focus-chain walk already finds the owner and rebuilds on focus
  change).
- `UI::Formatter`: the chip builder (shared by status line and pane headers).
- `UI::VMWindow` → `VMPane < Layout::Vertical`: header row (chip + column
  captions, replacing the `repaint_border` override); scope
  `show_cursor_when_inactive` to search; search field as a row in the
  layout, `close_search` re-focusing `content`.
- `UI::SystemWindow` → `SystemPane < Layout::Vertical`: header row;
  `Cursor::Limited` + position bookkeeping.
- Log pane: `Component::LogTextView` + header row; `$log` redirect rewires
  to its `IO`.
- Popups (`CpuFlagsWindow`, pickers, memory/power menus): untouched — frames
  on floating surfaces stay.

## Open questions

- The exact Δ (~0.04 measured-safe; is it *perceptible enough* on a pure
  `#000` background and a washed-out display?) and the fixed-tint floor
  values — the `[`/`]` demo-mode eyeball session (see *The tint itself*).
- Focused-chip contrast in the LIGHT theme under SGR 7: a near-white
  terminal inverts to near-white-on-dark — probably fine, but eyeball it.
- The solid-sidebar-under-transparency effect (see *The tint itself*) —
  eyeball at prototype time.

## Graduation

- The forks above → DECISIONS.md entries: **tint_secondaries_only**,
  **no_powerline_glyphs**, the focus-indication tree (bg-lift and
  caption-flip rejected; chip + cursor chosen — one entry, slug suggestion
  **labeled_focus_cues**), panes-as-Layouts (frameless-Window mode
  rejected — slug suggestion **panes_are_layouts**), and the tint
  direction (pole-directed step rejected by measurement — slug suggestion
  **tint_toward_grey**; carry the key ratios, they're the provenance).
- Per-symbol rationale (chip builder, the scoped
  `show_cursor_when_inactive`, SystemPane's `Cursor::Limited` row
  positions, the toward-grey step + contrast guard and the derived
  `frame`, the search-row-not-overlay one-liner on `open_search` — Popup
  self-centers, a focusable non-modal Overlay is forbidden upstream) →
  yardocs on those methods/tokens.
- README: nothing — no user-visible setup changes, no font dependency (that
  was the point of dropping the powerline glyph).
- CLAUDE.md: class-index renames (`VMWindow` → `VMPane`, …); the threading
  section is untouched.
