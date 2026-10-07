-- UI DSL engine (experimental, Debug Mode): CSS-like themes + declarative
-- layout for canvas UI.
--
-- Public surface (all guarded, never throws to the paint path):
--   UiDSL.parse(css_text)               -> { rules = {...}, errors = {...} }
--   UiDSL.style_for(sheet, tag, attrs)  -> merged, validated declarations
--   UiDSL.theme_overrides(sheet, tag)   -> palette overrides { bg=..., ... }, errors
--   UiDSL.load_theme_file(path)         -> ok, sheet, errors, nprops
--   UiDSL.theme_css_path(name)          -> path or nil
--   UiDSL.list_theme_files()            -> { { name, path, mtime }, ... }
--   UiDSL.apply_theme_to_app(app)       -> overlays settings.debug_theme_css
--                                           on the live Theme palette
--   UiDSL.node / UiDSL.measure / UiDSL.paint -> declarative layout nodes
--   UiDSL.demo_page()                   -> the css_test sandbox node tree
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
    table.sort(rules, function(a, b)
        if a.spec ~= b.spec then
            return a.spec < b.spec
        end
        return (a.seq or 0) < (b.seq or 0)
    end)
    return { rules = rules, errors = {} }
end

-- ===================================================== values + validators ===

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
-- Node spec fields: tag ("box"|"text"|"para"|"image"|"spacer"), id, classes,
-- text, src, w/h/min_h (CSS lengths or px), pad, gap, fill_h, bg, color,
-- radius, border, border_size, bold, role, align. Children flow in a column.

local function node_inset(n)
    return (n.pad or 0) * 2
end

local function text_role(n)
    return n.role or "default"
end

-- Options shared by measure and paint for text/para nodes: bold, color and
-- an optional CSS font-size face (Theme.face is a fixed role ladder; an
-- explicit px size builds its own face so authors can tune text freely).
local function text_opts(n)
    local opts = { bold = n.bold, color = n.color }
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

local function children_h(node, w)
    local total = 0
    local inner_w = w - node_inset(node)
    for i, child in ipairs(node.children or {}) do
        if i > 1 then total = total + (node.gap or 0) end
        total = total + UiDSL.measure(child, inner_w)
    end
    return total
end

-- Height of a node under width w.
function UiDSL.measure(node, w)
    if node._h_cache and node._h_w == w then return node._h_cache end
    local h
    if node.tag == "text" then
        h = P.text_size(node.text or "", px(node.w, w), text_role(node), text_opts(node)).h
    elseif node.tag == "para" then
        local lines, line_h = P.paragraph_metrics(node.text or "", px(node.w, w), text_role(node), text_opts(node))
        h = lines * line_h
    elseif node.tag == "image" then
        h = px(node.h, Theme.scale(80))
    elseif node.tag == "spacer" then
        h = px(node.h, Theme.scale(12))
    else -- box
        local inner = children_h(node, w)
        h = inner > 0 and inner or px(node.h, 0)
        if node.fill_h then h = math.max(h, node.fill_h) end
    end
    h = h + node_inset(node)
    if node.min_h then h = math.max(h, px(node.min_h, 0)) end
    node._h_cache, node._h_w = h, w
    return h
end

