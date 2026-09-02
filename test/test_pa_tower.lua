-- Regression tests for pa_tower.lua, run against a stub of the PrusaSlicer 3.0
-- plugin sandbox (see harness.lua). This exists because building PrusaSlicer
-- 3.0 takes far longer than the edit/check loop these tests give you.
--
--   cd test && lua test_pa_tower.lua
--
-- The stub mirrors ProjectApi.cpp deliberately, including the parts that bite:
-- ConfigBox:set() drops bool and string writes silently, and ConfigBox:value()
-- throws on a missing key and on any enum (EnumWrapper is absent from
-- ExposedConfigValue, so gcode_flavor is unreadable from Lua).

dofile("harness.lua")
dofile("../com.hyiger.slicer.calibration/pa_tower.lua")

local pass, fail = 0, 0
local function check(name, got, want)
    if got == want then
        pass = pass + 1
    else
        fail = fail + 1
        print(string.format("FAIL  %s\n        got  %s\n        want %s",
                            name, tostring(got), tostring(want)))
    end
end
local function approx(name, got, want)
    if type(got) == "number" and math.abs(got - want) < 1e-6 then
        pass = pass + 1
    else
        fail = fail + 1
        print(string.format("FAIL  %s\n        got  %s\n        want %s (+-1e-6)",
                            name, tostring(got), tostring(want)))
    end
end

-- The three PA values are declared as string params (the alpha11 float/int
-- swap truncates a "float" box to an integer), so the dialog hands them over
-- as strings. Defaults here mirror info.params exactly.
local BASE = {start_pa = "0.0", end_pa = "0.1", pa_step = "0.005",
              test_speed = 100, brim_width = 0, pa_command = "auto"}
local function opts(over)
    local o = {}
    for k, v in pairs(BASE) do o[k] = v end
    for k, v in pairs(over or {}) do o[k] = v end
    return o
end

