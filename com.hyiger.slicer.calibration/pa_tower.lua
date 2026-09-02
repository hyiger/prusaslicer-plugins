-- Pressure Advance calibration tower — chevron pattern.
--
-- Ported from CalibrationPADialog::generate_tower() + make_pa_pattern() in the
-- Filament Edition fork. The shape is one thick chevron (a V) inside a
-- one-layer-tall rectangular frame, extruded to num_levels x LAYERS_PER_LEVEL
-- layers. Each level gets a different pressure-advance value via per-layer
-- custom G-code, so a single print sweeps the whole range and you read the
-- best value off the corner that shows neither bulging nor under-extrusion.
--
-- Three deliberate deviations from the fork, all forced by the 3.0 plugin API
-- (the third is the PARAM TYPES note below):
--
--   1. The fork picks the firmware command from `gcode_flavor` first and only
--      falls back to printer_notes. `gcode_flavor` is an EnumWrapper, and the
--      Lua read path (ExposedConfigValue) has no EnumWrapper case, so reading
--      it throws "Unsupported config type". Auto-detect here is printer_notes
--      only, with an explicit override parameter as the escape hatch.
--
--   2. The fork sets variable_layer_height=false. That option is a bool, and
--      set_param() only handles double/int/Percentage/FloatOrPercentage/Enum —
--      bools and strings hit the catch-all and are dropped SILENTLY. So it is
--      not set here; if you have variable layer height enabled, the level
--      boundaries below will not line up with the actual layers.

local LAYERS_PER_LEVEL = 4      -- layers printed at each PA value
local CORNER_ANGLE     = 90.0   -- degrees, included angle at the chevron tip
local ARM_LENGTH       = 40.0   -- mm, length of each arm
local WALL_THICKNESS   = 1.6    -- mm, arm width and frame bar width
local FRAME_MARGIN     = 1.0    -- mm, gap between chevron bounds and the frame

