-- UI DSL engine (experimental, Debug Mode): CSS-like themes + declarative
-- layout for canvas UI.
--
-- Public surface (all guarded, never throws to the paint path):
--   UiDSL.parse(css_text)               -> { rules = {...}, errors = {...} }
--   UiDSL.style_for(sheet, tag, attrs)  -> merged, validated declarations
--   UiDSL.theme_overrides(sheet, tag)   -> palette overrides { bg=..., ... }, errors
--   UiDSL.merge_sheets(base, top)       -> theme under inline <style>
--   UiDSL.validate_sheet(sheet)         -> visible errors (unknown/invalid)
--   UiDSL.load_theme_file(path)         -> ok, sheet, errors, nprops
--   UiDSL.theme_css_path(name)          -> path or nil
--   UiDSL.list_theme_files()            -> { { name, path, mtime }, ... }
--   UiDSL.sandbox_path()                -> themes/pages/sandbox.html path
--   UiDSL.sandbox_exists()              -> bool (never writes)
--   UiDSL.install_sandbox()             -> ok, msg (never overwrites)
--   UiDSL.sandbox_tree(app, actions, vars) -> tree, merged_sheet, errors
--   UiDSL.resolve_binds(tree, app)       -> live data-bind values onto nodes
--   UiDSL.open_input(app, node)          -> system input dialog (overridable)
--   UiDSL.save_input(app, node, text)    -> dialog text back to the bind path
--   UiDSL.apply_theme_to_app(app)       -> overlays settings.debug_theme_css
--                                           on the live Theme palette
--   UiDSL.node / UiDSL.measure / UiDSL.paint -> declarative layout nodes
--   UiDSL.demo_page()                   -> the css_test sandbox node tree
--                                           (compat; sandbox.html is live)
--
-- CSS subset (intentionally small - e-ink + canvas reality):
--   selector { prop: value; ... }  with /* comments */
--   selectors: tag, .class, #id, comma lists (tag.class#id combinations)
--   colors: #rgb #rrggbb, rgb(r,g,b), gray(0.10), "10%", bare gray number
--   lengths: Npx / N -> Theme.scaleBySize(N)
--   custom props: --name: value;  -> collected into style.vars.name
--
-- The layout engine is a box model, not HTML: each node is a Lua spec table,
-- painted with ktui/primitives onto the blitbuffer. Long term this surface
-- should grow large enough to rebuild screens without touching Lua; the
-- css_test sandbox page is its proving ground.

local P = require("ktui/primitives")
local Theme = require("ktui/theme")

local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
if not lfs_ok or not lfs then
    local ok2, lfs2 = pcall(require, "lfs")
    lfs = ok2 and lfs2 or nil
end

local UiDSL = {}

-- Stable cascade order: by specificity, ties broken by source order.
-- Lua's table.sort is NOT stable, so without the explicit seq tie-break
-- equal-specificity rules could shuffle between runs and flip which one
-- wins the overwrite in style_for.
local function sort_rules(rules)
    table.sort(rules, function(a, b)
        if a.spec ~= b.spec then
            return a.spec < b.spec
        end
        return (a.seq or 0) < (b.seq or 0)
    end)
end

-- ============================================================ CSS parsing ===

local function strip_comments(css)
    return (css:gsub("/%*.-%*/", " "))
end

-- One declaration block -> decls{}, vars{} (custom props --name).
local function parse_declarations(block)
    local decls, vars = {}, {}
    for decl in (block .. ";"):gmatch("([^;]*)") do
        local prop, value = decl:match("^%s*(%-?%-?[%w%-]+)%s*:%s*(.-)%s*$")
        if prop then
            if prop:sub(1, 2) == "--" then
                vars[prop:sub(3)] = value
            else
                decls[prop] = value
            end
        end
    end
    return decls, vars
end

-- Parse a stylesheet into rules: { spec, tag, id, classes{}, decls{}, vars{} }.
-- Specificity = id*100 + classes*10 (tags tie-break by source order through
-- the stable sort). At-rule blocks (@vars etc.) become vars-only rules.
function UiDSL.parse(css_text)
    local rules = {}
    local text = strip_comments(tostring(css_text or ""))
    for selector, block in text:gmatch("([^{}]+)%s*{([^}]*)}") do
        if selector:match("^%s*@") then
            local _, vars = parse_declarations(block)
            if next(vars) then
                table.insert(rules, { spec = 0, tag = nil, id = nil, classes = {}, decls = {}, vars = vars })
            end
        else
            for raw_sel in selector:gmatch("[^,]+") do
                local sel = raw_sel:gsub("^%s+", ""):gsub("%s+$", "")
                if sel ~= "" then
                    local tag = sel:match("^([%a][%w%-]*)")
                    local id = sel:match("#([%w%-]+)")
                    local classes = {}
                    for cls in sel:gmatch("%.([%w%-]+)") do
                        classes[cls] = true
                    end
                    local ncls = 0
                    for _ in pairs(classes) do ncls = ncls + 1 end
                    table.insert(rules, {
                        -- CSS-ish specificity: id (100) > class (10) > tag
                        -- (1). The tag point matters: `div.foo` now outranks
                        -- plain `.foo` instead of tying with it.
                        spec = (id and 100 or 0) + ncls * 10 + (tag and 1 or 0),
                        tag = tag, id = id, classes = classes,
                        decls = parse_declarations(block),
                        seq = #rules + 1, -- source order, for the stable sort
                    })
                end
            end
        end
    end
    -- Stable cascade order: by specificity, ties broken by source order.
    -- Lua's table.sort is NOT stable, so without the explicit seq tie-break
    -- equal-specificity rules could shuffle between runs and flip which one
    -- wins the overwrite in style_for.
    sort_rules(rules)
    return { rules = rules, errors = {} }
end

-- ===================================================== values + validators ===

-- Theme palette names usable in any color position (color:, background:,
-- border-color:, ...). Resolved against the LIVE Theme at decoration time.
local THEME_COLORS = {
    primary   = "button_bg",   -- the app's solid accent (buttons, fills)
    onprimary = "button_text",
    ink       = "ink",
    muted     = "muted",
    border    = "border",
    panel     = "panel",
    soft      = "soft",
    bg        = "bg",
    danger    = "danger",
}

local function resolve_gray(val)
    -- gray(0.10) | 10% | 0.10 -> Blitbuffer gray (0 = white, 1 = black)
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
    -- Theme palette names: color resolves at USE time against the LIVE
    -- Theme palette, so a theme/density switch re-dresses existing nodes
    -- without re-parsing (nodes re-decorate on every tree build). NOTE: the
    -- palette value is a cdata color - NEVER compare it with ~= nil (invokes
    -- ColorRGB32:__eq(nil) and crashes in blitbuffer.lua); cdata is truthy.
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

local function resolve_length(val)
    local n = tonumber(tostring(val):match("^%-?[%.%d]+"))
    if not n then return nil end
    return Theme.scale(n)
end

