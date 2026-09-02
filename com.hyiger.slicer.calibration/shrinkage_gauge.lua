-- Dimensional accuracy / shrinkage gauge — XYZ cross.
--
-- Ported from make_shrinkage_gauge() + CalibrationShrinkageDialog in the
-- Filament Edition fork. Three 10x10 mm bars meet at a common corner and run
-- along X, Y and Z. Square through-holes at 25 mm intervals give caliper jaws
-- something to register on: each hole's near edge sits exactly at its labelled
-- distance from the corner datum, so a hole marked "25" measures 25 mm. Print
-- it, measure all three axes, and the error tells you the shrinkage compensation
-- your filament needs.
--
-- Three deviations from the fork, all forced by the 3.0 plugin API:
--
--   1. The fork cuts the holes with a single CGAL boolean. There is no mesh
--      boolean here, so each hole is a Negative volume instead — the slicer
--      subtracts them at slice time. Same result, and it sidesteps the
--      self-intersection failure the fork documents at long arm lengths, where
--      holes past ~125 mm could silently vanish.
--
--   2. The fork unions the three arms into one manifold. Here they are three
--      overlapping Solid volumes on one object, which the slicer unions itself.
--
--   3. Labels on the Z arm sit on the -Y face, not +Y. Raised text read from
--      +Y needs mirroring to read correctly, and the API has no mirror — only
--      rotation. Reading the same text from -Y needs none.

local BAR_SECTION   = 10.0   -- mm, cross-section of each arm
local HOLE_SIZE     = 5.0    -- mm, square through-hole (fits caliper jaws)
local HOLE_INTERVAL = 25.0   -- mm, spacing between holes
local TIP_MARGIN    = 0.5    -- mm, wall left before the arm tip
local LABEL_HEIGHT  = 4.0    -- mm, glyph height
local LABEL_DEPTH   = 0.8    -- mm, how far the label stands off the surface