-- PARAM TYPES: "float" and "int" are SWAPPED in 3.0.0-alpha11 (upstream #15611).
-- PluginDialog.cpp:248 builds a "float" param as NumberControl<IntValidator, int>
-- and :262 builds an "int" param as NumberControl<DoubleValidator, double>. So a
-- param declared "float" gets an INTEGER box. IntValidator::process rounds and
-- clamps, so 0.005 arrives as 0 and 0.6 arrives as 1 -- it is not a truncation.
--
-- The three PA values are therefore declared as strings and parsed here. That is
-- immune to the swap in BOTH directions, so this keeps working when Prusa fixes
-- it; declaring them "int" would work today and break on the fix. test_speed and
-- brim_width stay numeric because their values are whole numbers either way.
info = {
    id = "pa_tower",
    type = "project.plugin",
    title = "Pressure Advance Tower",
    menu = "Calibration/Pressure Advance Tower",
    params = {
        {name = "start_pa",   label = "Start PA",           type = "string", default = "0.0"},
        {name = "end_pa",     label = "End PA",             type = "string", default = "0.1"},
        {name = "pa_step",    label = "PA Step",            type = "string", default = "0.005"},
        {name = "test_speed", label = "Test Speed (mm/s)",  type = "float",  default = 100},
        {name = "brim_width", label = "Brim Width (mm)",    type = "float",  default = 0},
        {name = "pa_command", label = "PA command (auto / m572 / m900 / klipper)",
                              type = "string", default = "auto"},
    }
}

-- Defaults used both as the dialog values above and as the repair targets below.
local DEFAULT_START, DEFAULT_END, DEFAULT_STEP = 0.0, 0.1, 0.005
local DEFAULT_SPEED = 100.0
local MAX_LEVELS = 100   -- a mistyped step must not produce a 600 mm tower

-- printer_notes markers that mean "Prusa Buddy input-shaper firmware", which
-- takes M572 S rather than M900 K. These are the same markers Prusa's own
-- start_filament_gcode switches on. The printer MODEL name is not usable here:
-- the MK3.9 carries PRINTER_MODEL_MK4IS in its notes, not "MK3.9". Generic
-- Marlin printers carry none of these and correctly fall through to M900.
local M572_MARKERS = {"MK4IS", "XLIS", "MK4S", "MK3.9S", "MK3.5", "MINIIS", "COREONE"}

-- ConfigBox:value() throws if the key is absent from that preset box, so every
-- read is guarded. Returns nil rather than propagating.
local function read_config(box, key)
    local ok, value = pcall(function() return box:value(key) end)
    if ok then
        return value
    end
    return nil
end

-- Params may arrive as strings (see the PARAM TYPES note above), as numbers, or
-- as an empty box. Anything unusable falls back rather than aborting the run,
-- because a plugin cannot report an error to the user: execute() failures are
-- only SPDLOG_ERROR'd (Plugin.cpp:172), so raising here would reproduce
-- exactly the silent no-op this replaces.
local function num(value, fallback)
    if type(value) == "number" then
        return value
    end
    if type(value) == "string" then
        local parsed = tonumber((value:gsub("^%s+", ""):gsub("%s+$", "")))
        if parsed then
            return parsed
        end
    end
    return fallback
end

-- Returns the G-code prefix that a PA value is appended to.
local function pa_command_prefix(bed, override)
    override = string.lower(override or "auto")
    if override == "m572" then    return "M572 S" end
    if override == "m900" then    return "M900 K" end
    if override == "klipper" then return "SET_PRESSURE_ADVANCE ADVANCE=" end
    if override ~= "auto" then
        -- Not an error: an aborted run is invisible (see num()). Fall through
        -- to auto-detect, which is the best guess available.
        print("pa_tower: unknown pa_command '" .. override .. "', falling back to auto")
    end

    local notes = read_config(bed:printer_presets(), "printer_notes")
    if type(notes) ~= "string" then
        notes = ""
    end
    notes = string.upper(notes)

    -- Lua patterns have no alternation, so match the markers one at a time.
    -- Plain find (4th arg true) keeps the "." in MK3.9S literal.
    if string.find(notes, "KLIPPER", 1, true) then
        return "SET_PRESSURE_ADVANCE ADVANCE="
    end
    for _, marker in ipairs(M572_MARKERS) do
        if string.find(notes, marker, 1, true) then
            return "M572 S"
        end
    end
    return "M900 K"
end

-- One chevron arm: a bar running along +X, centred on Y so that a Z rotation
-- applied at the volume level pivots about the chevron tip rather than a corner.
-- make_cube's arguments are (x_size, y_size, z_size) with the min corner at the
-- origin, despite the API doc calling them width/height/depth.
local function make_arm(total_height)
    local arm = api.make_cube(ARM_LENGTH, WALL_THICKNESS, total_height)
    arm:translate(0, -WALL_THICKNESS / 2.0, 0)
    return arm
end

-- The frame is the fork's outer-box-minus-inner-box, rebuilt as four bars.
-- There is no mesh boolean in the plugin API, and four bars are exactly
-- equivalent for a rectangular frame.
local function append_frame(volumes, layer_height)
    local half = math.rad(CORNER_ANGLE / 2.0)
    local cos_a, sin_a = math.cos(half), math.sin(half)
    local hw = WALL_THICKNESS / 2.0

    -- Bounds of the two rotated arms, measured from the tip at the origin.
    local x_min = -hw * sin_a
    local x_max = ARM_LENGTH * cos_a + hw * sin_a
    local y_max = ARM_LENGTH * sin_a + hw * cos_a

    local ox_min = x_min - FRAME_MARGIN
    local ox_max = x_max + FRAME_MARGIN
    local oy_min = -y_max - FRAME_MARGIN
    local oy_max = y_max + FRAME_MARGIN

    local outer_w = ox_max - ox_min
    local outer_h = oy_max - oy_min
    local w = WALL_THICKNESS

    local function bar(size_x, size_y, at_x, at_y)
        table.insert(volumes, {
            mesh = api.make_cube(size_x, size_y, layer_height),
            translate = {x = at_x, y = at_y, z = 0}
        })
    end

    bar(outer_w, w, ox_min, oy_min)                      -- bottom
    bar(outer_w, w, ox_min, oy_max - w)                  -- top
    bar(w, outer_h - 2 * w, ox_min, oy_min + w)          -- left
    bar(w, outer_h - 2 * w, ox_max - w, oy_min + w)      -- right
end

function execute(opts)
    local start_pa   = num(opts.start_pa,   DEFAULT_START)
    local end_pa     = num(opts.end_pa,     DEFAULT_END)
    local step       = num(opts.pa_step,    DEFAULT_STEP)
    local test_speed = num(opts.test_speed, DEFAULT_SPEED)
    local brim_width = num(opts.brim_width, 0.0)

    -- Repair rather than refuse, for the reason given on num() above. Each
    -- adjustment is logged so the print can be explained afterwards.
    local notes = {}
    if start_pa < 0.0 then
        start_pa = 0.0
        notes[#notes + 1] = "negative start clamped to 0"
    end
    if end_pa < start_pa then
        start_pa, end_pa = end_pa, start_pa
        notes[#notes + 1] = "start/end swapped"
    end
    if end_pa <= start_pa then
        end_pa = start_pa + (DEFAULT_END - DEFAULT_START)
        notes[#notes + 1] = "empty range widened to " .. string.format("%.4f", end_pa)
    end
    if step <= 0.0 then
        step = (end_pa - start_pa) / 20.0
        notes[#notes + 1] = "non-positive step replaced with " .. string.format("%.4f", step)
    end
    if test_speed <= 0.0 then
        test_speed = DEFAULT_SPEED
        notes[#notes + 1] = "non-positive test speed replaced with " .. DEFAULT_SPEED
    end
    if brim_width < 0.0 then
        brim_width = 0.0
    end

    -- The epsilon is not in the fork, and it matters: (0.1 - 0.0) / 0.005 lands
    -- on either side of 20 depending on rounding, which silently costs a level.
    local num_levels = math.floor((end_pa - start_pa) / step + 1e-9) + 1
    if num_levels > MAX_LEVELS then
        num_levels = MAX_LEVELS
        step = (end_pa - start_pa) / (num_levels - 1)
        notes[#notes + 1] = string.format("capped at %d levels, step widened to %.4f",
                                          MAX_LEVELS, step)
    end
    if num_levels < 2 then
        step = (end_pa - start_pa) / 20.0
        num_levels = 21
        notes[#notes + 1] = "step exceeded the range, reset to 21 levels"
    end

    local bed = api.project:current_bed()

    -- Resolve the firmware command before touching anything: a bad override
    -- must not leave a half-built project and rewritten presets behind.
    local prefix = pa_command_prefix(bed, opts.pa_command)

    local print_cfg = bed:print_presets()

    local layer_height = read_config(print_cfg, "layer_height")
    if type(layer_height) ~= "number" or layer_height <= 0.0 then
        layer_height = 0.2
    end

    local total_layers = num_levels * LAYERS_PER_LEVEL
    local total_height = total_layers * layer_height

    -- Pin the geometry-defining setting, then force a uniform high speed.
    -- Pressure advance only shows up visibly above roughly 80 mm/s: the corner
    -- pressure spike scales with extrusion rate, and stock profiles print
    -- perimeters at 40-50 mm/s where every PA value looks equally blurry.
    print_cfg:set("layer_height", layer_height)
    print_cfg:set("perimeter_speed", test_speed)
    print_cfg:set("external_perimeter_speed", test_speed)
    print_cfg:set("small_perimeter_speed", test_speed)
    print_cfg:set("infill_speed", test_speed)
    print_cfg:set("solid_infill_speed", test_speed)
    print_cfg:set("top_solid_infill_speed", test_speed)
    print_cfg:set("gap_fill_speed", test_speed)
    print_cfg:set("brim_width", brim_width)

    -- Cooling slowdown would undo all of the above. Each chevron layer prints
    -- in one to three seconds, which trips "slow down if layer time < N", and
    -- every level then homogenises to the cooling-imposed minimum speed. These
    -- two live on the material preset, not the print preset.
    local material_cfg = bed:material_presets(0)
    material_cfg:set("slowdown_below_layer_time", 0)
    material_cfg:set("min_print_speed", test_speed)

    -- Build the chevron: arm A is the object's first volume, arm B and the
    -- four frame bars are attached volumes. add_object re-centres the whole
    -- object on the bed in XY once every volume is in, so only the relative
    -- placement here matters.
    local other_volumes = {
        {mesh = make_arm(total_height), rotate = {z = -CORNER_ANGLE / 2.0}},
    }
    append_frame(other_volumes, layer_height)

    -- Per-level PA commands, one per LAYERS_PER_LEVEL block, placed mid-layer
    -- so the boundary lands unambiguously inside the intended layer.
    --
    -- ORDER MATTERS: this has to run BEFORE add_object. Custom G-code written
    -- after the object is added never reaches the exported file -- the slice
    -- carries the geometry and none of the commands. Prusa's own temp_tower.lua
    -- inserts first for the same reason.
    api.project:clear_layer_custom_steps(bed)

    for i = 0, num_levels - 1 do
        local z  = i * LAYERS_PER_LEVEL * layer_height + layer_height / 2.0
        local pa = start_pa + i * step
        api.project:insert_layer_custom_gcode(bed, z, prefix .. string.format("%.4f", pa))
    end

    -- Leave PA at zero at the top, so the next print off this machine does not
    -- inherit the last level's value.
    local z_top = total_height - layer_height / 2.0
    api.project:insert_layer_custom_gcode(bed, z_top, prefix .. string.format("%.4f", 0.0))

    api.project:add_object{
        mesh = make_arm(total_height),
        rotate = {z = CORNER_ANGLE / 2.0},
        other_volumes = other_volumes,
    }

    local summary = string.format(
        "PA tower: %d levels, %.4f to %.4f step %.4f, %d layers at %.3f mm, command '%s'",
        num_levels, start_pa, start_pa + (num_levels - 1) * step, step,
        total_layers, layer_height, prefix)
    if #notes > 0 then
        summary = summary .. "  [adjusted: " .. table.concat(notes, "; ") .. "]"
    end
    print(summary)
end