-- Paint a node at (x, y) spanning width w (column flow). When view is given,
-- nodes carrying on_tap register their hitboxes (reverse order: children
-- first, so nested interactive boxes behave like the rest of the app).
function UiDSL.paint(node, bb, x, y, w, view)
    local pad = node.pad or 0
    local h = UiDSL.measure(node, w)
    local bg = node.bg
    if node.border then
        P.box(bb, x, y, w, h, {
            border = true, border_size = node.border_size or 1,
            border_color = node.border_color or Theme.border,
            background = bg or Theme.panel,
            radius = node.radius, -- nil = Theme default; false = square
        })
    elseif bg then
        P.rounded_rect(bb, x, y, w, h, bg, node.radius)
    end
    local cx = x + pad
    local cy = y + pad
    local inner_w = w - pad * 2
    if node.tag == "text" then
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
        P.paragraph(bb, node.text or "", cx, cy, inner_w, h - node_inset(node),
            text_role(node), text_opts(node))
    elseif node.tag == "image" then
        if node.src then
            P.image(bb, node.src, cx, cy, inner_w, h - node_inset(node), { cover = node.cover })
            if view then
                -- Bitmap content: hint the next refresh for hardware dithering.
                view.dithered = true
            end
        end
    elseif node.tag == "spacer" then
        -- nothing to paint
    else
        for _i, child in ipairs(node.children or {}) do
            UiDSL.paint(child, bb, cx, cy, inner_w, view)
            cy = cy + UiDSL.measure(child, inner_w) + (node.gap or 0)
        end
    end
    if view and node.on_tap then
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
-- Supported: div (box), p (paragraph), span/h1/h2/h3 (text), img (image),
-- br/hr (spacer). Unknown tags become transparent boxes. Attributes:
-- class, id, src (img), data-h (img height), data-action (tap callback from
-- the actions map). Double-quoted attributes only; &amp; &lt; &gt; &quot;
-- entities. {{name}} placeholders are substituted from the vars map BEFORE
-- parsing (e.g. {{shot}} -> screenshot path).
local HTML_ENTITIES = {
    ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">", ["&quot;"] = '"',
    ["&apos;"] = "'", ["&nbsp;"] = " ",
}

local function decode_entities(str)
    return (str:gsub("&([%w]+);", function(name)
        return HTML_ENTITIES["&" .. name .. ";"] or "&" .. name .. ";"
    end))
end

function UiDSL.from_html(html, actions, vars)
    actions = actions or {}
    vars = vars or {}
    html = tostring(html or ""):gsub("{{([%w_]+)}}", function(name)
        return tostring(vars[name] or "")
    end)
    html = html:gsub("<%-%-.-%%-%->", " ") -- comments

    local root = UiDSL.node({ tag = "box", children = {}, html_tag = "body" })
    local stack = { root }
    local function top() return stack[#stack] end

    local VOID = { img = true, br = true, hr = true }
    local TEXT_HOST = { p = true, span = true, h1 = true, h2 = true, h3 = true }

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
            n = UiDSL.node({ tag = "image", src = attrs.src,
                h = attrs["data-h"] or "60px", cover = attrs["data-cover"] == "true" })
        elseif name == "p" then
            n = UiDSL.node({ tag = "para" })
        elseif name == "br" then
            n = UiDSL.node({ tag = "spacer", h = "4px" })
        elseif name == "hr" then
            n = UiDSL.node({ tag = "spacer", h = "10px" })
        elseif name == "h1" then
            n = UiDSL.node({ tag = "text", role = "title", bold = true })
        elseif name == "h2" then
            n = UiDSL.node({ tag = "text", role = "heading", bold = true })
        elseif name == "h3" then
            n = UiDSL.node({ tag = "text", role = "small", bold = true })
        elseif name == "span" then
            n = UiDSL.node({ tag = "text" })
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
        if attrs["data-action"] and actions[attrs["data-action"]] then
            n.on_tap = actions[attrs["data-action"]]
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
            -- Consume the close of an inline tag we merged into a text host
            -- (it was never pushed onto the stack).
            if #skipped_inline > 0 and skipped_inline[#skipped_inline] == name
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
                open(name, attrs, selfclose)
            end
        end
    end
    return root
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

-- ======================================================== demo page (css_test) ===

-- Palette + node styling for the built-in sandbox look.
UiDSL.DEMO_CSS = [[
/* KOTavern sandbox theme - edit anything, hit Reload, see it live. */
/* Palette layer (feeds Theme). */
page {
  background: gray(0.04);
  color: #111111;
  panel-color: #ffffff;
  soft-color: gray(0.85);
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

return UiDSL