-- "float" params are integer boxes in 3.0.0-alpha11 (upstream #15611) and will
-- be double boxes once that is fixed. Both values here are whole numbers, so
-- this declaration is correct either way and needs no string workaround.
info = {
    id = "shrinkage_gauge",
    type = "project.plugin",
    title = "Shrinkage Gauge",
    menu = "Calibration/Shrinkage Gauge",
    params = {
        {name = "arm_length", label = "Arm Length (mm)", type = "float", default = 100},
        {name = "brim_width", label = "Brim Width (mm)", type = "float", default = 0},
    }
}

local MIN_ARM, MAX_ARM = 20.0, 200.0

local function num(value, fallback)
    if type(value) == "number" then return value end
    if type(value) == "string" then
        local parsed = tonumber((value:gsub("^%s+", ""):gsub("%s+$", "")))
        if parsed then return parsed end
    end
    return fallback
end

local function pick_font()
    local ok, font = pcall(function() return api.get_font("Helvetica") end)
    if ok and font then return font end
    return api.get_default_font()
end

-- Places a raised number on a face. The label mesh is never pre-translated:
-- volume rotation pivots on the mesh origin, so baking an offset in first would
-- swing it somewhere unintended. Position is computed from the mesh bounds and
-- applied as the volume's own translate, after rotation.
--
-- face "top"    text lies in XY and stands off +Z, read from above.
-- face "top_y"   as "top", but spun 90 degrees about Z so the glyphs run ALONG
--                the Y arm instead of across its 10 mm width. Rotating about Z
--                maps (x,y) to (-y,x), so the centring below swaps the two axes
--                and negates one.
-- face "front"   text is turned into XZ and stands off -Y, read from the front.
local function label_volume(font, text, face, cx, c2, surface)
    local mesh = api.emboss_text{font = font, text = text, depth = LABEL_DEPTH}
    local b = mesh:bounds()

    if face == "top" then
        -- Unrotated: x and y are the glyph plane, z is the extrusion.
        return {
            mesh = mesh,
            translate = {
                x = cx - (b.min_x + b.max_x) / 2.0,
                y = c2 - (b.min_y + b.max_y) / 2.0,
                z = surface - b.min_z,
            }
        }
    end

    if face == "top_y" then
        -- After rotate z=+90 the mesh spans x in (-max_y, -min_y) and
        -- y in (min_x, max_x); z is untouched. Text then reads bottom-to-top
        -- when the plate is viewed from above with +Y away from you.
        return {
            mesh = mesh,
            rotate = {z = 90},
            translate = {
                x = cx + (b.min_y + b.max_y) / 2.0,
                y = c2 - (b.min_x + b.max_x) / 2.0,
                z = surface - b.min_z,
            }
        }
    end

    -- rotate x=+90 maps +Z to -Y and +Y to +Z, so the glyph stands upright in
    -- XZ and its extrusion points out of the -Y face. Bounds below are the
    -- post-rotation ones, derived from the originals.
    return {
        mesh = mesh,
        rotate = {x = 90},
        translate = {
            x = cx - (b.min_x + b.max_x) / 2.0,
            y = surface + b.min_z,          -- outer face of the label lands on `surface`
            z = c2 - (b.min_y + b.max_y) / 2.0,
        }
    }
end

function execute(opts)
    local length = num(opts.arm_length, 100.0)
    local brim   = num(opts.brim_width, 0.0)

    -- Clamp rather than raise: plugin errors are only written to the log
    -- (Plugin.cpp:172), so an aborted run is indistinguishable from a crash.
    local notes = {}
    if length < MIN_ARM then
        length = MIN_ARM
        notes[#notes + 1] = "arm length raised to " .. MIN_ARM
    elseif length > MAX_ARM then
        length = MAX_ARM
        notes[#notes + 1] = "arm length capped at " .. MAX_ARM
    end
    if brim < 0.0 then brim = 0.0 end

    local bed = api.project:current_bed()
    local font = pick_font()

    local half = (BAR_SECTION - HOLE_SIZE) / 2.0   -- centres the hole in the bar
    local through = BAR_SECTION + 0.02             -- overshoot both faces cleanly
    local volumes = {}

    -- The other two arms. The X arm is the object's first volume, added last.
    volumes[#volumes + 1] = {mesh = api.make_cube(BAR_SECTION, length, BAR_SECTION)}
    volumes[#volumes + 1] = {mesh = api.make_cube(BAR_SECTION, BAR_SECTION, length)}

    local hole_count = 0
    local pos = HOLE_INTERVAL
    while pos + HOLE_SIZE <= length - TIP_MARGIN do
        local text = string.format("%d", math.floor(pos + 0.5))
        local mid  = pos + HOLE_SIZE / 2.0

        -- X arm: hole pierces through Y, label on the top face.
        volumes[#volumes + 1] = {
            mesh = api.make_cube(HOLE_SIZE, through, HOLE_SIZE),
            type = VolumeType.Negative,
            translate = {x = pos, y = -0.01, z = half},
        }
        volumes[#volumes + 1] = label_volume(font, text, "top", mid, BAR_SECTION / 2.0, BAR_SECTION)

        -- Y arm: hole pierces through X, label on the top face.
        volumes[#volumes + 1] = {
            mesh = api.make_cube(through, HOLE_SIZE, HOLE_SIZE),
            type = VolumeType.Negative,
            translate = {x = -0.01, y = pos, z = half},
        }
        volumes[#volumes + 1] = label_volume(font, text, "top_y", BAR_SECTION / 2.0, mid, BAR_SECTION)

        -- Z arm: hole pierces through X, label stands on the -Y face.
        volumes[#volumes + 1] = {
            mesh = api.make_cube(through, HOLE_SIZE, HOLE_SIZE),
            type = VolumeType.Negative,
            translate = {x = -0.01, y = half, z = pos},
        }
        volumes[#volumes + 1] = label_volume(font, text, "front", BAR_SECTION / 2.0, mid, 0.0)

        hole_count = hole_count + 3
        pos = pos + HOLE_INTERVAL
    end

    bed:print_presets():set("brim_width", brim)

    -- A previous calibration run may have left per-layer commands on this bed.
    -- The gauge wants none, and a stray M572 or M106 would silently ride along.
    -- Done before add_object, matching the other two plugins.
    api.project:clear_layer_custom_steps(bed)

    api.project:add_object{
        mesh = api.make_cube(length, BAR_SECTION, BAR_SECTION),
        other_volumes = volumes,
    }

    local summary = string.format(
        "Shrinkage gauge: %.0f mm arms, %d holes, %d labels",
        length, hole_count, hole_count)
    if #notes > 0 then
        summary = summary .. "  [adjusted: " .. table.concat(notes, "; ") .. "]"
    end
    print(summary)
end
