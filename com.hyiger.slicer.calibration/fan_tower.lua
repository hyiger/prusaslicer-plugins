-- Fan speed tower.
--
-- Ported from make_fan_tower() + CalibrationFanDialog in the Filament Edition
-- fork. Two columns carry a stack of bridged shelves; each 10 mm level also
-- gets a cone for fine-detail cooling and an overhang for slope cooling, plus a
-- standalone thin column beside the model to show stringing. One M106 per level
-- sweeps the fan across the range, so a single print shows where cooling stops
-- helping and starts warping.
--
-- Read the result from the top down: the highest fan speed that still bridges
-- cleanly without lifting corners is the one to keep.
--
-- IMPORTANT — this plugin cannot switch the slicer's own fan control off.
-- `cooling`, `fan_always_on` and `enable_dynamic_fan_speeds` are bool options,
-- and set_param() silently drops bool writes, so PrusaSlicer will keep emitting
-- its own M106 at every layer change and overwrite the sweep. The plugin READS
-- those three (bool reads work) and warns when they would interfere. Turn them
-- off by hand on the Filament preset before slicing.
--
-- Two deviations from the fork's geometry, both forced by the API:
--
--   1. The base plate is a plain box. The fork builds a chamfered plate from
--      explicit vertices, and there is no way to construct a mesh from vertex
--      data here. The chamfer was cosmetic.
--
--   2. The overhang is a symmetric prism, not a one-sided wedge. A right wedge
--      would need a Negative volume to halve a prism, and at this scale that
--      negative would reach into the neighbouring column and notch it. The
--      symmetric form tests the same 30-degree slope on both sides.

local BASE_H       = 1.0    -- mm, base plate height
local BASE_D       = 20.0   -- mm, base plate depth
local COL_DIAM     = 5.0    -- mm, column diameter
local COL_SPACING  = 45.0   -- mm, column centre-to-centre
local SHELF_THICK   = 2.0   -- mm, overhang shelf thickness
local SHELF_DEPTH   = COL_DIAM
local LEVEL_HEIGHT  = 10.0  -- mm per fan speed level
local CONE_RADIUS   = 2.0   -- mm
local FACET_ANGLE   = 360.0 / 32.0   -- degrees, matches the fork's 32-segment circles
local OVERHANG_DEG  = 30.0  -- degrees of slope on the overhang

info = {
    id = "fan_tower",
    type = "project.plugin",
    title = "Fan Speed Tower",
    menu = "Calibration/Fan Speed Tower",
    params = {
        {name = "start_fan",  label = "Start Fan Speed (%)", type = "float", default = 0},
        {name = "end_fan",    label = "End Fan Speed (%)",   type = "float", default = 100},
        {name = "fan_step",   label = "Fan Speed Step (%)",  type = "float", default = 10},
        {name = "brim_width", label = "Brim Width (mm)",     type = "float", default = 0},
    }
}

local MAX_LEVELS = 40   -- a 1% step over 0-100 would otherwise build a 1 m tower

local function num(value, fallback)
    if type(value) == "number" then return value end
    if type(value) == "string" then
        local parsed = tonumber((value:gsub("^%s+", ""):gsub("%s+$", "")))
        if parsed then return parsed end
    end
    return fallback
end

local function read_config(box, key)
    local ok, value = pcall(function() return box:value(key) end)
    if ok then return value end
    return nil
end

