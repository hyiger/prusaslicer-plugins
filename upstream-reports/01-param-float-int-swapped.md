# Plugin API: `float` and `int` param types are swapped

**Version:** 3.0.0-alpha11 (`6f510128d7`) · **Type:** bug · **Severity:** high — silent data loss

> **Already reported upstream as [#15611](https://github.com/prusa3d/PrusaSlicer/issues/15611)**
> (opened 2026-09-01 by `erikbuild`, independently). Do not file this again. Kept
> here as the reference for our own workaround.

## Summary

`PluginDialog::emplace_float_param()` builds an **integer** control and
`emplace_int_param()` builds a **double** control. A plugin declaring
`type = "float"` gets an integer input box, which silently **rounds** any
fractional default or entry to a whole number — `IntValidator::process` rounds
and clamps, so `0.005` becomes `0` and `0.6` becomes `1`.

## Evidence

`src/slic3r-shared/src/Slic3r/App/Lua/PluginDialog.cpp`

```cpp
// line 248, inside emplace_float_param()
using Control = NumberControl<Yoga::IntValidator, int>;

// line 262, inside emplace_int_param()
using Control = NumberControl<Yoga::DoubleValidator, double>;
```

## Reproduce

```lua
info = {
    id = "repro", type = "project.plugin", title = "Repro", menu = "Repro/Float",
    params = { {name = "k", label = "K", type = "float", default = 0.005} }
}
function execute(opts) print("k = " .. tostring(opts.k)) end
```

The dialog shows `0`, not `0.005`. Integral defaults such as `100` are unaffected,
which makes the bug easy to miss — in a dialog of six params, only the ones with
fractional defaults collapse.

This is particularly damaging for calibration plugins, where the interesting
quantities (pressure advance, extrusion multiplier, retraction) are all fractions
well below 1. Every such value silently becomes 0.

## Fix

Swap the two `using Control = ...` lines.

## Note

The obvious workaround — declaring the param `"int"` to obtain the double control
— produces a plugin that breaks the moment this is fixed. Until then, the only
forward-compatible option is to declare such params `"string"` and parse them in
Lua, which is what we ended up doing.
