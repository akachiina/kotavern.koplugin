-- KtHTML: literal HTML+CSS pages rendered by MuPDF (separate sandbox).
--
-- The uidsl node engine stays untouched as the experimental file; this
-- module hosts REAL html/css documents through KOReader's own pipeline:
-- HtmlBoxWidget (ffi/mupdf story API) renders, we handle geometry (two
-- scroll modes), taps (own hitbox -> getLinkByPosition, never the global
-- tap_to_follow_links switch) and lifecycle (free on navigate).
--
-- Public surface (all guarded, never throws to the paint path):
--   KtHTML.theme_css()                 -> CSS string generated from Theme
--   KtHTML.render_body(template, app)  -> state-templated HTML
--   KtHTML.page_path(name)             -> themes/pages/<name> path
--   KtHTML.page_exists(name)           -> bool (never writes)
--   KtHTML.install_sandbox(force)      -> ok, errcode (never overwrites
--                                         unless force; user-owned file)
--   KtHTML.prepare(app, page, actions)  -> src {body, css, mtime}, errors
--                                      (string-level only: lint before layout)
--   KtHTML.ensure(app, view, page, src, w, h, opts)
--                                      -> doc (cached by file mtime + theme
--                                         + mode; opts.paginated)
--   KtHTML.current(app, page)          -> cached doc or nil
--   KtHTML.paint_window(doc, bb, x, y, w, h, scroll)
--                                      -> paints the visible window
--   KtHTML.paint_anims(doc, bb, bx, by, w, h, pageno)
--                                      -> overlays current anim frames
--   KtHTML.check_anim(name) / anim_dir(name) / prune_anim_players(...)
--                                      -> animation plumbing
--   KtHTML.tap(doc, app, page, actions, lx, ly)
--                                      -> true when a kt: link consumed it
--   KtHTML.invalidate(app, page)       -> drop the cached doc
--   KtHTML.free_all(app)               -> free every cached doc
--
-- State templates in the HTML (substituted per render from app.state):
--   {{s:path}}         -> html-escaped tostring(value)
--   {{c:path:class}}    -> class when the value is truthy, else ""
--   {{px:path:mult}}    -> floor(number * mult) .. "px" (margins/widths)
--   {{e:path:fallback}} -> escaped value, or fallback when nil/""
--   {{t:path:a|b}}      -> escaped a when truthy, else escaped b (split on
--                          the FIRST |; texts may hold colons, not } or |)
--
-- Link scheme (tap -> action -> full re-render, the e-ink way):
--   kt:nav:PAGE        -> app:navigate(PAGE)
--   kt:back            -> app:go_back()
--   kt:toggle:PATH     -> settings.* via App:toggle_setting (saved),
--                         anything else flips in memory + refresh
--   kt:input:PATH      -> Modals.input dialog, saves back, refreshes
--   kt:action:NAME[:ID]-> actions[NAME](ID); unknown names are visible
--                         errors, never silent dead taps
--   kt:anim:NAME       -> animated sprite overlay (GifAnim over the MuPDF
--                         bitmap, rect from the link box; tap consumes and
--                         does nothing by design). NAME is a bare frames
--                         subdir of assets/ (pre-composited full frames).
-- No press flash by design: every tap already ends in a full refresh, and
-- the app's native buttons don't flash either (extra flashes = ghosting).
--
-- Scroll modes: tall bitmap + pixel scroll (default, reuses Scroll as-is)
-- or pagination (layout at viewport height, scroll quantizes to pages).
-- Tall mode auto-falls-back to pagination when the doc paginates.

local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local HtmlBoxWidget = require("ui/widget/htmlboxwidget")
local Theme = require("ktui/theme")

local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
if not lfs_ok or not lfs then
    local ok2, lfs2 = pcall(require, "lfs")
    lfs = ok2 and lfs2 or nil
end

local KtHTML = {}

-- Tall-bitmap cap (w x TALL_H x 1 byte). Past this the doc paginates and
-- tall mode auto-falls-back to pagination for that paint.
KtHTML.TALL_H = 10000

-- Content height of a laid-out body: smallest layout height that still fits
-- on one page (bisection, 32px precision). One-time cost per file/theme
-- change (the result rides the doc cache); each probe is a throwaway
-- layout that is freed immediately.
function KtHTML.measure_content(src, w)
    local Constants = require("kt_constants")
    local probe = HtmlBoxWidget:new{ dimen = Geom:new{ w = w, h = 64 } }
    local function pages_at(h)
        local n = 99
        pcall(function()
            probe.dimen = Geom:new{ w = w, h = h }
            probe:setContent(src.body, src.css,
                Theme.scale(Theme.get_base_font_size()),
                false, nil, Constants.PLUGIN_DIR .. "/assets")
            n = probe.page_count or 99
        end)
        return n
    end
    local total = nil
    if pages_at(KtHTML.TALL_H) == 1 then
        local lo, hi = 1, KtHTML.TALL_H
        if pages_at(lo) == 1 then
            total = lo -- empty doc, nothing to scroll
        else
            while hi - lo > 32 do
                local mid = math.floor((lo + hi) / 2)
                if pages_at(mid) > 1 then
                    lo = mid
                else
                    hi = mid
                end
            end
            total = hi
        end
    end
    pcall(function() probe:free() end)
    return total
end

