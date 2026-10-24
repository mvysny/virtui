# Show what the balloon controller is doing, and why

**Status:** brainstorming (2026-10-24). Nothing built.

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

## Where it could go

The header rule is mostly empty. At 170 columns, `vt-ubuntu`'s header has ~130 columns of `─`
between 🎈 and the IP. `VMPane#overview_row`'s own rule says that right of the name is what the VM
is *doing right now*, so this is where the status belongs.

### A. Words in the header rule (my favourite)

```
 ▶ 🐧 vt-ubuntu 🎈↑ raised to 2.6G: 70% used ──────────────────────── 192.168.123.239 ─
 ▶ 🐧 vt-ubuntu 🎈↓ lowered to 1.8G: 41% used ─────────────────────── 192.168.123.239 ─
 ▶ 🐧 vt-ubuntu 🎈⏸ holding 58s: the guest swapped ────────────────── 192.168.123.239 ─
 ▶ 🐧 vt-ubuntu 🎈▲ at its 4G max, 92% used ───────────────────────── 192.168.123.239 ─   red
 ▶ 🐧 vt-ubuntu 🎈_ at its 2G floor ───────────────────────────────── 192.168.123.239 ─   dim
 ▶ 🐧 vt-ubuntu 🎈- ───────────────────────────────────────────────── 192.168.123.239 ─   fine: as today
```

- The glyph after 🎈 says which group the VM is in. The words say why. Colour is by severity:
  dim for routine, yellow for *holding*, red for *at max*.
- *acted* stays up until something else replaces it, or for N seconds (`Q_acted_lifetime`).
- The countdown ticks every 2 s. That's fine, because nothing to its right moves except the
  IP, which is right-aligned.
- On a narrow terminal the words go first, then the glyph never does (`Q_narrow`).

### B. One glyph only, the words in the focused VM's status bar

The header gets just the glyph. When a VM is selected, the status bar adds its full text. This
is quieter, but question 1 then needs the cursor on the right VM. On a screen you glance at,
"at max" should not need a keypress.

### C. Actions and transitions to the log pane

`$log.info` once per change of state, not per tick:

```
11:47:02 vt-ubuntu ↑ 1G → 1.3G: 70% used
11:47:07 vt-ubuntu ↑ 1.3G → 1.7G: 70% used, swapping out 20M/s
11:47:31 vt-ubuntu ▲ at its 4G max, 92% used
11:48:40 vt-ubuntu ↓ 4G → 3.6G: 41% used
```

That is the history the header can't show: how a burst was absorbed. A `memramp` cycle produces
~15 lines over three minutes, and an idle box produces none. This works alongside A, not
instead of it.

## A shape for the code

`Status` stays a value, but gains a `kind` (`:fine`, `:raised`, `:lowered`, `:holding`,
`:at_floor`, `:at_max`, `:unsupported`, `:stale`, `:disabled`, `:stopped`) and a short
user-facing text. The `"VM reports …"` log line stays as it is for debug. The glyphs and
colours for each kind live in `lib/ui/`, as the invariant requires.

*acted* needs one change in `BallooningVM`: remember the last action (kind, text, uptime) so the
next "no new data" tick can still report it. The voters' reasons already read well after a
colon ("usage is at or over the 65% trigger"); the header may want them shorter
(`Q_reason_wording`).

## Open questions

- `Q_which_view`: A, B, C, or A + C? My lean is **A + C**. A answers "what now" at a glance,
  and C answers "what happened".
- `Q_acted_lifetime`: how long ↑/↓ and their text stay up after the action. Until the next
  state change (so a VM that stops at 2.6G says "raised to 2.6G" for an hour), or ~10 s and
  then back to *fine*? I lean towards ~10 s. After that "fine" is the truth.
- `Q_glyphs`: `↑ ↓ ⏸ ▲ _ - x`? `⏸` is emoji-width in some fonts, and the Promise is no special
  font. `=` or `‖` for holding might be safer.
- `Q_at_max_severity`: red as soon as it's capped, or only once the guest is also swapping?
  A guest capped at 66% is fine, one capped at 95% and swapping is not.
- `Q_narrow`: below what width do the words drop, and do they drop before the IP?
- `Q_reason_wording`: reuse the voters' reasons verbatim, or a shorter header form ("70% used",
  "swapping 20M/s")?
- `Q_floor_shown`: is *at floor* worth any text at all, or is a dim `_` enough? It is the
  normal resting state of an idle small VM.
