-- CSS palette overlay (Debug Mode): the only piece of the retired UIDSL
-- engine worth keeping. Themes (*.css in <data>/themes/) declare palette
-- overrides via a `page { ... }` rule; this module parses that subset and
-- overlays it onto the LIVE Theme palette (apply_theme_to_app).
--
-- Kept intentionally small: no node layer, no validators beyond color
-- resolution, unknown properties surface as visible errors (theme authors
-- need the feedback), and a broken sheet can never kill the paint path.
local Theme = require("ktui/theme")

local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
if not lfs_ok or not lfs then
    local ok2, lfs2 = pcall(require, "lfs")
    lfs = ok2 and lfs2 or nil
end

local ThemeCSS = {}

-- Theme palette names usable in any color position; resolved against the
-- LIVE Theme at use time. NOTE: the palette value is a cdata color - NEVER
-- compare it with ~= nil (invokes ColorRGB32:__eq(nil) and crashes);
-- cdata is truthy.
local THEME_COLORS = {
    primary   = "button_bg",
    onprimary = "button_text",
    ink       = "ink",
    muted     = "muted",
    border    = "border",
    panel     = "panel",
    soft      = "soft",
    bg        = "bg",
    danger    = "danger",
}

-- Where a palette property lands on Theme.
local PROPS = {
    ["background"]        = { theme = "bg" },
    ["background-color"]  = { theme = "bg" },
    ["color"]             = { theme = "ink" },
    ["muted-color"]       = { theme = "muted" },
    ["border-color"]      = { theme = "border" },
    ["panel-color"]       = { theme = "panel" },
    ["soft-color"]        = { theme = "soft" },
    ["button-color"]      = { theme = "button_bg" },
    ["button-text-color"] = { theme = "button_text" },
    ["danger-color"]      = { theme = "danger" },
    -- Registered so typos still surface as visible errors.
    ["font-size"]         = {},
    ["radius"]            = {},
    ["border-size"]       = {},
}

-- =============================================================== colors ===

local function resolve_gray(val)
    local Blitbuffer = require("ffi/blitbuffer")
    local n
    local pct = val:match("^([%d%.]+)%%%s*$")
    if pct then
        n = tonumber(pct) / 100
    elseif val:match("^gray%(") then
        n = tonumber(val:match("^gray%(([%-%d%.]+)%)$"))
    else
        n = tonumber(val)
    end
    if not n then return nil end
    n = math.max(0, math.min(1, n))
    local ok, color = pcall(Blitbuffer.gray, n)
    return ok and color or nil
end

local function resolve_color(val)
    local Blitbuffer = require("ffi/blitbuffer")
    val = tostring(val):gsub("^%s+", ""):gsub("%s+$", "")
    if val == "" then return nil end
    local theme_key = THEME_COLORS[val:lower()]
    if theme_key then
        return Theme[theme_key]
    end
    if val:sub(1, 1) == "#" then
        local ok, color = pcall(Blitbuffer.colorFromString, val)
        return ok and color or nil
    end
    if val:match("^rgb") then
        local r, g, b = val:match("^rgb%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*%)$")
        if r and g and b then
            local ok, color = pcall(function()
                return Blitbuffer.ColorRGB32(tonumber(r), tonumber(g), tonumber(b), 0xFF)
            end)
            return ok and color or nil
        end
        return nil
    end
    return resolve_gray(val)
end

-- ============================================================ parsing ===

-- One declaration block -> table[prop] = value.
local function parse_declarations(block)
    local decls = {}
    for decl in (block .. ";"):gmatch("([^;]*)") do
        local prop, value = decl:match("^%s*([%w%-]+)%s*:%s*(.-)%s*$")
        if prop then decls[prop] = value end
    end
    return decls
end

-- Parse the palette subset: global rules beat scoped rules (a `.card
-- { background: }` must never repaint the whole app - the old UIDSL bug,
-- preserved here as the same strict contract).
local function parse_sheet(css_text)
    local rules = {}
    local text = tostring(css_text or ""):gsub("/%*.-%*/", " ")
    for selector, block in text:gmatch("([^{}]+)%s*{([^}]*)}") do
        local sel = (selector:gsub("^%s+", ""):gsub("%s+$", ""))
        local tag = sel:match("^([%a][%w%-]*)")
        local id = sel:match("#([%w%-]+)")
        local classes = {}
        for cls in sel:gmatch("%.([%w%-]+)") do
            classes[cls] = true
        end
        table.insert(rules, { tag = tag, id = id, classes = classes,
            decls = parse_declarations(block) })
    end
    return { rules = rules, errors = {} }
