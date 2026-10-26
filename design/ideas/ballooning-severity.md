# How alarmed should the balloon status be?

**Status:** seed (2026-10-26), to be brainstormed in its own session. Split off from the
balloon status in the VM header, built 2026-10-26.

## The question

The VM header colours the balloon status by severity (`UI::VMPane::BALLOON_GLYPHS`): grey,
yellow, red. Its one red state is *at max*: the guest wants more memory and virtui can't give
it. But "capped" covers everything from a guest that is fine to one about to OOM-kill its load. A guest capped at 66%
is fine. One capped at 95% and swapping is not. Red on every cap is a red that people learn to
ignore.

Until this is decided, the header goes red as soon as a guest is capped.

## Scenarios to grade

Each one needs a severity, and needs to say which reads tell it apart.

| # | Scenario | Reads available today |
|---|---|---|
| 1 | Capped at max, usage just over the raise trigger (~66%), no swap activity | `MemoryStat` usage |
| 2 | Capped at max, usage high (≥ 90%), no swap activity | `MemoryStat` usage |
| 3 | Capped at max, swapping out now | swap-out rate from `domstats` |
| 4 | Capped at max, swap nearly full | swap level via the guest agent (may be quiet) |
| 5 | Capped at max, the guest agent quiet, so swap level unknown | — |
| 6 | Capped below max because the host itself is short of RAM, if virtui ever refuses a raise for that reason | `System::` host RAM |
| 7 | Ballooning switched off (`x`) while the guest is short | `MemoryStat`, ballooning off |
| 8 | No balloon device (no 🎈) while the guest is short | `MemoryStat` only, if the stats period is set |
| 9 | Stale data (🐢) on a guest that was last seen short | the last `MemoryStat` |
| 10 | Held by the swap veto for a long time, again and again: memory sits unused, the opposite problem | swap veto re-arming |

## To decide

- How many levels: two (fine / red) or three (dim / yellow / red)?
- Is it the state alone, or how long it has lasted? (A cap that lasts 2 s against one that
  lasts 5 min.)
- Do 7–9 belong in the balloon status at all, or in the RAM bar's own colour?
- Does red also tell the user what to do (`mm`, a bigger `<memory>`), or is that the health
  check's job?
