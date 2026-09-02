# Plugin API: `ConfigBox:set()` silently drops string and bool writes

**Version:** 3.0.0-alpha11 (`6f510128d7`) · **Type:** bug · **Severity:** high — fails silently

## Summary

`set_param()` handles five value types. Everything else hits a catch-all that
sets `success = false`, and the `ConfigBox:set` binding **discards that return
value**. A plugin writing a string or bool option gets no error, no log line, and
no effect.

## Evidence

`src/slic3r-shared/src/Slic3r/App/Lua/ProjectApi.cpp`

The visitor at line 160 covers `double`, `int`, `Percentage`,
`FloatOrPercentage` and `EnumWrapper`. Anything else:

```cpp
[&success](auto& val) { success = false; }   // line 212
```

And the binding throws the result away:

```cpp
"set", [](Domain::ConfigBox& config, const std::string& name, const sol::object& value)
{
    set_param(config, name, value);          // line 730 — return value ignored
}
```

## Why it matters

The read path is asymmetric with the write path, in both directions:

| Type | `ConfigBox:value()` reads | `ConfigBox:set()` writes |
|---|---|---|
| `std::string` | yes | **no — silently dropped** |
| `bool` | yes | **no — silently dropped** |
| `EnumWrapper` | **no — throws "Unsupported config type"** | yes |

`ExposedConfigValue` (line 627) lists `bool` and `std::string` but not
`EnumWrapper`; `set_param` covers `EnumWrapper` but neither of the other two.
Neither asymmetry looks deliberate — nothing about writing a string is less safe
than writing an enum, and the real sandboxing (no `os`, no `io`,
directory-scoped `require`) is implemented elsewhere and much more carefully.

Concrete consequences we hit:

- `variable_layer_height` (bool) cannot be disabled, so a plugin that lays out
  per-layer G-code cannot guarantee its level boundaries line up with layers.
- `start_gcode` / `end_gcode` (strings) cannot be set, so anything a plugin
  generates is unavoidably wrapped in the profile's own preamble — bed heat,
  homing, mesh levelling, prime line. This alone rules out maintenance and
  diagnostic plugins that must emit a specific, self-contained G-code sequence.
- `gcode_flavor` (enum) cannot be read, so a plugin cannot tell which firmware
  dialect the printer speaks. Selecting between `M572`, `M900 K` and
  `SET_PRESSURE_ADVANCE` has to fall back to regex-matching `printer_notes`.

## Suggested fix

1. Add `std::string` and `bool` cases to the `set_param` visitor.
2. Add `EnumWrapper` to `ExposedConfigValue`, returning its serialized string.
3. Raise a Lua error when `set_param` returns false, rather than discarding it.
   Silent no-ops are the worst failure mode here: the plugin author sees working
   code that does nothing.
