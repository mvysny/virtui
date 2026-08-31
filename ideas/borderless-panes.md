# Borderless panes: backgrounds differentiate, a chip + the cursor say focus

**Status:** designed 2026-08-31, nothing implemented. Blocked first on the
tuile side — see *What tuile needs to grow* below; the virtui work is a
retrofit once those land. The look: Catppuccin-Latte-in-LazyVim — window
frames go away (popups/dialogs keep theirs), panes are told apart by
background shade instead, and focus gets *labeled* indicators because the
frame's `active_border_color` flip dies with the frame.

## The layout

- `VMWindow` is the "editor": the primary pane, where all interaction lives
  (power/memory/search keys). It keeps the **terminal's default background**.
- `SystemWindow` + log are the "sidebar row": read-only telemetry, tinted one
  step darker/lighter than the terminal background, separated from each other
  by a one-cell `│` column in the existing `frame` token (placed in
  `AppLayout#rect=`).
- No horizontal separator between the VM pane and the bottom row — the
  background step *is* the separation.

**Why not full Catppuccin (paint every background explicitly):** virtui would
stop blending with the user's terminal theme and would own every
contrast pairing — including the LIGHT theme's deliberately *symbolic* ANSI
colors (green/red/magenta), which the terminal remaps to shades chosen
against *its* background, not ours. Tinting only the secondary panes keeps
that choice intact and is exactly the LazyVim editor-vs-explorer effect.
This is a real fork → DECISIONS.md entry on graduation (slug suggestion
**tint_secondaries_only**, no `D_` prefix here on purpose — the grep
tripwire).

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
3. **A header row per pane** (the frame's caption has to move somewhere
   anyway): the same chip, on the pane itself — the spatial anchor, lazygit's
   active-pane title. Inverted when focused, dim otherwise.
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

## What tuile needs to grow

In priority order; the first is the blocker, the rest are nice-to-haves with
workarounds.

1. **A frameless `Window` mode** (`frame = false`, or a sibling container).
   `Window` unconditionally paints its border, and both virtui windows
   subclass it for scrolling + focusability — rebuilding them on raw layouts
   would reimplement those. The border's jobs need homes: caption → an
   optional header row; `footer`/`footer_text` (search field, popup hints) →
   keep a bottom row; the scrollbar → still needs its column. virtui's
   `repaint_border` override becomes a header-row override, nearly
   line-for-line.
2. **`inverse: true` on `StyledString::Style`** (SGR 7). `Style` has only
   fg/bg/bold/italic/underline/strikethrough, so "inverted" today means
   explicit fg+bg theme tokens per variant. SGR 7 swaps whatever colors are
   actually in effect — terminal-theme-proof, zero color decisions, and
   generally reusable. *Workaround without it:* a `focus_segment` token pair
   in both theme variants, like the existing captions' `fg: :black, bg: …`.
3. **Expose the OSC-11 background RGB.** `TerminalBackground` already parses
   the terminal's actual background color and reduces it to light/dark; expose
   the RGB and virtui can *derive* the sidebar tint from the real background
   (±4–5% luminance at the same hue) so the effect works on any terminal
   theme. *Workaround:* fixed near-neutral tints per dark/light variant
   (24-bit `Color.rgb` is supported), degrading to 256-palette greyscale-ramp
   steps under tmux/old terminals.

Already there, no work needed: `Component#bg_color=` accepts a fixed color or
a `Theme::Ref`, children inherit via `effective_bg_color`, and the draw
helpers fill the background behind every span — background-differentiated
panes work today.

## The virtui-side change list

- `UI::Theme`: new tokens — secondary-pane bg (pair), chip colors (unless
  tuile grows `inverse`); delete `tab_inactive`.
- `UI::AppLayout`: drop frame captions, add the separator column in `rect=`;
  `refresh_status` renders chip + `q quit` + hint (the focus-chain walk
  already finds the owner and rebuilds on focus change).
- `UI::Formatter`: the chip builder (shared by status line and pane headers).
- `UI::VMWindow`: `repaint_border` → header-row override; scope
  `show_cursor_when_inactive` to search.
- `UI::SystemWindow`: `Cursor::Limited` + position bookkeeping.
- Popups (`CpuFlagsWindow`, pickers, memory/power menus): untouched — frames
  on floating surfaces stay.

## Open questions

- Focused-chip contrast in the LIGHT theme if tuile's `inverse` is used:
  SGR 7 on a near-white terminal inverts to near-white-on-dark — probably
  fine, but eyeball it.
- Does the header row cost a content row in the 13-row SystemWindow, or does
  the frame's freed top border row pay for it? (Frameless drops top+bottom
  border rows; header + footer rows spend them again. Net zero for panes
  that keep both; the log pane may gain a row.)
- Where does the VM pane's search field sit without a bottom border — a
  plain bottom row of the pane, presumably; check it reads as attached.

## Graduation

- The forks above → DECISIONS.md entries: **tint_secondaries_only**,
  **no_powerline_glyphs**, and the focus-indication tree (bg-lift and
  caption-flip rejected; chip + cursor chosen — one entry, slug suggestion
  **labeled_focus_cues**).
- Per-symbol rationale (chip builder, the scoped
  `show_cursor_when_inactive`, SystemWindow's `Cursor::Limited` row
  positions, tint derivation if OSC-11 RGB lands) → yardocs on those
  methods/tokens.
- README: nothing — no user-visible setup changes, no font dependency (that
  was the point of dropping the powerline glyph).
- CLAUDE.md: class-index entries only if new classes appear (a `Pane`
  wrapper, say); the threading section is untouched.
