-- Stub of the PrusaSlicer 3.0 plugin sandbox, faithful to ProjectApi.cpp.
local L = {}   -- log of everything the plugin did

local function new_mesh(kind, dims, origin)
  local m = {kind=kind, dims=dims, off={origin[1],origin[2],origin[3]}}
  function m:translate(x,y,z) self.off={self.off[1]+x,self.off[2]+y,self.off[3]+z} end
  function m:bounds()
    return {min_x=self.off[1], max_x=self.off[1]+dims[1],
            min_y=self.off[2], max_y=self.off[2]+dims[2],
            min_z=self.off[3], max_z=self.off[3]+dims[3]}
  end
  return m
end

-- set_param() handles ONLY double/int/Percentage/FloatOrPercentage/EnumWrapper.
-- bool and string fall through the catch-all and are dropped silently.
local function new_box(name, contents)
  local b = {}
  function b:value(k)
    local v = contents[k]
    if v == nil then error("Invalid preset item name '"..k.."': not found") end
    if type(v) == "table" and v.enum then error("Unsupported config type") end
    return v.v
  end
  function b:set(k, val)
    local cur = contents[k]
    if cur == nil then
      L[#L+1] = {set_missing = name.."."..k}
      return
    end
    if cur.t == "bool" or cur.t == "string" then
      L[#L+1] = {set_DROPPED = name.."."..k}
      return
    end
    L[#L+1] = {set = name.."."..k, value = val}
    cur.v = val
  end
  return b
end

local PRINT, MATERIAL, PRINTER

local bed = {}
function bed:print_presets()      return PRINT end
function bed:material_presets(i)  return MATERIAL end
function bed:printer_presets()    return PRINTER end

-- VolumeType is a global enum in the plugin sandbox (ProjectApi.cpp:810).
VolumeType = {Solid=1, Negative=2, Modifier=3, SupportBlocker=4, SupportEnforcer=5, Invalid=6}

api = {}
-- make_cube's min corner is at the origin; cylinders and cones are centred in
-- XY with their base at z=0. The stub mirrors that so placement is testable.
api.make_cube     = function(x,y,z)   return new_mesh("cube", {x,y,z}, {0,0,0}) end
api.make_cylinder = function(r,h,fa)  return new_mesh("cylinder", {2*r,2*r,h}, {-r,-r,0}) end
api.make_cone     = function(r,h,fa)  return new_mesh("cone", {2*r,2*r,h}, {-r,-r,0}) end
api.make_prism    = function(w,l,h)   return new_mesh("prism", {w,l,h}, {-w/2,-l/2,0}) end
api.get_default_font = function() return {name="stub"} end
api.get_font = function(n) return {name=n} end
-- emboss_text lies in XY and extrudes +Z. Glyph extent is faked from the text
-- length so bounds-based centring can be checked.
api.emboss_text = function(o)
  local w = #tostring(o.text) * 2.4
  return new_mesh("text", {w, 4.0, o.depth}, {0, 0, 0})
end
api.project = {}
function api.project:current_bed() return bed end
function api.project:clear_layer_custom_steps(b) L[#L+1] = {clear=true} end
function api.project:insert_layer_custom_gcode(b, z, g) L[#L+1] = {z=z, gcode=g} end
function api.project:add_object(def)
  local vols = {{mesh=def.mesh, rotate=def.rotate, translate=def.translate}}
  for _,v in ipairs(def.other_volumes or {}) do vols[#vols+1] = v end
  L[#L+1] = {add_object = vols}
end

function reset(notes, layer_height)
  L = {}
  PRINT = new_box("print", {
    layer_height             = {t="double", v=layer_height or 0.2},
    perimeter_speed          = {t="double", v=45},
    external_perimeter_speed = {t="fop",    v=25},
    small_perimeter_speed    = {t="fop",    v=25},
    infill_speed             = {t="double", v=80},
    solid_infill_speed       = {t="fop",    v=80},
    top_solid_infill_speed   = {t="fop",    v=40},
    gap_fill_speed           = {t="double", v=40},
    brim_width               = {t="double", v=0},
    variable_layer_height    = {t="bool",   v=true},
  })
  MATERIAL = new_box("material", {
    slowdown_below_layer_time = {t="int",    v=15},
    min_print_speed           = {t="double", v=15},
    bridge_fan_speed          = {t="int",    v=100},
    disable_fan_first_layers  = {t="int",    v=1},
    full_fan_speed_layer      = {t="int",    v=4},
    min_fan_speed             = {t="int",    v=30},
    max_fan_speed             = {t="int",    v=100},
    cooling                   = {t="bool",   v=true},
    fan_always_on             = {t="bool",   v=true},
    enable_dynamic_fan_speeds = {t="bool",   v=false},
  })
  PRINTER = new_box("printer", {
    printer_notes = {t="string", v=notes or ""},
    gcode_flavor  = {enum=true},
  })
  return L
end
function getlog() return L end