function execute(opts)
    local start_fan = num(opts.start_fan,  0.0)
    local end_fan   = num(opts.end_fan,    100.0)
    local step      = num(opts.fan_step,   10.0)
    local brim      = num(opts.brim_width, 0.0)

    -- Repair rather than refuse: an error would only reach the log.
    local notes = {}
    start_fan = math.max(0.0, math.min(100.0, start_fan))
    end_fan   = math.max(0.0, math.min(100.0, end_fan))
    if end_fan < start_fan then
        start_fan, end_fan = end_fan, start_fan
        notes[#notes + 1] = "start/end swapped"
    end
    if end_fan <= start_fan then
        end_fan = math.min(100.0, start_fan + 100.0)
        if end_fan <= start_fan then start_fan = 0.0 end
        notes[#notes + 1] = "empty range widened"
    end
    if step <= 0.0 then
        step = (end_fan - start_fan) / 10.0
        notes[#notes + 1] = string.format("non-positive step replaced with %.1f", step)
    end
    if brim < 0.0 then brim = 0.0 end

    local num_levels = math.floor((end_fan - start_fan) / step + 1e-9) + 1
    if num_levels > MAX_LEVELS then
        num_levels = MAX_LEVELS
        step = (end_fan - start_fan) / (num_levels - 1)
        notes[#notes + 1] = string.format("capped at %d levels, step widened to %.1f",
                                          MAX_LEVELS, step)
    end
    if num_levels < 2 then
        num_levels = 2
        step = end_fan - start_fan
        notes[#notes + 1] = "step exceeded the range, reset to 2 levels"
    end

    local bed = api.project:current_bed()
    local print_cfg = bed:print_presets()

    local layer_height = read_config(print_cfg, "layer_height")
    if type(layer_height) ~= "number" or layer_height <= 0.0 then
        layer_height = 0.2
    end

    local total_height = BASE_H + num_levels * LEVEL_HEIGHT
    local col_r  = COL_DIAM / 2.0
    local col_x  = COL_SPACING / 2.0
    -- The standalone column sits clear of the left one, with the base extended
    -- underneath it so it is not printing on bare bed.
    local lone_x = -col_x - COL_DIAM * 2.0 - col_r
    local base_left  = lone_x - COL_DIAM
    local base_right = col_x + col_r
    local base_w = base_right - base_left

    local volumes = {}
    local function add(mesh, tx, ty, tz)
        volumes[#volumes + 1] = {mesh = mesh, translate = {x = tx, y = ty, z = tz}}
    end

    -- Cylinders are centred on Z in XY with their base at z=0, so they are
    -- placed by centre; make_cube's min corner is at the origin.
    add(api.make_cylinder(col_r, total_height, FACET_ANGLE), -col_x, 0, 0)
    add(api.make_cylinder(col_r, total_height, FACET_ANGLE),  col_x, 0, 0)
    add(api.make_cylinder(col_r, total_height, FACET_ANGLE), lone_x, 0, 0)

    -- Overhang spans the gap between the standalone column and the left one,
    -- overlapping 1 mm into each so it fuses rather than floats.
    local gap = (-col_x - col_r) - (lone_x + col_r)
    local overhang_w = gap + 2.0
    local overhang_h = gap * math.tan(math.rad(OVERHANG_DEG))

    for i = 0, num_levels - 1 do
        local level_z = BASE_H + i * LEVEL_HEIGHT
        local shelf_z = level_z + LEVEL_HEIGHT - SHELF_THICK

        add(api.make_cube(COL_SPACING, SHELF_DEPTH, SHELF_THICK),
            -COL_SPACING / 2.0, -SHELF_DEPTH / 2.0, shelf_z)

        -- The first level is the settling level: no features, so the fan change
        -- at its boundary has plain wall to act on.
        if i > 0 then
            add(api.make_cone(CONE_RADIUS, LEVEL_HEIGHT - SHELF_THICK - 2.0, FACET_ANGLE),
                0, 0, level_z)
            -- make_prism is centred in X and Y with its base at z=0, so its
            -- centre goes at the midpoint of the gap.
            add(api.make_prism(overhang_w, COL_DIAM, overhang_h),
                (lone_x + col_r + (-col_x - col_r)) / 2.0, 0, level_z)
        end
    end

    print_cfg:set("brim_width", brim)

    -- The settable half of the fork's fan-control reset. The three bools it
    -- also clears are dropped silently by set_param, hence the check below.
    local material_cfg = bed:material_presets(0)
    material_cfg:set("bridge_fan_speed", -1)
    material_cfg:set("disable_fan_first_layers", 0)
    material_cfg:set("full_fan_speed_layer", 0)
    material_cfg:set("min_fan_speed", 0)
    material_cfg:set("max_fan_speed", 0)

    local interfering = {}
    for _, key in ipairs({"cooling", "fan_always_on", "enable_dynamic_fan_speeds"}) do
        if read_config(material_cfg, key) == true then
            interfering[#interfering + 1] = key
        end
    end

    -- Level 0's command has to land on the very first layer; the rest sit just
    -- inside the layer that starts their level.
    --
    -- ORDER MATTERS: this has to run BEFORE add_object, or none of it reaches
    -- the exported G-code. See the same note in pa_tower.lua.
    api.project:clear_layer_custom_steps(bed)
    for i = 0, num_levels - 1 do
        local z = (i == 0) and (layer_height / 2.0)
                           or (BASE_H + i * LEVEL_HEIGHT + layer_height / 2.0)
        local pct = start_fan + i * step
        local pwm = math.min(255, math.floor(pct * 255.0 / 100.0 + 0.5))
        api.project:insert_layer_custom_gcode(
            bed, z, string.format("M106 S%d ; fan %.0f%%", pwm, pct))
    end

    api.project:add_object{
        mesh = api.make_cube(base_w, BASE_D, BASE_H),
        translate = {x = base_left, y = -BASE_D / 2.0, z = 0},
        other_volumes = volumes,
    }

    local summary = string.format(
        "Fan tower: %d levels, %.0f%% to %.0f%% step %.0f%%, %.1f mm tall at %.3f mm layers",
        num_levels, start_fan, start_fan + (num_levels - 1) * step, step,
        total_height, layer_height)
    if #notes > 0 then
        summary = summary .. "  [adjusted: " .. table.concat(notes, "; ") .. "]"
    end
    if #interfering > 0 then
        summary = summary .. "  [WARNING: turn these off on the Filament preset or the"
                          .. " slicer will overwrite the fan sweep: "
                          .. table.concat(interfering, ", ") .. "]"
    end
    print(summary)
end
