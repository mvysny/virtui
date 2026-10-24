# VM info window: what `i` could show next

The `i` window (`UI::VMInfoWindow`) shipped 2026-10-24 with what `dumpxml` holds. These were left
out to keep the first cut small:

- `Q_autostart`: "starts with the host" is a useful static fact, but it is not in the XML. It
  comes from `virsh dominfo` (`Autostart:`, `Persistent:`), one more spawned read inside the
  same `BackgroundTask`, plus its `VMEmulator` counterpart. Worth it?
- `Q_hostdev_names`: show `PCI 0000:01:00.0` as is (what ships), or resolve it to "NVIDIA RTX
  3060" through `/sys/bus/pci/devices/*/` or `lspci`? More useful, but it is a host read in
  `lib/system/` and a second source.
- `Q_window_size`: the popup is a fixed `Fraction.new(0.7, 0.8)`. A plain VM is ~20 rows, so
  the box is mostly empty. Tuile's `Popup` has no fit-to-content; a `Size` computed from the
  wrapped row count would need the width first.
- `Q_live_or_inactive`: the window shows the live XML of a running domain. A "changed, takes
  effect on next boot" marker would need `--inactive` too and a diff.