-- Collect a run into something assertable.
local function run(notes, layer_height, over, model)
    reset(notes, layer_height, model)
    execute(opts(over))
    local r = {sets = {}, dropped = {}, missing = {}, gcodes = {}, volumes = nil}
    for _, e in ipairs(getlog()) do
        if e.set          then r.sets[e.set] = e.value end
        if e.set_DROPPED  then r.dropped[#r.dropped + 1] = e.set_DROPPED end
        if e.set_missing  then r.missing[#r.missing + 1] = e.set_missing end
        if e.gcode        then r.gcodes[#r.gcodes + 1] = {z = e.z, g = e.gcode} end
        if e.add_object   then r.volumes = e.add_object end
    end
    return r
end

local function prefix_of(r) return (r.gcodes[1].g:gsub("[%d%.]+$", "")) end

-- ---------------------------------------------------------------- levels ---
local r = run("PRINTER_MODEL_COREONE", 0.2)
check("21 levels + 1 reset entry", #r.gcodes, 22)
check("first PA is start_pa",      r.gcodes[1].g,  "M572 S0.0000")
check("last level is end_pa",      r.gcodes[21].g, "M572 S0.1000")
check("trailing reset to zero",    r.gcodes[22].g, "M572 S0.0000")
approx("first insert is mid-layer 1",  r.gcodes[1].z,  0.1)
approx("levels are 4 layers apart",    r.gcodes[2].z,  0.9)
approx("last level z",                 r.gcodes[21].z, 16.1)
approx("reset sits in the top layer",  r.gcodes[22].z, 16.7)

-- The +1e-9 epsilon in num_levels: without it (0.1-0.0)/0.005 can floor to 19
-- and silently drop a level. Guard the exact case that trips it.
check("no off-by-one from float division", #run("COREONE", 0.2).gcodes, 22)

-- ------------------------------------------------------------- geometry ---
check("2 arms + 4 frame bars", #r.volumes, 6)
approx("arm length",     r.volumes[1].mesh.dims[1], 40.0)
approx("arm width",      r.volumes[1].mesh.dims[2], 1.6)
approx("arm height = total layers x lh", r.volumes[1].mesh.dims[3], 16.8)
approx("arm centred on Y before rotation", r.volumes[1].mesh.off[2], -0.8)
check("arms splay symmetrically",
      r.volumes[1].rotate.z + r.volumes[2].rotate.z, 0.0)
approx("half the corner angle", r.volumes[1].rotate.z, 45.0)
for i = 3, 6 do
    approx("frame bar " .. i .. " is one layer tall", r.volumes[i].mesh.dims[3], 0.2)
end
-- Frame must enclose the chevron: arms reach 28.8500 in +X and +-28.8500 in Y.
approx("frame outer width",  r.volumes[3].mesh.dims[1], 31.4156421)
approx("frame outer height", r.volumes[5].mesh.dims[2] + 2 * 1.6, 59.6999134)
approx("right bar sits at the outer edge", r.volumes[6].translate.x, 28.2499567)

-- -------------------------------------------------------------- presets ---
check("no write was silently dropped", #r.dropped, 0)
check("no write aimed at the wrong box", #r.missing, 0)
check("perimeter speed forced",  r.sets["print.perimeter_speed"], 100.0)
check("external perimeter speed forced", r.sets["print.external_perimeter_speed"], 100.0)
check("gap fill speed forced",   r.sets["print.gap_fill_speed"], 100.0)
check("layer height pinned",     r.sets["print.layer_height"], 0.2)
check("cooling slowdown off",    r.sets["material.slowdown_below_layer_time"], 0)
check("min print speed raised",  r.sets["material.min_print_speed"], 100.0)
check("brim off by default",     r.sets["print.brim_width"], 0.0)
check("brim honoured", run("COREONE", 0.2, {brim_width = 5.0}).sets["print.brim_width"], 5.0)

-- ------------------------------------------------------------- firmware ---
check("Core One -> M572",        prefix_of(run("PRINTER_MODEL_COREONE", 0.2)), "M572 S")
check("MK4IS -> M572",           prefix_of(run("PRINTER_MODEL_MK4IS", 0.2)), "M572 S")
check("MK3.9 carries MK4IS",     prefix_of(run("PRINTER_MODEL_MK4IS", 0.2)), "M572 S")
check("MK4S -> M572",            prefix_of(run("PRINTER_MODEL_MK4S", 0.2)), "M572 S")
check("XL IS -> M572",           prefix_of(run("PRINTER_MODEL_XLIS", 0.2)), "M572 S")
check("MK3.5 -> M572",           prefix_of(run("PRINTER_MODEL_MK3.5", 0.2)), "M572 S")
check("MINI IS -> M572",         prefix_of(run("PRINTER_MODEL_MINIIS", 0.2)), "M572 S")
check("markers are case-insensitive", prefix_of(run("printer_model_mk4is", 0.2)), "M572 S")
check("MK3 has no marker -> M900", prefix_of(run("PRINTER_MODEL_MK3", 0.2)), "M900 K")
check("empty notes -> M900",     prefix_of(run("", 0.2)), "M900 K")
check("Klipper detected",        prefix_of(run("Klipper generic", 0.2)),
      "SET_PRESSURE_ADVANCE ADVANCE=")
check("override m572",    prefix_of(run("", 0.2, {pa_command = "m572"})), "M572 S")
check("override m900",    prefix_of(run("COREONE", 0.2, {pa_command = "m900"})), "M900 K")
check("override klipper", prefix_of(run("COREONE", 0.2, {pa_command = "klipper"})),
      "SET_PRESSURE_ADVANCE ADVANCE=")
check("override is case-insensitive", prefix_of(run("", 0.2, {pa_command = "M572"})), "M572 S")

-- printer_notes missing from the box entirely must not abort the run.
reset("COREONE", 0.2)
local pp = api.project:current_bed():printer_presets()
pp.value = function(self, k) error("Invalid preset item name '" .. k .. "': not found") end
local ok = pcall(function() execute(opts()) end)
check("absent printer_notes falls back cleanly", ok, true)

-- --------------------------------------------------- input repair ---------
-- execute() failures are only SPDLOG_ERROR'd, never shown in the UI, so bad
-- input must never abort: an aborted run looks identical to a broken plugin.
local function survives(over)
    reset("COREONE", 0.2)
    local ok = pcall(function() execute(opts(over)) end)
    if not ok then return false, 0 end
    local n = 0
    for _, e in ipairs(getlog()) do if e.gcode then n = n + 1 end end
    return true, n
end
local function levels(over) local _, n = survives(over) return n - 1 end

-- Defaults must survive the round trip through string params.
check("string defaults parse", levels{}, 21)
check("numeric params still accepted", levels{start_pa = 0.0, end_pa = 0.1, pa_step = 0.005}, 21)
check("whitespace tolerated", levels{end_pa = "  0.1  "}, 21)

-- Each of these used to abort with an invisible error. All must now build.
check("start == end still builds",   (survives{start_pa = "0.1", end_pa = "0.1"}), true)
check("reversed range still builds", (survives{start_pa = "0.2", end_pa = "0.1"}), true)
check("zero step still builds",      (survives{pa_step = "0"}), true)
check("negative step still builds",  (survives{pa_step = "-0.01"}), true)
check("sub-step range still builds",
      (survives{start_pa = "0.0", end_pa = "0.004", pa_step = "0.005"}), true)
check("garbage text still builds",   (survives{start_pa = "abc", end_pa = "xyz"}), true)
check("empty boxes still build",     (survives{start_pa = "", end_pa = "", pa_step = ""}), true)
check("unknown pa_command still builds", (survives{pa_command = "marlin"}), true)
check("unknown pa_command falls back to auto-detect",
      prefix_of(run("COREONE", 0.2, {pa_command = "marlin"})), "M572 S")

-- Reversed input is swapped, not discarded: 0.2..0.1 sweeps 0.1 up to 0.2.
local rev = run("COREONE", 0.2, {start_pa = "0.2", end_pa = "0.1"})
check("swap keeps the low end first", rev.gcodes[1].g, "M572 S0.1000")

-- A mistyped step must not produce a metre-tall tower.
local huge = run("COREONE", 0.2, {start_pa = "0", end_pa = "2", pa_step = "0.0001"})
check("level count capped", #huge.gcodes <= 101, true)
check("capped tower stays printable", huge.volumes[1].mesh.dims[3] <= 100 * 4 * 0.2, true)

-- Negative brim would be rejected by the slicer; clamp it.
check("negative brim clamped", run("COREONE", 0.2, {brim_width = -5}).sets["print.brim_width"], 0.0)
check("non-positive speed replaced",
      run("COREONE", 0.2, {test_speed = 0}).sets["print.perimeter_speed"], 100.0)

-- ---------------------------------------------------- layer height sweep ---
for _, lh in ipairs({0.1, 0.15, 0.25, 0.3}) do
    local rr = run("COREONE", lh)
    approx(string.format("lh=%.2f arm height", lh), rr.volumes[1].mesh.dims[3], 84 * lh)
    approx(string.format("lh=%.2f reset z", lh), rr.gcodes[22].z, 84 * lh - lh / 2)
end
-- A nonsense layer height falls back to 0.2 rather than producing a zero-height object.
approx("bad layer height falls back to 0.2", run("COREONE", -1).volumes[1].mesh.dims[3], 16.8)

local opts_for_order = opts()

-- ------------------------------------------------------------- call order ---
-- Custom G-code written AFTER add_object never reaches the exported file: the
-- slice carries the geometry and none of the commands, with no error anywhere.
-- Prusa's own temp_tower.lua inserts first. This pins that order.
do
    reset("COREONE", 0.2)
    execute(opts_for_order)
    local add_at, last_gcode_at = nil, nil
    for i, e in ipairs(getlog()) do
        if e.add_object then add_at = i end
        if e.gcode or e.clear then last_gcode_at = i end
    end
    check("add_object happens", add_at ~= nil, true)
    if add_at and last_gcode_at then
        check("custom G-code is written before add_object", last_gcode_at < add_at, true)
    else
        check("custom G-code calls were made", last_gcode_at ~= nil, true)
    end
end

-- ------------------------------------------- printer_model fallback --------
-- Regression: a Core One INDX exports printer_notes EMPTY and
-- printer_model = COREONE_INDX4T, with gcode_flavor = reprap. Notes-only
-- detection fell through to M900 K, which Buddy firmware ignores -- the tower
-- printed and calibrated nothing. gcode_flavor cannot be read from Lua at all,
-- so printer_model is the only signal left.
check("Core One INDX detected from printer_model",
      prefix_of(run("", 0.2, nil, "COREONE_INDX4T")), "M572 S")
check("notes still win when both are present",
      prefix_of(run("PRINTER_MODEL_MK4IS", 0.2, nil, "SOMETHING_ELSE")), "M572 S")
check("model marker matches with an underscore suffix",
      prefix_of(run("", 0.2, nil, "MK4S_HT90")), "M572 S")
check("Klipper detected from model too",
      prefix_of(run("", 0.2, nil, "Klipper Voron")), "SET_PRESSURE_ADVANCE ADVANCE=")
check("both empty still falls back to M900",
      prefix_of(run("", 0.2, nil, "")), "M900 K")
check("an unknown model falls back to M900",
      prefix_of(run("", 0.2, nil, "ENDER3")), "M900 K")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
