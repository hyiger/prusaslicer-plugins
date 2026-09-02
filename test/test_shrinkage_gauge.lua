-- Regression tests for shrinkage_gauge.lua. See harness.lua for the stub.
--   cd test && lua test_shrinkage_gauge.lua
dofile("harness.lua")
dofile("../com.hyiger.slicer.calibration/shrinkage_gauge.lua")

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

local function run(over)
    reset("COREONE", 0.2)
    local o = {arm_length = 100, brim_width = 0}
    for k, v in pairs(over or {}) do o[k] = v end
    execute(o)
    local r = {sets = {}, volumes = nil, gcodes = 0, cleared = false}
    for _, e in ipairs(getlog()) do
        if e.set then r.sets[e.set] = e.value end
        if e.add_object then r.volumes = e.add_object end
        if e.gcode then r.gcodes = r.gcodes + 1 end
        if e.clear then r.cleared = true end
    end
    return r
end
local function count(vols, pred)
    local n = 0
    for _, v in ipairs(vols) do if pred(v) then n = n + 1 end end
    return n
end
local solid    = function(v) return v.mesh.kind == "cube" and v.type == nil end
local negative = function(v) return v.type == VolumeType.Negative end
local label    = function(v) return v.mesh.kind == "text" end

-- ------------------------------------------------------------- structure ---
local r = run()
-- 3 arms + 3 holes/arm * 3 arms + one label each = 3 + 9 + 9
check("volume count at 100 mm", #r.volumes, 21)
check("three solid arms",       count(r.volumes, solid), 3)
check("nine holes",             count(r.volumes, negative), 9)
check("nine labels",            count(r.volumes, label), 9)
check("holes are Negative volumes, not booleans",
      r.volumes[4].type, VolumeType.Negative)

-- The first volume is the X arm, passed as add_object's `mesh`.
approx("X arm length", r.volumes[1].mesh.dims[1], 100)
approx("X arm section", r.volumes[1].mesh.dims[2], 10)
approx("Y arm runs along Y", r.volumes[2].mesh.dims[2], 100)
approx("Z arm runs along Z", r.volumes[3].mesh.dims[3], 100)

-- ------------------------------------------------------------- the datum ---
-- The whole point of the gauge: a hole labelled 25 must have its near edge at
-- exactly 25 mm, so a caliper jaw registering there reads 25.
local first_hole
for _, v in ipairs(r.volumes) do
    if negative(v) and v.translate and math.abs(v.translate.x - 25) < 1e-6 then
        first_hole = v; break
    end
end
check("a hole starts at the 25 mm datum", first_hole ~= nil, true)
if first_hole then
    approx("hole is 5 mm square", first_hole.mesh.dims[1], 5)
    approx("hole is centred in the bar", first_hole.translate.z, 2.5)
end

-- ------------------------------------------------------------ hole counts ---
local function holes_for(len) return count(run{arm_length = len}.volumes, negative) end
-- The fork's bound is `pos + HOLE_SIZE <= length - 0.5`, so the first hole at
-- 25 mm needs 30.5 mm of arm. Anything shorter is a gauge with no marks on it
-- at all -- matching the fork, but worth knowing before printing a 20 mm one.
check("20 mm arms fit no holes",   holes_for(20),  0)
check("30 mm arms fit no holes",   holes_for(30),  0)
check("30.5 mm is the threshold",  holes_for(30.5), 3)
check("55 mm arms fit one each",   holes_for(55),  3)
check("100 mm arms fit three each", holes_for(100), 9)
check("200 mm arms fit seven each", holes_for(200), 21)

-- ---------------------------------------------------------------- labels ---
-- X-arm labels lie flat unrotated; Y-arm labels are spun 90 about Z so they run
-- ALONG the arm rather than across its 10 mm width; Z-arm labels stand on -Y.
local flat, spun, front = 0, 0, 0
for _, v in ipairs(r.volumes) do
    if label(v) then
        if v.rotate and v.rotate.x == 90 then front = front + 1
        elseif v.rotate and v.rotate.z == 90 then spun = spun + 1
        else flat = flat + 1 end
    end
end
check("three X-arm labels lie flat", flat, 3)
check("three Y-arm labels are spun 90", spun, 3)
check("three Z-arm labels stand on the front face", front, 3)

-- Rotation happens about the mesh origin before the offset, so a spun label is
-- only centred if the translate swaps the axes. Check where it actually lands:
-- across the arm it must sit on the 5 mm centreline, and along the arm it must
-- sit on its hole's midpoint.
for _, v in ipairs(r.volumes) do
    if label(v) and v.rotate and v.rotate.z == 90 then
        local b = v.mesh:bounds()
        -- after rotate z=90: x spans (-max_y, -min_y), y spans (min_x, max_x)
        local cx = v.translate.x + (-b.max_y + -b.min_y) / 2.0
        local cy = v.translate.y + (b.min_x + b.max_x) / 2.0
        approx("spun label is centred across the arm", cx, 5.0)
        approx("spun label is centred on its hole", cy, 25 + 5 / 2.0)
        approx("spun label sits on the top face", v.translate.z, 10)
        break
    end
end

-- A top label's underside must land exactly on the bar's top face, or it floats.
for _, v in ipairs(r.volumes) do
    if label(v) and not v.rotate then
        approx("top label sits on the 10 mm face", v.translate.z, 10)
        break
    end
end

-- ---------------------------------------------------------------- presets ---
check("brim written",        r.sets["print.brim_width"], 0.0)
check("brim honoured",       run{brim_width = 5}.sets["print.brim_width"], 5.0)
check("negative brim clamped", run{brim_width = -3}.sets["print.brim_width"], 0.0)
check("no other preset touched", (function()
    local n = 0
    for _ in pairs(r.sets) do n = n + 1 end
    return n
end)(), 1)

-- ------------------------------------------------------------ leftovers ---
-- A previous PA or fan run leaves per-layer commands on the bed; a gauge that
-- inherited them would carry a stray M572 into the print.
check("previous custom G-code cleared", r.cleared, true)
check("gauge adds no G-code of its own", r.gcodes, 0)

-- ----------------------------------------------------------------- input ---
local function survives(over)
    reset("COREONE", 0.2)
    local o = {arm_length = 100, brim_width = 0}
    for k, v in pairs(over or {}) do o[k] = v end
    return pcall(function() execute(o) end)
end
check("below minimum still builds", (survives{arm_length = 5}), true)
check("above maximum still builds", (survives{arm_length = 5000}), true)
check("garbage still builds",       (survives{arm_length = "abc"}), true)
check("empty box still builds",     (survives{arm_length = ""}), true)
check("string input parses",        count(run{arm_length = "100"}.volumes, negative), 9)
check("short arms clamp to 20", #run{arm_length = 5}.volumes, 3)
check("long arms clamp to 200", count(run{arm_length = 5000}.volumes, negative), 21)

local opts_for_order = {arm_length = 100, brim_width = 0}

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