end

-- Extract palette overrides { theme_key -> blitbuffer color } + errors.
-- Only `page { ... }` (or an unscoped bare rule) may touch the palette.
function ThemeCSS.theme_overrides(sheet)
    local overrides, errors = {}, {}
    for _i, r in ipairs((sheet and sheet.rules) or {}) do
        local global = r.tag == "page"
            or (r.tag == nil and next(r.classes) == nil and r.id == nil)
        if global then
            for prop, value in pairs(r.decls) do
                local spec = PROPS[prop]
                if spec and spec.theme then
                    local color = resolve_color(value)
                    if color then
                        overrides[spec.theme] = color
                    else
                        errors[#errors + 1] = prop .. ": invalid color: " .. tostring(value)
                    end
                elseif spec == nil then
                    errors[#errors + 1] = "unknown property: " .. tostring(prop)
                end
            end
        end
    end
    return overrides, errors
end

-- ==================================================== theme file layer ===

local _theme_cache = {} -- path -> { mtime, sheet, errors, nprops }

function ThemeCSS.css_path(name)
    local Storage = require("kt_storage")
    if not name or name == "" then return nil end
    if not name:match("%.css$") then name = name .. ".css" end
    if name:find("/", 1, true) or name:find("\\", 1, true) then return nil end
    return Storage.data_dir() .. "/themes/" .. name
end

function ThemeCSS.list_files()
    local Storage = require("kt_storage")
    local dir = Storage.data_dir() .. "/themes"
    local out = {}
    if lfs then
        pcall(function()
            for name in lfs.dir(dir) do
                if name:match("%.css$") then
                    local path = dir .. "/" .. name
                    local attr = lfs.attributes(path, "modification")
                    table.insert(out, { name = name:gsub("%.css$", ""), path = path, mtime = attr })
                end
            end
        end)
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Load + parse + extract, cached per mtime (edit + reload picks changes up).
-- Returns ok, sheet, errors, nprops.
function ThemeCSS.load_file(path)
    if not path then return false, "no path" end
    local attr = nil
    if lfs then
        local ok, a = pcall(lfs.attributes, path, "modification")
        if ok then attr = a end
    end
    local cached = _theme_cache[path]
    if cached and cached.mtime == attr then
        return true, cached.sheet, cached.errors, cached.nprops
    end
    local f = io.open(path, "r")
    if not f then return false, "could not read " .. tostring(path) end
    local css = f:read("*a")
    f:close()
    local sheet = parse_sheet(css)
    local overrides, errors = ThemeCSS.theme_overrides(sheet)
    local nprops = 0
    for _ in pairs(overrides) do nprops = nprops + 1 end
    _theme_cache[path] = { mtime = attr, sheet = sheet, errors = errors, nprops = nprops }
    return true, sheet, errors, nprops
end

-- Apply settings.debug_theme_css onto the live Theme palette. Called from
-- App:apply_settings when debug mode is on. Always starts from the baked
-- palette: the overlay never accumulates across theme/density switches.
function ThemeCSS.apply_to_app(app)
    local settings = app and app.state and app.state.settings or {}
    Theme.set_theme(settings.theme or "light")
    local name = settings.debug_theme_css
    if not name or name == "" then return end
    local path = ThemeCSS.css_path(name)
    if not path then return end
    local ok, _sheet, errors, nprops = ThemeCSS.load_file(path)
    if not ok or not nprops or nprops == 0 then return end
    -- Extract from the (now cached) sheet and overlay onto the palette.
    local sheet = _theme_cache[path] and _theme_cache[path].sheet
    if not sheet then return end
    local overrides = ThemeCSS.theme_overrides(sheet)
    for key, color in pairs(overrides) do
        Theme[key] = color
    end
    app.state.debug_theme_errors = errors
end

return ThemeCSS
