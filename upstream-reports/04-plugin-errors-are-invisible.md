# Plugin API: `execute()` failures are never shown to the user

**Version:** 3.0.0-alpha11 (`6f510128d7`) · **Type:** bug / UX · **Severity:** medium

## Summary

When a plugin's `execute()` raises, the error goes to the log and nowhere else.
The dialog closes, nothing happens, and the user is given no indication that
anything went wrong.

## Evidence

`src/slic3r-shared/src/Slic3r/App/Lua/Plugin.cpp:172`

```cpp
if (const sol::protected_function_result ret = fn(opts); !ret.valid()) {
    const sol::error err = ret;
    SPDLOG_ERROR("Error executing script {}: {}", m_path, err.what());
}
```

`PluginSystem::execute_plugin` likewise only `SPDLOG_ERROR`s its two catch
blocks.

## Why it matters

A plugin cannot validate its input. Calling `error("End PA must be greater than
start PA")` produces exactly the same user-visible outcome as a plugin that
crashed, or one that silently did nothing: an unchanged plate.

We hit this in combination with the `float`/`int` swap (see report 01). Decimal
defaults were truncated to `0`, the plugin's own range check then failed, and the
user saw an empty bed with no message. Two clear failures, both invisible.

The workaround is to never raise: repair bad input, clamp it, and log what was
changed. That is strictly worse than telling the user, and it means plugins
quietly do something other than what was asked.

## Suggested fix

Surface the Lua error in the plugin dialog or as a notification — the same
treatment `PluginRegistry::install()` already gives installation failures, which
do reach the UI. Reusing `IPluginInstallationListener`'s pattern for execution
errors would be consistent with what is already there.
