# VM info window: "changed, takes effect on next boot"

The `i` window (`UI::VMInfoDialog`) shows the live XML of a running domain. A marker for a
definition edited since the VM started would need `dumpxml --inactive` too, and a comparison.

- `Q_live_or_inactive`: compare the two XMLs char-by-char? Never equal for a running domain:
  the live one adds `id=`, an `<alias>` per device, `index=` and `<backingStore>` per disk,
  `<resource>`, assigned ports and the agent's `state=`, and `<currentMemory>` is wherever the
  balloon has it (virtui moves it itself). The vt-ubuntu fixtures differ in 98 lines, one of
  them a real pending change (`discard='unmap'`). Counter-proposal: compare the two parsed
  `DomainConfig`s with the runtime-only fields (`running`, `agent` state, graphics `port`)
  normalized away, and name the fields that differ — `Pending   vda discard, max memory —
  takes effect once powered off and on`. Watch out for `host-model`: the live XML may expand
  it to `custom` + a model (unverified).
