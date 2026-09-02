-- Regression tests for fan_tower.lua. See harness.lua for the stub.
--   cd test && lua test_fan_tower.lua
dofile("harness.lua")
dofile("../com.hyiger.slicer.calibration/fan_tower.lua")

local pass, fail = 0, 0
local function check(name, got, want)
    if got == want then pass = pass + 1 else
        fail = fail + 1
        print(string.format("FAIL  %s\n        got  %s\n        want %s", name, tostring(got), tostring(want)))
    end
end
local function approx(name, got, want)
    if type(got) == "number" and math.abs(got - want) < 1e-6 then pass = pass + 1 else
        fail = fail + 1
        print(string.format("FAIL  %s\n        got  %s\n        want %s", name, tostring(got), tostring(want)))
    end
end

local BASE = {start_fan = 0, end_fan = 100, fan_step = 10, brim_width = 0}
local function run(over, notes, lh)
    reset(notes or "COREONE", lh or 0.2)
    local o = {}
    for k, v in pairs(BASE) do o[k] = v end
    for k, v in pairs(over or {}) do o[k] = v end
    execute(o)
    local r = {sets = {}, dropped = {}, missing = {}, gcodes = {}, volumes = nil, cleared = false}
    for _, e in ipairs(getlog()) do
        if e.set then r.sets[e.set] = e.value end
        if e.set_DROPPED then r.dropped[#r.dropped + 1] = e.set_DROPPED end
        if e.set_missing then r.missing[#r.missing + 1] = e.set_missing end
        if e.gcode then r.gcodes[#r.gcodes + 1] = {z = e.z, g = e.gcode} end
        if e.add_object then r.volumes = e.add_object end
        if e.clear then r.cleared = true end
    end
    return r
end
local function kinds(vols, kind)
    local n = 0
    for _, v in ipairs(vols) do if v.mesh.kind == kind then n = n + 1 end end
    return n
end

-- --------------------------------------------------------------- levels ---
local r = run()
check("0-100 step 10 gives 11 levels", #r.gcodes, 11)
check("first level is start_fan",  r.gcodes[1].g,  "M106 S0 ; fan 0%")
check("last level is end_fan",     r.gcodes[11].g, "M106 S255 ; fan 100%")
check("50% maps to PWM 128",       r.gcodes[6].g,  "M106 S128 ; fan 50%")

-- Level 0 must land on the very first layer; the rest just inside their level.
approx("level 0 lands on layer 1", r.gcodes[1].z, 0.1)
approx("level 1 at base + one level", r.gcodes[2].z, 1.0 + 10.0 + 0.1)
approx("level 10 z", r.gcodes[11].z, 1.0 + 100.0 + 0.1)

-- ------------------------------------------------------------- geometry ---
-- 3 columns + base is the object mesh + per level a shelf, and a cone and
-- overhang on every level but the first.
-- volumes[1] is the base plate: add_object's own `mesh` comes first, then
-- other_volumes in order.
check("base plate is the first volume", r.volumes[1].mesh.kind, "cube")
approx("base plate is 1 mm thick", r.volumes[1].mesh.dims[3], 1.0)

check("three columns", kinds(r.volumes, "cylinder"), 3)
check("11 shelves plus the base plate", kinds(r.volumes, "cube"), 12)
check("cones on all but the settling level", kinds(r.volumes, "cone"), 10)
check("overhangs on all but the settling level", kinds(r.volumes, "prism"), 10)

local cols = {}
for _, v in ipairs(r.volumes) do
    if v.mesh.kind == "cylinder" then cols[#cols + 1] = v end
end
approx("column diameter", cols[1].mesh.dims[1], 5.0)
approx("columns span the full height", cols[1].mesh.dims[3], 1.0 + 11 * 10.0)
approx("columns 45 mm apart", cols[2].translate.x - cols[1].translate.x, 45.0)

-- The standalone column must not touch the pair, or it is not a stringing test.
local lone_x = cols[3].translate.x
check("standalone column is clear of the left one",
      (-22.5 - 2.5) - (lone_x + 2.5) > 0, true)

-- ------------------------------------------------------- fan interference ---
-- The three bools cannot be written, so the plugin must read them and warn.
check("bool writes are never attempted", #r.dropped, 0)
check("no write aimed at the wrong box", #r.missing, 0)
check("bridge fan disabled",     r.sets["material.bridge_fan_speed"], -1)
check("first-layer fan gate off", r.sets["material.disable_fan_first_layers"], 0)
check("full speed layer off",    r.sets["material.full_fan_speed_layer"], 0)
check("min fan zeroed",          r.sets["material.min_fan_speed"], 0)
check("max fan zeroed",          r.sets["material.max_fan_speed"], 0)
check("brim written",            r.sets["print.brim_width"], 0.0)

-- --------------------------------------------------------------- leftovers ---
check("previous custom G-code cleared", r.cleared, true)

-- ------------------------------------------------------------ layer height ---
for _, lh in ipairs({0.15, 0.3}) do
    local rr = run({}, "COREONE", lh)
    approx(string.format("lh=%.2f level 0 at half a layer", lh), rr.gcodes[1].z, lh / 2)
    approx(string.format("lh=%.2f level 1", lh), rr.gcodes[2].z, 11.0 + lh / 2)
end

-- ----------------------------------------------------------- input repair ---
local function survives(over)
    reset("COREONE", 0.2)
    local o = {}
    for k, v in pairs(BASE) do o[k] = v end
    for k, v in pairs(over or {}) do o[k] = v end
    local ok = pcall(function() execute(o) end)
    if not ok then return false, 0 end
    local n = 0
    for _, e in ipairs(getlog()) do if e.gcode then n = n + 1 end end
    return true, n
end
local function levels(over) local _, n = survives(over) return n end

check("reversed range still builds", (survives{start_fan = 100, end_fan = 0}), true)
check("reversed range sweeps upward", run{start_fan = 100, end_fan = 0}.gcodes[1].g,
      "M106 S0 ; fan 0%")
check("zero step still builds",   (survives{fan_step = 0}), true)
check("equal ends still build",   (survives{start_fan = 50, end_fan = 50}), true)
check("garbage still builds",     (survives{start_fan = "x", end_fan = "y"}), true)
check("empty boxes still build",  (survives{start_fan = "", fan_step = ""}), true)
check("string input parses",      levels{start_fan = "0", end_fan = "100", fan_step = "10"}, 11)
check("over-100 clamped",         levels{end_fan = 500}, 11)
check("negative clamped",         levels{start_fan = -50}, 11)
-- A 1% step over the full range would be 101 levels, i.e. a metre of tower.
check("level count capped", levels{fan_step = 1} <= 40, true)

local opts_for_order = (function() local o={} for k,v in pairs(BASE) do o[k]=v end return o end)()

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

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