-- Blitbuffer color -> #rrggbb. NEVER compare colors to nil with ~= : LuaJIT
-- routes even `cdata ~= nil` through __eq and crashes ("attempt to index
-- local 'color'"). type() never triggers metamethods (same guard as icons).
function KtHTML.css_hex(color, fallback)
    if type(color) == "cdata" then
        local ok, r, g, b = pcall(function()
            return color:getR(), color:getG(), color:getB()
        end)
        if ok and r and g and b then
            return string.format("#%02x%02x%02x",
                math.max(0, math.min(255, r)),
                math.max(0, math.min(255, g)),
                math.max(0, math.min(255, b)))
        end
    end
    return fallback or "#000000"
end

-- Base stylesheet generated from the live Theme (string.format = our
-- "variables": no var() needed, MuPDF wouldn't have it anyway). The file's
-- own <style> block is appended AFTER this, so author rules win ties.
function KtHTML.theme_css()
    local font_px = Theme.scale(Theme.get_base_font_size())
    local css = string.format([[
body { margin: 0; background: %s; color: %s; }
h1 { font-size: %dpx; font-weight: bold; margin: 0 0 6px 0; }
h2 { font-size: %dpx; font: bold; margin: 0 0 4px 0; }
p { margin: 0 0 6px 0; }
a { color: %s; text-decoration: none; }
.card { border: 1px solid %s; background: %s; padding: 10px; margin: 0 0 10px 0; }
.hero { background: %s; padding: 12px; margin: 0 0 10px 0; }
.muted { color: %s; }
.center { text-align: center; }
.right { text-align: right; }
.pill { display: inline-block; border: 1px solid %s; padding: 8px 14px; margin: 0 4px 6px 0; }
.pill.primary { background: %s; color: %s; }
table.fila { width: 100%%; margin: 0 0 6px 0; }
table.fila td { vertical-align: middle; padding: 2px 6px 2px 0; }
code { background: %s; padding: 0 4px; }
pre { background: %s; padding: 8px; }
hr { border: none; border-top: 1px solid %s; margin: 8px 0; }
img { vertical-align: middle; }
]],
        KtHTML.css_hex(Theme.bg, "#ffffff"),
        KtHTML.css_hex(Theme.ink, "#000000"),
        font_px + 5, font_px + 2,
        KtHTML.css_hex(Theme.ink, "#000000"),
        KtHTML.css_hex(Theme.border, "#000000"),
        KtHTML.css_hex(Theme.panel, "#ffffff"),
        KtHTML.css_hex(Theme.soft, "#cccccc"),
        KtHTML.css_hex(Theme.muted, "#666666"),
        KtHTML.css_hex(Theme.muted, "#666666"),
        KtHTML.css_hex(Theme.button_bg, "#000000"),
        KtHTML.css_hex(Theme.button_text, "#ffffff"),
        KtHTML.css_hex(Theme.soft, "#cccccc"),
        KtHTML.css_hex(Theme.soft, "#cccccc"),
        KtHTML.css_hex(Theme.soft, "#cccccc"))
    -- Component library (buttons, fields, switches, chips, segmented,
    -- progress, avatars). Pure CSS over <a>/div/span/table + kt: links; the
    -- engine never changes for these. Device-verify list: border-radius,
    -- SVG <img>, table fidelity (each marked in the sandbox demos).
    css = css .. string.format([[
.pill.secondary { background: %s; color: %s; }
.pill.ghost { border: none; background: %s; }
.pill.on { background: %s; color: %s; }
.nonlink { color: %s; border-color: %s; }
a.field { display: block; border: 1px solid %s; background: %s; color: %s; padding: 8px 10px; margin: 0 0 6px 0; }
.field .hint { color: %s; }
.switchstate { font-weight: bold; }
.chip { display: inline-block; border: 1px solid %s; color: %s; font-size: 85%%; padding: 2px 8px; margin: 0 4px 4px 0; }
table.seg { width: 100%%; border: 1px solid %s; margin: 0 0 6px 0; }
table.seg td { text-align: center; padding: 8px 4px; }
table.seg td.on { background: %s; color: %s; }
.pbar { border: 1px solid %s; padding: 2px; margin: 0 0 6px 0; }
.pfill { background: %s; height: 10px; }
img.avatar { width: 48px; height: 48px; }
.round { border-radius: 50%%; }
]],
        KtHTML.css_hex(Theme.panel, "#ffffff"),
        KtHTML.css_hex(Theme.ink, "#000000"),
        KtHTML.css_hex(Theme.bg, "#ffffff"),
        KtHTML.css_hex(Theme.button_bg, "#000000"),
        KtHTML.css_hex(Theme.button_text, "#ffffff"),
        KtHTML.css_hex(Theme.muted, "#666666"),
        KtHTML.css_hex(Theme.soft, "#cccccc"),
        KtHTML.css_hex(Theme.muted, "#666666"),
        KtHTML.css_hex(Theme.panel, "#ffffff"),
        KtHTML.css_hex(Theme.ink, "#000000"),
        KtHTML.css_hex(Theme.muted, "#666666"),
        KtHTML.css_hex(Theme.soft, "#cccccc"),
        KtHTML.css_hex(Theme.muted, "#666666"),
        KtHTML.css_hex(Theme.muted, "#666666"),
        KtHTML.css_hex(Theme.button_bg, "#000000"),
        KtHTML.css_hex(Theme.button_text, "#ffffff"),
        KtHTML.css_hex(Theme.muted, "#666666"),
        KtHTML.css_hex(Theme.ink, "#000000"))
    return css
end

-- <style> blocks are extracted (concatenated) and never rendered as nodes;
-- <script> blocks are discarded so code can't leak onto the page as text.
function KtHTML.extract_style(html)
    local styles = {}
    local function strip(tag, keep)
        local open_p = "<%s*" .. tag .. "[^>]*>"
        local close_p = "<%s*/%s*" .. tag .. "%s*>"
        return (html:gsub(open_p .. "([%s%S]-)" .. close_p, function(body)
            if keep then table.insert(styles, body) end
            return " "
        end))
    end
    html = strip("[sS][tT][yY][lL][eE]", true)
    html = strip("[sS][cC][rR][iI][pP][tT]", false)
    return html, table.concat(styles, "\n")
end

local function html_escape(s)
    return tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;")
        :gsub(">", "&gt;"):gsub('"', "&quot;")
end

-- Dotted path read from app.state (no creation on read).
local function state_lookup(app, path)
    if not path or path == "" then return nil end
    local t = app and app.state
    if type(t) ~= "table" then return nil end
    for seg in tostring(path):gmatch("[^%.]+") do
        if type(t) ~= "table" then return nil end
        t = t[seg]
    end
    return t
end

-- Dotted path write, creating intermediate tables (fresh sandbox.* paths
-- materialize on first tap/save instead of vanishing silently).
local function state_ensure(app, path)
    local t = app and app.state
    if type(t) ~= "table" or not path or path == "" then return nil, nil end
    local parent, key = nil, nil
    for seg in tostring(path):gmatch("[^%.]+") do
        if type(t) ~= "table" then return nil, nil end
        parent, key = t, seg
        if t[seg] == nil then t[seg] = {} end
        t = t[seg]
    end
    return parent, key
end

-- Substitute {{s:}}, {{c:}}, {{px:}} templates from live app.state.
function KtHTML.render_body(template, app)
    template = tostring(template or "")
    template = template:gsub("{{px:([^}:]+):([^}:]+)}}", function(path, mult)
        local n = tonumber(state_lookup(app, path)) or 0
        return math.floor(n * (tonumber(mult) or 1)) .. "px"
    end)
    template = template:gsub("{{c:([^}:]+):([^}:]+)}}", function(path, cls)
        if state_lookup(app, path) then return cls end
        return ""
    end)
    template = template:gsub("{{e:([^}:]+):([^}]*)}}", function(path, fb)
        -- Hint semantics (mirrors uidsl value's data-empty): fallback shows
        -- ONLY when the value is missing, so <span>{{s:p}}</span><span
        -- class="hint">{{e:p:hint}}</span> never doubles the text.
        local v = state_lookup(app, path)
        if v == nil or v == "" then return fb end
        return ""
    end)
    template = template:gsub("{{t:([^}:]+):([^}]*)}}", function(path, rest)
        local a, b = rest:match("^([^|]*)|(.*)$")
        if a == nil then a, b = rest, "" end
        if state_lookup(app, path) then return html_escape(a) end
        return html_escape(b)
    end)
    template = template:gsub("{{s:([^}:]+)}}", function(path)
        local v = state_lookup(app, path)
        if v == nil then return "" end
        return html_escape(v)
    end)
    return template
end

function KtHTML.page_path(name)
    local Storage = require("kt_storage")
    if not name or name == "" then return nil end
    if not name:match("%.html$") then name = name .. ".html" end
    if name:find("/", 1, true) or name:find("\\", 1, true) then return nil end
    return Storage.data_dir() .. "/themes/pages/" .. name
end

function KtHTML.page_exists(name)
    local path = KtHTML.page_path(name)
    if not path then return false end
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

function KtHTML.mtime(path)
    if lfs and path then
        local ok, a = pcall(lfs.attributes, path, "modification")
        if ok then return a end
    end
    return nil
end

-- Write the skeleton file. Never overwrites unless force=true (user-owned).
function KtHTML.install_sandbox(force)
    local path = KtHTML.page_path("html_sandbox.html")
    if not force and KtHTML.page_exists("html_sandbox.html") then
        return false, "exists"
    end
    local dir = path:match("^(.*)/[^/]+$")
    local parent = dir and dir:match("^(.*)/[^/]+$")
    pcall(function()
        if lfs and lfs.mkdir then
            if parent then lfs.mkdir(parent) end
            lfs.mkdir(dir)
        end
    end)
    local f = io.open(path, "w")
    if not f then return false, "write" end
    f:write(KtHTML.HTML_SKELETON)
    f:close()
    return true, path
end

-- Read + template + lint a page WITHOUT laying out (string-level only, so
-- the caller can reserve the error strip before choosing the layout
-- viewport). Returns src { body, css, mtime } plus errors, or nil + errors.
function KtHTML.prepare(app, page, actions)
    local path = KtHTML.page_path(page)
    if not path then
        return nil, { "bad page name: " .. tostring(page) }
    end
    local f = io.open(path, "r")
    local raw = f and f:read("*a")
    if f then f:close() end
    if not raw then
        return nil, { "page not found: " .. tostring(path) }
    end
    local errors = {}
    local stripped, inline_css = KtHTML.extract_style(raw)
    local body = KtHTML.render_body(stripped, app)
    -- Lint hrefs up front: unknown kt: actions/schemes surface here (MuPDF
    -- itself stays silent on everything, by design of this sandbox).
    for uri in body:gmatch('href%s*=%s*"([^"]+)"') do
        if uri:find("^kt:", 1) then
            local scheme, rest = uri:match("^kt:([^:]+):?(.*)$")
            if scheme == "action" then
                local aname = (rest or ""):match("^([^:]+)")
                if not aname or aname == "" or not (actions or {})[aname] then
                    errors[#errors + 1] = "unknown action: "
                        .. tostring(aname ~= "" and aname or rest)
                end
            elseif scheme == "anim" then
                local anerr = KtHTML.check_anim(rest)
                if anerr then errors[#errors + 1] = anerr end
            elseif scheme == "btn" then
                -- Validated at ensure/paint time (the anchor becomes a
                -- native canvas pill; unknown names just sit there dead).
            elseif scheme ~= "nav" and scheme ~= "back"
                and scheme ~= "toggle" and scheme ~= "input" then
                errors[#errors + 1] = "unknown link: " .. tostring(uri)
            end
        end
    end
    return {
        body = body,
        css = KtHTML.theme_css() .. "\n" .. (inline_css or ""),
        mtime = KtHTML.mtime(path),
    }, errors
end

-- Validate an animation name (kt:anim:NAME): a bare subdirectory of assets/
-- holding 2+ frame PNGs. Returns an error string or nil. The raw .gif is
-- never used: KOReader's giflib misdecodes delta frames (frame 0 + white
-- boxes), so animations ship as pre-composited full frames (see
-- tools/gen_debug_banner.py + ktui/gifanim.lua).
function KtHTML.check_anim(name)
    if not name or name == "" or name:find("[/\\]", 1) then
        return "bad anim name: " .. tostring(name)
    end
    if not name:match("^[%w_%-]+$") then
        return "bad anim name: " .. tostring(name)
    end
    local Constants = require("kt_constants")
    local dir = Constants.PLUGIN_DIR .. "/assets/" .. name
    local pngs = 0
    if lfs then
        pcall(function()
            for entry in lfs.dir(dir) do
                if entry:sub(-4):lower() == ".png" then
                    pngs = pngs + 1
                end
            end
        end)
    end
    if pngs < 2 then
        return "anim without frames: " .. tostring(name)
    end
    return nil
end

function KtHTML.anim_dir(name)
    local Constants = require("kt_constants")
    return Constants.PLUGIN_DIR .. "/assets/" .. tostring(name)
end

-- Build (or reuse) the MuPDF doc for prepared source. Returns doc where doc
-- is { widget, total_h, page_count, paginated, viewport_h, anims }. Cached
-- by file mtime + theme + mode; tall mode falls back to pagination when
-- MuPDF paginates the tall layout.
function KtHTML.ensure(app, view, page, src, w, h, opts)
    opts = opts or {}
    if not src then return nil end
    local theme_id = Theme.get_theme() .. "|" .. tostring(Theme.get_base_font_size())
    local want_paginated = opts.paginated and true or false
    local key = page .. "\0" .. tostring(src.mtime) .. "\0" .. theme_id
        .. "\0" .. (want_paginated and "p" or "t")
    app.state.kthtml_docs = app.state.kthtml_docs or {}
    local cached = app.state.kthtml_docs[page]
    if cached and cached.key == key and cached.widget then
        return cached
    end
    if cached then KtHTML.free_doc(cached) end
    local Constants = require("kt_constants")
    local widget = HtmlBoxWidget:new{
        dimen = Geom:new{ w = w, h = h },
    }
    local ok = pcall(function()
        widget:setContent(src.body, src.css,
            Theme.scale(Theme.get_base_font_size()),
            false, nil, Constants.PLUGIN_DIR .. "/assets")
    end)
    if not ok or not widget.document then
        pcall(function() widget:free() end)
        return nil
    end
    local doc = {
        key = key, widget = widget, viewport_h = h,
        page_count = widget.page_count or 1, paginated = want_paginated,
        view_app = app, view = view,
    }
    if not want_paginated then
        -- Tall bitmap: relayout at cap height. Content height is found by
        -- bisecting the 1-page/2-pages boundary (getUsedBBox reports the
        -- full page for HTML, and text-only measuring would miss trailing
        -- images). Past the cap = fall back to pagination for this cycle.
        local pages_at_cap = 1
        pcall(function()
            widget.dimen = Geom:new{ w = w, h = KtHTML.TALL_H }
            widget:setContent(src.body, src.css,
                Theme.scale(Theme.get_base_font_size()),
                false, nil, Constants.PLUGIN_DIR .. "/assets")
            pages_at_cap = widget.page_count or 1
        end)
        doc.page_count = pages_at_cap
        if pages_at_cap > 1 then
            doc.paginated = true
            pcall(function()
                widget.dimen = Geom:new{ w = w, h = h }
                widget:setContent(src.body, src.css,
                    Theme.scale(Theme.get_base_font_size()),
                    false, nil, Constants.PLUGIN_DIR .. "/assets")
            end)
            doc.page_count = widget.page_count or 1
            doc.total_h = h
        else
            doc.total_h = KtHTML.measure_content(src, w) or h
        end
    else
        doc.total_h = h
    end
    -- Animation rects come from the LINK boxes (kt:anim:NAME wraps the
    -- static <img>): getPageLinks is per laid-out page, so rects are
    -- page-local and paint offsets them by scroll (tall) or page (paged).
    -- Keys are stable across rebuilds (page:name:index), so players are
    -- reused instead of leaking timers.
    -- Two MuPDF quirks handled here, both measured against the real engine:
    -- image-only anchors collapse to zero-width boxes, and one anchor may
    -- surface several overlapping entries. So anchors REQUIRE an explicit
    -- CSS box (display:inline-block + width/height), sub-8px boxes are
    -- dropped, and near-identical boxes for the same animation merge
    -- (largest wins). Distinct positions stay distinct instances.
    doc.anims = {}
    doc.btns = {}
    for pno = 1, doc.page_count do
        local links = {}
        pcall(function()
            local pg = widget.document:openPage(pno)
            links = pg:getPageLinks() or {}
            pg:close()
        end)
        for _, link in ipairs(links) do
            local uri = link.uri or link.url or ""
            local bname, bid = uri:match("^kt:btn:([^:]+):?(.*)$")
            if bname and link.x0 and link.x1 and link.y0 and link.y1 then
                -- Native-canvas button anchored by href="kt:btn:NAME[:ID]":
                -- the MuPDF box is only the anchor slot; the VISIBLE pill is
                -- painted by our Widgets.button (pressed state, hit test,
                -- regional refresh) over the bitmap. The anchor text stays
                -- as the label fallback so the HTML still reads well raw.
                doc.btns[#doc.btns + 1] = {
                    name = bname, id = bid ~= "" and bid or nil,
                    page = pno,
                    x0 = link.x0, y0 = link.y0,
                    x1 = link.x1, y1 = link.y1,
                }
            end
            local aname = uri:match("^kt:anim:([^:]+)$")
            if aname and link.x0 and link.x1 and link.y0 and link.y1
                and KtHTML.check_anim(aname) == nil then
        local lw, lh = link.x1 - link.x0, link.y1 - link.y0
                if lw >= 8 and lh >= 8 then
                    local dup = false
                    for _, prev in ipairs(doc.anims) do
                        if prev.name == aname and prev.page == pno
                            and math.abs(prev.x0 - link.x0) < 3
                            and math.abs(prev.y0 - link.y0) < 3
                            and math.abs((prev.x1 - prev.x0) - lw) < 3
                            and math.abs((prev.y1 - prev.y0) - lh) < 3 then
                            dup = true
                            local pa = (prev.x1 - prev.x0)
                                * (prev.y1 - prev.y0)
                            if lw * lh > pa then
                                prev.x0, prev.y0 = link.x0, link.y0
                                prev.x1, prev.y1 = link.x1, link.y1
                            end
                            break
                        end
                    end
                    if not dup then
                        doc.anims[#doc.anims + 1] = {
                            name = aname, page = pno,
                            x0 = link.x0, y0 = link.y0,
                            x1 = link.x1, y1 = link.y1,
                            key = "kthtml:anim:" .. page .. ":" .. aname
                                .. ":" .. tostring(#doc.anims + 1),
                        }
                    end
                end
            end
        end
    end
    KtHTML.prune_anim_players(app, page, doc.anims)
    app.state.kthtml_docs[page] = doc
    return doc
end

-- Stop players of animations that vanished from the rebuilt HTML (their
-- timers would otherwise paint stale rects until a page change).
function KtHTML.prune_anim_players(app, page, anims)
    if not app or not app.state then return end
    local players = app.state.gif_players
    if type(players) ~= "table" then return end
    local live = {}
    for _, a in ipairs(anims or {}) do live[a.key] = true end
    local prefix = "kthtml:anim:" .. tostring(page) .. ":"
    local GifAnim = require("ktui/gifanim")
    for key, player in pairs(players) do
        if tostring(key):sub(1, #prefix) == prefix and not live[key] then
            pcall(function() GifAnim.stop(player) end)
            players[key] = nil
        end
    end
end

-- Currently cached doc for a page (tap closures re-fetch through this so a
-- tap that invalidates never operates on a freed widget).
function KtHTML.current(app, page)
    if app and app.state and app.state.kthtml_docs then
        return app.state.kthtml_docs[page]
    end
    return nil
end

-- Paint the visible window. Tall mode blits the scroll subrect; paginated
-- mode syncs the widget page from the scroll offset and paints it whole.
-- After the bitmap, kt:btn anchors are OVERPAINTED by native canvas pills
-- (Widgets.button): visible pressed state + own hitboxes. view is needed
-- to register hitboxes; without one (tests painting raw) buttons only
-- draw. Screen-coords offset (bx, by) = content origin in the blitbuffer.
function KtHTML.paint_btns(doc, bb, bx, by, w, h, pageno, view, actions)
    if not doc or not doc.btns or #doc.btns == 0 then return end
    local W = require("ktui/widgets")
    for _, b in ipairs(doc.btns) do
        if b.page == pageno then
            local rx, ry = bx + b.x0, by + b.y0
            local rw, rh = b.x1 - b.x0, b.y1 - b.y0
            if rw > 8 and rh > 8 and rx < bx + w and ry < by + h
                and rx + rw > bx and ry + rh > by then
                local label = tostring(b.name)
                local on_tap = nil
                if actions and actions[b.name] then
                    on_tap = function()
                        actions[b.name](b.id)
                    end
                end
                -- Buttons need a view to register hitboxes; already have the
                -- bitmap behind them (the anchor text was painted by MuPDF -
                -- we paint the pill ON TOP so the raw text is hidden).
                W.button(view or { hitboxes = {} }, bb, {
                    x = math.floor(rx), y = math.floor(ry),
                    w = math.floor(rw), h = math.floor(rh),
                    label = label, id = b.id,
                    on_tap = on_tap,
                })
            end
        end
    end
end

-- Paint the visible window. Tall mode blits the scroll subrect; paginated
-- mode syncs the widget page from the scroll offset and paints it whole.
-- view/actions (optional) drive the kt:btn native-pill overlay: pass the
-- SAME view the page paint uses so buttons register their hitboxes there.
function KtHTML.paint_window(doc, bb, x, y, w, h, scroll, view, actions)
    if not doc or not doc.widget then return end
    local widget = doc.widget
    if doc.paginated then
        local count = math.max(1, doc.page_count)
        local vh = math.max(1, doc.viewport_h or h)
        local pno = math.floor((scroll or 0) / vh) + 1
        pno = math.max(1, math.min(count, pno))
        if widget.page_number ~= pno then
            widget:setPageNumber(pno)
            widget:freeBb()
        end
        widget:paintTo(bb, x, y)
        KtHTML.paint_anims(doc, bb, x, y, w, h, pno)
        KtHTML.paint_btns(doc, bb, x, y, w, h, pno, view, actions)
        return
    end
    widget:_render()
    local src = widget.bb
    if not src then return end
    local total = doc.total_h or h
    local sy = math.max(0, math.min(scroll or 0, math.max(0, total - h)))
    local vh = math.min(h, total - sy)
    if vh <= 0 then return end
    pcall(function()
        bb:blitFrom(src, x, y, 0, sy, w, vh)
    end)
    KtHTML.paint_anims(doc, bb, x, y - sy, w, h, 1)
    KtHTML.paint_btns(doc, bb, x, y - sy, w, h, 1, view, actions)
end

-- Overlay the current frame of every animation intersecting the viewport.
-- (bx, by) is the content origin in screen coords; pageno selects which
-- laid-out page's rects apply (tall mode: always page 1).
function KtHTML.paint_anims(doc, bb, bx, by, w, h, pageno)
    if not doc or not doc.anims or #doc.anims == 0 then return end
    if not doc.view_app then return end
    local ok, GifAnim = pcall(require, "ktui/gifanim")
    if not ok or not GifAnim then return end
    for _, a in ipairs(doc.anims) do
        if a.page == pageno then
            local rx, ry = bx + a.x0, by + a.y0
            local rw, rh = a.x1 - a.x0, a.y1 - a.y0
            if rw > 0 and rh > 0 and rx < bx + w and ry < by + h
                and rx + rw > bx and ry + rh > by then
                local player = GifAnim.ensure(doc.view_app, doc.view,
                    a.key, KtHTML.anim_dir(a.name), {
                        w = math.floor(rw), h = math.floor(rh),
                        rect = { x = rx, y = ry, w = rw, h = rh },
                    })
                if player then
                    GifAnim.draw(player, bb, rx, ry, rw, rh)
                end
            end
        end
    end
end

-- Total content height (for max_scroll).
function KtHTML.content_h(doc, h)
    if not doc then return h end
    if doc.paginated then
        return math.max(1, doc.page_count) * math.max(1, doc.viewport_h or h)
    end
    return doc.total_h or h
end

-- Route a tap at page-local coords (bx, by = content origin on screen).
-- scroll offsets into the tall bitmap; paginated links are page-local.
-- Returns true when a kt: link consumed it.
-- Touch feedback: the tapped link's rect gets a regional no-flash refresh
-- ("a2" = fast black/white waveform, same class the scrollbar thumb uses)
-- BEFORE the action runs. On e-ink that inverts the link's pixels for one
-- frame - a button press without a full-screen wave. Screens without a2
-- fall back to "ui" through KOReader's refresh queue.
function KtHTML.tap(doc, app, page, actions, bx, by, scroll, tx, ty)
    if not doc or not doc.widget then return false end
    local widget = doc.widget
    local lx, ly = tx - bx, ty - by
    if not doc.paginated then
        ly = ly + (scroll or 0)
    end
    if lx < 0 or ly < 0 then return false end
    local link = nil
    pcall(function()
        -- Page-local hit test (bypasses the global tap_to_follow_links
        -- switch: our pages always want their own links live).
        local pg = widget.document:openPage(widget.page_number or 1)
        local links = pg:getPageLinks() or {}
        pg:close()
        for _, l in ipairs(links) do
            if l.x0 and lx >= l.x0 and lx < l.x1 and ly >= l.y0 and ly < l.y1 then
                link = l
                break
            end
        end
    end)
    if not link then return false end
    local uri = link.uri or link.url or ""
    if not uri:find("^kt:", 1) then
        return false -- external links: ignored, like the dictionary popup
    end
    -- Touch feedback on the link's own rectangle only (screen coords).
    if doc.view and doc.view.refresh and link.x1 and link.y1 then
        pcall(function()
            local sx, sy = bx + link.x0, by + link.y0
            if not doc.paginated then sy = sy - (scroll or 0) end
            local geom = Geom:new{
                x = sx, y = sy,
                w = math.max(1, math.floor(link.x1 - link.x0)),
                h = math.max(1, math.floor(link.y1 - link.y0)),
            }
            UIManager:setDirty(doc.view, "a2", geom)
            UIManager:forceRePaint()
        end)
    end
    local scheme, rest = uri:match("^kt:([^:]+):?(.*)$")
    rest = rest or ""
    if scheme == "nav" and rest ~= "" then
        app:navigate(rest)
        return true
    elseif scheme == "back" then
        app:go_back()
        return true
    elseif scheme == "toggle" and rest ~= "" then
        -- State templates render into the body at prepare time, so every
        -- mutation invalidates the cached doc (the next paint rebuilds).
        KtHTML.invalidate(app, page)
        if rest:find("^settings%.") then
            app:toggle_setting(rest:sub(10))
        else
            local parent, key = state_ensure(app, rest)
            if parent and key then
                parent[key] = not (parent[key] == true)
            end
            app:refresh(true)
        end
        return true
    elseif scheme == "input" and rest ~= "" then
        local cur = state_lookup(app, rest)
        local title = rest:match("[^%.]+$") or rest
        local Modals = require("ktui/modals")
        Modals.input(title, tostring(cur == nil and "" or cur), "", nil,
            function(text)
                local parent, key = state_ensure(app, rest)
                if parent and key then parent[key] = tostring(text or "") end
                KtHTML.invalidate(app, page)
                app:refresh(true)
            end)
        return true
    elseif scheme == "action" then
        local aname, aid = rest:match("^([^:]+):?(.*)$")
        if aid == "" then aid = nil end
        local fn = actions and aname and actions[aname]
        if fn then
            fn(aid)
            KtHTML.invalidate(app, page)
            return true
        end
        return false
    elseif scheme == "btn" then
        -- The anchor was overpainted by a native canvas button with its
        -- own hitbox (paint_btns); a tap reaching the router anyway means
        -- no button was painted (unmapped action name): consume it so it
        -- does not fall through to anything underneath.
        return true
    elseif scheme == "anim" then
        -- Tap does nothing by design (the sprite just plays); consume so
        -- the tap doesn't fall through to anything underneath.
        return true
    end
    return false
end

function KtHTML.free_doc(doc)
    if doc and doc.widget then
        pcall(function() doc.widget:free() end)
        doc.widget = nil
    end
end

function KtHTML.invalidate(app, page)
    if app and app.state and app.state.kthtml_docs then
        local doc = app.state.kthtml_docs[page]
        if doc then
            KtHTML.free_doc(doc)
            app.state.kthtml_docs[page] = nil
        end
    end
end

function KtHTML.free_all(app)
    if app and app.state and app.state.kthtml_docs then
        for _, doc in pairs(app.state.kthtml_docs) do
            KtHTML.free_doc(doc)
        end
        app.state.kthtml_docs = nil
    end
end

-- ======================================================== sandbox skeleton ===
-- HTML_SKELETON is written to themes/pages/html_sandbox.html on demand
-- (never overwritten: the file is user-owned). It mirrors the uidsl sandbox
-- card by card so the two engines can be compared side by side - but this
-- one is LITERAL html+css rendered by MuPDF, no custom parser anywhere.
-- Templates {{s:}}/{{c:}}/{{px:}} read live app.state; links use the kt:
-- scheme (nav/back/toggle/input/action). pt-BR (debug page, NOT gettext).

KtHTML.HTML_SKELETON = [[
<style>
/* Autoral: vence a base gerada do Theme (vem depois dela). */
.hero { background: #e8e8e8; padding: 12px; margin: 0 0 10px 0; }
.card { border: 1px solid #333333; background: #ffffff; padding: 10px; margin: 0 0 10px 0; }
.muted { color: #666666; }
.center { text-align: center; }
.right { text-align: right; }
.tinta { color: #b41e1e; font-size: 20px; }
.miolo { color: #888888; }
.metade { width: 50%; }
/* ERRO DE PROPOSITO: acao voar + esquema unknown aparecem em "HTML problems:" */
</style>
<div class="hero">
  <h1>HTML + CSS de verdade (MuPDF)</h1>
  <p class="muted">Este arquivo e themes/pages/html_sandbox.html - edite, salve, toque em Recarregar. Tags reais: div p span h1 h2 h3 img table a br hr. Entidades: &amp; &lt; &gt; &quot;.</p>
</div>
<div class="card">
  <h2>Tipografia</h2>
  <h3>h3 pequeno e bold</h3>
  <p>Paragrafo com <b>negrito</b>, <i>italico</i> e <code>codigo</code> inline de verdade.</p>
  <p><span class="tinta">span com cor e fonte 20px</span></p>
  <p class="miolo">classe combinada</p>
</div>
<div class="card">
  <h2>Alinhamento (p e span)</h2>
  <p class="center">paragrafo centralizado</p>
  <p class="right muted">paragrafo a direita</p>
  <p class="center"><span>span centralizado</span></p>
</div>
<div class="card">
  <h2>Imagem (sonic animado em tamanhos)</h2>
  <table><tr>
    <td style="vertical-align: bottom;"><a class="anim" style="display: inline-block; width: 24px; height: 24px;" href="kt:anim:debug_banner"><img src="debug_banner/frame_1.png" style="width: 24px;"/></a></td>
    <td style="vertical-align: bottom;"><a class="anim" style="display: inline-block; width: 32px; height: 32px;" href="kt:anim:debug_banner"><img src="debug_banner/frame_1.png" style="width: 32px;"/></a></td>
    <td style="vertical-align: bottom;"><a class="anim" style="display: inline-block; width: 48px; height: 48px;" href="kt:anim:debug_banner"><img src="debug_banner/frame_1.png" style="width: 48px;"/></a></td>
    <td style="vertical-align: bottom;"><a class="anim" style="display: inline-block; width: 64px; height: 64px;" href="kt:anim:debug_banner"><img src="debug_banner/frame_1.png" style="width: 64px;"/></a></td>
    <td style="vertical-align: bottom;"><a class="anim" style="display: inline-block; width: 80px; height: 80px;" href="kt:anim:debug_banner"><img src="debug_banner/frame_1.png" style="width: 80px;"/></a></td>
  </tr></table>
  <p class="muted">5 Sonics animados lado a lado (~8fps, base alinhada). O MuPDF pinta o frame 1 parado; o GifAnim desenha os frames por cima no retangulo do link (a caixa explicita no &lt;a&gt; e obrigatoria: link so com imagem colapsa). Toque nao faz nada de proposito.</p>
  <p><img src="sonic_debug.gif" style="width: 200px; height: 60px;"/></p>
  <p class="muted">Cover: width+height juntos o MuPDF estica (nao corta como o canvas). Observe a diferenca.</p>
  <p><img src="nao_existe.png" style="width: 60px;"/></p>
  <p class="muted">Ausente vira [image] (marcador do proprio MuPDF).</p>
</div>
<div class="card">
  <h2>Linha horizontal (tabela)</h2>
  <table class="fila"><tr><td class="metade"><p class="center muted">50% fixa</p></td><td><p class="center muted">resto divide</p></td></tr></table>
  <table class="fila"><tr><td><p>sem flexbox: tabela lado a lado</p></td></tr></table>
</div>
<div class="card">
  <h2>Componentes (pills kt:)</h2>
  <p><a class="pill primary" href="kt:action:shot">Capturar tela</a> <a class="pill" href="kt:action:reload">Recarregar</a></p>
  <p><a class="anim" style="display: inline-block; width: 120px; height: 36px;" href="kt:btn:reload">[botao nativo]</a></p>
  <p class="muted">kt:btn: a ancora vira um botao nativo do canvas (pill flutuante com estado de pressao) pintado por cima do bitmap.</p>
  <p><a class="pill {{c:settings.debug_mode:on}}" href="kt:toggle:settings.debug_mode">debug: {{s:settings.debug_mode}}</a></p>
  <p class="muted">Toggle real (liga/desliga e salva). Avatar: <img src="sonic_debug.gif" style="width: 48px;"/></p>
</div>
<div class="card">
  <h2>Botoes (variantes)</h2>
  <p><a class="pill primary" href="kt:action:shot">Primario</a> <a class="pill secondary" href="kt:action:reload">Secundario</a> <a class="pill ghost" href="kt:action:reload">Fantasma</a> <span class="pill nonlink">Desligado</span></p>
  <p><a class="pill" href="kt:action:shot"><img src="camera.svg" style="width: 14px;"/> Capturar</a></p>
  <p class="muted">Desligado nao tem href: sem link, intocavel por construcao. Icone SVG embutido: a confirmar no aparelho.</p>
</div>
<div class="card">
  <h2>Campo e interruptor</h2>
  <p><a class="field" href="kt:input:sandbox.nome"><span>{{s:sandbox.nome}}</span><span class="hint">{{e:sandbox.nome:digite seu nome}}</span></a></p>
  <p><a class="pill {{c:sandbox.sw:on}}" href="kt:toggle:sandbox.sw"><span class="switchstate">{{t:sandbox.sw:LIGADO|desligado}}</span></a></p>
  <p class="muted">Campo com cara de campo (borda + hint apagado). Switch e pill com texto de estado.</p>
</div>
<div class="card">
  <h2>Chips, segmentos, progresso, avatar</h2>
  <p><span class="chip">humano</span><span class="chip">mago</span><span class="chip">1234 tok</span></p>
  <table class="seg"><tr><td class="{{c:sandbox.segA:on}}"><a href="kt:toggle:sandbox.segA">A</a></td><td class="{{c:sandbox.segB:on}}"><a href="kt:toggle:sandbox.segB">B</a></td><td class="{{c:sandbox.segC:on}}"><a href="kt:toggle:sandbox.segC">C</a></td></tr></table>
  <div class="pbar"><div class="pfill" style="width: {{px:sandbox.conta:10}};"></div></div>
  <p class="muted">Barra ligada no contador do Playground (0..9 vira 0..90%). Avatar: <img class="avatar round" src="sonic_debug.gif"/> (circulo se o MuPDF honrar border-radius).</p>
</div>
<div class="card">
  <h2>Playground (estado vivo)</h2>
  <p><a class="pill {{c:sandbox.ligado:on}}" href="kt:toggle:sandbox.ligado">Lampada (troca de cor no toque)</a></p>
  <p class="muted">Apagado = contorno, aceso = solido.</p>
  <p><a class="pill" href="kt:action:step:-1">-1</a> <b>{{s:sandbox.conta}}</b> <a class="pill" href="kt:action:step:1">+1</a></p>
  <p class="muted">Contador com trava 0..9.</p>
  <p><a class="pill" href="kt:action:move:-1">esq</a> <a class="pill" href="kt:action:move:1">dir</a></p>
  <p><img src="sonic_debug.gif" style="width: 40px; margin-left: {{px:sandbox.pos:24}};"/></p>
  <p class="muted">esq/dir movem o sonic (margin-left calculado em Lua). Sem animacao aqui: estado discreto por toque.</p>
</div>
<div class="card">
  <h2>Entrada de texto (input + echo)</h2>
  <p><a class="pill" href="kt:input:sandbox.nome">digite seu nome</a></p>
  <p class="muted">Voce digitou:</p>
  <p><b>{{s:sandbox.nome}}</b></p>
  <p class="muted">Sem input nativo no MuPDF: o link abre o teclado e o echo mostra na hora.</p>
</div>
<hr/>
<div class="card">
  <h2>Acoes (kt:action)</h2>
  <p><a class="pill" href="kt:action:reload">Recarregar</a> <a class="pill" href="kt:action:shot">Capturar tela</a> <a class="pill" href="kt:action:voar">Acao inexistente (vira erro)</a></p>
  <p><a class="pill" href="kt:unknown:coisa">Esquema inexistente (vira erro)</a></p>
</div>
<br/>
<div class="card">
  <h2>Erros visiveis</h2>
  <p>A acao voar e o esquema unknown aparecem em "HTML problems:" (o MuPDF silencia tudo; o lint e Lua).</p>
</div>
<p class="center muted">html_sandbox.html - <a href="kt:action:reload">recarregar</a></p>
]]

return KtHTML