-- Property registry: validation kind + where it lands on the Theme palette.
local PROPS = {
    ["background"]        = { kind = "color", theme = "bg" },
    ["background-color"]  = { kind = "color", theme = "bg" },
    ["color"]             = { kind = "color", theme = "ink" },
    ["muted-color"]       = { kind = "color", theme = "muted" },
    ["border-color"]      = { kind = "color", theme = "border" },
    ["panel-color"]       = { kind = "color", theme = "panel" },
    ["soft-color"]        = { kind = "color", theme = "soft" },
    ["button-color"]      = { kind = "color", theme = "button_bg" },
    ["button-text-color"] = { kind = "color", theme = "button_text" },
    ["danger-color"]      = { kind = "color", theme = "danger" },
    ["font-size"]         = { kind = "length" },
    ["radius"]            = { kind = "length" },
    ["border-size"]       = { kind = "length" },
    -- Node-layer props (styled onto nodes by UiDSL.apply_styles; they
    -- never reach the palette, but stay registered so typos still surface).
    ["pad"]               = { kind = "length" },
    ["gap"]               = { kind = "length" },
    ["border"]            = { kind = "bool" },
    ["bold"]              = { kind = "bool" },
    ["font-weight"]       = { kind = "string" },
    ["role"]              = { kind = "string" },
    ["align"]             = { kind = "string" },
    ["h"]                 = { kind = "length" },
    ["min-h"]             = { kind = "length" },
    ["text-align"]        = { kind = "string" },
    ["width"]             = { kind = "string" },
    ["flex"]              = { kind = "string" },
    ["display"]           = { kind = "string" },
    ["vertical-align"]    = { kind = "string" },
    ["valign"]            = { kind = "string" },
    ["kind"]              = { kind = "string" },
    ["icon-name"]         = { kind = "string" },
    ["icon"]              = { kind = "string" },
    ["icon-size"]         = { kind = "length" },
    ["avatar-size"]       = { kind = "length" },
    ["size"]              = { kind = "length" },
    -- Layout round 2: horizontal row alignment + outer margins. halign only
    -- means something on a row; margin/margin-x apply to any node (vertical
    -- margin comes from the parent's gap - e-ink keeps the model simple).
    ["halign"]            = { kind = "string" },
    ["margin"]            = { kind = "length" },
    ["margin-x"]          = { kind = "length" },
}

-- Resolve a single declaration value (public: the sandbox lists bad values).
function UiDSL.resolve_value(prop, value)
    local spec = PROPS[prop]
    local kind = spec and spec.kind or "string"
    if kind == "color" then
        local c = resolve_color(value)
        if not c then
            return nil, "invalid color: " .. tostring(value)
        end
        return c
    elseif kind == "length" then
        local n = resolve_length(value)
        if not n then
            return nil, "invalid length: " .. tostring(value)
        end
        return n
    elseif kind == "bool" then
        local v = tostring(value):lower()
        if v == "true" or v == "false" then return v == "true" end
        return nil, "invalid boolean: " .. tostring(value)
    end
    return tostring(value)
end

-- Cascade rules onto an element (tag + attrs{id, classes}). Later (higher
-- specificity) rules overwrite earlier ones.
function UiDSL.style_for(sheet, tag, attrs)
    attrs = attrs or {}
    local out, vars = {}, {}
    for _i, r in ipairs((sheet and sheet.rules) or {}) do
        local hit = (r.tag == nil or r.tag == tag)
            and (r.id == nil or r.id == attrs.id)
        if hit then
            for cls in pairs(r.classes) do
                if not (attrs.classes and attrs.classes[cls]) then
                    hit = false
                    break
                end
            end
        end
        if hit then
            for k, v in pairs(r.decls) do out[k] = v end
            if r.vars then for k, v in pairs(r.vars) do vars[k] = v end end
        end
    end
    out.vars = vars
    return out
end

-- Theme overlay: validated colors keyed by Theme palette names. Errors are
-- collected, never thrown - a broken sheet can't kill the paint path.
function UiDSL.theme_overrides(sheet, tag)
    local overrides, errors = {}, {}
    for _i, r in ipairs((sheet and sheet.rules) or {}) do
        -- Palette layer accepts ONLY global rules: `page { ... }`, or an
        -- unscoped rule with no tag, classes or id. The old tolerant mode
        -- ("classes/ids don't gate theme application") made any node-scoped
        -- rule leak into the WHOLE app palette: one `.card { background: }`
        -- repainted every screen black. Node rules decorate nodes only.
        local hit = r.tag == "page" or r.tag == tag
            or (r.tag == nil and next(r.classes) == nil and r.id == nil)
        if hit then
            for prop, value in pairs(r.decls) do
                local spec = PROPS[prop]
                if spec and spec.theme then
                    local color, err = UiDSL.resolve_value(prop, value)
                    if color then
                        overrides[spec.theme] = color
                    else
                        errors[#errors + 1] = prop .. ": " .. tostring(err)
                    end
                elseif spec == nil then
                    -- Unknown property: harmless in the palette layer, but
                    -- surface it so theme authors see their typos.
                    errors[#errors + 1] = "unknown property: " .. tostring(prop)
                end
                -- spec with kind but no theme (length props): validated on
                -- demand by style_for; nothing to overlay on the palette.
            end
        end
    end
    return overrides, errors
end

-- ====================================================== theme file loading ===

local _theme_cache = {} -- path -> { mtime, sheet, errors, nprops }

function UiDSL.theme_css_path(name)
    local Storage = require("kt_storage")
    if not name or name == "" then return nil end
    if not name:match("%.css$") then name = name .. ".css" end
    if name:find("/", 1, true) or name:find("\\", 1, true) then return nil end
    return Storage.data_dir() .. "/themes/" .. name
end

function UiDSL.list_theme_files()
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

-- Load + parse + validate. Cached per mtime (edit + reload picks changes up).
function UiDSL.load_theme_file(path)
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
    local sheet = UiDSL.parse(css)
    local overrides, errors = UiDSL.theme_overrides(sheet, "page")
    local nprops = 0
    for _ in pairs(overrides) do nprops = nprops + 1 end
    _theme_cache[path] = { mtime = attr, sheet = sheet, errors = errors, nprops = nprops }
    return true, sheet, errors, nprops
end

-- Apply settings.debug_theme_css onto the live Theme palette. Called from
-- App:apply_settings (and from the sandbox Reload) when debug mode is on.
function UiDSL.apply_theme_to_app(app)
    -- Always start from the baked palette: the overlay never accumulates
    -- across theme/density switches.
    local settings = app and app.state and app.state.settings or {}
    Theme.set_theme(settings.theme or "light")
    local name = settings.debug_theme_css
    if not name or name == "" then return end
    local path = UiDSL.theme_css_path(name)
    if not path then return end
    local ok, sheet, errors, nprops = UiDSL.load_theme_file(path)
    if not ok or not sheet or not nprops or nprops == 0 then return end
    local overrides = UiDSL.theme_overrides(sheet, "page")
    for key, color in pairs(overrides) do
        Theme[key] = color
    end
    app.state.debug_theme_errors = errors
end

-- =============================================================== layout ===
-- Node spec fields: tag ("box"|"row"|"text"|"para"|"image"|"spacer"|
-- "icon"|"toggle"|"avatar"|"button"), id, classes, text, src,
-- w/h/min_h (CSS lengths or px), pad, gap, fill_h, bg, color, radius,
-- border, border_size, bold, role, align, width, flex, display, valign,
-- kind, icon_name, icon_size, avatar_name, avatar_src, toggle_value,
-- data_bind. box children flow in a column; row children flow in a row.

local Widgets_mod  -- lazy to avoid circular require
local Icons_mod

local function get_widgets()
    if not Widgets_mod then Widgets_mod = require("ktui/widgets") end
    return Widgets_mod
end

local function get_icons()
    if not Icons_mod then Icons_mod = require("ktui/icons") end
    return Icons_mod
end

local function node_inset(n)
    return (n.pad or 0) * 2
end

local function text_role(n)
    return n.role or "default"
end

-- Cheap readability probe: ImageWidget with a missing file does NOT raise
-- (it builds an empty widget and paintTo succeeds painting nothing), so the
-- placeholder decision needs its own check. io.open+close per paint is
-- negligible next to a widget render.
local function file_readable(path)
    if not path or path == "" then return false end
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

-- Options shared by measure and paint for text/para nodes: bold, color,
-- alignment and an optional CSS font-size face (Theme.face is a fixed role
-- ladder; an explicit px size builds its own face so authors can tune text
-- freely). P.paragraph reads opts.align (TextBoxWidget alignment); the text
-- branch positions manually from node.align - both stay in sync here.
local function text_opts(n)
    local opts = { bold = n.bold, color = n.color, align = n.align }
    if n.font_size then
        local family = (n.role == "tiny" or n.role == "small")
            and "smallinfofont" or "cfont"
        local ok, face = pcall(require("ui/font").getFace, require("ui/font"), family, n.font_size)
        if ok and face then opts.face = face end
    end
    return opts
end

local function px(n, fallback)
    if n == nil then return fallback end
    if type(n) == "number" then return n end
    return resolve_length(n) or fallback
end

-- Resolve width: supports Npx, N%, plain number.
local function resolve_width(val, parent_w)
    if val == nil then return nil end
    if type(val) == "number" then return val end
    val = tostring(val)
    local pct = val:match("^([%d%.]+)%%$")
    if pct then
        local n = tonumber(pct)
        if n then return math.floor(parent_w * n / 100) end
    end
    return resolve_length(val)
end

-- Row layout: distribute inner_w among children. Fixed-width children first,
-- flex children share the remainder proportionally (default flex = 1).
-- Intrinsic width of a row child that has a natural size (icons, toggles,
-- avatars): these DON'T flex by default - they hug their content, so halign
-- has free space to distribute. Everything else (divs, paras, images, plain
-- text) defaults to flex=1 like before (fills the row).
local function intrinsic_row_w(node)
    if node.display == "none" then return nil end
    if node.tag == "icon" then
        local sz = node.icon_size or Theme.scale(14)
        return math.max(sz, 4)
    elseif node.tag == "toggle" then
        return Theme.scale(52)
    elseif node.tag == "avatar" then
        return node.avatar_size or Theme.scale(48)
    end
    return nil
end

local function row_child_widths(node, inner_w)
    local children = node.children or {}
    local n = #children
    if n == 0 then return {} end
    local gap = node.gap or 0
    -- Count visible children for gap calculation.
    local visible = 0
    for _, child in ipairs(children) do
        if child.display ~= "none" then visible = visible + 1 end
    end
    local total_gap = gap * math.max(0, visible - 1)
    local avail = math.max(0, inner_w - total_gap)
    local widths = {}
    local flex_total = 0
    local fixed_total = 0
    for i, child in ipairs(children) do
        if child.display == "none" then
            widths[i] = 0
        else
            local cw = resolve_width(child.width, inner_w)
                or (child.flex == nil and intrinsic_row_w(child))
            if cw then
                widths[i] = math.min(cw, avail)
                fixed_total = fixed_total + widths[i]
            else
                local fl = tonumber(child.flex) or 1
                widths[i] = -fl -- negative = flex placeholder
                flex_total = flex_total + fl
            end
        end
    end
    local flex_avail = math.max(0, avail - fixed_total)
    for i, child in ipairs(children) do
        if widths[i] and widths[i] < 0 then
            local fl = -widths[i]
            widths[i] = flex_total > 0 and math.floor(flex_avail * fl / flex_total) or 0
        end
    end
    return widths
end

-- Outer margin of a child in a flow (box column or row). CSS-like: margin
-- applies on BOTH sides of the axis (top+bottom in a column, left+right in
-- a row); margin-x only horizontal. Columns therefore add margin twice to
-- the flow height (before + after the child).
local function child_margin(child, axis)
    local m = child.margin or 0
    local mx = child.margin_x or 0
    return (axis == "x") and (mx + m) or m
end

local function children_h(node, w)
    local total = 0
    local inner_w = w - node_inset(node)
    local first = true
    for _i, child in ipairs(node.children or {}) do
        if child.display ~= "none" then
            if not first then total = total + (node.gap or 0) end
            first = false
            total = total + child_margin(child, "y") * 2 + UiDSL.measure(child, inner_w)
        end
    end
    return total
end

-- Height of a row's children: tallest child (horizontal flow).
local function row_content_h(node, w)
    local inner_w = w - node_inset(node)
    local widths = row_child_widths(node, inner_w)
    local max_h = 0
    for i, child in ipairs(node.children or {}) do
        if child.display ~= "none" and widths[i] and widths[i] > 0 then
            local ch = child_margin(child, "y") * 2 + UiDSL.measure(child, widths[i])
            if ch > max_h then max_h = ch end
        end
    end
    return max_h
end

-- Height of a node under width w.
function UiDSL.measure(node, w)
    if node.display == "none" then return 0 end
    if node._h_cache and node._h_w == w then return node._h_cache end
    local h
    if node.tag == "text" or node.tag == "value" then
        h = P.text_size(node.text or "", px(node.w, w), text_role(node), text_opts(node)).h
    elseif node.tag == "para" then
        local lines, line_h = P.paragraph_metrics(node.text or "", px(node.w, w), text_role(node), text_opts(node))
        h = lines * line_h
    elseif node.tag == "image" then
        h = px(node.h, Theme.scale(80))
    elseif node.tag == "spacer" then
        h = px(node.h, Theme.scale(12))
    elseif node.tag == "rule" then
        h = px(node.h, Theme.scale(10))
    elseif node.tag == "progress" then
        h = px(node.h, Theme.scale(10))
    elseif node.tag == "icon" then
        local sz = node.icon_size or Theme.scale(14)
        h = get_icons().text_size(node.icon_name or "home", sz).h
    elseif node.tag == "toggle" then
        h = Theme.scale(26)
    elseif node.tag == "avatar" then
        h = node.avatar_size or Theme.scale(48)
    elseif node.tag == "button" then
        h = px(node.h, Theme.btn_h())
    elseif node.tag == "input" then
        h = px(node.h, Theme.btn_h())
    elseif node.tag == "row" then
        h = row_content_h(node, w)
        if node.fill_h then h = math.max(h, node.fill_h) end
        -- Fixed height on a row: never smaller than the content.
        if node.h then h = math.max(h, px(node.h, 0)) end
    else -- box
        local inner = children_h(node, w)
        h = inner > 0 and inner or px(node.h, 0)
        if node.fill_h then h = math.max(h, node.fill_h) end
        -- Fixed height on a box: can be larger OR smaller than the content
        -- (content overflows visibly when smaller - author's call, like CSS).
        if node.h then h = px(node.h, h) end
    end
    h = h + node_inset(node)
    if node.min_h then h = math.max(h, px(node.min_h, 0)) end
    node._h_cache, node._h_w = h, w
    return h
end

-- Paint a node at (x, y) spanning width w. view registers hitboxes.
function UiDSL.paint(node, bb, x, y, w, view)
    if node.display == "none" then return end
    local pad = node.pad or 0
    local h = UiDSL.measure(node, w)
    local bg = node.bg
    -- Button draws its own background via W.button; skip the generic box.
    if node.tag ~= "button" then
        if node.border then
            P.box(bb, x, y, w, h, {
                border = true, border_size = node.border_size or 1,
                border_color = node.border_color or Theme.border,
                background = bg or Theme.panel,
                radius = node.radius,
            })
        elseif bg then
            P.rounded_rect(bb, x, y, w, h, bg, node.radius)
        end
    end
    local cx = x + pad
    local cy = y + pad
    local inner_w = w - pad * 2
    local inner_h = h - pad * 2
    if node.tag == "text" or node.tag == "value" then
        local opts = text_opts(node)
        local tw = math.min(inner_w, px(node.w, inner_w))
        local s = P.text_size(node.text or "", tw, text_role(node), opts)
        local tx = cx
        if node.align == "center" then
            tx = cx + math.floor((inner_w - math.min(s.w, tw)) / 2)
        elseif node.align == "right" then
            tx = cx + math.max(0, inner_w - math.min(s.w, tw))
        end
        P.text(bb, node.text or "", tx, cy, tw, text_role(node), opts)
    elseif node.tag == "para" then
        P.paragraph(bb, node.text or "", cx, cy, inner_w, inner_h,
            text_role(node), text_opts(node))
    elseif node.tag == "image" then
        local painted = false
        if node.anim then
            -- Animated sprite: frame player (GifAnim, ~8fps, rect-limited
            -- refresh) over a pre-composited frame directory. Stable key
            -- per src+h: tree rebuilds reuse the player (no timer leak),
            -- ticks self-stop on page change. Static frame_1 fallback when
            -- there is no view/app (headless) or the player fails.
            if view and view.app then
                local ok, GifAnim = pcall(require, "ktui/gifanim")
                if ok and GifAnim then
                    local key = "uidsl:" .. tostring(node.src) .. ":"
                        .. tostring(node.h or "")
                    local rect = { x = cx, y = cy, w = inner_w, h = inner_h }
                    -- Register the player rect ONLY while the node is inside
                    -- the view's visible content region: during a scroll the
                    -- node is still PAINTED (bleed is cleaned by the page's
                    -- chrome overpaint), but a rect registered off-screen
                    -- would keep the DIRECT tick blitting frames over
                    -- whatever sits there now - nav bar, error strip.
                    if GifAnim._rect_visible(view, rect) then
                        local player = GifAnim.ensure(view.app, view, key,
                            node.src or "", {
                                w = inner_w, h = inner_h,
                                rect = rect,
                            })
                        if player then
                            painted = GifAnim.draw(player, bb, cx, cy, inner_w, inner_h)
                            view.dithered = true
                        end
                    end
                end
            end
            if not painted and node.src and node.src ~= "" then
                -- Probe first: ImageWidget never raises on a missing file
                -- (it paints nothing and reports success), so an unchecked
                -- fallback would swallow the placeholder below.
                local f1 = node.src .. "/frame_1.png"
                if file_readable(f1) then
                    painted = P.image(bb, f1,
                        cx, cy, inner_w, inner_h, { cover = node.cover })
                end
            end
        elseif file_readable(node.src) then
            painted = P.image(bb, node.src, cx, cy, inner_w, inner_h,
                { cover = node.cover, radius = node.radius })
            if painted and view then
                view.dithered = true
            end
        end
        if not painted then
            -- Broken-image placeholder, HTML-like: framed box, broken-image
            -- icon centered, alt text below (or just the icon when there is
            -- no alt - like <img> without alt). Everything fits INSIDE the
            -- box: icon+text only when the height allows both, text clipped
            -- to the box (no painted-over captions below).
            P.box(bb, cx, cy, inner_w, inner_h, {
                border = true, border_size = 1,
                border_color = Theme.muted, background = Theme.bg,
                radius = node.radius,
            })
            local alt = (node.alt and node.alt ~= "") and node.alt or nil
            local alt_h = alt and Theme.line_h("tiny") or 0
            local gap = alt and Theme.scale(2) or 0
            -- Icon shrinks to whatever fits with the text inside the box.
            local ic_sz = math.max(0, math.min(Theme.scale(28),
                inner_h - alt_h - gap, inner_w))
            if ic_sz > 0 then
                local icon_y = cy + math.floor((inner_h - ic_sz - alt_h - gap) / 2)
                local icon_x = cx + math.floor((inner_w - ic_sz) / 2)
                local Icons = get_icons()
                if Icons.has_asset("image") then
                    Icons.draw(bb, "image", icon_x, icon_y, ic_sz,
                        { color = Theme.muted })
                else
                    P.text(bb, Icons.glyph("image") or "?", icon_x, icon_y,
                        ic_sz * 2, "default", { color = Theme.muted })
                end
                if alt then
                    -- Text inside the box, below the icon.
                    P.text(bb, alt, cx, icon_y + ic_sz + gap, inner_w,
                        "tiny", { color = Theme.muted })
                end
            elseif alt then
                -- Too short for the icon: alt text alone, v-centered.
                P.vcenter_text(bb, alt, cx, cy, inner_w, inner_h,
                    "tiny", { color = Theme.muted })
            end
        end
    elseif node.tag == "rule" then
        -- <hr>: horizontal rule centered in its band. CSS restyles it:
        -- .hr { background: ...; h: 2px; } paints a thicker colored line.
        if node.bg then
            local line_h2 = math.max(1, math.min(px(node.h, Theme.scale(10)), inner_h))
            P.rect(bb, cx, cy + math.floor((inner_h - line_h2) / 2), inner_w,
                line_h2, node.bg)
        else
            P.rect(bb, cx, cy + math.floor(inner_h / 2), inner_w, 1, Theme.border)
        end
    elseif node.tag == "progress" then
        -- Progress bar: track (soft) + fill (primary). Value from the bind
        -- (0..progress_max, clamped); nil state = empty bar.
        local maxv = node.progress_max or 100
        local val = math.max(0, math.min(maxv, tonumber(node.progress_value) or 0))
        local bar_h = math.max(3, math.min(inner_h, Theme.scale(12)))
        local bar_y = cy + math.floor((inner_h - bar_h) / 2)
        local fill_w = math.floor(inner_w * val / maxv)
        P.rounded_rect(bb, cx, bar_y, inner_w, bar_h, Theme.soft,
            math.floor(bar_h / 2))
        if fill_w > 0 then
            P.rounded_rect(bb, cx, bar_y, fill_w, bar_h, Theme.button_bg,
                math.floor(bar_h / 2))
        end
    elseif node.tag == "icon" then
        local Icons = get_icons()
        local sz = node.icon_size or Theme.scale(14)
        Icons.draw(bb, node.icon_name or "home", cx, cy, sz, { color = node.color })
    elseif node.tag == "toggle" then
        local tw = Theme.scale(52)
        local th = Theme.scale(26)
        P.zen_toggle(bb, cx, cy, tw, th, node.toggle_value and true or false)
    elseif node.tag == "avatar" then
        local sz = node.avatar_size or Theme.scale(48)
        get_widgets().avatar(bb, cx, cy, sz, node.avatar_src, node.avatar_name)
        if view then view.dithered = true end
    elseif node.tag == "input" then
        -- Text-field look: muted border, current value or placeholder hint.
        local txt = node.input_text or ""
        P.box(bb, cx, cy, inner_w, inner_h, {
            border = true, border_size = 1,
            border_color = Theme.muted, background = Theme.panel,
            radius = node.radius,
        })
        local txp = Theme.scale(10)
        if txt == "" then
            P.vcenter_text(bb, node.input_hint or "...", cx + txp, cy,
                inner_w - txp * 2, inner_h, "small", { color = Theme.muted })
        else
            P.vcenter_text(bb, txt, cx + txp, cy,
                inner_w - txp * 2, inner_h, "default", {})
        end
    elseif node.tag == "button" then
        local W = get_widgets()
        local target = view or { hitboxes = {} }
        W.button(target, bb, {
            x = x, y = y, w = w, h = h,
            label = node.text, icon = node.icon_name,
            icon_size = node.icon_size,
            kind = node.kind or "secondary",
            on_tap = node.on_tap,
        })
    elseif node.tag == "row" then
        -- Horizontal flow: children side by side. halign distributes leftover
        -- width: left (default, packed at start) | center | right | between.
        local widths = row_child_widths(node, inner_w)
        local valign = node.valign or "top"
        local halign = node.halign or "left"
        local used = 0
        local visible = 0
        for i, child in ipairs(node.children or {}) do
            if child.display ~= "none" and widths[i] and widths[i] > 0 then
                used = used + widths[i] + child_margin(child, "x")
                visible = visible + 1
            end
        end
        if visible > 1 then used = used + (visible - 1) * (node.gap or 0) end
        local free = math.max(0, inner_w - used)
        local rx = cx
        if halign == "center" then
            rx = cx + math.floor(free / 2)
        elseif halign == "right" then
            rx = cx + free
        end
        local nvis = 0
        for i, child in ipairs(node.children or {}) do
            if child.display ~= "none" and widths[i] and widths[i] > 0 then
                if nvis > 0 then rx = rx + (node.gap or 0) end
                if halign == "between" and nvis > 0 then
                    rx = rx + math.floor(free / (visible - 1))
                end
                nvis = nvis + 1
                rx = rx + child_margin(child, "x")
                local ch = UiDSL.measure(child, widths[i])
                local child_y = cy + child_margin(child, "y")
                if valign == "center" then
                    child_y = child_y + math.floor((inner_h - ch) / 2)
                elseif valign == "bottom" then
                    child_y = child_y + math.max(0, inner_h - ch)
                end
                UiDSL.paint(child, bb, rx, child_y, widths[i], view)
                rx = rx + widths[i]
            end
        end
    elseif node.tag == "spacer" then
        -- nothing to paint
    else
        -- box: vertical flow (margin spaces the child above AND below;
        -- margin_x insets it horizontally, shrinking the child's width).
        local first = true
        for _i, child in ipairs(node.children or {}) do
            if child.display ~= "none" then
                if not first then cy = cy + (node.gap or 0) end
                first = false
                local my = child_margin(child, "y")
                local mx2 = child_margin(child, "x")
                cy = cy + my
                UiDSL.paint(child, bb, cx + mx2, cy,
                    math.max(1, inner_w - mx2 * 2), view)
                cy = cy + UiDSL.measure(child, inner_w) + my
            end
        end
    end
    -- Hitbox for data-action (button registers its own via W.button).
    if view and node.on_tap and node.tag ~= "button" then
        P.hit(view, x, y, w, h, node.on_tap,
            "uidsl:" .. tostring(node.id or node.class or node.tag))
    end
end

-- Build a node from a spec (copy + reset measure cache).
function UiDSL.node(spec)
    local n = {}
    if spec then for k, v in pairs(spec) do n[k] = v end end
    n._h_cache = nil
    return n
end

-- ================================================ HTML subset -> node tree ===
-- The "conversion" layer: a small HTML document is turned into the SAME node
-- tree the canvas painter consumes. The canvas UI remains the only renderer.
--
-- Supported: div (box), row (horizontal box), p (paragraph),
-- span/h1/h2/h3 (text), img (image, data-anim plays a pre-composited frame
-- directory via GifAnim), br/hr/spacer (spacer), icon, toggle,
-- avatar, button (native pill), value (live readout), input (text field).
-- Unknown tags become transparent boxes. Attributes: class, id,
-- src (img/avatar), data-h (img height), data-fit (img cover|contain),
-- width/flex (row children), name/size (icon/avatar), kind/icon (button),
-- title/placeholder (input dialog + hint), data-empty (value fallback),
-- data-bind (toggle/button/input read an app.state path; toggle/button
-- flip the bool on tap, button kind follows it; with data-step/data-min/
-- data-max the button counts instead; input opens the dialog and saves),
-- data-bind-width + data-width-scale (spacer width tracks a number -
-- walks siblings in a row), data-action + data-id (tap callback
-- actions[name](id, node) from the actions map; unknown names surface as
-- errors). Double-quoted
-- attributes only; &amp; &lt; &gt; &quot; entities. {{name}} placeholders
-- are substituted from the vars map BEFORE parsing (e.g. {{shot}} ->
-- screenshot path). <style> blocks are extracted (returned as css_text,
-- concatenated in order) and <script> blocks discarded - neither becomes
-- nodes, so code never leaks onto the canvas as text.
local HTML_ENTITIES = {
    ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">", ["&quot;"] = '"',
    ["&apos;"] = "'", ["&nbsp;"] = " ",
}

local function decode_entities(str)
    return (str:gsub("&([%w]+);", function(name)
        return HTML_ENTITIES["&" .. name .. ";"] or "&" .. name .. ";"
    end))
end

-- sandbox.html may carry its own stylesheet: <style> blocks are extracted
-- (concatenated in source order) and never become nodes; <script> blocks are
-- discarded the same way so code never leaks onto the canvas as text.
-- Returns root, css_text, errors. data-action with an optional data-id calls
-- actions[name](id, node, ...); an unknown action is a visible error, never
-- a silent dead tap.
local function extract_style_blocks(html)
    local styles = {}
    -- Case-insensitive <style ...>...</style> / <script ...>...</script>.
    local function strip(tag, keep)
        local open_p = "<%s*" .. tag .. "[^>]*>"
        local close_p = "<%s*/%s*" .. tag .. "%s*>"
        -- [%s%S] spans newlines: <style> blocks are multiline.
        return (html:gsub(open_p .. "([%s%S]-)" .. close_p, function(body)
            if keep then table.insert(styles, body) end
            return " "
        end))
    end
    html = strip("[sS][tT][yY][lL][eE]", true)
    html = strip("[sS][cC][rR][iI][pP][tT]", false)
    return html, table.concat(styles, "\n")
end

function UiDSL.from_html(html, actions, vars)
    actions = actions or {}
    vars = vars or {}
    html = tostring(html or "")
    local stripped, local_css = extract_style_blocks(html)
    html = stripped
    local css_text = local_css or ""
    local errors = {}
    html = html:gsub("{{([%w_]+)}}", function(name)
        return tostring(vars[name] or "")
    end)
    html = html:gsub("<%-%-.-%%-%->", " ") -- comments

    local root = UiDSL.node({ tag = "box", children = {}, html_tag = "body" })
    local stack = { root }
    local function top() return stack[#stack] end

    local VOID = { img = true, br = true, hr = true, icon = true, toggle = true,
        avatar = true, spacer = true, value = true, input = true, progress = true }
    local TEXT_HOST = { p = true, span = true, h1 = true, h2 = true, h3 = true, button = true }

    local function add_text(str)
        str = decode_entities(str)
        str = str:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
        if str == "" then return end
        local t = top()
        if t.text_host then
            t.text = t.text and (t.text .. " " .. str) or str
        else
            t.children = t.children or {}
            local last = t.children[#t.children]
            if last and last.tag == "text" and not last.html_tag then
                last.text = last.text .. " " .. str
            else
                table.insert(t.children, UiDSL.node({ tag = "text", text = str }))
            end
        end
    end

    -- Inline tags inside a text host (p/span/h*) have no block semantics:
    -- the para/text painters only render the host's own text, so a child
    -- node's words used to VANISH (<p>a <b>b</b></p> painted just "a ").
    -- These tags now merge into the host's text (formatting dropped - full
    -- inline runs are a future step) and their close tag is consumed.
    local INLINE_TAGS = {
        b = true, strong = true, i = true, em = true, u = true, s = true,
        code = true, small = true, big = true, mark = true, span = true, a = true,
    }
    local skipped_inline = {}

    local function open(name, attrs, selfclose)
        if top().text_host and INLINE_TAGS[name] then
            table.insert(skipped_inline, name)
            return
        end
        local n
        if name == "img" then
            local fit = attrs["data-fit"]
            n = UiDSL.node({ tag = "image", src = attrs.src,
                h = attrs["data-h"] or "60px",
                cover = attrs["data-cover"] == "true" or fit == "cover",
                anim = attrs["data-anim"] == "true",
                alt = attrs.alt,
                radius = attrs["data-radius"]
                    and tonumber(tostring(attrs["data-radius"]):match("^([%d%.]+)"))
                    or nil })
        elseif name == "p" then
            n = UiDSL.node({ tag = "para" })
        elseif name == "br" then
            n = UiDSL.node({ tag = "spacer", h = "4px" })
        elseif name == "hr" then
            -- Real rule: paintable line (color/size from CSS .hr { ... }).
            n = UiDSL.node({ tag = "rule", h = "10px" })
        elseif name == "h1" then
            n = UiDSL.node({ tag = "text", role = "title", bold = true })
        elseif name == "h2" then
            n = UiDSL.node({ tag = "text", role = "heading", bold = true })
        elseif name == "h3" then
            n = UiDSL.node({ tag = "text", role = "small", bold = true })
        elseif name == "span" then
            n = UiDSL.node({ tag = "text" })
        elseif name == "row" then
            n = UiDSL.node({ tag = "row", children = {} })
        elseif name == "button" then
            n = UiDSL.node({ tag = "button",
                kind = attrs.kind or attrs["data-kind"] or "secondary",
                icon_name = attrs.icon or attrs["data-icon"],
                icon_size = attrs["icon-size"] and tonumber(attrs["icon-size"]) })
        elseif name == "icon" then
            n = UiDSL.node({ tag = "icon",
                icon_name = attrs.name or attrs["data-name"] or attrs.icon or "home",
                icon_size = attrs.size and tonumber(attrs.size)
                    or attrs["icon-size"] and tonumber(attrs["icon-size"]) })
        elseif name == "toggle" then
            n = UiDSL.node({ tag = "toggle",
                bind_key = attrs["data-bind"] or attrs.bind,
                toggle_value = attrs.on == "true" or attrs.checked == "true"
                    or attrs.value == "true" or attrs["data-on"] == "true" })
        elseif name == "avatar" then
            n = UiDSL.node({ tag = "avatar",
                avatar_src = attrs.src,
                avatar_name = attrs.name or attrs["data-name"],
                avatar_size = attrs.size and tonumber(attrs.size)
                    or attrs["data-size"] and tonumber(attrs["data-size"]) })
        elseif name == "spacer" then
            n = UiDSL.node({ tag = "spacer", h = attrs["data-h"] or "12px",
                bind_width = attrs["data-bind-width"],
                bind_scale = attrs["data-width-scale"] and tonumber(attrs["data-width-scale"]) })
        elseif name == "progress" then
            -- Barra de progresso: data-bind lê um número (0..100, clamp);
            -- data-max re-escala (ex: contador 0..9 vira 0..100%).
            n = UiDSL.node({ tag = "progress", h = attrs["data-h"] or "10px",
                bind_key = attrs["data-bind"] or attrs.bind,
                progress_max = tonumber(attrs["data-max"]) or 100 })
        elseif name == "value" then
            n = UiDSL.node({ tag = "value",
                empty_text = attrs["data-empty"] or attrs.empty })
        elseif name == "input" then
            n = UiDSL.node({ tag = "input",
                input_title = attrs.title or attrs["data-title"],
                input_hint = attrs.placeholder or attrs["data-placeholder"] or attrs.hint })
        else
            n = UiDSL.node({ tag = "box", children = {} }) -- div + unknown tags
        end
        n.html_tag = name
        n.id = attrs.id
        if attrs.class then
            local classes = {}
            for cls in attrs.class:gmatch("%S+") do classes[cls] = true end
            n.classes = classes
            n.class = attrs.class
        end
        -- Width / flex may come from attributes (CSS wins later in
        -- apply_styles when both are present).
        if attrs.width then n.width = attrs.width end
        if attrs.flex then n.flex = attrs.flex end
        if attrs["data-width"] then n.width = attrs["data-width"] end
        if attrs["data-flex"] then n.flex = attrs["data-flex"] end
        if attrs["data-bind"] or attrs.bind then
            n.bind_key = attrs["data-bind"] or attrs.bind
        end
        -- Numeric stepper (button only): tap adds data-step, clamped to
        -- data-min/data-max. Without data-step a bound button flips a bool.
        if attrs["data-step"] then n.bind_step = tonumber(attrs["data-step"]) end
        if attrs["data-min"] then n.bind_min = tonumber(attrs["data-min"]) end
        if attrs["data-max"] then n.bind_max = tonumber(attrs["data-max"]) end
        if attrs["data-action"] then
            local aname = attrs["data-action"]
            local fn = actions[aname]
            if fn then
                n._has_action = true
                local aid = attrs["data-id"]
                n.on_tap = function(...)
                    return fn(aid, n, ...)
                end
            else
                errors[#errors + 1] = "unknown action: " .. tostring(aname)
            end
        end
        if attrs["data-h"] and n.tag ~= "image" then
            n.min_h = attrs["data-h"]
        end
        local t = top()
        t.children = t.children or {}
        table.insert(t.children, n)
        if not VOID[name] and not selfclose then
            if TEXT_HOST[name] then n.text_host = true end
            table.insert(stack, n)
        end
    end

    local pos = 1
    while pos <= #html do
        local lt = html:find("<", pos, true)
        if not lt then
            add_text(html:sub(pos))
            break
        end
        if lt > pos then add_text(html:sub(pos, lt - 1)) end
        local gt = html:find(">", lt, true)
        if not gt then break end -- malformed tail: ignored
        local inner = html:sub(lt + 1, gt - 1)
        pos = gt + 1
        if inner:sub(1, 1) == "/" then
            local name = inner:match("^/%s*([%w%-]+)")
            -- Void elements are never pushed: an explicit </img> etc. is a
            -- no-op (without this guard the tolerant-close below would pop
            -- real ancestors looking for a match).
            if name and VOID[name] then
                -- ignore
            -- Consume the close of an inline tag we merged into a text host
            -- (it was never pushed onto the stack).
            elseif #skipped_inline > 0 and skipped_inline[#skipped_inline] == name
                and top() and top().text_host then
                table.remove(skipped_inline)
            else
                -- Tolerant close: pop until the matching open tag.
                while #stack > 1 and top().html_tag ~= name do
                    table.remove(stack)
                end
                if #stack > 1 then table.remove(stack) end
            end
        else
            local selfclose = inner:sub(-1) == "/"
            if selfclose then inner = inner:sub(1, -2) end
            local name = inner:match("^%s*([%w%-]+)")
            if name then
                local attrs = {}
                for k, v in inner:gmatch('([%w%-]+)%s*=%s*"([^"]*)"') do
                    attrs[k] = v
                end
                -- <style>/<script> never reach the tree: style bodies were
                -- extracted up front, script bodies discarded. Stray tags here
                -- (unclosed blocks) are skipped so code can't leak as text.
                local lname = name:lower()
                if lname ~= "style" and lname ~= "script" then
                    open(name, attrs, selfclose)
                end
            end
        end
    end
    return root, css_text, errors
end

-- ================================= CSS -> node styling (decorates the tree) ===

-- Apply the stylesheet onto a node tree: CSS wins over the spec when the
-- property is present. One level of align inheritance: box -> text children.
function UiDSL.apply_styles(node, sheet)
    if not node then return node end
    if sheet then
        local st = UiDSL.style_for(sheet, node.html_tag or node.tag,
            { id = node.id, classes = node.classes })
        local bg = resolve_color(st["background"] or st["background-color"])
        if bg then node.bg = bg end
        local ink = resolve_color(st["color"])
        if ink then node.color = ink end
        local bc = resolve_color(st["border-color"])
        if bc then node.border_color = bc end
        local r = resolve_length(st["radius"])
        if r then node.radius = r end
        local p = resolve_length(st["pad"])
        if p then node.pad = p end
        local g = resolve_length(st["gap"])
        if g then node.gap = g end
        local bs = resolve_length(st["border-size"])
        if bs then node.border_size = bs end
        local fs = resolve_length(st["font-size"])
        if fs then node.font_size = fs end
        local hh = resolve_length(st["h"] or st["height"])
        if hh then node.h = hh end
        local mh = resolve_length(st["min-h"])
        if mh then node.min_h = mh end
        if st.border ~= nil then
            if st.border == "true" or st.border == "1" then
                node.border = true
            elseif st.border == "false" or st.border == "0" or st.border == "none" then
                node.border = false
            end
        end
        if node.border_size then node.border = true end
        if st.bold == "true" or st["font-weight"] == "bold" then node.bold = true end
        if st.align or st["text-align"] then node.align = st.align or st["text-align"] end
        if st.role then node.role = st.role end
        -- Layout layer: width (Npx | N% | number), flex, display, valign.
        -- CSS wins over the HTML attributes set in from_html.
        if st.width then node.width = st.width end
        if st.flex then node.flex = st.flex end
        if st.display then
            local d = tostring(st.display):lower()
            if d == "none" then node.display = "none" end
        end
        if st["vertical-align"] then node.valign = tostring(st["vertical-align"]):lower() end
        if st.valign then node.valign = tostring(st.valign):lower() end
        -- Component layer: button kind (primary|secondary|ghost), icon refs.
        if st.kind then node.kind = tostring(st.kind):lower() end
        if st["icon-name"] or st["icon"] then
            node.icon_name = st["icon-name"] or st["icon"]
        end
        local isz = st["icon-size"]
        if isz then
            local nsz = resolve_length(isz)
            if nsz then node.icon_size = nsz end
        end
        local asz = st["avatar-size"] or st.size
        if asz and node.tag == "avatar" then
            local nsz = resolve_length(asz)
            if nsz then node.avatar_size = nsz end
        end
        -- Margins: outer spacing handled by the PARENT flow (box column and
        -- row both honor child.margin/margin_x), not by the node's own box.
        local mg = resolve_length(st["margin"])
        if mg then node.margin, node.margin_x = mg, mg end
        local mgx = resolve_length(st["margin-x"])
        if mgx then node.margin_x = mgx end
        -- Row horizontal alignment: left (default) | center | right | between.
        if st.halign then node.halign = tostring(st.halign):lower() end
        -- Image corners: data-radius attribute or CSS radius on an image.
        if node.tag == "image" and not node.radius then
            local rr = resolve_length(st.radius or st["border-radius"])
            if rr then node.radius = rr end
        end
    end
    for _i, child in ipairs(node.children or {}) do
        UiDSL.apply_styles(child, sheet)
    end
    -- One-level align inheritance: a styled box passes text-align to its
    -- direct text/para children that have no align of their own.
    if node.align and node.tag == "box" then
        for _i, child in ipairs(node.children or {}) do
            if (child.tag == "text" or child.tag == "para") and not child.align then
                child.align = node.align
            end
        end
    end
    -- Row valign inheritance: a row passes vertical-align to itself only;
    -- children keep their own (default top). Nothing to propagate.
    -- A display:none node contributes nothing: clear its cached height so a
    -- stale measure from before the style pass can't leak into paint.
    if node.display == "none" then
        node._h_cache, node._h_w = nil, nil
    end
    return node
end

-- The sheet the sandbox paints with: the debug theme file when one is armed,
-- otherwise the built-in demo stylesheet.
-- The built-in demo sheet is parsed once per session (css_test rebuilds
-- its tree per paint otherwise).
local _demo_sheet = nil
function UiDSL.demo_sheet()
    if not _demo_sheet then
        _demo_sheet = UiDSL.parse(UiDSL.DEMO_CSS)
    end
    return _demo_sheet
end

function UiDSL.current_sheet(app)
    local name = app and app.state and app.state.settings
        and app.state.settings.debug_theme_css or nil
    if name and name ~= "" then
        local path = UiDSL.theme_css_path(name)
        if path then
            local ok, sheet = UiDSL.load_theme_file(path)
            if ok and sheet then return sheet end
        end
    end
    return UiDSL.demo_sheet()
end

-- Merge two sheets: base (theme) under top (inline <style>). Rules are
-- re-sequenced so source order spans the merge, then re-sorted by the same
-- cascade - inline wins ties, specificity still wins overall.
function UiDSL.merge_sheets(base, top)
    local rules = {}
    for _, r in ipairs((base and base.rules) or {}) do
        table.insert(rules, r)
    end
    for _, r in ipairs((top and top.rules) or {}) do
        table.insert(rules, r)
    end
    for i, r in ipairs(rules) do r.seq = i end
    sort_rules(rules)
    return { rules = rules, errors = {} }
end

-- Validate every declaration of a sheet (node layer): unknown properties
-- and unresolvable values become visible errors instead of silent no-ops.
-- The palette layer keeps its own reporter (theme_overrides).
function UiDSL.validate_sheet(sheet)
    local errors = {}
    for _, r in ipairs((sheet and sheet.rules) or {}) do
        for prop, value in pairs(r.decls or {}) do
            local spec = PROPS[prop]
            if spec == nil then
                errors[#errors + 1] = "unknown property: " .. tostring(prop)
            else
                local _, err = UiDSL.resolve_value(prop, value)
                if err then
                    errors[#errors + 1] = prop .. ": " .. tostring(err)
                end
            end
        end
    end
    return errors
end

-- =================================================== sandbox.html loader ===
-- The sandbox screen is a USER file: themes/pages/sandbox.html (HTML with an
-- optional <style> block). Pure CSS themes (themes/*.css) keep working
-- untouched underneath it: theme sheet first, inline <style> on top.
-- Combos that all work: CSS-only (theme), HTML-only (active theme dresses
-- it), HTML+CSS (inline wins ties). Errors are always shown, never fallback
-- to the demo behind the author's back.

function UiDSL.sandbox_path()
    local Storage = require("kt_storage")
    return Storage.data_dir() .. "/themes/pages/sandbox.html"
end

function UiDSL.sandbox_exists()
    local f = io.open(UiDSL.sandbox_path(), "r")
    if f then f:close() return true end
    return false
end

-- Write the skeleton file. Never overwrites unless force=true: sandbox.html
-- is user-owned (the app's Reset action backs the old file up to .bak first).
-- Returns ok, errcode (nil on success, "exists" | "write" otherwise).
function UiDSL.install_sandbox(force)
    local path = UiDSL.sandbox_path()
    if not force and UiDSL.sandbox_exists() then
        return false, "exists"
    end
    local dir = path:match("^(.*)/[^/]+$")
    local parent = dir and dir:match("^(.*)/[^/]+$")
    -- lfs.mkdir creates ONE level: ensure the parent (themes/) first.
    pcall(function()
        if lfs and lfs.mkdir then
            if parent then lfs.mkdir(parent) end
            lfs.mkdir(dir)
        end
    end)
    local f = io.open(path, "w")
    if not f then return false, "write" end
    f:write(UiDSL.SKELETON_HTML)
    f:close()
    return true, path
end

local _sbx = {} -- { mtime, sheet_id, tree, merged, errors }

-- data-bind: "settings.debug_mode" reads app.state.settings.debug_mode.
-- Walk the dotted path from app.state. Reads never create tables (missing
-- reads as nil); writes pass create=true so fresh paths like
-- sandbox.ligado materialize on first tap. Returns value, parent, leaf key.
local function bind_lookup(app, path, create)
    if not path or path == "" then return nil, nil, nil end
    local t = app and app.state
    if type(t) ~= "table" then return nil, nil, nil end
    local parent, key = nil, nil
    for seg in tostring(path):gmatch("[^%.]+") do
        if type(t) ~= "table" then return nil, nil, nil end
        parent, key = t, seg
        if t[seg] == nil and create then t[seg] = {} end
        t = t[seg]
    end
    return t, parent, key
end

local function bind_refresh(app)
    if app and app.refresh then app:refresh(true) end
end

-- Resolve every node carrying bind_key (public for tests: sandbox_tree
-- calls it after every style pass, including cache hits, because binds
-- are live state, not file content):
--   toggle/button + bind (no data-step): read the bool; a tap flips it and
--     refreshes (explicit data-action wins the tap). A bound button also
--     paints primary when on / secondary when off - the visible color flip.
--   button + bind + data-step: tap adds the step, clamped to
--     data-min/data-max (explicit data-action still wins the tap).
--   value + bind: node.text tracks tostring(state) - a live readout
--     (data-empty supplies the text shown when the state is nil/"").
--   input + bind: node.input_text tracks tostring(state); a tap opens the
--     system input dialog and saves back to the path (explicit data-action
--     still wins the tap).
--   spacer + data-bind-width: node.width tracks number * scale px - inside
--     a <row> this walks the siblings (discrete steps per tap; e-ink
--     never animates, each tap is one full refresh).
local function resolve_binds(tree, app, errors)
    if not tree then return end
    local function flip_bool(path)
        return function()
            local _, parent, key = bind_lookup(app, path, true)
            if parent and key then
                parent[key] = not (parent[key] == true)
            end
            bind_refresh(app)
        end
    end
    local function step_num(node)
        local path = node.bind_key
        return function()
            local cur, parent, key = bind_lookup(app, path, true)
            if parent and key then
                local n = (tonumber(cur) or 0) + (node.bind_step or 1)
                if node.bind_min ~= nil then n = math.max(n, node.bind_min) end
                if node.bind_max ~= nil then n = math.min(n, node.bind_max) end
                parent[key] = n
            end
            bind_refresh(app)
        end
    end
    -- Returns true when a layout-affecting field changed. The measure cache
    -- is keyed by width only, so any mutation here must bust it - otherwise
    -- a tap that changes state (wider value text, grown spacer) would leave
    -- ancestors (row/card) with stale heights and cards would overlap.
    -- Change flags propagate upward: a grown child clears every box above.
    local function walk(node)
        local changed = false
        if node.bind_key then
            local val = bind_lookup(app, node.bind_key)
            -- Bind closures capture THIS app: a cached tree that outlived its
            -- app (plugin reopened, tests reuse trees) must rebuild them, or
            -- taps would write into the dead app's state forever. An explicit
            -- data-action tap is NOT a bind closure: it never gets rebuilt.
            if node._bind_app ~= app then
                if not node._has_action then
                    node.on_tap = nil
                end
                node._bind_app = app
            end
            if node.tag == "toggle" then
                node.toggle_value = (val == true)
                if not node.on_tap then
                    node.on_tap = flip_bool(node.bind_key)
                end
            elseif node.tag == "button" then
                if node.bind_step ~= nil then
                    if not node.on_tap then
                        node.on_tap = step_num(node)
                    end
                else
                    node.toggle_value = (val == true)
                    -- Live color: the bound bool drives the pill kind (bind
                    -- wins over kind=/CSS here by design - the tap visibly
                    -- flips secondary <-> primary).
                    if type(val) == "boolean" or val == nil then
                        node.kind = node.toggle_value and "primary" or "secondary"
                    end
                    if not node.on_tap then
                        node.on_tap = flip_bool(node.bind_key)
                    end
                end
            elseif node.tag == "value" then
                local new_text
                if val == nil or val == "" then
                    new_text = node.empty_text or ""
                else
                    new_text = tostring(val)
                end
                if node.text ~= new_text then
                    node.text = new_text
                    changed = true
                end
            elseif node.tag == "progress" then
                -- Live fill: number from state (0..progress_max). Cache-busts
                -- like value so the parent's measure re-runs if h tracks it.
                local new_v = tonumber(val) or 0
                if node.progress_value ~= new_v then
                    node.progress_value = new_v
                    changed = true
                end
            elseif node.tag == "input" then
                node.input_text = tostring(val == nil and "" or val)
                if not node.on_tap then
                    node.on_tap = function()
                        UiDSL.open_input(app, node)
                    end
                end
            end
        end
        if node.bind_width then
            -- Parenthesize: bind_lookup returns (value, parent, key) and
            -- the extras must not leak into tonumber as the base argument.
            local n = tonumber((bind_lookup(app, node.bind_width))) or 0
            local scale = node.bind_scale or Theme.scale(24)
            n = math.max(0, math.min(20, n))
            local new_w = math.floor(n * scale)
            if node.width ~= new_w then
                node.width = new_w
                changed = true
            end
        end
        for _, child in ipairs(node.children or {}) do
            if walk(child) then changed = true end
        end
        if changed then node._h_cache, node._h_w = nil, nil end
        return changed
    end
    walk(tree)
end

UiDSL.resolve_binds = resolve_binds

-- Write dialog text back to the node's bind path. Public (and split from
-- open_input) so tests drive the save path without showing UI.
function UiDSL.save_input(app, node, text)
    if not node or not node.bind_key then return end
    local _, parent, key = bind_lookup(app, node.bind_key, true)
    if parent and key then
        parent[key] = tostring(text or "")
    end
    bind_refresh(app)
end

-- Open the system single-line input dialog for an <input> node. Public and
-- overridable (tests replace it to capture the node without showing UI);
-- the dialog's OK callback funnels through save_input above.
function UiDSL.open_input(app, node)
    if not node then return end
    local current = tostring((bind_lookup(app, node.bind_key)) or "")
    local Modals = require("ktui/modals")
    Modals.input(node.input_title or "Editar",
        current, node.input_hint, nil, function(text)
            UiDSL.save_input(app, node, text)
        end)
end

-- Build the sandbox tree from the user file. Cached by file mtime + theme
-- sheet identity (edit + Reload picks changes up). Missing/unreadable file
-- yields an empty tree plus a visible error - never the demo.
function UiDSL.sandbox_tree(app, actions, vars)
    local path = UiDSL.sandbox_path()
    local mtime = nil
    if lfs then
        local ok, a = pcall(lfs.attributes, path, "modification")
        if ok then mtime = a end
    end
    local theme_sheet = UiDSL.current_sheet(app)
    if _sbx.tree and _sbx.mtime == mtime and _sbx.sheet_id == theme_sheet then
        -- Binds are live state, not file content: re-resolve on every hit so
        -- a toggle flipped last paint reads the new value (the tree cache
        -- would otherwise freeze toggle_value at first-parse time).
        resolve_binds(_sbx.tree, app, _sbx.errors)
        return _sbx.tree, _sbx.merged, _sbx.errors
    end
    local errors = {}
    local f = io.open(path, "r")
    local html = f and f:read("*a")
    if f then f:close() end
    local tree, merged
    if not html then
        errors[#errors + 1] = "sandbox.html not found: " .. tostring(path)
        tree = UiDSL.node({ tag = "box", children = {} })
        merged = theme_sheet
    else
        local inline_css, html_errors
        tree, inline_css, html_errors = UiDSL.from_html(html, actions, vars)
        for _, e in ipairs(html_errors or {}) do
            errors[#errors + 1] = e
        end
        local inline_sheet = UiDSL.parse(inline_css or "")
        for _, e in ipairs(UiDSL.validate_sheet(inline_sheet)) do
            errors[#errors + 1] = e
        end
        merged = UiDSL.merge_sheets(theme_sheet, inline_sheet)
        tree = UiDSL.apply_styles(tree, merged)
        resolve_binds(tree, app, errors)
    end
    _sbx = { mtime = mtime, sheet_id = theme_sheet, tree = tree,
        merged = merged, errors = errors }
    return tree, merged, errors
end

-- ======================================================== demo page (css_test) ===

-- Palette + node styling for the built-in sandbox look.
UiDSL.DEMO_CSS = [[
/* KOTavern sandbox theme - edit anything, hit Reload, see it live. */
/* Palette layer (feeds Theme). */
page {
  background: gray(0.04);
  color: #111111;
  panel-color: #ffffff;
  soft-color: gray(0.25);
  border-color: gray(0.2);
  muted-color: gray(0.45);
  radius: 6px;
}
/* Node layer (decorates the converted HTML nodes). */
.hero { background: gray(0.10); radius: 10px; pad: 12px; gap: 6px; }
.card { border: true; border-size: 1px; border-color: gray(0.35); background: gray(0); radius: 8px; pad: 10px; gap: 6px; }
.muted { color: gray(0.45); }
.center { text-align: center; }
.right { text-align: right; }
.btn { border: true; border-size: 2px; border-color: gray(0.10); background: gray(0); radius: 21px; pad: 8px; min-h: 44px; text-align: center; }
]]

-- The sandbox document: a real HTML string, converted to nodes and decorated
-- by the stylesheet. Body text is written directly (debug page, pt-BR by
-- the author's request; it is NOT routed through gettext).
UiDSL.DEMO_HTML = [[
<div class="hero">
  <h1>KOTavern: HTML + CSS → canvas</h1>
  <p class="muted">Esta página inteira é uma string HTML convertida em nós e pintada pelo canvas UI (primitivas P.*). O canvas continua desenhando tudo; o HTML/CSS só descreve o que deve ser desenhado.</p>
</div>
<div class="card">
  <h2>Card A - parágrafos</h2>
  <p>Um parágrafo maior para mostrar o box model medindo as linhas quebradas antes de pintá-las no blitbuffer, sem clipping, só ordem de pintura.</p>
</div>
<div class="card">
  <h2>Card B - alinhamento</h2>
  <p class="center">texto centralizado</p>
  <p class="right muted">texto à direita</p>
</div>
<div class="card">
  <h2>Card C - imagem</h2>
  <img src="{{shot}}" data-h="60px"/>
  <p class="muted">O botão Captura grava a tela atual nessa mesma pasta.</p>
</div>
<div class="btn" data-action="reload"><span>Recarregar CSS</span></div>
<div class="btn" data-action="shot"><span>Capturar tela</span></div>
<p class="center muted">Debug Mode - ktui/uidsl.lua</p>
]]

-- Build the sandbox tree: DEMO_HTML -> nodes -> styled by the sheet.
function UiDSL.demo_page(sheet, actions)
    local Storage = require("kt_storage")
    local shot = Storage.data_dir() .. "/kotavern_css_test.png"
    local html = UiDSL.DEMO_HTML:gsub("{{shot}}", shot)
    local tree = UiDSL.from_html(html, actions or {})
    return UiDSL.apply_styles(tree, sheet)
end

-- ======================================================== sandbox skeleton ===
-- SKELETON_HTML is written to themes/pages/sandbox.html on demand (never
-- overwritten: the file is user-owned). It exercises the WHOLE DSL surface
-- in one screen: every tag, attribute, property, color form and the error
-- path. Comments (<!-- -->) document the surface - this file is the living
-- reference. pt-BR (debug page, NOT routed through gettext).

UiDSL.SKELETON_HTML = [[
<style>
/* Paleta (alimenta o Theme por baixo do sandbox). */
page {
  background: gray(0.04);
  color: #111111;
  panel-color: #ffffff;
  soft-color: gray(0.25);
  border-color: gray(0.2);
  muted-color: gray(0.45);
  radius: 6px;
}
/* Nos: tag, .classe, #id, listas, combinacao tag.classe */
.hero { background: gray(0.10); radius: 10px; pad: 12px; gap: 6px; }
.card { border: true; border-size: 1px; border-color: gray(0.35); background: gray(0); radius: 8px; pad: 10px; gap: 6px; }
.fila { gap: 8px; vertical-align: center; }
.base { vertical-align: bottom; }
value { text-align: center; }
.metade { width: 50%; }
.muted { color: gray(0.45); }
.center { text-align: center; }
.right { text-align: right; }
.btn { border: true; border-size: 2px; border-color: gray(0.10); background: gray(0); radius: 21px; pad: 8px; min-h: 44px; text-align: center; }
/* Cores: #rgb #rrggbb rgb() gray() % e NOMES DO TEMA: primary muted border panel soft bg danger */
.tinta { color: rgb(180, 30, 30); font-size: 20px; }
.miolo, #unico { color: gray(0.3); }
.hr { background: primary; h: 2px; margin: 4px; }
.imgredonda { radius: 14px; }
</style>
<div class="hero">
  <h1>HTML + CSS no canvas</h1>
  <p class="muted">Este arquivo e themes/pages/sandbox.html - edite, salve, Reload. Tags: div row p span h1 h2 h3 img br hr icon toggle avatar button value input. Entidades: &amp; &lt; &gt; &quot;.</p>
</div>
<div class="card">
  <h2>Tipografia</h2>
  <h3>h3 pequeno e bold</h3>
  <p>Paragrafo com <b>negrito inline vira texto</b> e continua.</p>
  <p><span class="tinta">span com cor e fonte 20px</span></p>
  <p id="unico" class="miolo">seletor #id + classe combinados</p>
</div>
<div class="card">
  <h2>Alinhamento (p e span)</h2>
  <p class="center">paragrafo centralizado</p>
  <p class="right muted">paragrafo a direita</p>
  <span class="center">span centralizado</span>
</div>
<div class="card">
  <h2>Imagem (sonic em tamanhos)</h2>
  <row class="fila base">
    <img src="{{sonic_frames}}" data-anim="true" data-h="24px"/>
    <img src="{{sonic_frames}}" data-anim="true" data-h="32px"/>
    <img src="{{sonic_frames}}" data-anim="true" data-h="48px"/>
    <img src="{{sonic_frames}}" data-anim="true" data-h="64px"/>
    <img src="{{sonic_frames}}" data-anim="true" data-h="80px"/>
  </row>
  <p class="muted">5 Sonics animados lado a lado (~8fps, base alinhada). Cada um e 1 timer com refresh so no retangulo.</p>
  <img src="{{sonic}}" data-h="120px" data-fit="cover"/>
  <p class="muted">Cover preenche a caixa e corta de proposito (compare com o contain acima).</p>
  <img src="{{sonic}}" data-h="64px" data-fit="cover" class="imgredonda"/>
  <p class="muted">radius (CSS ou data-radius) arredonda os cantos da imagem.</p>
  <img src="/caminho/que/nao/existe.png" data-h="60px" alt="foto do usuario"/>
  <p class="muted">Ausente = icone de imagem quebrada + texto do alt (como no HTML).</p>
</div>
<div class="card">
  <h2>Linha horizontal (row + width + flex)</h2>
  <row class="fila">
    <div class="metade"><p class="center muted">50% fixa</p></div>
    <div><p class="center muted">flex divide o resto</p></div>
  </row>
  <row class="fila">
    <icon name="search" size="20"/>
    <p>icone + texto lado a lado, centralizados</p>
  </row>
</div>
<div class="card">
  <h2>Componentes nativos</h2>
  <button kind="primary" icon="camera" data-action="shot">Capturar tela</button>
  <button kind="secondary" icon="refresh" data-action="reload">Recarregar</button>
  <row class="fila">
    <toggle data-bind="settings.debug_mode"/>
    <p class="muted">liga/desliga settings.debug_mode (data-bind)</p>
  </row>
  <row class="fila">
    <avatar name="Luna" size="48"/>
    <p class="muted">avatar com inicial (sem foto = disco + letra)</p>
  </row>
</div>
<div class="card">
  <h2>Playground (estado vivo)</h2>
  <button data-bind="sandbox.ligado">Lampada (troca de cor no toque)</button>
  <p class="muted">O botao acima liga/desliga sandbox.ligado: apagado = contorno, aceso = solido.</p>
  <row class="fila">
    <button data-bind="sandbox.conta" data-step="-1" data-min="0">-1</button>
    <value data-bind="sandbox.conta"/>
    <button data-bind="sandbox.conta" data-step="1" data-max="9">+1</button>
  </row>
  <p class="muted">Contador com trava 0..9 (data-step + data-min + data-max).</p>
  <row class="fila">
    <button data-bind="sandbox.pos" data-step="-1" data-min="0">esq</button>
    <button data-bind="sandbox.pos" data-step="1" data-max="8">dir</button>
  </row>
  <row class="fila">
    <spacer data-bind-width="sandbox.pos"/>
    <icon name="star" size="20"/>
  </row>
  <p class="muted">esq/dir movem a estrela (largura = pos x 24px). E-ink nao anima: cada toque e um redesenho.</p>
</div>
<div class="card">
  <h2>Entrada de texto (input + value)</h2>
  <input data-bind="sandbox.nome" title="Seu nome" placeholder="digite seu nome"/>
  <p class="muted">Voce digitou:</p>
  <value data-bind="sandbox.nome" data-empty="(nada ainda)"/>
  <p class="muted">Toque no campo para abrir o teclado; o value ecoa na hora.</p>
</div>
<hr/>
<div class="card">
  <h2>Progresso (barra viva)</h2>
  <progress data-bind="sandbox.conta" data-max="9"/>
  <p class="muted">A barra acompanha o contador la em cima (0..9): data-max re-escala para 0..100%.</p>
</div>
<div class="card">
  <h2>Acoes (data-action + data-id)</h2>
  <div class="btn" data-action="reload"><span>Recarregar</span></div>
  <div class="btn" data-action="shot" data-id="capa"><span>Capturar tela</span></div>
</div>
<hr/>
<p class="center muted">sandbox.html - poder maximo do DSL</p>
]]

return UiDSL
