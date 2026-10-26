# Show what the balloon controller is doing, and why

**Status:** decided (2026-10-26), ready to build. How red *at max* gets is split off into
`ballooning-severity.md`.

## The problem

`BallooningVM#status` explains every tick's decision, but only `$log.debug` ever sees it. On
screen there are just 🎈 and one character after it: `↑`, `↓`, `-`, or `x` for disabled.

That is how the old fixed 8 GiB floor hid. On a 4 GiB `vt-ubuntu` every tick said "VM max
memory … is below min_actual, doing nothing", and nothing on screen did. A guest at 95% RAM,
600 MiB swapped, had its load OOM-killed while virtui watched. To find out why, I had to wrap
`bin/virtui` in a `prepend` that wrote every status to a file.

## What I needed to see while testing, and could not

Watching `vt-ubuntu` through a `memramp` cycle, three questions kept coming up. Each needed
the status file:

1. **Why isn't it growing?** The guest is at 95% and the RAM bar doesn't move. The answer was
   the floor then; today it would be "already at the 4 GiB max".
2. **Why isn't it shrinking yet?** The load is gone and the guest is at 30%, but nothing
   happens for a minute. Is that the swap veto (60 s), the back-off (10 s), or the floor?
3. **What did it just do?** The arrow is no help. It shows `↑` only on the tick of the change.
   The next tick is "no new data", `memory_delta` is 0 again, and the arrow is back to `-`.
   It lasts one 2 s frame. Every `cap_*.txt` screen I captured during the ramp shows `-`.

## Every status there is, grouped by what the user should take from it

These are counts from that run's status log (242 lines, two VMs, ~4 min):

| Group | Status today | Seen | Worth showing? |
|---|---|---|---|
| **fine** | "nothing to do" (usage between 55% and 65%), "no new data" | 12 + not logged | no: silence is the message |
| **acted** | "raising memory by 30% to 2.6G: usage …", "lowering … by 10%" | 4 + 7 | yes, and it must last longer than one frame |
| **holding** | "not lowering memory: backing off for 8.0s", "…: the guest swapped recently; holding its memory for 58.3s" | 46 | yes, with the countdown: it answers question 2 |
| **at floor** | "New actual 2G is the same as current one 2G, doing nothing" | 22 | quietly; the wording is wrong for users |
| **at max** | "want to raise memory (…) but can't go over configured max mem 4G" | 30 | **loudly**: the guest is short and virtui cannot help. The user can (`mm`, or a bigger `<memory>`) |
| **can't steer** | "ballooning unsupported by the VM", "guest memory data is stale" | 121 + 0 | already shown: no 🎈, or 🐢 |
| **off** | "ballooning disabled by user", "vm stopped" | – | already shown: `x`, ⏹ |

So the new information is four states: *acted*, *holding*, *at floor*, *at max*. The rest is
either noise or already on screen.

## Decided: words in the header rule, transitions in the log (A + C)

Option B, a glyph only with the words in the focused VM's status bar, was rejected: question 1
would then need the cursor on the right VM, and on a screen you glance at, "at max" should not
need a keypress.

### A. Words in the header rule

The header rule is mostly empty. At 170 columns, `vt-ubuntu`'s header has ~130 columns of `─`
between 🎈 and the IP. `VMPane#overview_row`'s own rule says that right of the name is what the VM
is *doing right now*, so this is where the status belongs.

```
 ▶ 🐧 vt-ubuntu 🎈↑ raised to 2.6G: 70% used ──────────────────────── 192.168.123.239 ─
 ▶ 🐧 vt-ubuntu 🎈↓ lowered to 1.8G: 41% used ─────────────────────── 192.168.123.239 ─
 ▶ 🐧 vt-ubuntu 🎈‖ holding 58s: the guest swapped ────────────────── 192.168.123.239 ─   yellow
 ▶ 🐧 vt-ubuntu 🎈▲ at its 4G max, 92% used ───────────────────────── 192.168.123.239 ─   red
 ▶ 🐧 vt-ubuntu 🎈_ at its 2G floor ───────────────────────────────── 192.168.123.239 ─   dim
 ▶ 🐧 vt-ubuntu 🎈- ───────────────────────────────────────────────── 192.168.123.239 ─   fine: as today
 ▶ 🐧 vt-ubuntu 🎈↑ raised to 2.6G: 70%… ─── 192.168.123.239 ─                            narrow
```

- **Glyphs** `↑ ↓ ‖ ▲ _ - x`. Not `⏸`: it renders emoji-wide in some fonts, and the Promise is
  no special font. `‖` and `▲` are East Asian *ambiguous* width, the same class as the `↑ ↓`
  already on screen.
- **Colour by severity:** dim for routine, yellow for *holding*, red for *at max*. When *at max*
  turns red is `ballooning-severity.md`'s question; until it is answered, red as soon as capped.
- **Short header wording** ("70% used", "swapping 20M/s", "the guest swapped"). The voters'
  full reasons go to the log (C), which is naturally more verbose.
- ***acted* lasts 10 s**, then back to *fine*: after that "fine" is the truth. A VM that stops
  at 2.6G must not say "raised to 2.6G" for an hour.
- ***acted* takes priority over the back-off.** `resize` arms the 10 s back-off on every change,
  so the next fresh sample after a lower says "not lowering: backing off". If that counted
  as *holding*, it would replace "lowered to 1.8G" after one or two frames, and question 3
  would be back. The back-off runs exactly as long as *acted*, so it never shows as its
  own state. *Holding* is shown only for the swap veto and the boot back-off, the two that
  aren't caused by our own action. Raises are never vetoed, so this only affects lowers.
- ***at floor* gets its text.** It is the normal resting state of an idle small VM, so if it
  turns out chatty, the fallback is a dim `_` alone.
- **The countdown ticks every 2 s.** That's fine, because nothing to its right moves except the
  IP, which is right-aligned.
- **Narrow terminals:** the words are shortened with `…`; the glyph never is. The IP is always
  shown, with at least `───` before it, so the status reads as separate from the IP. If even
  🎈, glyph, `───` and IP don't fit, the header falls back to today's layout.

### C. Transitions to the log pane

`$log.info` once per change of kind, not per tick (a holding countdown is not a change),
with the voters' full reasons:

```
11:47:02 vt-ubuntu ↑ 1G → 1.3G: usage is at or over the 65% trigger
11:47:07 vt-ubuntu ↑ 1.3G → 1.7G: usage is at or over the 65% trigger, swapping out 20M/s
11:47:31 vt-ubuntu ▲ at its 4G max, 92% used: usage is at or over the 65% trigger
11:48:40 vt-ubuntu ↓ 4G → 3.6G: usage is under the 55% target
```

That is the history the header can't show: how a burst was absorbed. A `memramp` cycle produces
~15 lines over three minutes, and an idle box produces none.

## A shape for the code

`Status` stays a value, but gains a `kind` (`:fine`, `:raised`, `:lowered`, `:holding`,
`:at_floor`, `:at_max`, `:unsupported`, `:stale`, `:disabled`, `:stopped`), a short header
text, and the long reason for the log. The `"VM reports …"` debug line stays as it is. The
glyphs and colours for each kind live in `lib/ui/`, as the invariant requires.

*acted* needs one change in `BallooningVM`: remember the last action (kind, text, uptime on
the `Cooldown` clock) so the following "no new data" and back-off ticks still report it for
10 s.
