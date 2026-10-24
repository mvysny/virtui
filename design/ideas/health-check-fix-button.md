# Health check v2: a Fix button on the findings it can fix

v1 (`M` → Health check, `D_health_check`) lists findings read-only, each fix in words. v2 turns
the window into a picker: a finding whose fix is something virtui can already do shows a
`Fix` button, and pressing it runs that flow.

## Shape (agreed 2026-10-24)

- `Virt::Health::Finding` gains `remedy` [Symbol, nil], e.g. `:grow_root` on the free-tail
  note. Data, not a block: see `D_health_check`.
- `UI::HealthWindow` maps a remedy it knows to the existing `VMPane` flow (`grow_root_filesystem`)
  and shows `Button("Fix")` beside that finding; an unknown or nil remedy shows no button.
- `fix` stays the words, for every finding.

## Open questions

- `Q_remedies`: which findings get one? Free tail → Grow root is the obvious one. The
  `discard=unmap` and balloon fixes would need virtui to edit the definition (`dumpxml
  --inactive`, edit, `define`), which v1 decided against. Is a confirmed definition edit worth
  it now that there's a button for it?
- `Q_after_fix`: re-run the check once the fix finishes, so the window shows the result?
- `Q_window`: a `PickerWindow` of findings, or the `TextView` with buttons inline? Tuile's
  widgets decide this; look before sketching.
