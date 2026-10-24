# Show why the balloon controller is doing nothing

**Status:** suggested 2026-10-24, not decided.

## The problem

`BallooningVM#status` explains every tick's decision: "ballooning unsupported by the VM",
"guest memory data is stale", "not lowering memory: the guest swapped recently", "want to raise
memory … but can't go over configured max mem". Only `$log.debug` ever sees it. The screen
shows 🎈 and an arrow, so a VM the controller has given up on looks the same as one it is
happily leaving alone.

That is how the old fixed 8 GiB floor hid. On a 4 GiB `vt-ubuntu` every tick said "VM max
memory … is below min_actual, doing nothing", and nothing on screen did. A guest at 95% RAM,
600 MiB swapped, had its load OOM-killed while virtui watched.

## Options

- A dim one-line status under the VM's RAM row, or at the end of its header line.
- Only the focused VM's status, in the bottom status bar.
- Only the *stuck* cases (at max, unsupported, stale), as a glyph beside 🎈 with the text in
  the status bar on focus.

## Open questions

- `Q_which_statuses`: every status, or only the ones where the controller wants to act and
  cannot? "nothing to do" every 2 s is noise.
- `Q_where`: per-VM row, or the status bar for the focused VM?
