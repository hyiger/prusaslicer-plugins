# Plugin API: capability gaps found porting a calibration suite

**Version:** 3.0.0-alpha11 (`6f510128d7`) · **Type:** feature request

## Context

We maintain a PrusaSlicer fork with a calibration and maintenance suite, and
tried to move it onto the 3.0 plugin API so it stops being a merge burden. Of
ten tools, **six port cleanly**; three are blocked on a single missing hook; two
cannot be expressed at all.

This is a report on where the boundary sits, from someone who went looking for
it. The API is a good design — `project.plugin` covers "generate geometry and
per-layer G-code" thoroughly, and Prusa's own temperature and flow towers are
proof. Everything below is about the next tier of plugin.

## What ported without friction

Pressure-advance tower, fan-speed tower, max-flow tower, shrinkage gauge,
extrusion-multiplier cube, temperature tower. All are geometry plus per-layer
G-code plus numeric preset writes, which the API handles well. `add_object`'s
automatic bed-centring and `other_volumes` composition in particular made the
geometry straightforward. We have the pressure-advance tower working as a plugin
today; the temperature and flow towers duplicate what Prusa already ships, which
is itself a good sign about where the API's centre of gravity is.

## Gap 1 — no mesh construction from vertices

`api.make_*` covers eleven primitives, plus `emboss_text`, `emboss_svg` and
`load_stl`. There is no way to build a mesh from vertex and index data.

Anything whose shape is computed rather than assembled from boxes is therefore
out of reach: heightfields, lofted profiles, swept sections, any surface derived
from measured data. Our bed-mesh visualiser needs exactly this — a probe grid is
an arbitrary heightfield and cannot be approximated by primitives without
becoming a different thing (a bar chart).

There is also no boolean operation, so the fork's frame-minus-cutout shapes have
to be rebuilt as four separate bars. Workable, but only because the shapes happen
to be rectangular.

**Ask:** `api.make_mesh{vertices = {...}, triangles = {...}}`, and ideally
`mesh:minus(other)` / `mesh:union(other)`. The underlying
`indexed_triangle_set` and CGAL booleans are already there; this is a binding,
not new machinery.

## Gap 2 — no rendering hooks

Plugins can add objects to the project and nothing else. There is no way to draw
an overlay, register a shader, or add a viewport panel.

Our bed-mesh visualiser renders a colour-mapped overlay on the bed itself with a
dedicated GLSL program, plus a stats panel and a baseline-vs-current compare
mode. None of that has an expression in the API — and unlike Gap 1, no
approximation gets close, because the value is in registering the data *to the
bed*, not in having a model of it.

**Ask:** even a narrow hook would help — a way to supply a per-cell colour map
for the bed surface, or a read-only 2D panel a plugin can populate. Full
shader access is presumably not on the table, and does not need to be.

## Gap 3 — no device access

Several maintenance tools drive the printer directly over USB serial: a guided
cold-pull procedure with prompts on the printer's screen, and a bed-mesh probe
run (`G28` → `G29` → `M420 V1 T1`, parsed back). Both are inherently about
talking to the machine.

We understand why arbitrary device access is not in a sandbox that
deliberately withholds `os` and `io`. But the current position means the entire
category of maintenance plugins is impossible, and those are exactly the tools
users most want to share.

**Ask:** a brokered channel rather than raw access — the host owns the port and
the plugin submits a script of commands and receives parsed responses, with the
user confirming the connection. A capability declared in `manifest.json` and
approved at install time would fit the existing signing and trust model.

## Gap 4 — no way to emit a standalone G-code file

The only G-code mechanism is `insert_layer_custom_gcode(bed, z, gcode)`, which
attaches to a sliced project. A plugin that needs to produce a self-contained
procedure has to put a placeholder object on the plate and accept the profile's
entire start G-code — bed heat, homing, mesh levelling, prime line — wrapped
around its output.

For a maintenance procedure that is not merely untidy but unsafe: our cold-pull
file opens with `M862.3 P"COREONEINDX"` specifically so the printer refuses to
run it on the wrong model, and that guard has to be the first thing the printer
sees. As a plugin it would land after the preamble, behind a heated bed and a
prime line extruded through the very nozzle being cleaned.

Note this gap is partly a consequence of report 03: if `start_gcode` and
`end_gcode` were writable, a plugin could clear the preamble itself.

**Ask:** either make those two options writable, or add an explicit
`api.project:set_output_gcode(text)` for plugins that generate a procedure
rather than a print.

## Gap 5 — no post-processor hook

Three of our tools rewrite emitted G-code: per-object extrusion scaling for a
flow-rate test, per-Z-band retraction rewriting, and toolpath splicing for a
pressure-advance line pattern. `insert_layer_custom_gcode` inserts *between*
layers and cannot modify what the slicer produced.

**Ask:** a Lua callback invoked per emitted line or per layer during export,
even a read-and-replace one. This is the largest ask here and we would not
expect it soon; it is listed for completeness, since it is what separates
"plugins that add objects" from "plugins that change how things print".

## Smaller items

- `BedInstRef:printer_config()` is bound (`ProjectApi.cpp:779`) but carries no
  `//--` annotations, so it is absent from the generated stub and from
  `Plugin_API.md`. It exposes `name`, `tool_count` and `tools`, which is the
  natural way to write toolchanger-aware plugins — worth documenting.
- `Plugin_API.md` lists param types as `float`, `int` and `bool`. `string` is
  also supported (`PluginDialog.cpp:181`) and is used by the bundled
  `lua_template`'s own hello-world.
- `plugin keygen --help` has the `-P/--private` and `-p/--public` descriptions
  swapped (`ReadCLI.cpp:884` and `:893`): `-p,--public` is described as "Path to
  generated private key", and vice versa. The behaviour is correct; only the
  help text is wrong.

## Summary

| Gap | Blocks | Rough cost |
|---|---|---|
| Mesh from vertices | any computed geometry | binding over existing types |
| Render hooks | visualisers, overlays | new surface |
| Device access | maintenance tools | new surface, needs a trust model |
| Standalone G-code output | procedure generators | small, if 03 is fixed |
| Post-processor hook | anything that rewrites toolpaths | large |

The first and fourth look inexpensive relative to what they unlock, and would
between them move two of our three blocked tools onto the API.
