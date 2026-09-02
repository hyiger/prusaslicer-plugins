# PrusaSlicer plugins — Filament Edition calibration

Lua plugins for **PrusaSlicer 3.0**, ported from the calibration tools in the
[Filament Edition fork](https://github.com/hyiger/PrusaSlicer). The plugin API
arrived in 3.0.0-alpha11; none of this works on 2.9.x.

Prusa's own bundle (`com.prusa3d.slicer.calibration`) ships a temperature tower
and a flow tower, so those are deliberately not duplicated here.

| Plugin | Menu | Status |
|---|---|---|
| `pa_tower.lua` | Calibration → Pressure Advance Tower | 75 tests |
| `shrinkage_gauge.lua` | Calibration → Shrinkage Gauge | 34 tests |
| `fan_tower.lua` | Calibration → Fan Speed Tower | 40 tests |

Bundle v0.3.0. All three load cleanly in 3.0.0-alpha11; none has been through a
real slice yet.

**Sharing this with someone else? Send them [INSTALL.md](INSTALL.md) and `hyiger.pem`
along with the zip** — the signed bundle will not install without the key, and
there is no in-app way to add it. See [PACKAGING.md](PACKAGING.md) for signing
and release steps.

## Install (this machine, development)

```bash
ln -s "$PWD/com.hyiger.slicer.calibration" \
      ~/Library/Application\ Support/PrusaSlicer/lua/com.hyiger.slicer.calibration
```

Then **Plugins → Rescan** in PrusaSlicer. The scan paths are `resources_dir()/lua`
and `data_dir()/lua`; the symlink above targets the second one on macOS.

## Test

There is no build of PrusaSlicer 3.0 in the loop, so the plugin is exercised
against a stub of the sandbox instead:

```bash
sh test/run_all.sh
```

`test/harness.lua` mirrors `ProjectApi.cpp` deliberately, including the sharp
edges: `ConfigBox:set()` drops `bool` and `string` writes **silently**, and
`ConfigBox:value()` throws both on a missing key and on any enum. Tests assert
that no write is dropped and none is aimed at the wrong preset box, which is the
only way to catch those two failure modes short of running the slicer.

## Known deviations from the fork

Both are forced by the 3.0 API, not by choice:

- **PA command auto-detection is `printer_notes` only.** The fork keys off
  `gcode_flavor` first. That option is an `EnumWrapper`, and the Lua read path
  (`ExposedConfigValue`) has no enum case, so reading it throws. The
  `pa_command` parameter is the escape hatch — set it to `m572`, `m900` or
  `klipper` when auto-detect guesses wrong.
- **The PA values are string inputs, not number boxes.** `float` and `int` are
  swapped in alpha11: `PluginDialog.cpp:242` builds a `"float"` param as
  `NumberControl<IntValidator, int>`, so a `"float"` box is really an integer box
  and truncates a default of `0.005` to `0`. String params are unaffected by the
  swap in either direction, so they keep working once Prusa fixes it — whereas
  declaring these `"int"` would work today and break on the fix.
- **Bad input is repaired, never rejected.** `execute()` failures are only
  `SPDLOG_ERROR`'d (`PluginSystem.cpp:172`) and never reach the UI, so raising an
  error looks exactly like a broken plugin: the dialog closes and the bed stays
  empty. A reversed range is swapped, a non-positive step is recomputed, garbage
  falls back to the default, and the level count is capped at 100. Every
  adjustment is appended to the summary line in the log.
- **The fan tower cannot silence the slicer's own fan control.** `cooling`,
  `fan_always_on` and `enable_dynamic_fan_speeds` are bools, so PrusaSlicer keeps
  emitting `M106` at every layer change and overwrites the sweep. The plugin
  *reads* those three (bool reads work) and warns in its log summary when they
  would interfere — turn them off on the Filament preset before slicing.
- **`variable_layer_height` is not disabled.** It is a `bool`, and `set_param()`
  drops bools silently. If you have variable layer height on, the PA level
  boundaries will not line up with the printed layers. Turn it off by hand.

## Before trusting the first print

Nothing here has been through a real slice yet. Check, in order:

1. The chevron and its frame appear on the plate, frame enclosing the V.
2. The object is 84 layers tall at 0.2 mm (16.8 mm) with default settings.
3. Preview shows a PA command every 4 layers, and the correct one for your
   printer — the plugin also prints a one-line summary to the log.
4. The four frame bars fuse into one closed rectangle rather than leaving seams.
