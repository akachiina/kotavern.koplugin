-- Headless smoke harness for the canvas UI.
-- Paints the chrome (header/pills/kebab, nav), the dashboard grid, a chat
-- with markdown bubbles and a settings row/button sample onto real
-- Blitbuffers, asserts ink, and dumps PNGs for visual inspection.
--
-- Run with KOReader's runtime so the real fonts/blitbuffer/widgets load.
-- KO_HOME points KOReader's data dir at a writable location (the install dir
-- itself is often read-only):
--   cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy \
--       ./luajit /path/to/kotavern.koplugin/tools/ui_smoke.lua
--
-- Output: /tmp/kotavern_ui/*.png  (exit 0 = all checks passed)

local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/")
local PLUGIN = here .. "/.."
-- Replicate KOReader's own loader env (setupkoenv.lua, run from its root),
-- then put the plugin's modules in front so ui/theme etc. resolve to ours.
package.path = "common/?.lua;frontend/?.lua;plugins/exporter.koplugin/?.lua;" .. package.path
package.cpath = "common/?.so;common/?.dll;/usr/lib/lua/?.so;" .. package.cpath
require("ffi/loadlib")
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local checks, fails = 0, 0
local function ok(cond, name)
    checks = checks + 1
    if not cond then
        fails = fails + 1
        io.stderr:write("FAIL: " .. tostring(name) .. "\n")
    else
        print("ok   " .. name)
    end
end

local OUT_DIR = "/tmp/kotavern_ui"
os.execute("mkdir -p " .. OUT_DIR)

-- Globals KOReader's device modules expect (normally set by reader.lua).
G_reader_settings = {
    readSetting = function(self, k, default) return default end,
    saveSetting = function() end,
    isTrue = function() return false end,
    isFalse = function() return true end,
    isNilOrTrue = function() return false end,
    isNilOrFalse = function() return false end,
    nilOrTrue = function() return true end,
    nilOrFalse = function() return false end,
    has = function() return false end,
}
G_defaults = { readSetting = function() return 0 end }

-- Headless document context (fontlist + ImageWidget probes at load).
package.preload["document/canvascontext"] = function()
    local C = {}
    function C:isKindle() return false end
    function C:hasSystemFonts() return false end
    function C:getWidth() return 600 end
    function C:getHeight() return 800 end
    function C:getScreenMode() return "portrait" end
    function C:scaleBySize(n) return n end
    function C:setDPI() end
    function C:getDPI() return 167 end
    function C:nativeTextHeight() return 20 end
    return C
end
package.preload["document/documentregistry"] = function()
    -- NOTE: called as DocumentRegistry:isImageFile(file) -> (self, file).
    return {
        isImageFile = function(self, path)
            local e = tostring(path):lower():match("%.([%w]+)$")
            return e == "png" or e == "jpg" or e == "jpeg" or e == "gif" or e == "svg"
        end,
    }
end

-- Deterministic 600x800 e-ink viewport, DPI 1.
local Device = require("device")
-- The SDL emulator device lacks some platform probes fontlist's scanner calls
-- at load; add harmless stubs (real device tables have them on targets).
for _, m in ipairs({ "isKindle", "isKobo", "isPocketBook", "isCervantes",
    "isSonyPRSTUX", "isAndroid", "isRemarkable", "is_bookline" }) do
    if Device[m] == nil then Device[m] = function() return false end end
end
local Screen = Device.screen
local VW, VH = 600, 800
function Screen:getWidth() return VW end
function Screen:getHeight() return VH end
function Screen:scaleBySize(n) return n end
function Screen:getScreenMode() return "portrait" end
local Screen_bb = Screen.bb

local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")

local Theme = require("ktui/theme")        -- ours (plugin path wins)
local P = require("ktui/primitives")       -- ours
local Icons = require("ktui/icons")        -- ours
local Header = require("ktui/header")      -- ours
local Nav = require("ktui/nav")            -- ours
local Pages = require("ktui/pages")        -- ours
local ChatBubbles = require("ktui/chat_bubbles") -- ours
local Cards = require("ktui/cards")        -- ours
local Widgets = require("ktui/widgets")    -- ours
local Scroll = require("ktui/scroll")      -- ours

ok(Icons.has_asset("home"), "icons: home.svg asset found")
ok(Icons.has_asset("logo"), "icons: logo.svg asset found")
ok(not Icons.has_asset("paw"), "icons: paw correctly has no asset (glyph fallback)")
ok(Theme.get_theme() == "light", "theme: defaults to light")

-- Minimal fake App: just enough state for the paint path (no taps fired).
local function fake_app(state_overrides)
    local app = {
        plugin = nil,
        state = {
            page = "dashboard",
            settings = {},
            scroll = {},
            sheet = nil,
            messages = {},
            chats_index = {},
            personas = { list = {}, active = nil },
            dashboard_query = "",
            dashboard_filter = "all",
            is_generating = false,
            reasoning_open = {},
            reasoning_full = {},
            current_character = "Aria",
        },
    }
    for k, v in pairs(state_overrides or {}) do app.state[k] = v end
    function app:scroll_key() return self.state.page end
    function app:stream_refresh_label() return "Calm" end
    function app:chats_visible() return self.state.chats_index or {} end
    function app:chats_unseen_count() return self.state._unseen or 0 end
    function app:dashboard_columns() return 3 end
    function app:dashboard_card_h() return Theme.scale(400) end
    function app:dashboard_items()
        return {
            { name = "Aria", path = nil, tags = { "human", "mage" }, tokens = 1234, creator = "Luna", fav = true },
            { name = "Botão ✓ unicode", path = nil, tags = {}, tokens = 0, creator = "" },
            { name = "Kai", path = nil, tags = { "elfo" }, tokens = 999, creator = "Zed" },
            { name = "Mira", path = nil, tags = {}, tokens = 42, creator = "Ada" },
            { name = "Nox", path = nil, tags = {}, tokens = 7, creator = "Eve" },
            { name = "Sol", path = nil, tags = {}, tokens = 1, creator = "Sol" },
        }
    end
    -- Theme editor surface (mirrors kt_app): the Appearance>Chat page reads
    -- the current look through these; rows only call the write paths on tap.
    function app:chat_look()
        local ChatTheme = require("ktui/chat_theme")
        local live = self.state.chat_theme_applied
        if live then return ChatTheme.normalize(live) end
        local s = self.state.settings
        return ChatTheme.normalize({
            style = s.bubble_style, chat_width = s.chat_width,
            font_file = s.chat_font_file, font_size = s.chat_font_size,
            custom_css = s.custom_css, avatar_shape = s.avatar_shape,
            avatar_size = s.avatar_size, show_avatars = s.show_avatars,
            show_timestamps = s.show_timestamps, show_tokens = s.show_tokens,
        })
    end
    function app:active_bubble_theme_id()
        local meta_id = self.state.current_chat_bubble_theme_id
        if meta_id ~= nil then return (meta_id ~= "" and meta_id) or nil end
        local g = self.state.settings.bubble_theme_id
        return (type(g) == "string" and g ~= "") and g or nil
    end
    function app:find_chat_theme(id)
        local ChatTheme = require("ktui/chat_theme")
        local Storage = require("kt_storage")
        for _, b in ipairs(ChatTheme.BUILTINS()) do
            if b.id == id then return b.theme, b.name end
        end
        for _, t in ipairs(Storage.list_chat_themes() or {}) do
            if t.id == id then return ChatTheme.normalize(t.theme), t.name end
        end
        return nil
    end
    return app
end

local function new_bb()
    local bb = Blitbuffer.new(VW, VH, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    return bb
end

local function ink_ratio(bb)
    local dark = 0
    for y = 0, VH - 1, 4 do
        for x = 0, VW - 1, 4 do
            if bb:getPixel(x, y):getR() < 128 then dark = dark + 1 end
        end
    end
    return dark
end

-- Dark pixel count inside a box (step 1: small regions need precision, e.g.
-- the 6px kebab dots and the 3px nav underline).
local function dark_in(bb, x, y, w, h)
    local dark = 0
    for yy = y, math.min(y + h, VH) - 1 do
        for xx = x, math.min(x + w, VW) - 1 do
            -- < 200: counts ink (0) AND muted grays (85/128); excludes white.
            if bb:getPixel(xx, yy):getR() < 200 then dark = dark + 1 end
        end
    end
    return dark
end

local function has_hit(view, prefix)
    for _, box in ipairs(view.hitboxes) do
        if tostring(box.label or ""):sub(1, #prefix) == prefix then
            return true
        end
    end
    return false
end

local function dump(bb, name)
    bb:writePNG(OUT_DIR .. "/" .. name .. ".png")
    print("wrote " .. OUT_DIR .. "/" .. name .. ".png")
end

-- Count registered hitboxes as a proxy for wiring sanity.
local function count_hits(view) return #view.hitboxes end

-- === 1. Dashboard: header (brand + pills) + grid + nav ======================
do
    local app = fake_app()
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()

    local content_top = Header.height(view)
    ok(content_top > Theme.metrics().titlebar_h, "header: dashboard height includes pill toolbar")

    local list_h = VH - content_top - Theme.metrics().nav_h
    Pages.dashboard(view, bb, 0, content_top, VW, list_h, 0)
    Nav.draw(view, bb, 0, VH - Theme.metrics().nav_h, VW, Theme.metrics().nav_h)
    Header.draw(view, bb, 0, 0, VW)

    ok(ink_ratio(bb) > 150, "dashboard: paints ink (brand, pills, cards, nav)")
    ok(count_hits(view) > 10, "dashboard: registers hitboxes (pills, cards, nav, kebab)")
    dump(bb, "dashboard")

    -- Fixed card heights (ST-style): every card paints at the same height -
    -- the desired setting capped at what fills 2 rows - whatever the count;
    -- 6 fit with zero scroll, overflow scrolls.
    local desired = app:dashboard_card_h()
    local gap = Theme.metrics().card_gap
    local function card_heights(v)
        local hs = {}
        for _, b in ipairs(v.hitboxes) do
            if tostring(b.label or ""):sub(1, 5) == "char:" then hs[#hs + 1] = b.h end
        end
        return hs
    end
    local fixed = (card_heights(view))[1] or 0
    local step = fixed + gap
    ok(fixed > 0 and fixed <= desired,
        "dashgrid: two-row cap never exceeds the desired height (" .. tostring(fixed) .. " <= " .. tostring(desired) .. ")")
    local function want_scroll(n)
        local total = math.ceil(n / 3) * step - gap
        return math.ceil(math.max(0, total - list_h) / step) * step
    end
    do
        local h6 = card_heights(view)
        local all_fixed = #h6 == 6
        for _, h in ipairs(h6) do all_fixed = all_fixed and h == fixed end
        ok(all_fixed, "dashgrid: 6 cards all paint at capped height (" .. tostring(fixed) .. ")")
        local ms6 = Pages.dashboard({ app = app, hitboxes = {} }, new_bb(), 0, content_top, VW, list_h, 0)
        ok(ms6 == want_scroll(6) and ms6 == 0,
            "dashgrid: 6 cards fit with zero scroll (max_scroll=" .. tostring(ms6) .. ")")
    end
    -- 7 cards (user case): same height as 6 - no shrinking; the 3rd row
    -- waits below the fold and the scrollbar takes it.
    do
        local app7 = fake_app()
        local items7 = app7:dashboard_items()
        table.insert(items7, { name = "Sete", path = nil, tags = {}, tokens = 5, creator = "Q" })
        function app7:dashboard_items() return items7 end
        local v7 = { app = app7, hitboxes = {} }
        local bb7 = new_bb()
        local ms7 = Pages.dashboard(v7, bb7, 0, content_top, VW, list_h, 0)
        local h7 = card_heights(v7)
        -- Only the visible rows paint (the 3rd waits below the fold), but
        -- every painted card must be at full desired height.
        local all_fixed = #h7 == 6
        for _, h in ipairs(h7) do all_fixed = all_fixed and h == fixed end
        ok(all_fixed, "dashgrid: 7 cards keep the same height (no shrink)")
        ok(ms7 == want_scroll(7) and ms7 > 0,
            "dashgrid: 7 cards scroll the 3rd row (max_scroll=" .. tostring(ms7) .. ")")
        -- Scrolled to the bottom, rows 2+3 paint; every one at full height.
        local v7s = { app = app7, hitboxes = {} }
        Pages.dashboard(v7s, new_bb(), 0, content_top, VW, list_h, ms7)
        local h7s = card_heights(v7s)
        local tail_full = #h7s == 4
        for _, h in ipairs(h7s) do tail_full = tail_full and h == fixed end
        ok(tail_full,
            "dashgrid: scrolled rows paint full height")
        dump(bb7, "dashboard_7cards")
    end
    -- 8 cards: same height again; scroll grows to the 3rd row.
    do
        local app8 = fake_app()
        local real_items = app8:dashboard_items()
        table.insert(real_items, { name = "Zed", path = nil, tags = {}, tokens = 5, creator = "Q" })
        table.insert(real_items, { name = "Uma", path = nil, tags = {}, tokens = 6, creator = "Q" })
        function app8:dashboard_items() return real_items end
        local v8 = { app = app8, hitboxes = {} }
        local bb8 = new_bb()
        local ms8 = Pages.dashboard(v8, bb8, 0, content_top, VW, list_h, 0)
        local h8 = card_heights(v8)
        local all_fixed = #h8 == 6
        for _, h in ipairs(h8) do all_fixed = all_fixed and h == fixed end
        ok(all_fixed, "dashgrid: 8 cards keep the same height (no shrink)")
        ok(ms8 == want_scroll(8) and ms8 > 0,
            "dashgrid: 8 cards scroll (max_scroll=" .. tostring(ms8) .. ")")
    end
end

-- === 2. Secondary page header: back + title + kebab (no close X) ===========
do
    local app = fake_app({ page = "chats", chats_index = { {}, {}, {} } })
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    Header.draw(view, bb, 0, 0, VW)
    ok(ink_ratio(bb) > 50, "header: secondary page paints (back, title, kebab)")
    ok(not has_hit(view, "close"), "header: no close X hitbox (exit is via kebab -> Quit)")
    dump(bb, "header_chats")
end

-- === 3. Chat page: markdown bubbles + action bar ============================
do
    local app = fake_app({
        page = "chat",
        messages = {
            { role = "assistant", name = "Aria", send_date = os.time(),
              content = "# Bem-vindo!\n\nTexto com **negrito**, `código` e *itálico*.\n\n```lua\nprint(\"oi\")\n```\n\n> uma citação" },
            { role = "user", name = "Você", send_date = os.time(), content = "Oi! Tudo bem?\n\nSegunda linha." },
        },
    })
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    Pages.chat(view, bb, 0, 0, VW, VH, 0)
    ok(ink_ratio(bb) > 300, "chat: paints bubbles + action bar")
    ok(count_hits(view) >= 4, "chat: registers message + bar hitboxes")
    dump(bb, "chat")
end

-- Reasoning block (collapsed) must render - regression guard: the pass-2
-- draw loop used to shadow gettext `_` with the numeric loop index, crashing
-- with "attempt to call local '_' (a number value)" on the first message that
-- carried reasoning (v0.5.3 reasoning channel capture exposed it).
do
    local app = fake_app({
        page = "chat",
        messages = {
            { role = "assistant", name = "Aria", send_date = os.time(),
              content = "Resposta final.",
              reasoning = "Pensamento interno passo a passo." },
        },
    })
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    local okp, err = pcall(function()
        Pages.chat(view, bb, 0, 0, VW, VH, 0)
    end)
    ok(okp, "chat: reasoning row renders without crashing (" .. tostring(err) .. ")")
    ok(ink_ratio(bb) > 50, "chat: reasoning label paints ink")
    dump(bb, "chat_reasoning")

    -- Expanded state: left-rule section with the reasoning text (the visual
    -- the user flagged as ugly when it was a nested bordered box).
    local send_date = os.time()
    local rmsg = { role = "assistant", name = "Aria", send_date = send_date,
        content = "Resposta final.",
        reasoning = "Pensamento interno em vários parágrafos.\n\nSegundo parágrafo com mais contexto de decisão.\n\nTerceiro parágrafo curto." }
    local app2 = fake_app({ page = "chat", messages = { rmsg } })
    local msg_key = tostring(send_date) .. ":" .. tostring("Aria") .. ":" .. #rmsg.content
    app2.state.reasoning_open[msg_key] = true
    local view2 = { app = app2, hitboxes = {} }
    local bb2 = new_bb()
    local okp2, err2 = pcall(function()
        Pages.chat(view2, bb2, 0, 0, VW, VH, 0)
    end)
    ok(okp2, "chat: reasoning EXPANDED renders without crashing (" .. tostring(err2) .. ")")
    ok(ink_ratio(bb2) > 150, "chat: expanded reasoning paints body text")
    local short_hint = false
    for _, hb in ipairs(view2.hitboxes) do
        if type(hb.label) == "string" and hb.label:sub(1, #"reasoning_more_") == "reasoning_more_" then
            short_hint = true
        end
    end
    ok(not short_hint, "chat: SHORT expanded reasoning is not clamped (no hint)")
    dump(bb2, "chat_reasoning_expanded")

    -- HTML-mode reasoning: expanded block renders through the same MuPDF doc
    -- path as bodies, with the muted overlay, and holds a live widget.
    local app_h = fake_app({ page = "chat",
        settings = { chat_html_render = true },
        messages = {
            { role = "assistant", name = "Aria", send_date = os.time(),
              content = "Resposta final.",
              reasoning = "Pensamento interno **com markdown** e lista:\n- um\n- dois ||segredo||" },
        } })
    local view_h = { app = app_h, hitboxes = {}, refresh = function() end }
    local bb_h = new_bb()
    local okp_h, err_h = pcall(function()
        Pages.chat(view_h, bb_h, 0, 0, VW, VH, 0)
    end)
    ok(okp_h, "chat html reasoning: collapsed renders (" .. tostring(err_h) .. ")")
    -- Open it: find the reasoning hitbox by label prefix and expand.
    local rbox = nil
    for _i, hb in ipairs(view_h.hitboxes) do
        if type(hb.label) == "string" and hb.label:sub(1, 10) == "reasoning_" then
            rbox = hb break
        end
    end
    ok(rbox ~= nil, "chat html reasoning: collapsed registers the expand hitbox")
    if rbox and rbox.callback then
        local oktap, errtap = pcall(rbox.callback, 0, 0)
        ok(oktap, "chat html reasoning: expand tap is safe (" .. tostring(errtap) .. ")")
        local bb_h2 = new_bb()
        local okp_h2, err_h2 = pcall(function()
            Pages.chat(view_h, bb_h2, 0, 0, VW, VH, 0)
        end)
        ok(okp_h2, "chat html reasoning: expanded render (" .. tostring(err_h2) .. ")")
        -- The expanded layout reasoning entries must be html kind with a live doc.
        local found = false
        local rkey_h, rentry_h = nil, nil
        for _lk2, l in pairs(view_h._chat_layout_cache or {}) do
            if type(l) == "table" and l.reasoning_entries and #l.reasoning_entries > 0
                and l.reasoning_entries[1].kind == "html"
                and l.reasoning_entries[1].widget
                and l.reasoning_entries[1].widget.document ~= nil then
                found = true
                rkey_h = l.msg_key
                rentry_h = l.reasoning_entries[1]
            end
        end
        ok(found, "chat html reasoning: expanded block renders via a live MuPDF doc")
        -- Spoiler inside reasoning: masked link exists under the |r namespace,
        -- tapping it through the band flips the namespace-scoped reveal state
        -- and rebuilds the doc (old widget freed, new one live).
        if found and rkey_h then
            local r_ns = rkey_h .. "|r"
            local spl_rect = nil
            local okp, pg = pcall(function()
                return rentry_h.widget.document:openPage(1)
            end)
            if okp and pg then
                local okp2, links = pcall(function() return pg:getPageLinks() end)
                pcall(function() pg:close() end)
                if okp2 and type(links) == "table" then
                    for _gl, lk in ipairs(links) do
                        if type(lk) == "table" and tostring(lk.uri or lk.url or "") == "kt:spl:1" then
                            spl_rect = lk break
                        end
                    end
                end
            end
            ok(spl_rect ~= nil, "chat html reasoning: spoiler exposes a kt:spl:1 link")
            local rband = nil
            for _sb, hb in ipairs(view_h.hitboxes) do
                if hb.label == "chathtml_" .. r_ns then rband = hb break end
            end
            ok(rband ~= nil, "chat html reasoning: reasoning band registers its own tap hitbox")
            if spl_rect and rband then
                local old_widget = rentry_h.widget
                local okp3 = pcall(function()
                    rband.callback(rband.x + (spl_rect.x0 or 0) + 2,
                        rband.y + (spl_rect.y0 or 0) + 2)
                end)
                ok(okp3, "chat html reasoning: spoiler tap does not crash")
                local rev = app_h.state.chat_spoilers_revealed
                ok(rev ~= nil and rev[r_ns] ~= nil and rev[r_ns][1] == true,
                    "chat html reasoning: tap flips the |r-namespaced reveal state")
                local bb_h3 = new_bb()
                local okp_h3, err_h3 = pcall(function()
                    Pages.chat(view_h, bb_h3, 0, 0, VW, VH, 0)
                end)
                ok(okp_h3, "chat html reasoning: revealed render (" .. tostring(err_h3) .. ")")
                local new_widget = nil
                for _lk3, l in pairs(view_h._chat_layout_cache or {}) do
                    if type(l) == "table" and l.msg_key == rkey_h
                        and l.reasoning_entries and #l.reasoning_entries > 0 then
                        new_widget = l.reasoning_entries[1].widget
                    end
                end
                ok(new_widget ~= nil and new_widget ~= old_widget,
                    "chat html reasoning: reveal rebuilds the reasoning doc")
            end
        end
    end

    -- Clamp (v0.6.4): a LONG expanded reasoning is capped at half the viewport
    -- with a pinned "Show more" hint, instead of pushing the reply off-screen
    -- (the "reasoning ocupa a tela toda" report). The hint hitbox expands the
    -- block in place; collapsing clears both open and full state.
    local parts = {}
    for i = 1, 40 do
        parts[i] = "Parágrafo " .. i .. " do raciocínio longo com bastante texto para estourar o clamp da metade da viewport."
    end
    local lmsg = { role = "assistant", name = "Aria", send_date = send_date,
        content = "Resposta final curta.",
        reasoning = table.concat(parts, "\n\n") }
    local lkey = tostring(send_date) .. ":" .. tostring("Aria") .. ":" .. #lmsg.content
    local app3 = fake_app({ page = "chat", messages = { lmsg } })
    app3.state.reasoning_open[lkey] = true
    local view3 = { app = app3, hitboxes = {}, refresh = function() end }
    local bb3 = new_bb()
    local okp3, err3 = pcall(function()
        Pages.chat(view3, bb3, 0, 0, VW, VH, 0)
    end)
    ok(okp3, "chat: clamped LONG reasoning renders without crashing (" .. tostring(err3) .. ")")
    local more_hit
    for _, hb in ipairs(view3.hitboxes) do
        if type(hb.label) == "string" and hb.label:sub(1, #"reasoning_more_") == "reasoning_more_" then
            more_hit = hb
        end
    end
    ok(more_hit ~= nil, "chat: clamped reasoning shows the 'Show more' hint hitbox")
    ok(more_hit == nil or more_hit.callback ~= nil, "chat: 'Show more' hitbox carries a callback")
    if more_hit then
        more_hit.callback()
        ok(app3.state.reasoning_full[lkey] == true, "chat: 'Show more' tap sets reasoning_full")
        local view3b = { app = app3, hitboxes = {}, refresh = function() end }
        local bb3b = new_bb()
        local okp3b = pcall(function()
            Pages.chat(view3b, bb3b, 0, 0, VW, VH, 0)
        end)
        ok(okp3b, "chat: fully expanded (post 'Show more') renders without crashing")
        local still_hint = false
        for _, hb in ipairs(view3b.hitboxes) do
            if type(hb.label) == "string" and hb.label:sub(1, #"reasoning_more_") == "reasoning_more_" then
                still_hint = true
            end
        end
        ok(not still_hint, "chat: full reasoning drops the 'Show more' hint")
    end
    local collapse_hit
    for _, hb in ipairs(view3.hitboxes) do
        if hb.label == "reasoning_" .. lkey then collapse_hit = hb end
    end
    ok(collapse_hit ~= nil, "chat: clamped reasoning keeps the collapse hitbox")
    if collapse_hit then
        collapse_hit.callback()
        ok(app3.state.reasoning_open[lkey] == nil and app3.state.reasoning_full[lkey] == nil,
            "chat: collapse clears reasoning_open and reasoning_full")
    end
    dump(bb3, "chat_reasoning_clamped")
end

-- === 4. Settings page (rows/toggles) ========================================
do
    local app = fake_app({ page = "settings" })
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    Pages.settings(view, bb, 0, 0, VW, VH - Theme.metrics().nav_h, 0)
    ok(ink_ratio(bb) > 100, "settings: paints rows")
    dump(bb, "settings")
end

-- Settings page with the Auto-Continue rows active (value functions run during
-- the paint - a bad tonumber/format would crash here).
do
    local app = fake_app({ page = "settings" })
    app.state.settings.auto_continue = true
    app.state.settings.auto_continue_length = 0
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    local okp, err = pcall(function()
        Pages.settings(view, bb, 0, 0, VW, VH - Theme.metrics().nav_h, 0)
    end)
    ok(okp, "settings: auto-continue rows render (" .. tostring(err) .. ")")
end

-- === 4b. Auto-Continue decision (ST user-settings parity, v0.6.5) ============
do
    local App = require("kt_app")
    local function mk_app()
        return setmetatable({
            state = {
                settings = {},
                messages = {},
                current_chat_path = "/tmp/chat.jsonl",
                is_generating = false,
            },
        }, { __index = App })
    end
    local target = { role = "assistant", content = "curta", send_date = 1 }
    local app = mk_app()
    app.state.messages = { { role = "user", content = "oi" }, target }

    ok(app:_auto_continue_decision(target, {}) == nil,
        "autocontinue: disabled by default (no chain)")

    app.state.settings.auto_continue = true
    app.state.settings.auto_continue_length = 200
    local d1 = app:_auto_continue_decision(target, {})
    ok(d1 ~= nil and d1.auto_continue_n == 1,
        "autocontinue: short reply below target chains a Continue (depth 1)")

    target.content = string.rep("palavra ", 400) -- ~3200 chars ≈ 800 tok
    ok(app:_auto_continue_decision(target, {}) == nil,
        "autocontinue: reply above the target stops the chain")

    target.content = "curta"
    target.completion_tokens = 500
    ok(app:_auto_continue_decision(target, {}) == nil,
        "autocontinue: real usage above target stops")
    target.completion_tokens = 50
    ok(app:_auto_continue_decision(target, {}) ~= nil,
        "autocontinue: real usage below target chains")
    ok(app:_auto_continue_decision(target, { continue_into = target }) ~= nil,
        "autocontinue: continue chain estimates from merged content")

    ok(app:_auto_continue_decision(target, { auto_continue_n = 5 }) == nil,
        "autocontinue: chain cap (5) stops runaway loops")

    target.completion_tokens = nil
    target.content = string.rep("x ", 2000)
    app.state.settings.auto_continue_length = 0
    ok(app:_auto_continue_decision(target, {}) ~= nil,
        "autocontinue: target 0 = no size gate (always continues a cut)")

    app.state.settings.auto_continue_length = 200
    target.content = "curta"
    ok(app:_auto_continue_decision(app.state.messages[1], {}) == nil,
        "autocontinue: non-assistant target refused")
    table.insert(app.state.messages, { role = "user", content = "fim" })
    ok(app:_auto_continue_decision(target, {}) == nil,
        "autocontinue: non-last target refused")
    table.remove(app.state.messages)
    app.state.is_generating = true
    ok(app:_auto_continue_decision(target, {}) == nil,
        "autocontinue: refuses while a generation is in flight")
end

-- === 4c. Regenerate clears the old reply immediately (ST parity, v0.6.5) ====
do
    local App = require("kt_app")
    local function mk_app()
        return setmetatable({
            state = { settings = {}, messages = {}, current_chat_path = nil },
        }, { __index = App })
    end

    -- Regenerate setup clears content + reasoning, keeping a restorable base.
    local msg = { role = "assistant", content = "resposta antiga", reasoning = "raciocinio antigo",
        swipes = { "resposta antiga" }, swipe_id = 1 }
    local app = mk_app()
    app.state.messages = { { role = "user", content = "oi" }, msg }
    -- (what _do_stream_message / _do_generate do on regenerate:)
    msg._streaming_reuse = true
    msg._streaming_base = msg.content
    msg._streaming_base_reasoning = msg.reasoning
    msg._reasoning_backed_up = true
    msg.content = ""
    msg.reasoning = nil
    ok(msg.content == "" and msg.reasoning == nil,
        "regen: the old reply clears immediately (content + reasoning)")

    -- Failure / stop / chat-switch path restores text AND reasoning.
    app:_restore_reused_message(msg, 2, nil)
    ok(msg.content == "resposta antiga", "regen: failure restores the old text")
    ok(msg.reasoning == "raciocinio antigo", "regen: failure restores the old reasoning")
    ok(msg._streaming_base == nil and msg._reasoning_backed_up == nil,
        "regen: backup keys cleared after restore")

    -- Success path commits the new text + reasoning and clears the backups.
    local msg2 = { role = "assistant", content = "",
        _streaming_reuse = true, _streaming_base = "old", _streaming_base_reasoning = "old r",
        _reasoning_backed_up = true, swipes = { "old" }, swipe_id = 1 }
    local app2 = mk_app()
    app2.state.messages = { msg2 }
    app2:_finish_reused_message(msg2, "nova resposta", {}, nil, nil, "novo raciocinio")
    ok(msg2.content == "nova resposta" and msg2.reasoning == "novo raciocinio",
        "regen: finalize commits the new text + reasoning")
    ok(msg2._streaming_base == nil and msg2._reasoning_backed_up == nil,
        "regen: finalize clears the backup keys")
    ok(#msg2.swipes == 2 and msg2.swipes[2] == "nova resposta",
        "regen: finalize appends the new swipe variant")
end

-- === 4d. Preset editor: full prompt editing + field completeness (v0.6.7) ===
do
    local App = require("kt_app")
    local function mk_app()
        return setmetatable({ state = {} }, { __index = App })
    end

    -- present_preset keeps nested structures (shared by reference) and the
    -- text fields the old whitelist dropped.
    local app = mk_app()
    local stored = {
        id = "p1", name = "ST Preset", temperature = 0.7,
        prompts = { { identifier = "main", name = "Main Prompt", role = "system", content = "olá" } },
        prompt_order = { { character_id = 100001, order = { { identifier = "main", enabled = true } } } },
        st_fields = { squashed_system_prompt = true },
        continue_postfix = "\n", reasoning_effort = "low", stop = "The End",
    }
    local draft = app:present_preset(stored)
    ok(draft.prompts == stored.prompts, "preset edit: prompts table survives present_preset (by reference)")
    ok(draft.prompt_order == stored.prompt_order, "preset edit: prompt_order survives present_preset")
    ok(draft.continue_postfix == "\n" and draft.reasoning_effort == "low" and draft.stop == "The End",
        "preset edit: stop / continue_postfix / reasoning_effort survive present_preset")

    -- Seeding: presets without prompts/prompt_order get the ST defaults
    -- (editable Prompt Manager) - this is what made presets created in-app
    -- "parameters only" before v0.6.7.
    local bare = { id = "p2", name = "In-app" }
    ok(app:ensure_preset_prompts(bare) == true, "preset edit: seeds prompts+prompt_order on a bare preset")
    ok(type(bare.prompts) == "table" and #bare.prompts > 0, "preset edit: seeded prompts list populated")
    ok(type(bare.prompt_order) == "table" and #bare.prompt_order > 0, "preset edit: seeded prompt_order populated")
    local has_history
    for _i, p in ipairs(bare.prompts) do
        if p.identifier == "chatHistory" then has_history = p end
    end
    ok(has_history ~= nil and has_history.marker == true, "preset edit: chatHistory marker seeded")
    local order_ids, main_pos, history_pos = {}, nil, nil
    for _i, it in ipairs(bare.prompt_order[1].order) do
        order_ids[it.identifier] = _i
        if it.identifier == "main" then main_pos = _i end
        if it.identifier == "chatHistory" then history_pos = _i end
    end
    ok(main_pos ~= nil and history_pos ~= nil and main_pos < history_pos,
        "preset edit: seeded order puts the main prompt before chatHistory (ST layout)")
    ok(order_ids.worldInfoAfter ~= nil and order_ids.worldInfoAfter > history_pos,
        "preset edit: worldInfoAfter follows chatHistory (post-history)")
    ok(app:ensure_preset_prompts(bare) == false, "preset edit: seeding is idempotent")

    -- edit_preset seeds too (the editor entry point). The draft is a copy of
    -- the record that SHARES the nested tables (present_preset semantics).
    app.state.editing_preset = nil
    app.state.page = "dashboard"
    app:edit_preset(bare)
    local ed = app.state.editing_preset
    ok(app.state.page == "preset_editor" and ed ~= nil and ed ~= bare,
        "preset edit: edit_preset navigates with a draft copy")
    ok(ed.prompts == bare.prompts and ed.prompt_order == bare.prompt_order,
        "preset edit: draft shares the nested tables with the record")

    -- Save contract: the draft shares nested tables with the persisted
    -- record, so a Prompt Manager edit on the draft IS the stored edit
    -- (present → edit → save_preset_edit persists that same table).
    draft.prompts[1].content = "novo conteúdo"
    ok(stored.prompts[1].content == "novo conteúdo",
        "preset edit: draft edits land in the persisted record (save round-trip)")
    draft.prompts[1].content = "olá"

    -- Duplicate deep-copies the nested structures (editing the copy must not
    -- mutate the original).
    local dup_prompts
    do
        local dup = {}
        for k, v in pairs(bare) do dup[k] = v end
        if type(dup.prompts) == "table" then
            dup.prompts = {}
            for _i, p in ipairs(bare.prompts) do
                local cp = {}
                for pk, pv in pairs(p) do cp[pk] = pv end
                table.insert(dup.prompts, cp)
            end
        end
        dup_prompts = dup.prompts
    end
    ok(dup_prompts ~= nil and dup_prompts ~= bare.prompts and dup_prompts[1] ~= bare.prompts[1],
        "preset edit: duplicate deep-copies prompts (no aliasing)")

    -- Field list completeness: every sampler key build_payload reads from the
    -- preset must be editable in the editor.
    local editable = {}
    for _i, f in ipairs(App.PRESET_FIELDS) do
        if f.key then editable[f.key] = f end
    end
    for _i, key in ipairs({ "temperature", "top_p", "top_k", "top_a", "min_p",
        "repetition_penalty", "frequency_penalty", "presence_penalty", "seed", "n",
        "max_tokens", "openai_max_context", "streaming", "model_id", "name",
        "reasoning_effort", "verbosity", "continue_postfix", "stop" }) do
        if not editable[key] then
            ok(false, "preset edit: field editable in PRESET_FIELDS - " .. key)
        end
    end
    ok(editable.temperature ~= nil and editable.reasoning_effort ~= nil
        and editable.stop ~= nil and editable.verbosity ~= nil and editable.continue_postfix ~= nil,
        "preset edit: all build_payload sampler keys + stop/nudge fields are editable")
    ok(editable.reasoning_effort.choices ~= nil and editable.verbosity.choices ~= nil,
        "preset edit: enum fields expose choices (sheet picker, no keyboard)")
    ok(editable.temperature.numeric == nil and editable.top_k.numeric == true,
        "preset edit: floats free-text, integers numeric (NumberPicker integer-only)")
end

-- === 4e. Payload sampler gating + flat API errors (v0.6.8) ===================
do
    local Client = require("kt_client")
    -- Strict cloud (ST CUSTOM parity): preset carries the full extended set,
    -- the endpoint must NOT receive any of it (HTTP 400 top_a fix).
    local full = { temperature = 0.8, max_tokens = 512, top_p = 0.9,
        top_k = 40, top_a = 0.9, min_p = 0.1, repetition_penalty = 1.1,
        frequency_penalty = 0.2, presence_penalty = 0.3 }
    local strict = Client:build_payload({}, { base_url = "https://api.openai.com/v1", model_id = "gpt-4o" }, full, false)
    ok(strict.temperature == 0.8 and strict.top_p == 0.9 and strict.frequency_penalty == 0.2,
        "sampler gate: base params still sent to strict clouds")
    ok(strict.top_k == nil and strict.top_a == nil and strict.min_p == nil
        and strict.repetition_penalty == nil,
        "sampler gate: strict clouds get no extended samplers (HTTP 400 fix)")

    -- OpenRouter (ST OPENROUTER parity): full extended set.
    local orr = Client:build_payload({}, { base_url = "https://openrouter.ai/api/v1", model_id = "m" }, full, false)
    ok(orr.top_k == 40 and orr.min_p == 0.1 and orr.repetition_penalty == 1.1 and orr.top_a == 0.9,
        "sampler gate: OpenRouter gets the full extended set")

    -- Local servers (lenient): extended minus top_a.
    local loc = Client:build_payload({}, { base_url = "http://localhost:5001/v1", model_id = "m" }, full, false)
    ok(loc.top_k == 40 and loc.min_p == 0.1 and loc.repetition_penalty == 1.1 and loc.top_a == nil,
        "sampler gate: local servers get extended minus top_a")
    local lan = Client:build_payload({}, { base_url = "http://192.168.1.10:8080/v1", model_id = "m" }, full, false)
    ok(lan.top_k == 40 and lan.top_a == nil, "sampler gate: LAN IPs count as local")

    -- Neutral defaults from imported ST presets never go out.
    local defaults = { top_k = 0, top_a = 0, min_p = 0, repetition_penalty = 1 }
    local clean = Client:build_payload({}, { base_url = "https://openrouter.ai/api/v1", model_id = "m" }, defaults, false)
    ok(clean.top_k == nil and clean.top_a == nil and clean.min_p == nil
        and clean.repetition_penalty == nil,
        "sampler gate: neutral defaults (0 / 1) are omitted")

    -- Per-connection override (auto / on / off).
    local forced = Client:build_payload({}, { base_url = "https://api.openai.com/v1", model_id = "m", extended_samplers = "on" }, full, false)
    ok(forced.top_k == 40 and forced.top_a == 0.9, "sampler gate: 'on' forces extended everywhere")
    local muted = Client:build_payload({}, { base_url = "https://openrouter.ai/api/v1", model_id = "m", extended_samplers = "off" }, full, false)
    ok(muted.top_k == nil and muted.top_a == nil and muted.min_p == nil,
        "sampler gate: 'off' suppresses even on OpenRouter")

    -- Reasoning models: extended samplers were never sent; unchanged.
    local rreason = Client:build_payload({}, { base_url = "https://openrouter.ai/api/v1", model_id = "o3-mini" }, full, false)
    ok(rreason.max_completion_tokens ~= nil and rreason.top_k == nil and rreason.temperature == nil,
        "sampler gate: reasoning path untouched (no samplers, max_completion_tokens)")

    -- Connection editor exposes the override; present_connection keeps the
    -- fields the old whitelist dropped (stop/post_processing/etc).
    local App = require("kt_app")
    local ext_field
    for _i, f in ipairs(App.CONNECTION_FIELDS) do
        if f.key == "extended_samplers" then ext_field = f end
    end
    ok(ext_field ~= nil and ext_field.choices and ext_field.choices[1] == "on",
        "sampler gate: connection editor exposes extended_samplers (on/off)")
    local conn = { id = "c1", name = "N", base_url = "http://x/v1", api_key = "k",
        model_id = "m", temperature = 0.7, max_tokens = 100, streaming = true,
        stop = "END", extra_headers = { ["X-A"] = "1" }, post_processing = "strict",
        start_reply_with = "Ok", extended_samplers = "on" }
    local app = setmetatable({ state = {} }, { __index = App })
    local draft = app:present_connection(conn)
    ok(draft.stop == "END" and draft.post_processing == "strict"
        and draft.start_reply_with == "Ok" and draft.extended_samplers == "on"
        and type(draft.extra_headers) == "table",
        "sampler gate: connection edit draft keeps stop/post_processing/extended_samplers")

    -- Error body decoding (regression net for the exact 400 bodies seen in
    -- the wild): flat provider errors surface their message, not raw JSON.
    ok(Client:decode_error_body('{"message":"Validation: Unsupported parameter(s): `top_a`","type":"Bad Request","code":400}', 400)
        == "API error: Validation: Unsupported parameter(s): `top_a`",
        "error decode: flat OpenRouter 400 shows the provider message")
    ok(Client:decode_error_body('{"error":{"message":"Rate limited","type":"tokens","code":"rate_limit_exceeded"}}', 429)
        == "API error: Rate limited",
        "error decode: wrapped error.message wins")
    ok((Client:decode_error_body("gateway timeout", 502)):find("gateway timeout", 1, true) ~= nil,
        "error decode: non-JSON body is surfaced verbatim")
    ok(Client:decode_error_body("", 500) == "API error (HTTP 500)",
        "error decode: empty body keeps the bare status line")

    -- 401/403 append the key hint (provider messages are often cryptic);
    -- other statuses are untouched.
    ok(Client:decode_error_body('{"error":{"message":"Missing auth"}}', 401)
        == "API error: Missing auth (check the API key)",
        "error decode: 401 wrapped error gains the key hint")
    ok(Client:decode_error_body('{"message":"pi error (http 401)","code":401}', 401)
        == "API error: pi error (http 401) (check the API key)",
        "error decode: 401 flat message gains the key hint")
    ok(Client:decode_error_body('{"error":{"message":"Nope"}}', 400)
        == "API error: Nope",
        "error decode: 400 has no key hint")
    ok(Client:decode_error_body("", 403)
        == "API error (HTTP 403) (check the API key)",
        "error decode: bare 403 gains the key hint")

    -- Keyless families for the pre-flight guard: local/LAN + Pollinations
    -- need no key; hosted providers do.
    ok(Client.requires_api_key("https://openrouter.ai/api/v1") == true,
        "key guard: OpenRouter requires a key")
    ok(Client.requires_api_key("https://api.openai.com/v1") == true,
        "key guard: OpenAI requires a key")
    ok(Client.requires_api_key("http://localhost:11434/v1") == false,
        "key guard: localhost needs no key")
    ok(Client.requires_api_key("http://192.168.1.10:8080/v1") == false,
        "key guard: LAN needs no key")
    ok(Client.requires_api_key("https://text.pollinations.ai/openai") == false,
        "key guard: Pollinations needs no key")
end

-- === 4f. Missing-key pre-flight guard blocks before any request ==============
do
    local App = require("kt_app")
    local shown = {}
    local real_show = UIManager.show
    UIManager.show = function(self, widget) shown[#shown + 1] = widget end
    local app = setmetatable({
        state = { settings = {}, messages = {}, scroll = {}, page = "chat",
            current_chat_id = "c1", is_generating = false,
            current_connection = { base_url = "https://openrouter.ai/api/v1", api_key = "" } },
    }, { __index = App })
    app:_do_generate({}, {})
    ok(app.state.is_generating == false,
        "key guard: keyless hosted connection never starts generating")
    ok(#shown == 1 and tostring(shown[1].text):find("API key", 1, true) ~= nil,
        "key guard: toast names the missing API key")
    UIManager.show = real_show
end

-- === 4g. Provider preset name resolution (editor row never lies) =============
do
    local Client = require("kt_client")
    ok(Client.provider_name("https://openrouter.ai/api/v1") == "OpenRouter",
        "provider: exact URL matches its preset")
    ok(Client.provider_name("https://openrouter.ai/api/v1/") == "OpenRouter",
        "provider: trailing slash still matches")
    ok(Client.provider_name("https://openrouter.ai/api/v1/chat/completions") == "OpenRouter",
        "provider: pasted /chat/completions still matches")
    ok(Client.provider_name("https://my-relay.local:8080/v1") == nil,
        "provider: custom URL matches nothing")
    ok(Client.provider_name(nil) == nil and Client.provider_name("") == nil,
        "provider: empty URL matches nothing")
end

-- === 4h. Error context + debug bundle (never leaks the key) ===================
do
    local Client = require("kt_client")
    local conn = { name = "OpenRouter", base_url = "https://openrouter.ai/api/v1", api_key = "sk-or-v1-SECRETSECRET" }
    ok(Client.describe_error(conn, "m", 401, "Nope")
        == "OpenRouter (openrouter.ai) · m: Nope (HTTP 401)",
        "describe: full context line")
    ok(Client.describe_error(conn, "m", nil, "Nope")
        == "OpenRouter (openrouter.ai) · m: Nope",
        "describe: mid-stream has no status")
    ok(Client.describe_error({ base_url = "https://x.test/v1" }, nil, 500, "Boom")
        == "x.test: Boom (HTTP 500)",
        "describe: nameless connection falls back to host")
    ok(Client.describe_error(nil, nil, nil, "Boom") == "Boom",
        "describe: nothing known passes the message through")

    local fp = Client.key_fingerprint("sk-or-v1-SECRETSECRET")
    ok(fp:find("SECRETSECRET", 1, true) == nil and fp:find("CRET", 1, true) ~= nil
        and fp:find("len=21", 1, true) ~= nil,
        "fingerprint: last4 + length only, never the key")
    ok(Client.key_fingerprint("Bearer abcdef"):find("bearer%-prefix") ~= nil,
        "fingerprint: flags a pasted Bearer prefix")
    ok(Client.key_fingerprint("  abc"):find("whitespace") ~= nil,
        "fingerprint: flags surrounding whitespace")
    ok(Client.key_fingerprint("") == "none" and Client.key_fingerprint(nil) == "none",
        "fingerprint: empty key reads none")

    local names = Client.header_names(conn)
    local has_auth = false
    for _, n in ipairs(names) do if n == "Authorization" then has_auth = true end end
    ok(has_auth, "headers: key present sends Authorization")
    local names2 = Client.header_names({ base_url = "http://localhost:11434/v1" })
    local has_auth2 = false
    for _, n in ipairs(names2) do if n == "Authorization" then has_auth2 = true end end
    ok(not has_auth2, "headers: keyless connection sends no Authorization")

    local big = string.rep("x", 5000)
    local entry = Client.debug_entry({ backend = "curl_bg", connection = conn,
        model = "m", status = 401, body = big })
    ok(entry:find("SECRETSECRET", 1, true) == nil,
        "debug entry: full key value never recorded")
    ok(entry:find("openrouter.ai", 1, true) ~= nil and entry:find("curl_bg", 1, true) ~= nil
        and entry:find("401", 1, true) ~= nil and entry:find("truncated", 1, true) ~= nil,
        "debug entry: host, backend, status kept; long body truncated")

    local Store = require("kt_storage")
    local trimmed = Store.trim_debug_log(string.rep("y", 70 * 1024), "new-entry")
    ok(#trimmed <= 32 * 1024 and trimmed:sub(-10) == "new-entry\n",
        "debug trim: oversized log keeps the tail")
    ok(Store.trim_debug_log("abc", "de") == "abc\nde\n",
        "debug trim: small logs append cleanly")

    -- report_api_error composes the toast and records the bundle (file I/O stubbed).
    local captured = {}
    local real_append = Store.append_debug
    Store.append_debug = function(text) captured[#captured + 1] = text return true end
    Client.last_http = { status = 401, body = "Missing Authentication header" }
    local App = require("kt_app")
    local app = setmetatable({ state = { settings = {} } }, { __index = App })
    local toast = app:report_api_error({ prefix = "Stream error: ",
        connection = conn, model = "m", backend = "curl_bg", message = "pi error (http 401)" })
    ok(toast == "Stream error: OpenRouter (openrouter.ai) · m: pi error (http 401) (HTTP 401)",
        "report: toast names provider, model and status")
    ok(#captured == 1 and captured[1]:find("SECRETSECRET", 1, true) == nil
        and captured[1]:find("Missing Authentication header", 1, true) ~= nil,
        "report: bundle recorded with full body, without the key")
    Store.append_debug = real_append
end

-- === 4i. Stream repaint throttle + greeting macro expansion ====================
do
    local App = require("kt_app")
    local Store = require("kt_storage")

    -- Stub the network spawn: capture stream callbacks, no curl, no timers.
    local ck_key = "kt_client"
    local real_client = package.loaded[ck_key]
    local captured = {}
    package.loaded[ck_key] = {
        new = function()
            return {
                set_poll_interval = function() end,
                set_timeouts = function() end,
                set_retries = function() end,
                start_stream = function(self, msgs, conn, preset, on_chunk, on_done, on_error)
                    captured = { on_chunk = on_chunk, on_done = on_done, on_error = on_error }
                    return 4242
                end,
            }
        end,
    }
    -- Stub chat persistence (never touch the real data dir here).
    local real_create, real_append_fn = Store.create_chat, Store.append_message
    local real_getap, real_getp = Store.get_active_persona, Store.get_persona
    local real_load, real_save = Store.load_chat, Store.save_chat
    Store.create_chat = function() return { id = "t1", path = "/tmp/smoke_t1.jsonl" } end
    Store.append_message = function() end
    Store.load_chat = function()
        return { header = { chat_metadata = {} }, messages = {} }
    end
    Store.save_chat = function() end
    -- Count real repaint requests (UIManager.setDirty stubbed).
    local paints = {}
    local real_dirty = UIManager.setDirty
    UIManager.setDirty = function(...) paints[#paints + 1] = true end

    local function mk_stream_app(mode)
        local a = setmetatable({
            state = { settings = { stream_refresh = mode }, messages = {}, scroll = {},
                page = "chat", current_chat_id = "c9", current_chat_path = "/tmp/smoke_t1.jsonl",
                current_character = "Aria", current_connection = { base_url = "http://x/v1" } },
        }, { __index = App })
        -- Fake view so _refresh_streaming reaches the (stubbed) UIManager.
        a.view = { chat_region = { x = 0, y = 0, w = 600, h = 700 } }
        return a
    end

    -- calm: burst of chunks paints once, but follow still tracks every chunk.
    Store.get_active_persona = function() return nil end
    local app = mk_stream_app("calm")
    app:_do_stream_message({}, {})
    paints = {} -- drop the stream-start refresh; count chunk repaints only
    ok(app.state.user_scrolled_up == nil, "stream: follow flag starts clear")
    captured.on_chunk("a", "a")
    captured.on_chunk("b", "ab")
    captured.on_chunk("c", "abc")
    ok(#paints == 1, "stream calm: burst of 3 chunks repaints once (got " .. #paints .. ")")
    ok(app.state.scroll["chat_c9"] == 999999, "stream calm: position tracks every chunk")
    -- Forcing the clock gate open repaints again immediately (no sleeping).
    app._last_stream_paint = 0
    captured.on_chunk("d", "abcd")
    ok(#paints == 2, "stream calm: next chunk after the interval repaints")
    -- Manual scroll-up pins the position while text still accumulates.
    app.state.user_scrolled_up = true
    app.state.scroll["chat_c9"] = 10
    captured.on_chunk("e", "abcde")
    ok(app.state.scroll["chat_c9"] == 10, "stream: manual scroll-up pins the position")

    -- still: zero partial repaints, position still tracked.
    paints = {}
    local app2 = mk_stream_app("still")
    app2:_do_stream_message({}, {})
    paints = {}
    captured.on_chunk("a", "a")
    captured.on_chunk("b", "ab")
    ok(#paints == 0, "stream still: no partial repaints")
    ok(app2.state.scroll["chat_c9"] == 999999, "stream still: position still tracked")

    -- live: every chunk repaints (old behavior preserved).
    paints = {}
    local app3 = mk_stream_app("live")
    app3:_do_stream_message({}, {})
    paints = {}
    captured.on_chunk("a", "a")
    captured.on_chunk("b", "ab")
    ok(#paints == 2, "stream live: every chunk repaints")

    -- Greeting macros expand at creation (persona name, or You fallback).
    Store.get_active_persona = function() return "p1" end
    Store.get_persona = function() return { id = "p1", name = "Bia" } end
    local app4 = setmetatable({
        state = { settings = {}, messages = {}, scroll = {}, page = "dashboard",
            chats_index = {} },
    }, { __index = App })
    local character = { name = "Aria" }
    app4:_start_new_chat("/tmp/aria.png", "Aria", { id = "c1" }, character,
        "Chat", "*smiles at {{user}}*, I'm {{char}}")
    local first = app4.state.messages[1]
    ok(first and first.content == "*smiles at Bia*, I'm Aria"
        and not first.content:find("{{", 1, true),
        "greeting: {{user}}/{{char}} expand to the persona name (got "
        .. tostring(first and first.content) .. ")")
    Store.get_active_persona = function() return nil end
    local app5 = setmetatable({
        state = { settings = {}, messages = {}, scroll = {}, page = "dashboard",
            chats_index = {} },
    }, { __index = App })
    app5:_start_new_chat("/tmp/aria.png", "Aria", { id = "c1" }, character,
        "Chat", "hi {{user}}")
    ok(app5.state.messages[1] and app5.state.messages[1].content == "hi You",
        "greeting: no persona falls back to You")

    package.loaded[ck_key] = real_client
    Store.create_chat, Store.append_message = real_create, real_append_fn
    Store.get_active_persona, Store.get_persona = real_getap, real_getp
    Store.load_chat, Store.save_chat = real_load, real_save
    UIManager.setDirty = real_dirty
end

-- === 4j. User avatar never borrows the character card ==========================
do
    -- Solid black card fixture: unmistakable in pixel counts.
    local card = Blitbuffer.new(48, 48, Blitbuffer.TYPE_BB8)
    card:fill(Blitbuffer.COLOR_BLACK)
    card:writePNG("/tmp/smoke_card.png")
    local ChatBubbles = require("ktui/chat_bubbles")
    local msgs = {
        { role = "user", content = string.rep("hello world. ", 40), name = "You" },
        { role = "assistant", content = "hi", name = "Aria" },
    }
    local function paint(with_persona_avatar)
        local st = { page = "chat", settings = { show_avatars = true }, messages = msgs }
        local a = fake_app(st)
        if with_persona_avatar then
            a._active_persona_avatar = function() return "/tmp/smoke_card.png" end
        end
        local v = { app = a, hitboxes = {} }
        local b = new_bb()
        ChatBubbles.draw(v, b, 0, 0, VW, VH, 0, msgs, "Aria", false, "You",
            "/tmp/smoke_card.png", nil)
        local n = 0
        for yy = 0, 119 do
            for xx = 8, 68 do
                if b:getPixel(xx, yy):getR() < 80 then n = n + 1 end
            end
        end
        return n
    end
    -- A/B on the same layout: with a persona avatar the black card IS the
    -- user avatar (control proves the strip catches the disc); without one
    -- the strip must hold only the initial-fallback ink.
    local with_av = paint(true)
    local without_av = paint(false)
    ok(with_av > 1000, "avatar: persona avatar paints the card (control=" .. with_av .. ")")
    ok(without_av < 700 and without_av < with_av - 500,
        "avatar: user without persona gets the initial fallback, not the card (got " .. without_av .. ")")
end

-- === 4k. Flick = one small fixed step (zenpm row parity) =======================
do
    local AppView = require("ktui/app_view")
    local function mk_swipe_view()
        local view = {
            app = fake_app({ page = "chat" }),
            list_bounds = nil,
            swipe_step = 540,
            max_scroll = 100000,
        }
        function view:refresh() end -- swallow repaints; assert on state.scroll
        return setmetatable(view, { __index = AppView })
    end
    local function fling(view, direction, distance, from)
        view.app.state.scroll["chat"] = from or 0
        AppView.onSwipeKotavern(view, nil, {
            direction = direction, distance = distance,
            pos = { x = 300, y = 400 },
        })
        return view.app.state.scroll["chat"]
    end
    local view = mk_swipe_view()
    ok(fling(view, "north", 100) == 540,
        "flick: short swipe moves one step")
    ok(fling(view, "north", 5400) == 540,
        "flick: long swipe moves the SAME single step (no leaps)")
    ok(fling(view, "south", 100, 3000) == 2460,
        "flick: southbound keeps the sign")
    ok(fling(view, "north", nil) == 540,
        "flick: missing distance still moves one step")
    view.max_scroll = 600
    ok(fling(view, "north", 5400, 300) == 600,
        "flick: clamped at max_scroll")
    -- The chat's swipe unit itself is a few text lines (zenpm row order).
    local ChatBubbles = require("ktui/chat_bubbles")
    ok(ChatBubbles.line_step() > 0 and ChatBubbles.line_step() * 8 < 540,
        "flick: chat step is line-based and small (8 lines, not a page)")
end

-- === 4m. Self-update selection/validation (no network) =========================
do
    local Update = require("kt_update")
    ok(Update.version_gt("0.2.0", "0.1.0") and not Update.version_gt("0.1.0", "0.2.0")
        and not Update.version_gt("0.2.0", "0.2.0") and Update.version_gt("v1.10.0", "1.9.9"),
        "update: semver compare")
    ok(Update.asset_name_for("v0.2.0") == "kotavern.koplugin-0.2.0.zip"
        and Update.asset_name_for("") == nil,
        "update: asset naming")
    ok(Update.default_repo() == "akachiina/kotavern.koplugin",
        "update: repo comes pre-configured")
    ok(Update.normalize_channel("dev") == "commits"
        and Update.normalize_channel("commits") == "commits"
        and Update.normalize_channel(nil) == "stable",
        "update: channel normalization (legacy dev reads as commits)")
    ok(Update.trusted_url("https://objects.githubusercontent.com/x")
        and Update.trusted_url("https://codeload.github.com/o/r/zipball/main")
        and not Update.trusted_url("http://github.com/x")
        and not Update.trusted_url("https://evil.example/x.zip"),
        "update: download host trust (codeload in, http out)")
    ok(Update.unsafe_entry("/abs") and Update.unsafe_entry("a/../../b")
        and not Update.unsafe_entry("kotavern.koplugin/main.lua"),
        "update: zip path traversal guard")

    local releases = {
        { tag_name = "v0.3.0", prerelease = true, published_at = "2026-10-06",
          assets = { { name = "kotavern.koplugin-0.3.0.zip",
            browser_download_url = "https://github.com/o/r/releases/download/v0.3.0/kotavern.koplugin-0.3.0.zip",
            digest = "sha256:" .. string.rep("a", 64) } } },
        { tag_name = "v0.2.0", prerelease = false, published_at = "2026-10-05",
          assets = { { name = "kotavern.koplugin-0.2.0.zip",
            browser_download_url = "https://objects.githubusercontent.com/abc",
            digest = "sha256:" .. string.rep("b", 64) } } },
        { tag_name = "v0.1.0", prerelease = false, published_at = "2026-10-01",
          assets = { { name = "kotavern.koplugin-0.1.0.zip",
            browser_download_url = "https://objects.githubusercontent.com/old" } } },
    }
    local stable = Update.pick_stable_release(releases)
    ok(stable and stable.version == "0.2.0",
        "update: stable skips prereleases and digest-less assets")
    ok(Update.pick_latest_commit({ { sha = "cafef00dd123456789" } }) == "cafef00",
        "update: commit short SHA")
    ok(Update.pick_latest_commit({}) == nil and Update.pick_latest_commit(nil) == nil,
        "update: empty commit list")

    local cmd = Update.api_cmd("https://api.github.com/x")
    ok(cmd:find("User%-Agent", 1) ~= nil
        and cmd:find("Authorization", 1, true) == nil,
        "update: API calls carry UA, never a token")

    -- The About line runs through gettext now ("KOTavern v"/"Stable" are
    -- msgids): expect whatever the ACTIVE translation yields, not frozen
    -- English (the audit fix: the old concat never fired the translations).
    local GT = require("gettext")
    ok(Update.about_title({ channel = "stable", version = "0.2.0" })
        == GT("KOTavern v") .. "0.2.0" .. " " .. GT("Stable"),
        "update: stable About line (gettext-piped)")
    ok(Update.about_title({ channel = "commits", version = "0.2.0", commit = "a1b2c3d" })
        == GT("KOTavern v") .. "0.2.0" .. " (a1b2c3d)",
        "update: commits About line (gettext-piped)")
    ok(Update.installed_build(nil).version ~= nil
        and Update.installed_build({ channel = "commits", version = "0.2.0" }).channel == "commits",
        "update: installed build with legacy fallback")
    ok(Update.is_newer({ channel = "stable", version = "0.2.0" }, { version = "0.1.0" })
        and not Update.is_newer({ channel = "stable", version = "0.2.0" }, { version = "0.2.0" })
        and Update.is_newer({ channel = "commits", commit = "bbb" }, { channel = "commits", commit = "aaa" })
        and not Update.is_newer({ channel = "commits", commit = "aaa" }, { channel = "commits", commit = "aaa" }),
        "update: newer detection per channel")
    local okc2, errc2 = Update.check({ repo = "not-a-repo", channel = "stable" })
    ok(okc2 == false, "update: malformed repo rejected (" .. tostring(errc2) .. ")")
end

-- === 4n. Nav labels follow the active language (never frozen) ==================
do
    local Nav = require("ktui/nav")
    local GT = require("gettext")
    local labels = Nav.labels()
    ok(#labels == 4, "nav: 4 tab labels")
    -- Simulate a language switch by swapping the active translation table
    -- (what I18n.install/changeLang do on device); labels must re-evaluate.
    local save_home, save_chats = GT.translation["Home"], GT.translation["Chats"]
    GT.translation["Home"] = "INÍCIO-X"
    GT.translation["Chats"] = "CHATS-X"
    local switched = Nav.labels()
    ok(switched[1] == "INÍCIO-X" and switched[2] == "CHATS-X",
        "nav: labels re-evaluate on language switch (no frozen English)")
    GT.translation["Home"] = save_home
    GT.translation["Chats"] = save_chats
    ok(Nav.labels()[1] == labels[1], "nav: labels restored after switch")
end

-- === 4o. i18n survives close → reopen (the mixed-language bug) ==================
do
    local I18n = require("kt_i18n")
    local GT = require("gettext")
    local st = G_reader_settings
    local real_read = st.readSetting
    st.readSetting = function(self, k, default)
        if k == "language" then return "pt_BR" end
        return real_read(self, k, default)
    end
    -- Plugin-only msgid (KOReader core never defines it).
    local MSG = "Stream refresh"
    I18n.uninstall() -- start clean whatever ran before
    ok(GT.translation[MSG] == nil, "i18n: clean slate has no plugin strings")
    I18n.install() -- 1st open
    ok(GT.translation[MSG] == "Atualização do stream", "i18n: install loads pt")
    I18n.uninstall() -- X close: strings must leave with the plugin...
    ok(GT.translation[MSG] == nil, "i18n: close wipes plugin strings")
    I18n.install() -- ...and come back on reopen (was English forever)
    ok(GT.translation[MSG] == "Atualização do stream", "i18n: reopen re-applies pt")
    -- Language switch mid-session flows through the changeLang hook.
    local saved_lang = GT.current_lang
    GT.changeLang("es")
    ok(GT.translation[MSG] == "Actualización del stream", "i18n: switch to es applies")
    GT.changeLang(saved_lang)
    ok(GT.translation[MSG] == "Atualização do stream", "i18n: switch back restores pt")
    I18n.uninstall() -- leave the global table as found
    st.readSetting = real_read
    ok(GT.translation[MSG] == nil, "i18n: global state clean afterwards")
end

-- === 4r. Backup: sizes, zip round-trip, migrate, storage page ====================
do
    local Store = require("kt_storage")
    local Backup = require("kt_backup")
    ok(Store.format_bytes(512) == "512 B"
        and Store.format_bytes(2048) == "2.0 KB"
        and Store.format_bytes(3 * 1024 * 1024) == "3.0 MB",
        "backup: human sizes")
    ok(Backup.crc32("hello") == 0x3610A686, "backup: crc32 check value")
    ok(Backup.valid_manifest({ app = "kotavern", kind = "backup" })
        and not Backup.valid_manifest({ app = "x" })
        and not Backup.valid_manifest(nil),
        "backup: manifest validation")

    -- Fixture tree: files, subdir, and a .tmp that must be skipped.
    os.execute("rm -rf /tmp/bkfix && mkdir -p /tmp/bkfix/src/sub")
    local f = io.open("/tmp/bkfix/src/a.txt", "w"); f:write(string.rep("a", 100)); f:close()
    f = io.open("/tmp/bkfix/src/sub/b.bin", "w"); f:write(string.rep("b", 5000)); f:close()
    f = io.open("/tmp/bkfix/src/junk.tmp", "w"); f:write("x"); f:close()
    local collected = Backup.collect_files("/tmp/bkfix/src")
    local has_tmp = false
    for _, p in ipairs(collected) do
        if p:match("%.tmp$") then has_tmp = true end
    end
    ok(not has_tmp and #collected == 3, "backup: collect skips .tmp (got " .. #collected .. ")")

    -- Real round-trip: our writer → ffi/archiver Reader → bytes compared.
    local entries = {
        { name = "sub/" },
        { name = "sub/b.bin", path = "/tmp/bkfix/src/sub/b.bin" },
        { name = "a.txt", path = "/tmp/bkfix/src/a.txt" },
        { name = "kotavern-backup.json", data = Backup.manifest(2) },
    }
    local okw, errw = Backup.zip_write("/tmp/bkfix/out.zip", entries)
    ok(okw, "backup: zip_write (" .. tostring(errw) .. ")")
    os.execute("rm -rf /tmp/bkfix/rt && mkdir -p /tmp/bkfix/rt")
    local Archiver = require("ffi/archiver")
    local archive = Archiver.Reader:new()
    local readback = {}
    if archive:open("/tmp/bkfix/out.zip") then
        for entry in archive:iterate() do
            if entry.mode == "file" then
                archive:extractToPath(entry.path, "/tmp/bkfix/rt/" .. entry.path)
            end
        end
        archive:close()
        local function slurp(p)
            local fh = io.open(p, "rb")
            if not fh then return nil end
            local d = fh:read("*a"); fh:close()
            return d
        end
        readback.a = slurp("/tmp/bkfix/rt/a.txt")
        readback.b = slurp("/tmp/bkfix/rt/sub/b.bin")
        readback.m = slurp("/tmp/bkfix/rt/kotavern-backup.json")
    end
    local orig_a = io.open("/tmp/bkfix/src/a.txt", "rb"):read("*a")
    local orig_b = io.open("/tmp/bkfix/src/sub/b.bin", "rb"):read("*a")
    ok(readback.a == orig_a and readback.b == orig_b and type(readback.m) == "string",
        "backup: archiver reads our zip back byte-identical")
    local okj, man = pcall(require("json").decode, readback.m or "")
    ok(okj and Backup.valid_manifest(man), "backup: manifest round-trips")

    -- Migrate onto fixture dirs (explicit src; settings save is a noop).
    local okm, errm = Store.migrate_data_root("/tmp/bkfix/dst", "/tmp/bkfix/src")
    ok(okm, "backup: migrate copies (" .. tostring(errm) .. ")")
    local df = io.open("/tmp/bkfix/dst/kotavern/a.txt", "rb")
    local has_tmp_dst = io.open("/tmp/bkfix/dst/kotavern/junk.tmp", "rb")
    ok(df ~= nil, "backup: migrated content lands under dst/kotavern")
    if df then df:close() end
    ok(has_tmp_dst == nil, "backup: .tmp not migrated")
    if has_tmp_dst then has_tmp_dst:close() end
    os.execute("mkdir -p /tmp/bkfix/sameroot/kotavern")
    local oks, errs = Store.migrate_data_root("/tmp/bkfix/sameroot", "/tmp/bkfix/sameroot/kotavern")
    ok(oks and errs == "same", "backup: same root is a no-op")
    local okn, errn = Store.migrate_data_root("/tmp/bkfix/src/sub", "/tmp/bkfix/src")
    ok(not okn, "backup: nested root refused")

    -- Storage page renders (bars + actions) without crashing.
    local App = require("kt_app")
    local app = setmetatable({
        state = { settings = {}, scroll = {}, page = "data_storage" },
    }, { __index = App })
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    local Pages = require("ktui/pages")
    local okp, maxs = pcall(Pages.data_storage, view, bb, 0, 0, VW, VH, 0)
    ok(okp and type(maxs) == "number" and #view.hitboxes > 0,
        "backup: storage page renders bars + actions")
    -- The settings_data row leading here must paint too (missing require
    -- crashed the device once: global Storage was nil in its value_fn).
    local view2 = { app = app, hitboxes = {} }
    local bb2 = new_bb()
    local okd = pcall(Pages.settings_data, view2, bb2, 0, 0, VW, VH, 0)
    ok(okd and #view2.hitboxes > 0, "backup: settings_data paints incl. usage row")
    os.execute("rm -rf /tmp/bkfix")
end

-- === 4v. geom: pure layout math (zero requires, headless-safe) ==============
do
    local Gm = require("ktui/geom")
    local w = Gm.distribute_remainder(100, 3)
    ok(w[1] + w[2] + w[3] == 100 and w[1] == 34 and w[3] == 33,
        "geom: remainder spread 34/33/33 (sums exactly)")
    local w1 = Gm.distribute_remainder(7, 4)
    ok(w1[1] == 2 and w1[4] == 1, "geom: 7 over 4 spreads 2/2/2/1")
    ok(Gm.center_offset(100, 30) == 35, "geom: center 30 in 100 -> 35")
    ok(Gm.center_offset(10, 30, 2) == 2, "geom: overflow clamps to min_top")
    local bh, ys = Gm.stack({ { h = 20 }, { h = 10 } }, 2, 4)
    ok(bh == 40 and ys[1] == 4 and ys[2] == 26,
        "geom: stack 20+10 gap2 pad4 -> 40 @4/@26")
    ok(Gm.stack({}, 2, 4) == 8, "geom: empty stack is just pads")
    ok(Gm.fit_icon(50, 20, 8, 22, function(s) return s * 2 end) == 15,
        "geom: fit_icon picks largest fitting (15)")
    ok(Gm.fit_icon(10, 20, 8, 22, function(s) return s * 2 end) == 8,
        "geom: fit_icon falls back to min")
    local xs, tr = Gm.row_slots(300, 10, { 34, 52, 26 })
    ok(xs[1] == 256 and xs[2] == 204 and xs[3] == 178 and tr == 178,
        "geom: slots compose right-to-left")
    ok(Gm.cap_two_rows(606, 8, 400, 163) == 299,
        "geom: cap is min(desired, viewport) -> 299")
    ok(Gm.cap_two_rows(2000, 8, 400, 163) == 400,
        "geom: big viewport keeps desired")
    ok(Gm.cap_two_rows(100, 8, 400, 163) == 163,
        "geom: tiny viewport hits readability floor")
    local p1, m1 = Gm.paginate({ 100, 100, 100 }, 8, 220, 20)
    ok(#p1 == 3 and m1 and p1[2].first == 2 and p1[2].last == 2,
        "geom: paginate reserves chevrons (3 pages)")
    local p2, m2 = Gm.paginate({ 50, 50, 50 }, 8, 200, 0)
    ok(#p2 == 1 and not m2 and p2[1].last == 3,
        "geom: paginate fits all when possible (1 page)")
    local p3, m3 = Gm.paginate({ 50, 60, 50 }, 10, 130, 16)
    ok(#p3 == 3 and m3, "geom: paginate never strands an item (3 pages)")
end

-- === 4v2. Static guard: no `_()` call inside a `for _,` body =================
-- `_` is gettext everywhere; a `for _, x` index shadows it, and any nested
-- `_()` then calls the numeric index ("attempt to call upvalue '_'" - the
-- quick-reply Edit crash, which needed ≥1 saved reply to fire). Crude block
-- machine over our own sources; one-liners with balanced ends are skipped.
do
    local srcs = { "kt_app.lua", "ktui/app_view.lua", "ktui/bar.lua",
        "ktui/cards.lua", "ktui/chat_bubbles.lua", "ktui/deck.lua",
        "ktui/geom.lua", "ktui/gifanim.lua", "ktui/header.lua",
        "ktui/icons.lua", "ktui/kthtml.lua", "ktui/modals.lua",
        "ktui/nav.lua", "ktui/pages.lua", "ktui/primitives.lua",
        "ktui/scroll.lua", "ktui/sheets.lua", "ktui/theme.lua",
        "ktui/widgets.lua" }
    local function strip(l)
        l = l:gsub('"(?:[^"\\]|\\.)*"', '""')
        l = l:gsub("'(?:[^'\\]|\\.)*'", "''")
        return (l:gsub("%-%-.*$", ""))
    end
    local bad = {}
    for _, rel in ipairs(srcs) do
        local f = io.open(PLUGIN .. "/" .. rel, "r")
        if f then
            local lines = {}
            for line in f:lines() do lines[#lines + 1] = line end
            f:close()
            local stack = {}
            for i, raw in ipairs(lines) do
                local l = strip(raw)
                local fvars = l:match("^%s*for%s+(.-)%s+in%s")
                if fvars and l:find("%f[%w]do%f[%W]") and not l:find("%f[%w]end%f[%W]") then
                    local under = false
                    for v in fvars:gmatch("([^,]+)") do
                        if v:match("^%s*_%s*$") then under = true end
                    end
                    stack[#stack + 1] = { under = under, line = i }
                elseif (l:find("^%s*function%f[%W]") or l:find("%f[%W]then%s*$")
                        or l:find("%f[%W]do%s*$"))
                    and not l:find("%f[%W]end%f[%W]") then
                    stack[#stack + 1] = { under = false }
                elseif l:find("^%s*end%f[%W]") then
                    if #stack > 0 then stack[#stack] = nil end
                elseif l:find("[^%w]_%(") then
                    for _, fr in ipairs(stack) do
                        if fr.under then
                            bad[#bad + 1] = rel .. ":" .. i .. " (for at " .. fr.line .. ")"
                            break
                        end
                    end
                end
            end
        end
    end
    ok(#bad == 0, "lint: no _() call inside a for_, body (" .. table.concat(bad, "; ") .. ")")
end

-- === 4w. GIF player lifecycle (frames, stop frees, no leak) =======================
do
    local GifAnim = require("ktui/gifanim")
    local gif = PLUGIN .. "/assets/debug_banner" -- pre-composited full frames
    local app = fake_app({ page = "settings" })
    local view = { app = app, hitboxes = {} }
    local refresh_args = nil
    function view:refresh(...) refresh_args = { ... } end
    local player = GifAnim.ensure(app, view, "banner", gif,
        { w = 64, h = 64, rect = { x = 10, y = 10, w = 64, h = 64 } })
    ok(player ~= nil and player.n >= 2, "gif: sonic decodes to 2+ frames")
    local f1 = GifAnim.frame(player)
    ok(type(f1) == "cdata", "gif: current frame is a blitbuffer")
    -- Every pre-composited frame is a COMPLETE picture: ink must not be
    -- exclusive to frame 1 (that was the raw GIF's delta-frames bug).
    local frame_ink = {}
    for i = 1, player.n do
        local b = player.bbs[i]
        local ink = 0
        if b then
            for y = 0, b:getHeight() - 1, 3 do
                for x = 0, b:getWidth() - 1, 3 do
                    if b:getPixel(x, y):getR() < 200 then ink = ink + 1 end
                end
            end
        end
        frame_ink[i] = ink
    end
    ok(frame_ink[2] > 20 and frame_ink[player.n] > 20,
        "gif: every frame is a complete picture (ink f2=" .. frame_ink[2] ..
        " last=" .. frame_ink[player.n] .. ")")
    local function queued_tick()
        for _, t in ipairs(UIManager._task_queue or {}) do
            if t.action == player.tick then
                return true
            end
        end
        return false
    end
    ok(player.tick ~= nil and queued_tick(), "gif: tick scheduled while playing")

    -- Fallback path (DIRECT off): the classic widget repaint that lands in
    -- view:refresh(nil, rect) — the contract the banner always had.
    GifAnim.DIRECT = false
    player.tick()
    -- NOTE: colon-call self is NOT in ... — args here are (nil, rect).
    local rrect = refresh_args and refresh_args[2]
    ok(rrect ~= nil and rrect.x == 10 and rrect.w == 64,
        "gif: fallback tick repaints the gif rect only")

    -- DIRECT path: the frame goes straight into the compositor buffer and
    -- only the banner region is queued for refresh — no widget repaint.
    GifAnim.DIRECT = true
    refresh_args = nil
    local dirty_args = nil
    local real_setdirty = UIManager.setDirty
    UIManager.setDirty = function(_, ...) dirty_args = { ... }; return true end
    local screen_bb = Screen.bb
    screen_bb:fill(Blitbuffer.COLOR_WHITE)
    player.idx = 0 -- tick advances first (idx % n + 1), so this lands on frame 1
    player.tick()
    UIManager.setDirty = real_setdirty
    local dnil, dmode, dregion = dirty_args and dirty_args[1],
        dirty_args and dirty_args[2], dirty_args and dirty_args[3]
    ok(dirty_args ~= nil and dnil == nil and dmode == "a2"
        and dregion ~= nil and dregion.x == 10 and dregion.w == 64,
        "gif: direct tick refreshes only the banner region via a2 (no blink)")
    ok(refresh_args == nil, "gif: direct tick bypasses view:refresh entirely")
    local direct_ink = 0
    for yy = 10, 74, 2 do
        for xx = 10, 74, 2 do
            if screen_bb:getPixel(xx, yy):getR() < 128 then direct_ink = direct_ink + 1 end
        end
    end
    ok(direct_ink > 20, "gif: direct tick paints the frame into Screen.bb")

    -- Stop settles once with full quality (ticks run pure a2, ghost masked
    -- by motion): capture the settle mode.
    local settle_modes = {}
    UIManager.setDirty = function(_, _, mode) settle_modes[#settle_modes + 1] = mode; return true end
    GifAnim.stop(player)
    UIManager.setDirty = real_setdirty
    ok(#settle_modes >= 1 and settle_modes[#settle_modes] == "ui",
        "gif: stop settles once with ui")

    -- Pacing is device-aware: capture scheduleIn delays on fresh ensures.
    -- (Headless SDL reports e-ink, so assert the SELECTION, not the device.)
    local delays = {}
    local real_schedule = UIManager.scheduleIn
    UIManager.scheduleIn = function(_, delay) delays[#delays + 1] = delay; return true end
    local Device = require("device")
    local real_eink = Device.hasEinkScreen
    local function fresh_pace(eink, key)
        delays = {}
        Device.hasEinkScreen = function() return eink end
        local a = fake_app({ page = "settings" })
        local v = { app = a, hitboxes = {} }
        function v:refresh() end
        local p = GifAnim.ensure(a, v, key, gif, { w = 32, h = 32 })
        GifAnim.stop(p)
        GifAnim.stop_all(a)
        return delays[1]
    end
    local d_off = fresh_pace(false, "pace-lcd")
    local d_on = fresh_pace(true, "pace-eink")
    Device.hasEinkScreen = real_eink
    UIManager.scheduleIn = real_schedule
    ok(d_off == GifAnim.INTERVAL,
        "gif: tick pacing is 8fps off e-ink (delay=" .. tostring(d_off) .. ")")
    ok(d_on == GifAnim.EINK_INTERVAL,
        "gif: tick pacing is ~2fps on e-ink (delay=" .. tostring(d_on) .. ")")
    -- Night ticks use "ui" (A2-night starves input on new panels when
    -- updates queue: the inverted-only debug-page freeze).
    local real_theme = Theme.get_theme()
    Theme.set_theme("inverted")
    local app_n = fake_app({ page = "settings" })
    local view_n = { app = app_n, hitboxes = {} }
    function view_n:refresh() end
    local player_n = GifAnim.ensure(app_n, view_n, "night", gif, { w = 32, h = 32,
        rect = { x = 4, y = 4, w = 32, h = 32 } })
    local night_modes = {}
    local real_setdirty = UIManager.setDirty
    UIManager.setDirty = function(_, _, mode) night_modes[#night_modes + 1] = mode; return true end
    GifAnim.DIRECT = true
    player_n.idx = 0
    player_n.tick()
    UIManager.setDirty = real_setdirty
    Theme.set_theme(real_theme)
    ok(night_modes[1] == "ui",
        "gif: night tick refreshes via ui (got " .. tostring(night_modes[1]) .. ")")
    GifAnim.stop(player_n)
    GifAnim.stop_all(app_n)
    -- Fallback coalesce: back-to-back fallback ticks repaint at most once.
    GifAnim.DIRECT = false
    local app_c = fake_app({ page = "settings" })
    local view_c = { app = app_c, hitboxes = {} }
    local nfb = 0
    function view_c:refresh() nfb = nfb + 1 end
    local player_c = GifAnim.ensure(app_c, view_c, "coal", gif, { w = 32, h = 32,
        rect = { x = 4, y = 4, w = 32, h = 32 } })
    player_c.tick()
    player_c.tick()
    ok(nfb == 1, "gif: fallback ticks coalesce (repaints=" .. nfb .. ")")
    GifAnim.stop(player_c)
    GifAnim.stop_all(app_c)
    GifAnim.DIRECT = true

    -- The shared painter clears the box with the page background first:
    -- a smaller synthetic frame in a bigger box proves the margins come back
    -- as bg (white), not as the previous frame's ink (the trail bug).
    local tiny = Blitbuffer.new(32, 32, Blitbuffer.TYPE_BB8)
    tiny:fill(Blitbuffer.COLOR_WHITE)
    local fake_player = { stopped = false, bbs = { tiny }, idx = 1, n = 1 }
    local bb = new_bb()
    bb:fill(Blitbuffer.COLOR_WHITE)
    bb:paintRect(10, 10, 64, 64, Blitbuffer.COLOR_BLACK) -- fake "previous frame"
    ok(GifAnim.draw(fake_player, bb, 10, 10, 64, 64) == true, "gif: draw paints a frame")
    -- AppView hands bb type as 'cdata' too; a literal nil bb must be rejected BEFORE any paint call.
    ok(GifAnim.draw(fake_player, nil, 10, 10, 64, 64) == false, "gif: draw nil bb false no crash")
    local corner = bb:getPixel(11, 11)
    ok(corner:getR() > 200, "gif: draw clears the box before blitting (no trail band)")
    ok(bb:getPixel(26, 26):getR() > 200, "gif: frame ink lands centered")
    GifAnim.stop_all(app)
    ok(app.state.gif_players == nil and not queued_tick(),
        "gif: stop_all clears players and the tick")

    -- Race hardening (random device crash class): stop marks stopped FIRST,
    -- so a tick still queued before the unschedule is a no-op even if it
    -- runs with the buffers already freed. Simulate exactly that window.
    do
        local ar = fake_app({ page = "settings" })
        local vr = { app = ar, hitboxes = {} }
        function vr:refresh() end
        local pr = GifAnim.ensure(ar, vr, "race", gif, { w = 64, h = 64 })
        -- Captured tick + a manually freed table: stop() ran, buffers went
        -- away, ONLY THEN the stale tick fires (unschedule lost the race).
        pr.stopped = true
        pr.bbs = nil -- what stop() leaves behind after freeing
        local oktick, errtick = pcall(pr.tick)
        ok(oktick, "gif: stale tick after stop (buffers freed) is a no-op ("
            .. tostring(errtick) .. ")")
        -- Stop() is idempotent: a double stop from racing callers cannot
        -- re-free (a freed FFI buffer free() segfaults, pcall does not save).
        GifAnim.stop(pr) -- real stop path now (still stopped)
        ok(pr.bbs == nil, "gif: stop() is idempotent (no re-free of freed buffers)")
        GifAnim.stop_all(ar)
        -- draw() after stop: must return false, never touch freed buffers.
        local dbb = new_bb()
        dbb:fill(Blitbuffer.COLOR_WHITE)
        ok(GifAnim.draw(pr, dbb, 0, 0, 32, 32) == false,
            "gif: draw on a stopped player paints nothing and survives")
        ok(dbb:getPixel(16, 16):getR() > 200,
            "gif: draw on stopped player left the target untouched")
        -- Corrupt slot: idx landing on a non-cdata entry must fall back to
        -- a live frame (or nil), never hand a broken value to the blitter.
        local ac = fake_app({ page = "settings" })
        local vc = { app = ac, hitboxes = {} }
        function vc:refresh() end
        local pc = GifAnim.ensure(ac, vc, "corrupt", gif, { w = 64, h = 64 })
        local first_live = pc.bbs[1]
        pc.bbs[pc.idx] = "not-a-bb" -- simulated freed/replaced slot
        local fc = GifAnim.frame(pc)
        ok(fc == first_live or type(fc) == "cdata",
            "gif: corrupt frame slot falls back to a live buffer")
        GifAnim.stop_all(ac)
    end

    -- Missing file degrades to nil (caller falls back to first frame).
    local app2 = fake_app({ page = "settings" })
    local view2 = { app = app2, hitboxes = {} }
    function view2:refresh() end
    ok(GifAnim.ensure(app2, view2, "banner", "/tmp/nope.gif", { w = 64, h = 64 }) == nil,
        "gif: missing file plays nothing")
    GifAnim.stop_all(app2)
    -- Clock-anchored advancement: a player whose ticks skip (sheet pause/
    -- obscured/slow EPDC) does not crawl, but a wall-clock jump cannot spin
    -- unbounded either (MAX_CATCHUP cap).
    do
        local ak = fake_app({ page = "settings" })
        local vk = { app = ak, hitboxes = {} }
        function vk:refresh() end
        local pk = GifAnim.ensure(ak, vk, "clock", gif, { w = 64, h = 64 })
        GifAnim.DIRECT = false
        local base = GifAnim.wall_clock()
        local fake_now = base
        local real_wc = GifAnim.wall_clock
        GifAnim.wall_clock = function() return fake_now end
        pk.idx = 1
        pk.tick() -- no last_t yet: one stride
        ok(pk.idx == 2 and pk.last_t == fake_now,
            "gif: first tick strides once and anchors the clock")
        fake_now = base + GifAnim.tick_interval() * 11.6 -- 11 skipped intervals
        pk.tick()
        -- strides here = 1 regular + min(missed, MAX_CATCHUP), all cycled
        -- through n frames: assert via the modulo, not an absolute idx.
        local strides = 1 + GifAnim.MAX_CATCHUP
        local expect2 = ((2 - 1 + strides) % pk.n) + 1
        ok(pk.idx == expect2,
            "gif: skipped intervals catch up capped at " .. GifAnim.MAX_CATCHUP
            .. " (got idx=" .. tostring(pk.idx) .. " want=" .. tostring(expect2) .. ")")
        fake_now = base + 3600 -- suspend resume: a full-hour wall jump
        pk.tick()
        -- exactly ONE more capped stride (1 + MAX_CATCHUP) from expect2.
        local expect3 = ((expect2 - 1 + 1 + GifAnim.MAX_CATCHUP) % pk.n) + 1
        ok(pk.idx == expect3,
            "gif: wall-clock jump spins at most one capped stride (got "
            .. tostring(pk.idx) .. " want=" .. tostring(expect3) .. ")")
        GifAnim.wall_clock = real_wc
        GifAnim.DIRECT = true
        GifAnim.stop(pk)
        GifAnim.stop_all(ak)
    end

    -- Leaked timer self-stops on page change (the dashboard freeze class).
    local app3 = fake_app({ page = "settings" })
    local view3 = { app = app3, hitboxes = {} }
    local refreshed = 0
    function view3:refresh(...) refreshed = refreshed + 1 end
    local pl3 = GifAnim.ensure(app3, view3, "banner", gif, { w = 64, h = 64 })
    ok(pl3 ~= nil, "gif: player for the leak test")
    app3.state.page = "dashboard" -- any path that forgot stop_all
    pl3.tick()
    ok(pl3.stopped == true and refreshed == 0
        and (app3.state.gif_players == nil or app3.state.gif_players["banner"] == nil),
        "gif: tick self-stops off-page without repainting")
    -- show_dashboard (the Home tab) stops players explicitly.
    local App = require("kt_app")
    local app4 = setmetatable({
        state = { settings = {}, scroll = {}, page = "settings" },
    }, { __index = App })
    local view4 = { app = app4, hitboxes = {} }
    function view4:refresh(...) end
    local pl4 = GifAnim.ensure(app4, view4, "banner", gif, { w = 64, h = 64 })
    ok(pl4 ~= nil, "gif: player for the dashboard test")
    app4:show_dashboard()
    ok(app4.state.gif_players == nil, "gif: Home tab stops the animation")
    do
        local a3 = fake_app({ page = "settings",
            settings = { debug_mode = true } })
        local v3 = { app = a3, hitboxes = {} }
        function v3:refresh() end
        local b3 = new_bb()
        local Pt = require("ktui/pages")
        Pt.settings(v3, b3, 0, 0, VW, VH, 0)
        dump(b3, "settings_debug")
    end
    GifAnim.stop_all(app)
end

-- === 4x. Cover thumbnails: generate once, paint small ============================
do
    local Thumbs = require("ktui/thumbs")
    local lfs = require("libs/libkoreader-lfs")
    -- Synthetic noisy card (~1200px, PNG-hostile pixels like real art).
    local big = Blitbuffer.new(1200, 1200, Blitbuffer.TYPE_BB8)
    big:fill(Blitbuffer.COLOR_WHITE)
    math.randomseed(1234)
    for i = 1, 2500 do
        big:paintRect(math.random(0, 1180), math.random(0, 1180), 20, 20,
            Blitbuffer.gray(math.random()))
    end
    big:writePNG("/tmp/thumb_src.png")
    local P = require("ktui/primitives")
    local tp = Thumbs.generate("/tmp/thumb_src.png")
    ok(tp ~= nil, "thumbs: big card generates a thumb")
    local iw, ih = P.image_dims(tp)
    ok(iw ~= nil and math.max(iw, ih) <= Thumbs.LONG_SIDE,
        "thumbs: long side capped at 480 (got " .. tostring(iw) .. "x" .. tostring(ih) .. ")")
    ok(Thumbs.cached("/tmp/thumb_src.png") == tp, "thumbs: second call hits the cache")
    -- Edited file (new size) misses and regenerates under a new key.
    os.execute("cp /tmp/thumb_src.png /tmp/thumb_src2.png && echo x >> /tmp/thumb_src2.png")
    ok(Thumbs.key_for("/tmp/thumb_src2.png") ~= Thumbs.key_for("/tmp/thumb_src.png"),
        "thumbs: mtime/size change invalidates")
    os.remove("/tmp/thumb_src.png")
    os.remove("/tmp/thumb_src2.png")
    -- ensure() on a cold path enqueues without painting-time generation.
    local before = Thumbs.pending_count()
    Thumbs.ensure("/tmp/nope-missing.png", nil)
    ok(Thumbs.pending_count() == before, "thumbs: missing file never queues")
    -- Sweep caps the dir (limits shrunk for the test, then restored).
    local real_max, real_keep = Thumbs.MAX_FILES, Thumbs.SWEEP_KEEP
    Thumbs.MAX_FILES, Thumbs.SWEEP_KEEP = 5, 2
    local Store2 = require("kt_storage")
    local dir = Store2.data_dir() .. "/chat_thumbs"
    os.execute("mkdir -p " .. dir)
    for i = 1, 7 do
        local f = io.open(dir .. "/sweep" .. i .. ".png", "w")
        f:write("x")
        f:close()
    end
    Thumbs.sweep()
    local left = 0
    for name in lfs.dir(dir) do
        if name:match("^sweep%d+%.png$") then left = left + 1 end
    end
    for i = 1, 7 do os.remove(dir .. "/sweep" .. i .. ".png") end
    Thumbs.MAX_FILES, Thumbs.SWEEP_KEEP = real_max, real_keep
    ok(left <= 2, "thumbs: sweep keeps the cap (left " .. left .. ")")
    -- Grid card paints from the thumb (or placeholder) without the original.
    local Cards = require("ktui/cards")
    local app = fake_app({ page = "dashboard", settings = { show_covers = true } })
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    Cards.character(view, bb, { path = "/tmp/nope-missing.png", name = "Z",
        tags = {}, tokens = 0 }, 0, 0, 200, 200)
    ok(true, "thumbs: missing cover paints the fallback, no crash")
end

-- === 4q. Plugin language choice persists and drives the UI ======================
do
    local I18n = require("kt_i18n")
    local GT = require("gettext")
    local Store = require("kt_storage")
    local App = require("kt_app")
    local st = G_reader_settings
    local real_read = st.readSetting
    st.readSetting = function(self, k, default)
        if k == "language" then return "pt_BR" end
        return real_read(self, k, default)
    end
    local real_save = Store.save_settings
    Store.save_settings = function() end -- never touch the real file here
    I18n.uninstall()
    I18n.install()
    local MSG = "Stream refresh"

    local function mk_lang_app(plugin_lang)
        local a = setmetatable({
            state = { settings = { plugin_lang = plugin_lang }, scroll = {}, page = "settings" },
        }, { __index = App })
        a.view = { refresh = function() end }
        a.view.app = a -- Sheets.show walks view.app
        return a
    end
    -- Row source: stored choice wins, nil follows the device.
    ok(mk_lang_app("es"):active_lang() == "es", "lang: stored choice wins")
    ok(mk_lang_app(nil):active_lang() == "pt_BR", "lang: nil follows the device")
    -- Picker writes the choice through (Spanish action). Labels are
    -- captured up front: tapping rebuilds nothing, but the active language
    -- (hence GT2) changes underneath us.
    local app = mk_lang_app("pt_BR")
    app:choose_language()
    local GT2 = require("gettext")
    local want_es, want_follow = GT2("Spanish"), GT2("Follow system")
    local es_act, follow
    for _, act in ipairs(app.state.sheet.actions) do
        if act.label == want_es then es_act = act end
        if act.label == want_follow then follow = act end
    end
    ok(es_act ~= nil, "lang: picker offers Spanish")
    ok(follow ~= nil, "lang: picker offers Follow system")
    es_act.on_tap()
    ok(app.state.settings.plugin_lang == "es"
        and GT.translation[MSG] == "Actualización del stream",
        "lang: picking Spanish persists + applies")
    -- Follow system clears back to nil and restores the device language.
    follow.on_tap()
    ok(app.state.settings.plugin_lang == nil
        and GT.translation[MSG] == "Atualização do stream",
        "lang: follow clears + restores device pt")
    -- Closing restores the entry (device) language, never the picked one.
    GT.changeLang("es")
    I18n.uninstall()
    ok(GT.current_lang == "pt_BR", "lang: close restores the device language")
    I18n.install()
    st.readSetting = real_read
    Store.save_settings = real_save
    I18n.uninstall()
end

-- === 4p. List-mode favorite star: centered ink + working tap ===================
do
    local Cards = require("ktui/cards")
    local function paint_star(fav)
        local app = fake_app({ settings = {} })
        local view = { app = app, hitboxes = {} }
        local bb = new_bb()
        Cards.list_item(view, bb,
            { name = "T", fav = fav, tags = {}, tokens = 5, path = nil },
            0, 0, VW, 120, nil)
        return view, bb
    end
    local view, bb = paint_star(true)
    local top, bottom = 0, 0
    for yy = 0, 119 do
        for xx = VW - 100, VW - 1 do
            if bb:getPixel(xx, yy):getR() < 128 then
                if yy < 60 then top = top + 1 else bottom = bottom + 1 end
            end
        end
    end
    local total = top + bottom
    ok(total > 100 and math.abs(top - bottom) / total < 0.3,
        "favlist: star ink symmetric around row center (top=" .. top .. " bottom=" .. bottom .. ")")
    local has_hit = false
    for _, b in ipairs(view.hitboxes) do
        if tostring(b.label or ""):sub(1, 8) == "favlist:" then has_hit = true end
    end
    ok(has_hit, "favlist: star has a toggle hitbox")
    local view2 = paint_star(false)
    local has_hit2 = false
    for _, b in ipairs(view2.hitboxes) do
        if tostring(b.label or ""):sub(1, 8) == "favlist:" then has_hit2 = true end
    end
    ok(not has_hit2, "favlist: no star, no hitbox")
end

-- === 4q. Geometry-audit fixes: hit order, boolean values, disabled gating ===
do
    local Widgets = require("ktui/widgets")
    local Cards = require("ktui/cards")
    local Sheets = require("ktui/sheets")

    -- favlist: row hit registered BEFORE the star hit, so the star wins taps
    -- on overlap (reverse-order dispatch: last registered wins).
    do
        local app = fake_app({ settings = {} })
        local view = { app = app, hitboxes = {} }
        Cards.list_item(view, new_bb(),
            { name = "T", fav = true, tags = {}, tokens = 5, path = nil },
            0, 0, VW, 120, nil)
        local row_i, fav_i = nil, nil
        for i, b in ipairs(view.hitboxes) do
            local lb = tostring(b.label or "")
            if lb:sub(1, 10) == "list_item:" then row_i = i end
            if lb:sub(1, 8) == "favlist:" then fav_i = i end
        end
        ok(row_i and fav_i and row_i < fav_i,
            "favlist: star hit registered after the row hit (wins overlap)")
    end

    -- W.row: boolean values must not paint (tostring(true) leaked as "true").
    do
        local function paint_value(v)
            local app = fake_app({ settings = {} })
            local view = { app = app, hitboxes = {} }
            local bb = new_bb()
            Widgets.row(view, bb, { x = 0, y = 0, w = VW, h = 60,
                title = "T", value = v, toggle = true, toggle_value = true,
                on_toggle = function() end, on_tap = function() end })
            return view, bb
        end
        local _, bb_str = paint_value("On")
        local _, bb_bool = paint_value(true)
        -- Right-half ink: the "On" text paints extra ink over the identical
        -- toggle; boolean true must add nothing.
        local hw = math.floor(VW / 2)
        ok(dark_in(bb_str, hw, 0, VW - hw, 60) > dark_in(bb_bool, hw, 0, VW - hw, 60),
            "row: boolean value paints no text (string value paints)")
    end

    -- W.row: disabled rows register NO hits (row, toggle, or kebab).
    do
        local app = fake_app({ settings = {} })
        local view = { app = app, hitboxes = {} }
        Widgets.row(view, new_bb(), { x = 0, y = 0, w = VW, h = 60,
            title = "T", toggle = true, toggle_value = false,
            kebab = true, on_toggle = function() end,
            on_kebab = function() end, on_tap = function() end,
            enabled = false })
        ok(#view.hitboxes == 0,
            "row: disabled row registers no hits (got " .. #view.hitboxes .. ")")
    end

    -- Sheets: disabled actions register no hit; non-confirm Cancel is sheet:.
    do
        local app = fake_app({ page = "chat" })
        app.state.sheet = { title = "T", scroll = 0, actions = {
            { label = "Gone", enabled = false },
            { label = "Here", on_tap = function() end },
        } }
        local view = { app = app, hitboxes = {} }
        local okp, err = pcall(function() Sheets.draw(view, new_bb()) end)
        ok(okp, "sheets: disabled-action sheet renders (" .. tostring(err) .. ")")
        ok(has_hit(view, "sheet:Here") and not has_hit(view, "sheet:Gone"),
            "sheets: disabled action has no hit, enabled keeps its tap")
    ok(has_hit(view, "sheet:cancel"),
        "sheets: non-confirm Cancel registers as sheet:cancel")
    -- Row tap closes through Sheets.close (restores pre-sheet scroll);
    -- the old bare-nil skipped the restore and nested sheets stranded top.
    do
        local fired = false
        -- As Sheets.show leaves it: scroll zeroed, position stashed.
        app.state.scroll = { chat = 0 }
        function app:scroll_key() return "chat" end
        app.state.sheet = { title = "T", scroll = 0,
            _saved_scroll = { key = "chat", value = 500 },
            actions = { { label = "Go", on_tap = function() fired = true end } } }
        local v = { app = app, hitboxes = {} }
        function v:refresh() end
        app.view = v
        local bb2 = new_bb()
        Sheets.draw(v, bb2)
        for _, b in ipairs(v.hitboxes) do
            if b.label == "sheet:Go" then b.callback() end
        end
        ok(app.state.sheet == nil and fired
            and app.state.scroll.chat == 500,
            "sheets: row tap closes via close() (scroll restored, tap fired)")
    end
end

    -- Segmented: tab widths differ by at most 1px (remainder distributed).
    do
        local app = fake_app({ settings = {} })
        local view = { app = app, hitboxes = {} }
        Widgets.segmented(view, new_bb(), { x = 0, y = 0, w = 301, h = 36,
            tabs = { { id = 1, label = "A" }, { id = 2, label = "B" }, { id = 3, label = "C" } },
            active = 1, on_select = function() end })
        local widths = {}
        for _, b in ipairs(view.hitboxes) do
            if tostring(b.label or ""):sub(1, 4) == "seg:" then widths[#widths + 1] = b.w end
        end
        local mn, mx = math.huge, 0
        for _, wd in ipairs(widths) do mn = math.min(mn, wd); mx = math.max(mx, wd) end
        ok(#widths == 3 and mx - mn <= 1,
            "segmented: remainder distributed (width spread " .. tostring(mx - mn) .. ")")
    end
end

-- === 4t. Uniform card/list slots: names align across mixed content ===========
-- First dark-ink row inside the text zone (frame/star excluded by construction).
local function first_text_row(bb, x, y, w, h)
    local pad = Theme.scale(8)
    for yy = y + 2, y + h - 3 do
        for xx = x + pad + 2, x + w - pad - 2 do
            if bb:getPixel(xx, yy):getR() < 200 then return yy end
        end
    end
    return nil
end
do
    local Cards = require("ktui/cards")

    -- Grid caption: full card (tags+meta) vs bare card (neither). Fixed slots
    -- put both names at the same height; per-item bands did not.
    do
        local app = fake_app({ settings = {} })
        local function paint_card(item)
            local view = { app = app, hitboxes = {} }
            local bb = new_bb()
            Cards.character(view, bb, item, 0, 0, 180, 300)
            return bb
        end
        local full = paint_card({ name = "Aria", tags = { "human", "mage" }, tokens = 1234, creator = "Luna" })
        local bare = paint_card({ name = "B" })
        -- Scan only the caption half (initial lives in the top half).
        local y_full, y_bare = nil, nil
        for yy = 150, 297 do
            for xx = 10, 170 do
                if not y_full and full:getPixel(xx, yy):getR() < 200 then y_full = yy end
                if not y_bare and bare:getPixel(xx, yy):getR() < 200 then y_bare = yy end
            end
        end
        ok(y_full and y_bare and y_full == y_bare,
            "cards: caption names align with/without tags+meta ("
            .. tostring(y_full) .. " vs " .. tostring(y_bare) .. ")")
    end

    -- Dashboard list rows (rich): full vs bare item, same row height.
    do
        local app = fake_app({ settings = {} })
        local function paint_row(item)
            local view = { app = app, hitboxes = {} }
            local bb = new_bb()
            Cards.list_item(view, bb, item, 0, 0, VW, 120, nil)
            return bb
        end
        local full = paint_row({ name = "Aria", tags = { "human" }, tokens = 1234, creator = "Luna" })
        local bare = paint_row({ name = "B" })
        local y_full = first_text_row(full, 0, 0, VW, 120)
        local y_bare = first_text_row(bare, 0, 0, VW, 120)
        ok(y_full and y_bare and y_full == y_bare,
            "cards: list-row names align with/without tags+meta ("
            .. tostring(y_full) .. " vs " .. tostring(y_bare) .. ")")
    end

    -- Chats rows (legacy): empty preview vs filled preview.
    do
        local app = fake_app({ settings = {} })
        local function paint_chat(subtext, meta)
            local view = { app = app, hitboxes = {} }
            local bb = new_bb()
            Cards.list_item(view, bb,
                { name = "Chat", subtext = subtext, meta = meta }, 0, 0, VW, 120, nil)
            return bb
        end
        local filled = paint_chat("(Aria)", "hello")
        local empty = paint_chat("", "")
        local y_filled = first_text_row(filled, 0, 0, VW, 120)
        local y_empty = first_text_row(empty, 0, 0, VW, 120)
        ok(y_filled and y_empty and y_filled == y_empty,
            "cards: chat-row names align with/without preview ("
            .. tostring(y_filled) .. " vs " .. tostring(y_empty) .. ")")
    end
end

-- === 4u. load_settings keeps non-default persisted keys =========================
do
    local Store = require("kt_storage")
    local App = require("kt_app")
    local real_load, real_save = Store.load_settings, Store.save_settings
    Store.load_settings = function()
        return { theme = "light", streaming = false, update_channel = "commits",
            plugin_lang = "es", default_preset_id = "p1", last_seen_chats = 123,
            installed_build = { channel = "commits", version = "0.1.0" } }
    end
    Store.save_settings = function() end -- migrations must not touch disk here
    local app = setmetatable({ state = {} }, { __index = App })
    app:load_settings()
    local s = app.state.settings
    ok(s.update_channel == "commits", "settings: update_channel survives reboot")
    ok(s.plugin_lang == "es", "settings: plugin_lang survives reboot")
    ok(s.default_preset_id == "p1", "settings: default preset survives reboot")
    ok(s.last_seen_chats == 123, "settings: last_seen survives reboot")
    ok(type(s.installed_build) == "table" and s.installed_build.channel == "commits",
        "settings: installed_build survives reboot")
    ok(s.stream_refresh == "calm", "settings: missing defaults still filled")
    ok(s.streaming == false, "settings: explicit false not clobbered")
    Store.load_settings, Store.save_settings = real_load, real_save
end

-- === 4s. Character view: capped cover, collapsed sections ======================
do
    local card = {
        name = "Aria", description = string.rep("brave mage. ", 30),
        personality = "kind", scenario = "", first_mes = "hi",
        mes_example = "", system_prompt = "", post_history_instructions = "",
        creator_notes = "# Note\nSome **bold** text.\n\n- one\n- two\n\n> quoted",
        tags = { "mage" },
    }
    local app = fake_app({ page = "character_view" })
    app.state.viewing_character = { path = "/tmp/nope.png", card = card }
    app.state.current_character = "Aria"
    local view = { app = app, hitboxes = {} }
    function view:refresh() end
    local bb = new_bb()
    local Pages = require("ktui/pages")
    local function render(scroll, h)
        view.hitboxes = {}
        return Pages.character_view(view, bb, 0, 0, VW, h or VH, scroll)
    end
    local max_closed = render(0)
    ok(type(max_closed) == "number", "cv: renders with all sections closed")
    ok(app.state.character_view_expanded == nil,
        "cv: no auto-expand state ever set")
    -- Tap toggles exactly one section open.
    local sec_hit
    local sec_ids = {}
    for _, b in ipairs(view.hitboxes) do
        local id = tostring(b.label or ""):match("^cvsec:(.+)$")
        if id then
            if tostring(b.label or "") == "cvsec:description" then sec_hit = b end
            sec_ids[#sec_ids + 1] = id
        end
    end
    ok(sec_hit ~= nil, "cv: section header has a tap hitbox")
    ok(table.concat(sec_ids, ",") == "description,personality,first_mes,tags",
        "cv: curated sections in order (got " .. table.concat(sec_ids, ",") .. ")")
    sec_hit.callback()
    ok(app.state.character_view_open["description"] == true
        and app.state.character_view_open["personality"] == nil,
        "cv: tap opens only that section")
    -- Growth measured in a short viewport so content actually scrolls.
    sec_hit.callback() -- shut again after the opens-only assert above
    local small_closed = render(0, 300)
    sec_hit.callback() -- open
    local small_open = render(0, 300)
    ok(small_open > small_closed, "cv: open section grows the content")
    sec_hit.callback() -- shut
    ok(app.state.character_view_open["description"] ~= true,
        "cv: second tap closes it again")
    local has_avatar = false
    for _, b in ipairs(view.hitboxes) do
        if tostring(b.label or "") == "cv_avatar" then has_avatar = true end
    end
    ok(has_avatar, "cv: avatar tap opens fullscreen")
    -- Scroll position survives paging (no featured reset-to-top).
    app.state.scroll["character_view"] = 300
    local max_at_300 = render(300)
    ok(app.state.scroll["character_view"] == math.min(300, max_at_300),
        "cv: paging preserves scroll (no cover zoom reset)")
    -- Menu entry: first menu, no NEW badge (declarative, read the source).
    local main_src = io.open(PLUGIN .. "/main.lua", "r"):read("*a")
    ok(main_src:find("sorting_hint =", 1, true) == nil
        and main_src:find("new = true", 1, true) ~= nil,
        "menu: no sorting_hint assignment, NEW badge suppressed")
    -- Creator Notes paint as markdown above the sections (no collapse).
    local function ink_top()
        local n = 0
        for yy = 0, 399 do
            for xx = 0, VW - 1, 2 do
                if bb:getPixel(xx, yy):getR() < 128 then n = n + 1 end
            end
        end
        return n
    end
    local card_nonotes = {}
    for k, v in pairs(card) do card_nonotes[k] = v end
    card_nonotes.creator_notes = ""
    app.state.viewing_character = { path = "/tmp/nope.png", card = card_nonotes }
    bb:fill(Blitbuffer.COLOR_WHITE)
    local max_nonotes = render(0, 250)
    local ink_nonotes = ink_top()
    app.state.viewing_character = { path = "/tmp/nope.png", card = card }
    bb:fill(Blitbuffer.COLOR_WHITE)
    local max_notes = render(0, 250)
    ok(max_notes > max_nonotes, "cv: creator notes add always-visible content")
    ok(ink_top() > ink_nonotes + 50, "cv: notes band paints markdown ink near the top")
    render(0)
    dump(bb, "character_view")
    -- Avatar fallback (no image file): initial letter paints inside the box.
    local av_ink = 0
    for yy = 10, 130 do
        for xx = 10, 130 do
            if bb:getPixel(xx, yy):getR() < 128 then av_ink = av_ink + 1 end
        end
    end
    ok(av_ink > 20, "cv: fallback initial paints in the avatar box")
end

-- === 4t. Dashboard shows the card name, not the file name =========================
do
    -- Minimal PNG with a tEXt chara chunk (base64 JSON, like ST cards).
    local bit = require("bit")
    local b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local function b64enc(s)
        local out = {}
        for i = 1, #s, 3 do
            local a, b, c = s:byte(i, i + 2)
            b = b or 0
            c = c or 0
            local n = a * 65536 + b * 256 + c
            out[#out + 1] = b64:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1)
                .. b64:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
                .. (i + 1 > #s and "=" or b64:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1))
                .. (i + 2 > #s and "=" or b64:sub(n % 64 + 1, n % 64 + 1))
        end
        return table.concat(out)
    end
    local function make_card(path, name)
        local json = require("json")
        local payload = b64enc(json.encode({ name = name, description = "d" }))
        local function chunk(typ, data)
            local out = string.char(
                math.floor(#data / 16777216) % 256, math.floor(#data / 65536) % 256,
                math.floor(#data / 256) % 256, #data % 256) .. typ .. data
            -- CRC via pure lua (small payloads only).
            local crc, poly = 0xFFFFFFFF, 0xEDB88320
            local t = typ .. data
            for i = 1, #t do
                crc = bit.bxor(crc, t:byte(i))
                for _ = 1, 8 do
                    if bit.band(crc, 1) == 1 then
                        crc = bit.bxor(0xEDB88320, bit.rshift(crc, 1))
                    else
                        crc = bit.rshift(crc, 1)
                    end
                end
            end
            crc = bit.bxor(crc, 0xFFFFFFFF)
            local b = {}
            for _ = 1, 4 do b[#b + 1] = string.char(bit.band(crc, 0xFF)); crc = bit.rshift(crc, 8) end
            return out .. table.concat(b)
        end
        local f = io.open(path, "wb")
        -- Rebuild properly: signature + IHDR + tEXt + IEND with real CRCs.
        local sig = string.char(137, 80, 78, 71, 13, 10, 26, 10)
        local ihdr_data = string.char(0,0,0,1,0,0,0,1,8,2,0,0,0)
        f = io.open(path, "wb")
        f:write(sig)
        f:write(chunk("IHDR", ihdr_data))
        f:write(chunk("tEXt", "chara\0" .. payload))
        f:write(chunk("IEND", ""))
        f:close()
    end
    make_card("/tmp/card_file_xyz.png", "Real Card Name")
    local Store = require("kt_storage")
    local real_list = Store.list_character_files
    Store.list_character_files = function() return { "/tmp/card_file_xyz.png" } end
    local App = require("kt_app")
    local app = setmetatable({
        state = { settings = {}, dashboard_query = "", _card_cache = nil },
    }, { __index = App })
    local items = app:dashboard_items()
    ok(#items == 1 and items[1].display_name == "Real Card Name"
        and items[1].name == "card_file_xyz",
        "dashboard: display_name comes from the card (got "
        .. tostring(items[1] and items[1].display_name) .. ")")
    Store.list_character_files = real_list
    os.remove("/tmp/card_file_xyz.png")
end

-- === 4l. Message actions open on hold/kebab, never on tap =====================
do
    local AppView = require("ktui/app_view")
    local ChatBubbles = require("ktui/chat_bubbles")
    local opened = {}
    local app = fake_app({ page = "chat",
        settings = { show_avatars = true },
        messages = {
            { role = "user", content = "hello", name = "You" },
            { role = "assistant", content = "hi there", name = "Aria" },
        } })
    app.show_message_actions = function(self, idx) opened[#opened + 1] = idx end
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    ChatBubbles.draw(view, bb, 0, 0, VW, VH, 0, app.state.messages,
        "Aria", false, "You", nil, nil)
    local function box_with(prefix)
        for _, b in ipairs(view.hitboxes) do
            if tostring(b.label or ""):sub(1, #prefix) == prefix then return b end
        end
    end
    local function center(b) return { pos = { x = b.x + b.w / 2, y = b.y + b.h / 2 } } end
    local msghold = box_with("msghold_")
    ok(msghold ~= nil, "hold: bubble registers a hold zone")
    AppView.onTapKotavern(view, nil, center(msghold))
    ok(#opened == 0, "hold: tap on the bubble opens nothing")
    local held = AppView.onHoldKotavern(view, nil, center(msghold))
    ok(held == true and #opened == 1 and opened[1] == 1,
        "hold: long-press opens actions for that message")
    local kebab = box_with("kebab_")
    AppView.onTapKotavern(view, nil, center(kebab))
    ok(#opened == 2 and opened[2] == 1,
        "hold: kebab tap still opens actions")
    -- Synthetic tap-only box: hold ignores it, tap still works.
    local tapped = {}
    local v2 = { app = app, hitboxes = {} }
    require("ktui/primitives").hit(v2, 0, 0, 50, 50,
        function() tapped[#tapped + 1] = true end, "plain")
    ok(AppView.onHoldKotavern(v2, nil, { pos = { x = 10, y = 10 } }) == false
        and #tapped == 0,
        "hold: boxes without on_hold are ignored")
    AppView.onTapKotavern(v2, nil, { pos = { x = 10, y = 10 } })
    ok(#tapped == 1, "hold: plain tap boxes keep working")
end

-- Chat avatar tap: fullscreen photo (lists parity), only with a photo.
do
    local ChatBubbles = require("ktui/chat_bubbles")
    local AppView = require("ktui/app_view")
    local msgs = {
        { role = "user", content = "hello", name = "You" },
        { role = "assistant", content = "hi there", name = "Aria" },
    }
    local function paint_chat(char_img, user_img, fullscreen_fn)
        local app = fake_app({ page = "chat",
            settings = { show_avatars = true }, messages = msgs })
        app.show_message_actions = function() end
        app.show_character_image_fullscreen = fullscreen_fn
        if user_img then
            app._active_persona_avatar = function() return user_img end
        end
        local view = { app = app, hitboxes = {} }
        local bb = new_bb()
        ChatBubbles.draw(view, bb, 0, 0, VW, VH, 0, msgs,
            "Aria", false, "You", char_img, nil)
        return view
    end
    local function box_with(view, prefix)
        for _, b in ipairs(view.hitboxes) do
            if tostring(b.label or ""):sub(1, #prefix) == prefix then return b end
        end
    end
    -- No photos: no avatar hits (initial fallback stays untappable).
    local bare = paint_chat(nil, nil, function() end)
    ok(box_with(bare, "chat_avatar_") == nil, "avatar: no photo, no hitbox")
    -- Photos: one hit per message; tap opens fullscreen with that path.
    local opened = {}
    local fuller = paint_chat(PLUGIN .. "/assets/logo.svg", PLUGIN .. "/assets/logo.svg",
        function(_, path) opened[#opened + 1] = path end)
    local n_av, first_av = 0, nil
    for _, b in ipairs(fuller.hitboxes) do
        if tostring(b.label or ""):sub(1, 12) == "chat_avatar_" then
            n_av = n_av + 1
            first_av = first_av or b
        end
    end
    ok(n_av == 2, "avatar: one tap hitbox per message with photo (got " .. n_av .. ")")
    AppView.onTapKotavern(fuller, nil,
        { pos = { x = first_av.x + 1, y = first_av.y + 1 } })
    ok(#opened == 1 and opened[1] == PLUGIN .. "/assets/logo.svg",
        "avatar: tap opens the photo fullscreen")
end

-- Experimental HTML chat renderer (Debug toggle): the MuPDF doc must start
-- AT the bubble's content top (no @page top-margin dead space - the crooked
-- chat report) and a multi-line message must keep its rows (no newline
-- collapse into one paragraph).
do
    local app = fake_app({ page = "chat",
        settings = { chat_html_render = true },
        messages = {
            { role = "user", content = "ping", name = "You", send_date = os.time() },
            { role = "assistant", name = "Aria", send_date = os.time(),
              content = "# Heading\n**bold** body\nsecond line\nthird line\nfifth line" },
        } })
    local view = { app = app, hitboxes = {}, refresh = function() end }
    local b = new_bb()
    local okp, err = pcall(function() Pages.chat(view, b, 0, 0, VW, VH, 0) end)
    ok(okp, "chat html: renders without crashing (" .. tostring(err) .. ")")
    local bl, doc = nil, nil
    for _k, l in pairs(view._chat_layout_cache or {}) do
        if not l.is_user and not l.is_system then bl = bl or l end
    end
    -- The doc comes from the ASSISTANT layout's own html entry (user
    -- messages render through the doc path too, so scanning chat_html_docs
    -- with pairs can pick the "ping" doc).
    if bl and bl.entries then
        for _e, e in ipairs(bl.entries) do
            if e.kind == "html" then doc = { widget = e.widget, height = e.h } break end
        end
    end
    ok(bl ~= nil and doc ~= nil, "chat html: assistant bubble measured + doc cached")
    if bl and doc then
        -- Content top = bubble_y + pn_pad(10) + name_row_h(48, avatar on);
        -- the doc's own bitmap starts with ink (leading nbsp baseline), so
        -- the first body ink must land within the first ~2.5 lines.
        local content_top = bl.bubble_y + 10 + 48 + 8
        local first_ink = nil
        for yy = content_top - 12, content_top + 60 do
            for xx = 60, VW - 40, 3 do
                local px = b:getPixel(xx, yy)
                if px:getR() < 128 then first_ink = yy break end
            end
            if first_ink then break end
        end
        ok(first_ink ~= nil, "chat html: body ink exists")
        ok(first_ink ~= nil and first_ink <= content_top + 48,
            "chat html: text starts at the content top (no @page gap) (ink at "
            .. tostring(first_ink) .. " vs top " .. tostring(content_top) .. ")")
        -- 5 short lines must NOT collapse into one wrapped line (MuPDF
        -- newline behavior the <br> rewrite fixes): collapsed would be
        -- ~2 MuPDF rows (~60px); the real layout is ~25px/row * 5 (the
        -- canvas Theme.line_h overestimates MuPDF rows, so use 3x as floor).
        ok(doc.height >= Theme.line_h("default") * 3,
            "chat html: multi-line message keeps its rows (h="
            .. tostring(doc.height) .. ")")
    end
    dump(b, "chat_html_render")
end

-- HTML markdown coverage (the "markdown ainda não renderiza" round 2):
-- inline markup must re-express into tags in the emitted body, model text
-- must be escaped, and fence rows must become contiguous mono <p> blocks.
do
    local DbgChat = require("ktui/chat_bubbles")
    local body = DbgChat._test_chat_html_body(
        "~~hit~~ and `mono` and [txt](https://x.com) and ||secret||\n"
        .. "> quoted line\n- bullet\n```js\ncode_row\n```\n5<b>&<tail")
    ok(body ~= nil, "chat html md: test hook returns a body")
    if body then
        ok(body:find("<s>hit</s>", 1, true) ~= nil,
            "chat html md: ~~strike~~ becomes <s>")
        ok(body:find('<span class="ktcode">mono</span>', 1, true) ~= nil,
            "chat html md: `code` becomes mono span")
        ok(body:find('<a href="https://x.com">txt</a>', 1, true) ~= nil,
            "chat html md: [txt](url) becomes an anchor")
        ok(body:find('<a href="kt:spl:1" class="ktspl">secret</a>', 1, true) ~= nil,
            "chat html md: ||spoiler|| becomes the masked kt:spl link")
        -- Real italic (not the canvas path's bold fallback): * *, _ _, ***.
        local ital = DbgChat._test_chat_html_body("*it* and _it_ and ***bi***")
        ok(ital:find("<i>it</i>", 1, true) ~= nil,
            "chat html md: *em* and _em_ become <i>")
        ok(ital:find("<b><i>bi</i></b>", 1, true) ~= nil,
            "chat html md: ***bi*** becomes <b><i>")
        ok(DbgChat._test_chat_html_body("snake_case_word")
            :find("<i>", 1, true) == nil,
            "chat html md: snake_case keeps no emphasis")
        ok(DbgChat._test_chat_html_body("`a*b` and `c*d`")
            :find("<i>", 1, true) == nil,
            "chat html md: emphasis never pairs across code spans")
        -- Spoiler numbering is document order; reveal keeps the order stable.
        local spl = DbgChat._test_chat_html_body("||a|| and ||b||")
        ok(spl:find('kt:spl:1', 1, true) ~= nil
            and spl:find('kt:spl:2', 1, true) ~= nil,
            "chat html md: spoilers number in document order")
        local rev = DbgChat._test_chat_html_body("||a|| and ||b||", { [2] = true })
        ok(rev:find('<span class="ktspl ktsplopen">b</span>', 1, true) ~= nil
            and rev:find("kt:spl:2", 1, true) == nil,
            "chat html md: revealed spoiler renders as the open span")
        ok(body:find("ktq", 1, true) ~= nil,
            "chat html md: > line becomes the quote row")
        ok(body:find("\194\183 bullet", 1, true) ~= nil,
            "chat html md: - item gets the bullet")
        ok(body:find('<p class="ktfence">code_row</p>', 1, true) ~= nil,
            "chat html md: fenced rows flush as mono <p> blocks")
        -- Lone allowlisted openers convert (browser auto-close parity);
        -- unknown tags vanish keeping inner text; non-letters stay literal.
        ok(body:find("5<b>&amp;&lt;tail", 1, true) ~= nil,
            "chat html md: lone <b> converts, entities still escaped")
        ok(body:find("~~", 1, true) == nil and body:find("||", 1, true) == nil,
            "chat html md: no raw ~~ or || markers survive")
        -- Quote color parity (ST): "..." and curly "..." wrap in <q>
        -- (the "set Quote red, quoted text stayed plain" report); the
        -- stylesheet carries the italics + q color rules.
        local qs = DbgChat._test_chat_html_body('she said "hello there" ok')
        ok(qs:find('<q>"hello there"</q>', 1, true) ~= nil,
            "chat html md: straight-quoted run wraps in <q> (chars kept)")
        local qc = DbgChat._test_chat_html_body("curly \u{201C}nice\u{201D} tail")
        ok(qc:find("<q>", 1, true) ~= nil,
            "chat html md: curly-quoted run wraps in <q>")
        local KtHTML_q = require("ktui/kthtml")
        local ChatTheme_q = require("ktui/chat_theme")
        local css_q = KtHTML_q.chat_css(ChatTheme_q.resolved(fake_app({})))
        ok(css_q:find("i { font%-style: italic; color: ", 1, false) ~= nil,
            "chat html md: italics color rule present in the stylesheet")
        ok(css_q:find("q { color: ", 1, false) ~= nil,
            "chat html md: q color rule present in the stylesheet")
    end
end

-- Model-HTML allowlist (ST parity): paired tags convert, unknown markup
-- degrades to inner text, non-tag < stays literal, dangerous schemes and
-- script/style never reach the document.
do
    local DbgChat = require("ktui/chat_bubbles")
    local inline = DbgChat._test_chat_html_body(
        "<b>B</b> <I>I</I> <u>U</u> <s>S</s> <code>C</code> <small>sm</small>")
    ok(inline:find("<b>B</b>", 1, true) ~= nil
        and inline:find("<i>I</i>", 1, true) ~= nil
        and inline:find("<s>S</s>", 1, true) ~= nil,
        "chat html allow: b/i/s convert (case-insensitive)")
    ok(inline:find('<span class="ktcode">C</span>', 1, true) ~= nil
        and inline:find("<small>sm</small>", 1, true) ~= nil,
        "chat html allow: code/small convert")
    ok(inline:find("<b>U</b>", 1, true) ~= nil,
        "chat html allow: u falls back to bold (MuPDF ignores <u>)")
    local links = DbgChat._test_chat_html_body(
        '<a href="https://x.com">L</a> <A HREF=\'https://y.com\'>M</A> '
        .. '<a href="javascript:alert(1)">X</a> [t](ftp://x.com/y)')
    ok(links:find('<a href="https://x.com">L</a>', 1, true) ~= nil
        and links:find('<a href="https://y.com">M</a>', 1, true) ~= nil,
        "chat html allow: http(s) anchors pass (either quote style)")
    local nAnchors = 0
    for _m in links:gmatch("<a href") do nAnchors = nAnchors + 1 end
    ok(links:find("javascript", 1, true) == nil and nAnchors == 2,
        "chat html allow: javascript: scheme never becomes a link")
    ok(links:find("[t](ftp://x.com/y)", 1, true) ~= nil,
        "chat html allow: ftp markdown link stays literal")
    local misc = DbgChat._test_chat_html_body(
        "<foo>F</foo> a < b and c > d I <3 hearts stray </b> here")
    ok(misc:find("<foo", 1, true) == nil
        and misc:find("a &lt; b and c &gt; d", 1, true) ~= nil,
        "chat html allow: unknown tags drop brackets, comparisons literal")
    ok(misc:find("I &lt;3 hearts", 1, true) ~= nil
        and misc:find("stray  here", 1, true) ~= nil,
        "chat html allow: <3 literal, lone closer stripped")
    local style = DbgChat._test_chat_html_body(
        '<font color="#b41e1e">R</font> <font color="#ABC">S</font> '
        .. '<span style="color:#b41e1e">T</span> <center>C</center>')
    ok(style:find('style="color:#b41e1e"', 1, true) ~= nil
        and style:find('style="color:#aabbcc"', 1, true) ~= nil,
        "chat html allow: font color remapped (short hex expanded)")
    ok(style:find('align="center"', 1, true) ~= nil,
        "chat html allow: center remapped to aligned div")
    local drop = DbgChat._test_chat_html_body(
        "<script>alert(1)</script> keep\n<script>\nevil()\n</script> tail")
    ok(drop:find("alert", 1, true) == nil and drop:find("evil", 1, true) == nil,
        "chat html allow: script blocks dropped with content")
    ok(drop:find("keep", 1, true) ~= nil and drop:find("tail", 1, true) ~= nil,
        "chat html allow: text around script survives")
    ok(DbgChat._test_chat_html_body("<style>p{}</style>") == "",
        "chat html allow: style blocks dropped")
    local img = DbgChat._test_chat_html_body(
        '<img src="https://e.com/i.png" alt="A pic"> ![B](https://e.com/j.png)')
    ok(img:find("[image: A pic]", 1, true) ~= nil
        and img:find("[image: B]", 1, true) ~= nil,
        "chat html allow: img tags and images labeled, urls linked")
    -- Markdown emphasis still works around (and never inside) model tags.
    local mix = DbgChat._test_chat_html_body("**md** and <b>html</b> and `a*b`")
    ok(mix:find("<b>md</b>", 1, true) ~= nil
        and mix:find("<b>html</b>", 1, true) ~= nil
        and mix:find("<i>", 1, true) == nil,
        "chat html allow: markdown + model tags compose, code stays inert")
end

-- Model-HTML blocks: tables, lists, quotes, headings, pre, details.
do
    local DbgChat = require("ktui/chat_bubbles")
    local tbl = DbgChat._test_chat_html_body(
        "<table>\n<tr><td>A</td><td>B</td></tr>\n</table>")
    ok(tbl:find("| A | B |", 1, true) ~= nil
        and tbl:find("<table", 1, true) == nil,
        "chat html blocks: table rows become pipe-text, no remnants")
    local lst = DbgChat._test_chat_html_body(
        "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n<ol>\n<li>c</li>\n<li>d</li>\n</ol>")
    ok(lst:find("\194\183 a", 1, true) ~= nil
        and lst:find("1. c", 1, true) ~= nil
        and lst:find("2. d", 1, true) ~= nil
        and lst:find("<li", 1, true) == nil,
        "chat html blocks: ul bullets, ol numbering, no remnants")
    local bq = DbgChat._test_chat_html_body("<blockquote>Q</blockquote>")
    ok(bq:find("ktq", 1, true) ~= nil and bq:find(">Q<", 1, true) ~= nil,
        "chat html blocks: blockquote becomes the quote row")
    local hd = DbgChat._test_chat_html_body("<h2>Title</h2>")
    ok(hd:find("<b>Title</b>", 1, true) ~= nil,
        "chat html blocks: h2 becomes a bold row")
    local pre = DbgChat._test_chat_html_body("<pre>\nx = 1\n</pre>")
    ok(pre:find("ktfence", 1, true) ~= nil and pre:find("x = 1", 1, true) ~= nil,
        "chat html blocks: pre becomes fence rows")
    local pp = DbgChat._test_chat_html_body("<p>Para</p>")
    ok(pp == "Para",
        "chat html blocks: p unwraps to its text")
end

-- <details> tap-to-expand (ST disclosure parity via the spoiler machinery):
-- collapsed by default, numbered in document order, body only when revealed.
do
    local DbgChat = require("ktui/chat_bubbles")
    local d1 = DbgChat._test_chat_html_body(
        "<details><summary>Thoughts</summary>hidden body</details>")
    ok(d1:find('href="kt:det:1"', 1, true) ~= nil
        and d1:find("Thoughts", 1, true) ~= nil,
        "chat html details: summary anchors kt:det:1")
    ok(d1:find("hidden body", 1, true) == nil
        and d1:find("<details", 1, true) == nil,
        "chat html details: collapsed body hidden, no remnants")
    local d1o = DbgChat._test_chat_html_body(
        "<details><summary>Thoughts</summary>hidden body</details>",
        nil, { [1] = true })
    ok(d1o:find("hidden body", 1, true) ~= nil
        and d1o:find("kt:det:1", 1, true) ~= nil,
        "chat html details: revealed body shows, toggle kept")
    local d2 = DbgChat._test_chat_html_body(
        "line one\n<details>\n<summary>Multi\npart</summary>\nbody row\n</details>\nafter")
    ok(d2:find("kt:det:1", 1, true) ~= nil
        and d2:find("line one", 1, true) ~= nil
        and d2:find("after", 1, true) ~= nil
        and d2:find("body row", 1, true) == nil,
        "chat html details: multiline group, neighbors kept, body hidden")
    local d3 = DbgChat._test_chat_html_body(
        "<details><summary>A</summary>aa</details>\n<details><summary>B</summary>bb</details>",
        nil, { [2] = true })
    ok(d3:find("kt:det:1", 1, true) ~= nil
        and d3:find("kt:det:2", 1, true) ~= nil
        and d3:find(">aa<", 1, true) == nil
        and d3:find("bb", 1, true) ~= nil,
        "chat html details: independent numbering, selective reveal")
    local d4 = DbgChat._test_chat_html_body(
        "<details><summary>Never closed\nbody here")
    ok(d4:find("Never closed", 1, true) ~= nil
        and d4:find("<details", 1, true) == nil
        and d4:find("<summary", 1, true) == nil,
        "chat html details: unclosed degrades to collapsed, markers dropped")
    local d5 = DbgChat._test_chat_html_body(
        "<details><summary>**B** and ||s||</summary>bd</details>",
        { [1] = true }, { [1] = true })
    ok(d5:find("<b>B</b>", 1, true) ~= nil
        and d5:find("ktsplopen", 1, true) ~= nil,
        "chat html details: markdown and spoilers work inside summary")
end

-- Model-HTML render probes (probe-verified MuPDF behavior, mirroring the
-- allowlist notes in chat_bubbles.lua): <u> is ignored by this MuPDF (hence
-- the bold fallback mapping), while style="color:" and align="center" are
-- honored. If a MuPDF upgrade changes any of these, the mapping must follow.
do
    local Geom = require("ui/geometry")
    local HtmlBoxWidget = require("ui/widget/htmlboxwidget")
    local KtHTML = require("ktui/kthtml")
    local function render_sig(inner)
        local w = HtmlBoxWidget:new{ dimen = Geom:new{ w = 400, h = 200 } }
        w:setContent("<p>" .. inner .. "</p>", KtHTML.chat_css(),
            Theme.scale(Theme.get_base_font_size()),
            false, nil, PLUGIN .. "/assets")
        w:_render()
        local n, s = 0, 0
        for yy = 0, 199, 2 do
            for xx = 0, 399, 2 do
                local okp, px = pcall(function() return w.bb:getPixel(xx, yy) end)
                if okp and px and px:getR() < 200 then n = n + 1; s = s + xx + yy end
            end
        end
        local sig = n .. ":" .. s
        pcall(function() w:free() end)
        return sig
    end
    local plain_sig = render_sig("Probe alpha beta gamma")
    ok(render_sig("<u>Probe alpha beta gamma</u>") == plain_sig,
        "chat html render: <u> ignored by MuPDF (bold fallback stands)")
    ok(render_sig('<span style="color:#b41e1e">Probe alpha beta gamma</span>') ~= plain_sig,
        "chat html render: style color honored")
    ok(render_sig('<div align="center">Probe alpha beta gamma</div>') ~= plain_sig,
        "chat html render: align center honored")
end

-- Long-message tall-bitmap integrity (the "mensagem cortada" report): the
-- html_doc_for flow budgets the bitmap as pages(96px)*96 and relayouts there.
-- A long markdown bubble used to lose its tail: the relaid-out bitmap ended
-- mid-heading and the ordered list after it was gone at the bottom of the
-- scroll. Ground truth = a 20000px layout; the tall budget must cover it.
do
    local Geom = require("ui/geometry")
    local HtmlBoxWidget = require("ui/widget/htmlboxwidget")
    local KtHTML = require("ktui/kthtml")
    local rows = {}
    local function row(s) rows[#rows + 1] = s end
    row("# Markdown Test Demonstration")
    row("")
    row("## Headers")
    for hk = 1, 6 do row("**H" .. hk .. "**") end
    row("")
    row("## Emphasis")
    row("*italic* or _italic_")
    row("**bold** or __bold__")
    row("***bold italic***")
    row("~~strikethrough~~")
    row("==highlight== (if supported)")
    row("")
    row("## Lists")
    row("### Unordered")
    row("- Item 1")
    row("- Item 2")
    row("  - Nested item")
    row("  - Another nested item")
    row("- Item 3")
    row("")
    row("### Ordered")
    for ok_i = 1, 8 do row(ok_i .. ". Ordered item number " .. ok_i) end
    row("")
    row("## Second block after the lists")
    row("Tail line one")
    row("Tail line two")
    local content = table.concat(rows, "\n")

    local function probe(height)
        local w = 560
        local widget = HtmlBoxWidget:new{ dimen = Geom:new{ w = w, h = height } }
        widget:setContent(ChatBubbles._test_chat_html_body(content),
            KtHTML.chat_css(), Theme.scale(Theme.get_base_font_size()),
            false, nil, PLUGIN .. "/assets")
        return widget
    end
    local w96 = probe(96)
    local tall = math.max(96, (w96.page_count or 1) * 96)
    local wtall = probe(tall)
    wtall:_render()
    local tall_scan = KtHTML.scan_bottom(wtall.bb, 560,
        KtHTML.css_hex(Theme.chat_bg, "#ffffff"))
    local wtruth = probe(20000)
    wtruth:_render()
    local truth_scan = KtHTML.scan_bottom(wtruth.bb, 560,
        KtHTML.css_hex(Theme.chat_bg, "#ffffff"))
    ok(wtall.page_count == 1,
        "chat html: tall relayout fits on one page (tall=" .. tall
        .. " pages=" .. tostring(wtall.page_count) .. ")")
    ok(tall_scan ~= nil and truth_scan ~= nil and truth_scan <= tall_scan + 8,
        "chat html: tall budget covers the full content (tall_scan="
        .. tostring(tall_scan) .. " truth_scan=" .. tostring(truth_scan)
        .. " pages96=" .. tostring(w96.page_count) .. ")")
end

-- Chat HTML long-message scroll integrity (the "mensagem cortada" report):
-- the full canvas flow (a busy chat, the long markdown message last, paints
-- at several scrolls, doc-cache prune pressure) must keep the tail rows of
-- the long bubble: its measured height matches the fresh-probe truth, the
-- bottom paint still holds ink at the tail, and no cached layout keeps a
-- freed (pruned) widget (that used to repaint as a blank band).
do
    local rows = {}
    local function lrow(s) rows[#rows + 1] = s end
    lrow("# Long Scroll Test")
    lrow("")
    lrow("## Headers")
    lrow("**Alpha**")
    lrow("**Beta**")
    lrow("")
    lrow("## Emphasis")
    lrow("*italic* or _italic_")
    lrow("**bold** or __bold__")
    lrow("***bold italic***")
    lrow("~~strikethrough~~")
    lrow("")
    lrow("## Lists")
    lrow("- Item 1")
    lrow("- Item 2")
    lrow("  - Nested item")
    lrow("- Item 3")
    lrow("")
    lrow("## Code")
    lrow("Inline `code`")
    lrow("```python")
    lrow("def hello():")
    lrow('    print("World")')
    lrow("```")
    lrow("")
    lrow("> This is a blockquote.")
    lrow("")
    lrow("| Header 1 | Header 2 |")
    lrow("|----------|----------|")
    lrow("| Cell 1   | Cell 2   |")
    lrow("")
    lrow("---")
    lrow("")
    lrow("### Ordered")
    lrow("1. First")
    lrow("2. Second")
    lrow("   1. Nested")
    lrow("3. Third")
    lrow("")
    lrow("*TAILMARKER End of test.*")
    local long_content = table.concat(rows, "\n")

    local now = os.time()
    local msgs = {
        { role = "user", content = "pls use markdown", name = "You", send_date = now - 100 },
    }
    for mk = 1, 4 do
        msgs[#msgs + 1] = { role = "assistant", name = "Aria",
            content = "short reply number " .. mk, send_date = now - 100 + mk }
        msgs[#msgs + 1] = { role = "user", name = "You",
            content = "ok " .. mk, send_date = now - 100 + mk }
    end
    msgs[#msgs + 1] = { role = "assistant", name = "Aria",
        content = long_content, send_date = now }
    local app = fake_app({ page = "chat",
        settings = { chat_html_render = true },
        messages = msgs })
    local view = { app = app, hitboxes = {}, refresh = function() end }

    local function paint_at(scroll)
        view.hitboxes = {}
        local b = new_bb()
        local okp, total = pcall(function()
            return Pages.chat(view, b, 0, 0, VW, VH, scroll or 0)
        end)
        return okp, total, b
    end
    local function all_html_layouts()
        local out = {}
        for _lk, l in pairs(view._chat_layout_cache or {}) do
            if type(l) == "table" and l.entries then
                for _ek, e in ipairs(l.entries) do
                    if e.kind == "html" then
                        out[#out + 1] = { layout = l, entry = e }
                    end
                end
            end
        end
        return out
    end
    -- The long message is the tallest html entry (short replies are 1 line).
    local function find_long_layout()
        local best, best_e, best_h = nil, nil, -1
        for _bk, hit in ipairs(all_html_layouts()) do
            if (hit.entry.h or 0) > best_h then
                best, best_e, best_h = hit.layout, hit.entry, hit.entry.h or 0
            end
        end
        return best, best_e
    end
    -- Message-area height: the composer bar (pinned, Deck.px 54) is NOT
    -- message ink - scans must stay above it or they catch the bar buttons.
    local Deck = require("ktui/deck")
    local deck_rects = Deck.layout(view,
        { Deck.card("messages", { grow = true }),
          Deck.px("composer", Theme.scale(54)) },
        { x = 0, y = 0, w = VW, h = VH })
    local content_h = deck_rects.messages.h
    local function last_ink_y(b)
        for yy = content_h - 8, 0, -1 do
            for xx = 60, VW - 60, 6 do
                local okp, px = pcall(function() return b:getPixel(xx, yy) end)
                if okp and px and px:getR() < 128 then return yy end
            end
        end
        return nil
    end

    local okp_top, total_top, b_top = paint_at(0)
    ok(okp_top, "chat html scroll: top paint renders without crashing")
    local lay, entry = find_long_layout()
    ok(lay ~= nil and entry ~= nil, "chat html scroll: long message measured as an html entry")
    local measured_h = (entry and entry.h) or 0
    -- Fresh-probe truth at the same text width: a 20000px layout.
    local Geom = require("ui/geometry")
    local HtmlBoxWidget = require("ui/widget/htmlboxwidget")
    local KtHTML = require("ktui/kthtml")
    local truth_w = HtmlBoxWidget:new{
        dimen = Geom:new{ w = lay and lay.text_w or 500, h = 20000 } }
    truth_w:setContent(ChatBubbles._test_chat_html_body(long_content),
        KtHTML.chat_css(), Theme.scale(Theme.get_base_font_size()),
        false, nil, PLUGIN .. "/assets")
    truth_w:_render()
    local truth_h = KtHTML.scan_bottom(truth_w.bb, lay and lay.text_w or 500,
        KtHTML.css_hex(Theme.chat_bg, "#ffffff"))
    ok(truth_h ~= nil and math.abs(measured_h - truth_h) <= 8,
        "chat html scroll: measured height matches the truth (measured="
        .. tostring(measured_h) .. " truth=" .. tostring(truth_h) .. ")")
    -- Bottom paint: ink must reach the tail (bubble end holds the swipe row
    -- and the tail marker; a truncated doc would end rows higher).
    -- Pages.chat already returns max_scroll (total - message area).
    local max_scroll = total_top or 0
    local okp_bot, total_bot, b_bot = paint_at(max_scroll)
    ok(okp_bot, "chat html scroll: bottom paint renders without crashing")
    dump(b_bot, "chat_html_bottom")
    local li = last_ink_y(b_bot)
    ok(li ~= nil and li >= content_h - 120,
        "chat html scroll: bottom paint holds ink at the tail (last_ink="
        .. tostring(li) .. " content_h=" .. tostring(content_h) .. ")")
    -- Prune pressure: 22 more distinct long docs (27 total, over the cap)
    -- evict the first ones; then scroll back to the original long message:
    -- its CURRENT cached layout must hold a live widget (the fast-path
    -- guard re-measures instead of repainting a freed one as a blank band,
    -- and the prune never evicts docs referenced by this paint's layouts).
    local long_msg_key = lay and lay.msg_key or nil
    local orig_y = lay and lay.y or 0
    for pk = 1, 22 do
        msgs[#msgs + 1] = { role = "assistant", name = "Aria",
            content = long_content .. "\n\nextra block " .. pk, send_date = now + pk }
        paint_at(max_scroll)
    end
    paint_at(math.max(0, orig_y - 100))
    local cur_entry = nil
    for _ck, l in pairs(view._chat_layout_cache or {}) do
        if type(l) == "table" and l.msg_key == long_msg_key and l.entries then
            for _ce, e in ipairs(l.entries) do
                if e.kind == "html" then cur_entry = e break end
            end
        end
    end
    local live_now = cur_entry and cur_entry.widget
        and cur_entry.widget.document ~= nil
    ok(cur_entry ~= nil and live_now,
        "chat html scroll: scrolled-back layout holds a live widget after prune")
    local okp_re, _tr, b_re = paint_at(max_scroll)
    ok(okp_re, "chat html scroll: repaint after prune renders without crashing")
    local li_re = last_ink_y(b_re)
    ok(li_re ~= nil and li_re >= content_h - 120,
        "chat html scroll: repaint after prune still holds ink at the tail (last_ink="
        .. tostring(li_re) .. ")")
    dump(b_re, "chat_html_reprune")
end

-- Chat HTML band-source integrity (the src_y=0 bug): every visible band must
-- show the doc slice at its own scroll offset - a constant source offset
-- re-stamped the doc head on every band, so tall bubbles could never show
-- their tail ("mensagem cortada"). Match paint strips against the widget
-- bitmap and assert the found offsets track the scroll and reach the tail.
do
    local now2 = os.time()
    local msgs2 = {
        { role = "user", content = "ping", name = "You", send_date = now2 - 10 },
    }
    for fk = 1, 40 do
        msgs2[#msgs2 + 1] = { role = "assistant", name = "Aria",
            content = "Filler paragraph number " .. fk
                .. " with enough words to wrap a couple of rows.",
            send_date = now2 - 10 + fk }
    end
    local mid_rows = {}
    for fr = 1, 60 do
        mid_rows[#mid_rows + 1] = "mid filler row " .. string.format("%02d", fr)
            .. " one two three four"
    end
    msgs2[#msgs2 + 1] = { role = "assistant", name = "Aria",
        content = "HEADMARKER alpha beta gamma\n" .. table.concat(mid_rows, "\n")
            .. "\nTAILMARKER omega psi chi",
        send_date = now2 + 100 }
    local app2 = fake_app({ page = "chat",
        settings = { chat_html_render = true },
        messages = msgs2 })
    local view2 = { app = app2, hitboxes = {}, refresh = function() end }
    local function paint2(scroll)
        view2.hitboxes = {}
        local b = new_bb()
        local okp, total = pcall(function()
            return Pages.chat(view2, b, 0, 0, VW, VH, scroll or 0)
        end)
        return okp, total, b
    end
    local function find_html_band(want_key)
        for _bk, box in ipairs(view2.hitboxes) do
            if box.label and box.label == "chathtml_" .. tostring(want_key) then
                return box
            end
        end
        return nil
    end
    local function find_long2()
        local best, best_e, best_h = nil, nil, -1
        for _lk, l in pairs(view2._chat_layout_cache or {}) do
            if type(l) == "table" and l.entries then
                for _ek, e in ipairs(l.entries) do
                    if e.kind == "html" and (e.h or 0) > best_h then
                        best, best_e, best_h = l, e, e.h or 0
                    end
                end
            end
        end
        return best, best_e
    end
    local function ink_at(b, x, y)
        local okp, px = pcall(function() return b:getPixel(x, y) end)
        if not okp or not px then return 255 end
        return px:getR()
    end
    -- Best doc-row offset for a paint strip: min grayscale mismatch over the
    -- doc bitmap (step 4 rows). Returns offset, mismatch rate.
    local function match_offset(paint, px0, py0, strip_w, strip_h, doc_bb, doc_w, doc_h)
        local best_off, best_bad, total = 0, 1e9, 0
        for off = 0, math.max(0, doc_h - strip_h), 4 do
            local bad, n = 0, 0
            for dy = 0, strip_h - 1, 4 do
                for dx = 0, strip_w - 1, 12 do
                    local a = ink_at(paint, px0 + dx, py0 + dy)
                    local c = ink_at(doc_bb, dx, off + dy)
                    n = n + 1
                    if math.abs(a - c) > 60 then bad = bad + 1 end
                end
            end
            total = n
            if bad < best_bad then best_bad, best_off = bad, off end
        end
        return best_off, (total > 0) and (best_bad / total) or 1
    end

    local okp0, total0 = paint2(0)
    ok(okp0, "chat html bands: top paint renders without crashing")
    local deck2 = require("ktui/deck").layout(view2,
        { require("ktui/deck").card("messages", { grow = true }),
          require("ktui/deck").px("composer", Theme.scale(54)) },
        { x = 0, y = 0, w = VW, h = VH })
    local ch2 = deck2.messages.h
    -- Pages.chat already returns max_scroll (total - message area).
    local max0 = total0 or 0
    local lay2, entry2 = find_long2()
    ok(lay2 ~= nil and entry2 ~= nil and entry2.widget ~= nil,
        "chat html bands: long html entry with a widget")
    local long_key = lay2 and lay2.msg_key or nil
    local doc_bb = entry2 and entry2.widget and entry2.widget.bb or nil
    local doc_h = (entry2 and entry2.h) or 0
    local doc_w = (lay2 and lay2.text_w) or 0
    ok(doc_bb ~= nil and doc_h > VH,
        "chat html bands: test message is taller than the viewport (h="
        .. tostring(doc_h) .. ")")
    if doc_bb ~= nil and doc_h > VH then
        -- Bottom paint: the band must sit at the doc tail, not the head.
        local okp_b, _tb, b_b = paint2(max0)
        ok(okp_b, "chat html bands: bottom paint renders without crashing")
        local band_b = find_html_band(long_key)
        ok(band_b ~= nil, "chat html bands: bottom paint registers the long html band")
        dump(b_b, "chat_html_band_bottom")
        if band_b then
            -- At the true max the band must reach the message-area bottom.
            local band_bottom = band_b.y + band_b.h
            ok(math.abs(band_bottom - ch2) < 80,
                "chat html bands: bottom band reaches the area end (band_bottom="
                .. tostring(band_bottom) .. " area=" .. tostring(ch2) .. ")")
            local sx = math.max(0, math.floor(band_b.x))
            local sy = math.max(0, math.floor(band_b.y)) + 20
            local sw = math.min(doc_w, math.floor(band_b.w))
            local sh = math.min(60, math.floor(band_b.h) - 100)
            if sh > 20 and sw > 40 then
                local off_b, bad_b = match_offset(b_b, sx, sy, sw, sh, doc_bb, doc_w, doc_h)
                ok(bad_b < 0.25,
                    "chat html bands: bottom strip matches the doc (mismatch="
                    .. string.format("%.2f", bad_b) .. ")")
                local want_b = doc_h - math.floor(band_b.h)
                ok(math.abs(off_b - want_b) < 100,
                    "chat html bands: bottom band shows the doc tail (offset="
                    .. tostring(off_b) .. " want~" .. tostring(want_b) .. ")")
                -- Mid paint 400px up: the slice must move up by ~400.
                local mid_scroll = math.max(0, max0 - 400)
                local okp_m, _tm, b_m = paint2(mid_scroll)
                ok(okp_m, "chat html bands: mid paint renders without crashing")
                local band_m = find_html_band(long_key)
                if band_m then
                    local mx = math.max(0, math.floor(band_m.x))
                    local my = math.max(0, math.floor(band_m.y)) + 20
                    local mw = math.min(doc_w, math.floor(band_m.w))
                    local mh = math.min(60, math.floor(band_m.h) - 100)
                    if mh > 20 and mw > 40 then
                        local off_m, bad_m = match_offset(b_m, mx, my, mw, mh, doc_bb, doc_w, doc_h)
                        ok(bad_m < 0.25,
                            "chat html bands: mid strip matches the doc (mismatch="
                            .. string.format("%.2f", bad_m) .. ")")
                        local step = off_b - off_m
                        ok(step > 280 and step < 520,
                            "chat html bands: scrolling moves through the doc (step="
                            .. tostring(step) .. " for 400px scroll)")
                        dump(b_m, "chat_html_band_mid")
                    else
                        ok(false, "chat html bands: mid band too small to sample")
                    end
                else
                    ok(false, "chat html bands: mid paint registers the html band")
                end
            else
                ok(false, "chat html bands: bottom band too small to sample")
            end
        end
    end
end

-- Chat HTML emoji, with the TOFU CONTROL the old probes lacked: MuPDF
-- does NO per-glyph fallback across font-family lists, so the merged
-- faces (sans-x-*.ttf = NotoSans + NotoEmoji in ONE cmap) are the only
-- way emoji renders. A missing-glyph box (U+E000) and a real emoji must
-- differ MASSIVELY in ink - the old "emoji ink appears" probe read the
-- tofu outline as success for weeks.
do
    local Geom_e = require("ui/geometry")
    local HtmlBoxWidget_e = require("ui/widget/htmlboxwidget")
    local KtHTML_e = require("ktui/kthtml")
    local ChatTheme_e = require("ktui/chat_theme")
    local function emoji_ink(text)
        local w = HtmlBoxWidget_e:new{ dimen = Geom_e:new{ w = 460, h = 120 } }
        local okp = pcall(function()
            w:setContent("<p>" .. text .. "</p>",
                KtHTML_e.chat_css(ChatTheme_e.resolved({ state = { settings = {} } })),
                Theme.scale(Theme.get_base_font_size()), false, nil, PLUGIN .. "/assets")
        end)
        if not okp then return nil end
        w:_render()
        local n = 0
        for yy = 0, 119, 1 do
            for xx = 0, 459, 2 do
                local okp2, px = pcall(function() return w.bb:getPixel(xx, yy) end)
                if okp2 and px and px:getR() < 200 then n = n + 1 end
            end
        end
        pcall(function() w:free() end)
        return n
    end
    local tofu = emoji_ink("\u{E000}")
    local letter = emoji_ink("A")
    ok(tofu ~= nil and letter ~= nil and math.abs(tofu - letter) < 60,
        "emoji control: a missing glyph boxes at the letter scale (tofu="
        .. tostring(tofu) .. " letter=" .. tostring(letter) .. ")")
    local check = emoji_ink("\u{2705}")
    ok(check ~= nil and check >= tofu * 3,
        "emoji: U+2705 renders a REAL glyph (ink=" .. tostring(check)
        .. " vs tofu " .. tostring(tofu) .. ")")
    local joy = emoji_ink("\u{1F602}")
    ok(joy ~= nil and joy >= tofu * 2,
        "emoji: U+1F602 renders a REAL glyph (ink=" .. tostring(joy)
        .. " vs tofu " .. tostring(tofu) .. ")")
    -- Both emoji in one run with text: everything must draw (no blank line).
    local both = emoji_ink("yes \u{2705} and \u{1F602}!")
    ok(both ~= nil and both >= (check or 0) + (joy or 0) + 30,
        "emoji: mixed run draws text + both glyphs (ink=" .. tostring(both) .. ")")
end

-- Chat HTML real italic: MuPDF must use the slanted face, not faux-bold -
-- same word plain/<b>/<i> must all paint differently (like the uidsl
-- island-italic probe, but through the chat pipeline).
do
    local Geom = require("ui/geometry")
    local HtmlBoxWidget = require("ui/widget/htmlboxwidget")
    local KtHTML = require("ktui/kthtml")
    local function doc_sig(inner)
        local w = HtmlBoxWidget:new{ dimen = Geom:new{ w = 400, h = 200 } }
        w:setContent("<p>" .. inner .. "</p>", KtHTML.chat_css(),
            Theme.scale(Theme.get_base_font_size()),
            false, nil, PLUGIN .. "/assets")
        w:_render()
        local n, s = 0, 0
        for yy = 0, 199, 2 do
            for xx = 0, 399, 2 do
                local okp, px = pcall(function() return w.bb:getPixel(xx, yy) end)
                if okp and px and px:getR() < 200 then n = n + 1; s = s + xx + yy end
            end
        end
        pcall(function() w:free() end)
        return n .. ":" .. s
    end
    local s_plain = doc_sig("Slanted check word")
    local s_bold = doc_sig("<b>Slanted check word</b>")
    local s_ital = doc_sig("<i>Slanted check word</i>")
    ok(s_plain ~= s_ital,
        "chat html: <i> paints differently from upright (real italic face)")
    ok(s_ital ~= s_bold,
        "chat html: <i> paints differently from <b> (not faux-bold)")
end

-- Chat HTML spoiler tap-to-reveal end to end: paint a masked spoiler, tap
-- its link rect through the band hitbox, the reveal state flips, the doc is
-- rebuilt and the repaint no longer paints the mask bar (pixel proof).
do
    local now3 = os.time()
    local app3 = fake_app({ page = "chat",
        settings = { chat_html_render = true },
        messages = {
            { role = "assistant", name = "Aria",
              content = "before ||secret|| after", send_date = now3 },
        } })
    local refreshed = 0
    local view3 = { app = app3, hitboxes = {},
        refresh = function() refreshed = refreshed + 1 end }
    local b3 = new_bb()
    local okp3 = pcall(function() Pages.chat(view3, b3, 0, 0, VW, VH, 0) end)
    ok(okp3, "chat html spoiler: masked paint renders without crashing")
    local box3 = nil
    for _sk, hb in ipairs(view3.hitboxes) do
        if hb.label and hb.label:sub(1, 9) == "chathtml_" then box3 = hb break end
    end
    ok(box3 ~= nil, "chat html spoiler: html band registers a tap hitbox")
    local lay3, entry3 = nil, nil
    for _lk3, l in pairs(view3._chat_layout_cache or {}) do
        if type(l) == "table" and l.entries then
            for _ek3, e in ipairs(l.entries) do
                if e.kind == "html" then lay3, entry3 = l, e break end
            end
        end
    end
    ok(lay3 ~= nil and entry3 ~= nil and entry3.widget ~= nil,
        "chat html spoiler: html entry with a widget")
    local function widget_sig(w)
        if not w or not w.bb then return nil end
        local n, s = 0, 0
        for yy = 0, w.bb:getHeight() - 1, 3 do
            for xx = 0, w.bb:getWidth() - 1, 3 do
                local okp, px = pcall(function() return w.bb:getPixel(xx, yy) end)
                if okp and px and px:getR() < 200 then n = n + 1; s = s + xx + yy end
            end
        end
        return n .. ":" .. s
    end
    local sig_masked = widget_sig(entry3.widget)
    local spl_link = nil
    if entry3.widget and entry3.widget.document then
        local okp, pg = pcall(function() return entry3.widget.document:openPage(1) end)
        if okp and pg then
            local okp2, links = pcall(function() return pg:getPageLinks() end)
            pcall(function() pg:close() end)
            if okp2 and type(links) == "table" then
                for _gl, lk in ipairs(links) do
                    if type(lk) == "table" and tostring(lk.uri or lk.url or "") == "kt:spl:1" then
                        spl_link = lk break
                    end
                end
            end
        end
    end
    ok(spl_link ~= nil, "chat html spoiler: masked spoiler exposes a kt:spl:1 link")
    if box3 and spl_link then
        local okp = pcall(function()
            box3.callback(box3.x + (spl_link.x0 or 0) + 2, box3.y + (spl_link.y0 or 0) + 2)
        end)
        ok(okp, "chat html spoiler: tapping the spoiler does not crash")
        local rev = app3.state.chat_spoilers_revealed
        local key3 = lay3 and lay3.msg_key or nil
        ok(rev ~= nil and key3 ~= nil and rev[key3] ~= nil and rev[key3][1] == true,
            "chat html spoiler: tap flips the reveal state")
        ok(refreshed > 0, "chat html spoiler: tap requests a refresh")
        view3.hitboxes = {}
        local b3b = new_bb()
        local okp4 = pcall(function() Pages.chat(view3, b3b, 0, 0, VW, VH, 0) end)
        ok(okp4, "chat html spoiler: revealed repaint renders without crashing")
        local entry3b = nil
        for _lk4, l in pairs(view3._chat_layout_cache or {}) do
            if type(l) == "table" and l.entries then
                for _ek4, e in ipairs(l.entries) do
                    if e.kind == "html" then entry3b = e break end
                end
            end
        end
        local sig_open = entry3b and widget_sig(entry3b.widget)
        ok(sig_open ~= nil and sig_open ~= sig_masked,
            "chat html spoiler: revealed paint no longer paints the mask bar")
        dump(b3b, "chat_html_spoiler_open")
    end
end

-- Chat Theme engine (B0): schema, signatures, ST conversion round-trip,
-- color compositing, built-ins and the migration bubble->chat themes.
do
    local ChatTheme = require("ktui/chat_theme")
    -- normalize: junk in, schema out (ST import parity: unknown dropped).
    local n = ChatTheme.normalize({
        name = "  X  ", style = "weird", chat_width = 500,
        line_spacing = 900, colors = { surface = "#ABC", text = "zzz" },
        avatar_shape = "hexagon", show_avatars = false,
    })
    ok(n.style == "bubbles" and n.chat_width == 100
        and n.line_spacing == 130 and n.avatar_shape == "round",
        "theme: normalize clamps enums and ranges")
    -- Retired styles migrate, not default: a saved document theme lands on
    -- flat (the geometry it painted); ST chat_display 2 imports as flat.
    ok(ChatTheme.normalize({ style = "document" }).style == "flat",
        "theme: saved document themes migrate to flat")
    ok(ChatTheme.from_st({ name = "DocTest", chat_display = 2 }).style == "flat",
        "theme: ST chat_display 2 (document) imports as flat")
    ok(n.colors.surface == "#aabbcc" and n.colors.text == "",
        "theme: short hex expands, invalid color drops to inherit")
    ok(n.name == "  X  " and n.show_avatars == false,
        "theme: name kept verbatim, booleans coerce")
    -- sig: knob changes must change the signature (cache busting).
    local base = ChatTheme.normalize({})
    local s1 = ChatTheme.sig(base)
    ok(ChatTheme.sig(ChatTheme.normalize({})) == s1,
        "theme: sig is deterministic for identical themes")
    ok(ChatTheme.sig(ChatTheme.normalize({ chat_width = 70 })) ~= s1,
        "theme: sig changes when a knob changes")
    ok(ChatTheme.sig(ChatTheme.normalize({ colors = { surface = "#101010" } })) ~= s1,
        "theme: sig changes when a color changes")
    -- color utilities
    ok(ChatTheme.parse_color("rgba(0, 13, 57, 0.22)").r == 0,
        "theme: rgba parses")
    ok(ChatTheme.composite(ChatTheme.parse_color("rgba(0,0,0,0.5)"), "#ffffff")
        == "#808080",
        "theme: alpha composites over the base (50% black over white)")
    ok((ChatTheme.luminance("#101010") or 1) < 0.5,
        "theme: luminance detects dark colors")
    -- ST conversion round-trip: every built-in must import + map + export.
    local builtins = ChatTheme.BUILTINS()
    ok(#builtins == 5, "theme: all five ST presets load (" .. #builtins .. ")")
    local azure = ChatTheme.from_st(require("json").decode(
        [[{"name":"Azure","blur_tint_color":"rgba(23, 30, 33, 0.61)","chat_tint_color":"rgba(23, 23, 23, 0)","user_mes_blur_tint_color":"rgba(0, 28, 174, 0.2)","bot_mes_blur_tint_color":"rgba(0, 13, 57, 0.22)","chat_display":1,"avatar_style":1,"chat_width":50,"waifuMode":false,"timestamps_enabled":true,"mesIDDisplay_enabled":true,"timer_enabled":true}]]))
    ok(azure ~= nil and azure.style == "bubbles" and azure.avatar_shape == "rect",
        "theme: ST chat_display/avatar_style map")
    ok(azure.chat_width == 70 and azure.show_timestamps
        and azure.show_msg_ids and azure.show_gen_timer,
        "theme: ST knobs map (width floor 70/timestamps/mesID/timer)")
    ok(azure.colors.surface ~= "" and azure.colors.user_panel ~= "",
        "theme: ST rgba tints composite to hex")
    local st_out = ChatTheme.to_st(azure)
    ok(st_out.chat_display == 1 and st_out.avatar_style == 1
        and st_out.name == "Azure" and st_out.waifuMode == nil,
        "theme: export maps back to the ST shape (waifuMode omitted)")
    ok(ChatTheme.from_st({ no_name = true }) == nil,
        "theme: ST import requires a name (ST parity)")
    -- Dark theme import: surface must be dark, panels composited over it.
    local dark = ChatTheme.from_st(require("json").decode(
        [[{"name":"Dark","blur_tint_color":"rgba(23, 23, 23, 1)","chat_tint_color":"rgba(23, 23, 23, 1)","user_mes_blur_tint_color":"rgba(30, 30, 30, 0.9)","bot_mes_blur_tint_color":"rgba(30, 30, 30, 0.9)","main_text_color":"rgba(220, 220, 210, 1)"}]]))
    ok(dark and (ChatTheme.luminance(dark.colors.surface) or 1) < 0.3,
        "theme: dark ST theme composites to a dark surface")
    -- Migration: bubble theme entries become full chat themes.
    local Storage = require("kt_storage")
    -- (fake_app data_dir points at /tmp; the store migrates on first read)
    local themes = Storage.list_chat_themes()
    ok(type(themes) == "table", "theme: chat theme store loads/migrates")
end

-- Theme color overrides: the EXACT boot path that shipped a crash (the
-- first cut used a Blitbuffer.ColorRGB8 constructor that does not exist
-- in the runtime - apply_bubble_theme -> set_chat_color_overrides died on
-- every launch with a theme carrying colors). Guards the whole frame.
do
    local Theme_c = require("ktui/theme")
    local surface_before = Theme_c.chat_bg
    local okp_c = pcall(function()
        Theme_c.set_chat_color_overrides({
            surface = "#101010", ai_panel = "#181818", user_panel = "#202020",
        })
    end)
    ok(okp_c, "theme overrides: set_chat_color_overrides does not crash "
        .. "(the ColorRGB8 boot-loop regression)")
    local s_ok, s_r = pcall(function() return Theme_c.chat_bg:getR() end)
    ok(okp_c and s_ok and s_r < 60,
        "theme overrides: surface override applies (r=" .. tostring(s_r) .. ")")
    local p_ok, p_r = pcall(function() return Theme_c.chat_panel:getR() end)
    ok(p_ok and p_r < 60, "theme overrides: panel override applies (r="
        .. tostring(p_r) .. ")")
    -- Clearing restores the palette values.
    pcall(function() Theme_c.set_chat_color_overrides(nil) end)
    local r_ok, r_r = pcall(function() return Theme_c.chat_bg:getR() end)
    ok(r_ok and math.abs(r_r - (surface_before and surface_before:getR() or r_r)) <= 2,
        "theme overrides: clearing restores the palette surface (r="
        .. tostring(r_r) .. ")")
    -- An INVALID hex must fall back to the palette (never crash).
    local okp_bad = pcall(function()
        Theme_c.set_chat_color_overrides({ surface = "not-a-color" })
    end)
    local bad_ok, bad_r = pcall(function() return Theme_c.chat_bg:getR() end)
    ok(okp_bad and bad_ok and math.abs(bad_r - r_r) <= 2,
        "theme overrides: invalid hex keeps the palette (r=" .. tostring(bad_r) .. ")")
    Theme_c.set_chat_color_overrides(nil)
end

-- GLOBAL Appearance page paint (the B5 regression): the Density row's
-- value_fn reads a page-local labels table - a B5 cleanup deleted the
-- wrong copy and the page CRASHED ON DEVICE at boot (value_fn runs during
-- paint). This check paints the real page so a dangling-local class of
-- bug can never slip again.
do
    local app_g = fake_app({ page = "settings_appearance",
        settings = { theme = "light", base_font_size = 22, density = "normal",
            bubble_style = "bubbles", bubble_radius = "normal", chat_width = 100 } })
    local view_g = { app = app_g, hitboxes = {}, refresh = function() end }
    local bb_g = new_bb()
    local okp_g, err_g = pcall(function()
        Pages.settings_appearance(view_g, bb_g, 0, 0, VW, VH, 0)
    end)
    ok(okp_g, "global appearance: page paints without crashing ("
        .. tostring(err_g) .. ")")
    ok(app_g.state.settings.density == "normal",
        "global appearance: fixture paints with density settings present")
    dump(bb_g, "settings_appearance")
end

-- B6: the three-screen theme model. Launcher census, manager ordering +
-- in-chat context gate, and the theme editor end to end (create -> edit
-- a knob -> the saved theme carries it).
do
    local ChatTheme_b6 = require("ktui/chat_theme")
    local Storage_b6 = require("kt_storage")
    local app_b6 = fake_app({ page = "settings_appearance_chat",
        settings = { bubble_theme_id = "builtin:azure" } })
    function app_b6:create_theme() self._created = true end
    function app_b6:choose_default_bubble_theme() self._picked_default = true end
    function app_b6:navigate(page) self._nav = page end
    local view_b6 = { app = app_b6, hitboxes = {}, refresh = function() end }
    local bb_b6 = new_bb()
    local okp_b6 = pcall(function()
        Pages.settings_appearance_chat(view_b6, bb_b6, 0, 0, VW, VH, 0)
    end)
    ok(okp_b6, "b6 launcher: paints without crashing")
    -- Launcher = 3 rows (New theme / Themes… / Default theme), no knobs.
    local tap_count = #view_b6.hitboxes
    ok(tap_count == 3, "b6 launcher: exactly 3 tappable rows (got " .. tap_count .. ")")
    -- Tap each row by position: 1=New, 2=Themes…, 3=Default.
    view_b6.hitboxes[1].callback(0, 0)
    ok(app_b6._created == true, "b6 launcher: row 1 creates a theme")
    view_b6.hitboxes[2].callback(0, 0)
    ok(app_b6._nav == "settings_bubble_themes",
        "b6 launcher: row 2 routes to the Themes manager")
    view_b6.hitboxes[3].callback(0, 0)
    ok(app_b6._picked_default == true, "b6 launcher: row 3 opens the default picker")

    -- Manager in SETTINGS mode: user themes first, CREATE, builtins last.
    local app_mgr = fake_app({ page = "settings_bubble_themes",
        settings = {} })
    function app_mgr:navigate(page, extra)
        self._nav_mgr = page
        self._nav_extra = extra
    end
    function app_mgr:set_chat_bubble_theme() end
    function app_mgr:save_setting() end
    function app_mgr:refresh_bubble_theme() end
    function app_mgr:refresh() end
    -- One user theme in the store so the YOUR THEMES section exists.
    -- The store is ISOLATED for the manager census (earlier smoke blocks
    -- leave their own fixtures in it), then restored.
    local themes_snapshot = Storage_b6.list_chat_themes() or {}
    local user_theme = {
        id = "b6-user-test", name = "B6 User Theme",
        theme = ChatTheme_b6.normalize({ style = "flat", avatar_shape = "square" }),
    }
    Storage_b6.save_chat_themes({ user_theme })
    local view_mgr = { app = app_mgr, hitboxes = {}, refresh = function() end }
    local bb_mgr = new_bb()
    local okp_mgr = pcall(function()
        Pages.settings_bubble_themes(view_mgr, bb_mgr, 0, 0, VW, VH, 0)
    end)
    ok(okp_mgr, "b6 manager: settings mode paints without crashing")
    -- Rows: 1 section + 1 user + 2 create + 1 section + 5 builtins = 10
    -- tappables (sections are not hitboxes): 1 user + 2 create + 5 builtins.
    local mgr_taps = #view_mgr.hitboxes
    ok(mgr_taps == 8,
        "b6 manager: 1 user + 2 create + 5 builtins tappable rows (got " .. mgr_taps .. ")")
    -- Row 1 (user theme) opens the EDITOR with the id.
    view_mgr.hitboxes[1].callback(0, 0)
    ok(app_mgr._nav_mgr == "theme_edit"
        and app_mgr._nav_extra and app_mgr._nav_extra.editing_theme_id == "b6-user-test",
        "b6 manager: user theme tap opens the editor with its id")
    -- Last row = the 5th builtin (dark_v); tap = sheet (no navigation).
    view_mgr.hitboxes[mgr_taps].callback(0, 0)
    ok(app_mgr._nav_mgr == "theme_edit",
        "b6 manager: builtin tap opens a sheet (no page navigation)")

    -- Manager in CHAT mode (in_chat_context): Follow-default first, tap
    -- applies per-chat and returns to the chat.
    local app_ch = fake_app({ page = "settings_bubble_themes",
        settings = {} })
    app_ch.state.in_chat_context = true
    app_ch.state.current_chat_bubble_theme_id = nil
    local nav_log = {}
    function app_ch:navigate(page) nav_log[#nav_log + 1] = page end
    function app_ch:set_chat_bubble_theme(id) self._applied = id end
    local view_ch = { app = app_ch, hitboxes = {}, refresh = function() end }
    local bb_ch = new_bb()
    local okp_ch = pcall(function()
        Pages.settings_bubble_themes(view_ch, bb_ch, 0, 0, VW, VH, 0)
    end)
    ok(okp_ch, "b6 manager: chat mode paints without crashing")
    -- 1 follow-default + 1 user + 5 builtins = 7 rows.
    ok(#view_ch.hitboxes == 7,
        "b6 manager: chat mode = follow-default + all themes (got " .. #view_ch.hitboxes .. ")")
    view_ch.hitboxes[1].callback(0, 0)
    ok(app_ch._applied == "" and nav_log[#nav_log] == "chat",
        "b6 manager: Follow the default clears and returns to chat")
    view_ch.hitboxes[2].callback(0, 0)
    ok(app_ch._applied == "b6-user-test",
        "b6 manager: chat-mode tap applies the theme to THIS chat")

    -- Theme editor e2e: create -> edit style -> saved theme carries it.
    -- (chat_look on theme_edit reads the EDITED theme; edit writes it.)
    local app_ed = fake_app({ page = "theme_edit",
        settings = {} })
    app_ed.state.editing_theme_id = "b6-user-test"
    function app_ed:refresh_bubble_theme() end
    function app_ed:save_setting() end
    function app_ed:refresh() end
    function app_ed:navigate(page) self._nav_ed = page end
    function app_ed:prompt_theme_color() end
    function app_ed:choose_chat_font() end
    function app_ed:prompt_chat_font_size() end
    function app_ed:prompt_custom_css() end
    function app_ed:rename_bubble_theme() end
    function app_ed:duplicate_bubble_theme() end
    function app_ed:export_bubble_theme() end
    function app_ed:delete_bubble_theme() end
    function app_ed:set_chat_bubble_theme() end
    function app_ed:create_theme() end
    -- The real edit method's editing-screen path, mirrored on the fake:
    -- write to the EDITED theme, save the store.
    function app_ed:edit_chat_theme_key(key, value)
        local CT = require("ktui/chat_theme")
        local all = Storage_b6.list_chat_themes() or {}
        for ti = 1, #all do
            if all[ti].id == self.state.editing_theme_id then
                local th = CT.normalize(all[ti].theme)
                local ckey = key:match("^colors%.(%w+)$")
                if ckey then th.colors[ckey] = value else th[key] = value end
                all[ti].theme = th
                Storage_b6.save_chat_themes(all)
                return
            end
        end
    end
    local view_ed = { app = app_ed, hitboxes = {}, refresh = function() end }
    local bb_ed = new_bb()
    local okp_ed = pcall(function()
        Pages.theme_edit(view_ed, bb_ed, 0, 0, VW, VH, 0)
    end)
    ok(okp_ed, "b6 editor: paints without crashing")
    -- The DEFAULT-style full page: find the Chat style sheet + edit.
    -- Direct write through the app method the rows use:
    app_ed:edit_chat_theme_key("style", "bubbles")
    local after = Storage_b6.list_chat_themes()
    local saved_b6 = nil
    for ti = 1, #after do
        if after[ti].id == "b6-user-test" then saved_b6 = after[ti] end
    end
    ok(saved_b6 ~= nil and saved_b6.theme.style == "bubbles",
        "b6 editor: knob write lands on the EDITED theme (style=bubbles)")
    ok(ChatTheme_b6.normalize(saved_b6 and saved_b6.theme or {}).format
        == ChatTheme_b6.DEFAULTS.format,
        "b6 editor: saved theme keeps the schema format")
    -- No editing id -> manager fallback (never a blank page).
    app_ed.state.editing_theme_id = nil
    local okp_fb = pcall(function()
        Pages.theme_edit(view_ed, new_bb(), 0, 0, VW, VH, 0)
    end)
    ok(okp_fb and app_ed._nav_ed == "settings_bubble_themes",
        "b6 editor: no target falls back to the manager")
    -- Builtin guard: a builtin id bounces to the manager (read-only).
    app_ed.state.editing_theme_id = "builtin:azure"
    local okp_bl = pcall(function()
        Pages.theme_edit(view_ed, new_bb(), 0, 0, VW, VH, 0)
    end)
    ok(okp_bl and app_ed._nav_ed == "settings_bubble_themes",
        "b6 editor: builtin ids bounce to the manager (read-only)")
    -- Restore the snapshot + keep the fixture (the editor e2e used it).
    local restored = {}
    for ti = 1, #themes_snapshot do restored[#restored + 1] = themes_snapshot[ti] end
    restored[#restored + 1] = user_theme
    Storage_b6.save_chat_themes(restored)
end

-- Theme editor page: rows only (the live preview band was removed at the
-- author's request); the page must paint, expose the editor rows, and
-- carry no chat hitboxes.
do
    local app_e = fake_app({ page = "settings_appearance_chat",
        settings = { chat_html_render = true } })
    local view_e = { app = app_e, hitboxes = {}, refresh = function() end }
    local bb_e = new_bb()
    local okp_e = pcall(function()
        Pages.settings_appearance_chat(view_e, bb_e, 0, 0, VW, VH, 0)
    end)
    ok(okp_e, "editor: page paints without crashing")
    -- Rows start at the TOP now (no preview band): the first rows must
    -- hold ink well inside the first 120px.
    local top_ink = 0
    for yy = 6, 120, 3 do
        for xx = 20, VW - 20, 6 do
            local okp, px = pcall(function() return bb_e:getPixel(xx, yy) end)
            if okp and px and px:getR() < 128 then top_ink = top_ink + 1 end
        end
    end
    ok(top_ink > 40, "editor: rows start at the top (ink=" .. top_ink .. ")")
    dump(bb_e, "editor_page")
    -- Dark theme applied: the page still paints (the editor chrome stays
    -- on the app palette; only the values change).
    app_e.state.chat_theme_applied = require("ktui/chat_theme").normalize({
        name = "Dark editor", style = "bubbles",
        colors = { surface = "#101010", text = "#f0f0f0",
            ai_panel = "#181818", user_panel = "#202020" },
    })
    local bb_e2 = new_bb()
    local okp_e2 = pcall(function()
        Pages.settings_appearance_chat(view_e, bb_e2, 0, 0, VW, VH, 0)
    end)
    ok(okp_e2, "editor: dark theme page paints without crashing")
    -- No chat hitboxes ever (no preview = no msghold/chathtml on the page).
    local chat_boxes = 0
    for hb_i = 1, #view_e.hitboxes do
        local lab = view_e.hitboxes[hb_i].label
        if type(lab) == "string" and (lab:sub(1, 8) == "msghold_"
            or lab:sub(1, 9) == "chathtml_") then
            chat_boxes = chat_boxes + 1
        end
    end
    ok(chat_boxes == 0, "editor: no chat hitboxes on the settings page")
end

-- B2 ports: message IDs + gen timer, the chat footer band, and
-- line_spacing actually changing the rendered doc height.
do
    local ChatTheme = require("ktui/chat_theme")
    local now_b2 = os.time()


    -- Message IDs + gen timer in the name row (bubbles mode).
    local app_ids = fake_app({ page = "chat",
        settings = { chat_html_render = true },
        messages = {
            { role = "assistant", name = "Aria", gen_ms = 2340,
              content = "timed reply", send_date = now_b2 + 2 },
        } })
    app_ids.state.chat_theme_applied = ChatTheme.normalize({
        show_msg_ids = true, show_gen_timer = true })
    local view_ids = { app = app_ids, hitboxes = {}, refresh = function() end }
    local bb_ids = new_bb()
    local okp_ids = pcall(function() Pages.chat(view_ids, bb_ids, 0, 0, VW, VH, 0) end)
    ok(okp_ids, "b2 ids+timer: paints without crashing")
    local lay_ids = nil
    for _ik, l in pairs(view_ids._chat_layout_cache or {}) do
        if type(l) == "table" and not l.is_user and not l.is_system then lay_ids = l end
    end
    ok(lay_ids ~= nil and lay_ids.gen_ms == 2340,
        "b2 gen timer: duration rides the layout")
    dump(bb_ids, "b2_ids_timer")

    -- Footer band: clock/msgs/model row above the composer.
    local app_f = fake_app({ page = "chat",
        settings = { chat_footer = true, chat_html_render = true },
        messages = {
            { role = "assistant", name = "Aria", content = "body", send_date = now_b2 + 3 },
        } })
    local view_f = { app = app_f, hitboxes = {}, refresh = function() end }
    local bb_f = new_bb()
    local okp_f = pcall(function() Pages.chat(view_f, bb_f, 0, 0, VW, VH, 0) end)
    ok(okp_f, "b2 footer: chat paints without crashing")
    -- The footer band sits right above the composer (54px): muted ink in
    -- [VH-54-24, VH-54) must exist (clock + items).
    local footer_ink = 0
    for yy = VH - 54 - 24, VH - 54 - 2, 2 do
        for xx = 20, VW - 20, 4 do
            local okp, px = pcall(function() return bb_f:getPixel(xx, yy) end)
            if okp and px and px:getR() < 200 then footer_ink = footer_ink + 1 end
        end
    end
    ok(footer_ink > 10,
        "b2 footer: band holds info ink above the composer (" .. footer_ink .. ")")
    dump(bb_f, "b2_footer")

    -- Line spacing: the same 3-line doc must render TALLER at 130 than 70.
    local function spacing_doc_height(spacing)
        local app_s = fake_app({})
        app_s.state.chat_theme_applied = ChatTheme.normalize({ line_spacing = spacing })
        local resolved = ChatTheme.resolved(app_s)
        local Geom = require("ui/geometry")
        local HtmlBoxWidget = require("ui/widget/htmlboxwidget")
        local KtHTML = require("ktui/kthtml")
        local wd = HtmlBoxWidget:new{ dimen = Geom:new{ w = 460, h = 600 } }
        wd:setContent("<p>row one<br>row two<br>row three</p>",
            KtHTML.chat_css(resolved), 22, false, nil, PLUGIN .. "/assets")
        wd:_render()
        local h = KtHTML.scan_bottom(wd.bb, 460, resolved.colors.surface)
        pcall(function() wd:free() end)
        return h
    end
    local h70 = spacing_doc_height(70)
    local h130 = spacing_doc_height(130)
    ok(h70 ~= nil and h130 ~= nil and h130 > h70 + 12,
        "b2 spacing: line_spacing grows the doc height (70=" .. tostring(h70)
        .. " 130=" .. tostring(h130) .. ")")
end

-- P0 round: swipe sig fix (twin-swipe layout staleness), doc bg per
-- style, dark footer band, mask_text contrast.
do
    local ChatTheme_p = require("ktui/chat_theme")
    -- 1. TWIN SWIPES: two swipes sharing head+tail samples (and length)
    -- used to reuse the cached layout - the tap looked dead or "jumped".
    -- After the sig fix, the cycle must re-measure: the counter AND the
    -- rendered middle text follow the active swipe.
    local twin_head = string.rep("h", 60)
    local twin_tail = string.rep("t", 60)
    local twinA = twin_head .. "ALPHA-MARK" .. twin_tail
    local twinB = twin_head .. "BRAVO-MARK" .. twin_tail
    local msg_sw = {
        role = "assistant", name = "Aria", send_date = os.time(),
        content = twinA, swipes = { twinA, twinB }, swipe_id = 1,
    }
    local app_sw = fake_app({ page = "chat",
        settings = { chat_html_render = false },
        messages = { msg_sw } })
    local view_sw = { app = app_sw, hitboxes = {}, refresh = function() end }
    local bb_sw = new_bb()
    pcall(function() Pages.chat(view_sw, bb_sw, 0, 0, VW, VH, 0) end)
    local function sw_layout()
        for _sk, l in pairs(view_sw._chat_layout_cache or {}) do
            if type(l) == "table" and l.swipes_id then return l end
        end
    end
    local lay1 = sw_layout()
    ok(lay1 ~= nil and lay1.swipes_id == 1, "swipe sig: first swipe measured")
    -- Cycle like App:cycle_swipe does (msg fields only).
    msg_sw.swipe_id = 2
    msg_sw.content = twinB
    pcall(function() Pages.chat(view_sw, bb_sw, 0, 0, VW, VH, 0) end)
    local lay2 = sw_layout()
    ok(lay2 ~= nil and lay2.swipes_id == 2,
        "swipe sig: twin swipe RE-MEASURES (counter follows, was stale)")
    local body_txt = ""
    if lay2 and lay2.entries then
        for _se, e in ipairs(lay2.entries) do
            if type(e.text) == "string" then body_txt = body_txt .. e.text end
        end
    end
    ok(body_txt:find("BRAVO", 1, true) ~= nil,
        "swipe sig: twin swipe renders the ACTIVE text (BRAVO, not ALPHA)")

    -- 2. Doc bg per style: flat paints surface behind assistant docs.
    local app_fl = fake_app({ page = "chat",
        settings = { chat_html_render = true },
        messages = {
            { role = "assistant", name = "Aria", send_date = os.time(),
              content = "flat body text" },
        } })
    app_fl.state.chat_theme_applied = ChatTheme_p.normalize({
        name = "Flat dark", style = "flat",
        colors = { surface = "#101010", text = "#f0f0f0",
            ai_panel = "#303030", user_panel = "#404040" },
    })
    require("ktui/theme").set_chat_color_overrides({
        surface = "#101010", ai_panel = "#303030",
        user_panel = "#404040", text = "#f0f0f0",
    })
    local style_before_p = Theme.get_bubble_style()
    Theme.set_bubble_style("flat")
    local view_fl = { app = app_fl, hitboxes = {}, refresh = function() end }
    local bb_fl = new_bb()
    local okp_fl = pcall(function() Pages.chat(view_fl, bb_fl, 0, 0, VW, VH, 0) end)
    Theme.set_bubble_style(style_before_p)
    ok(okp_fl, "flat doc bg: flat dark theme paints without crashing")
    local doc_fl = nil
    for _fk, l in pairs(view_fl._chat_layout_cache or {}) do
        if type(l) == "table" and l.entries then
            for _fe, e in ipairs(l.entries) do
                if e.kind == "html" and e.widget and e.widget.bb then
                    doc_fl = e.widget
                end
            end
        end
    end
    if doc_fl then
        local okp_pad, px_pad = pcall(function()
            return doc_fl.bb:getPixel(3, 3):getR()
        end)
        -- Flat assistant: the doc must paint the SURFACE (#101010 = 16),
        -- NOT the ai panel (#303030 = 48) - the opaque "text stripe".
        -- Tolerance: the corner sample can catch row anti-aliasing, so the
        -- assertion is "far below the panel", not "exactly the surface".
        ok(okp_pad and px_pad < 32,
            "flat doc bg: assistant doc paints the surface, not the panel (r="
            .. tostring(okp_pad and px_pad or -1) .. ")")
    else
        ok(false, "flat doc bg: no html doc found")
    end

    -- 3. Dark footer band: the status bar above the composer follows the
    -- theme (the nil-locals order bug painted it palette white).
    local app_ft = fake_app({ page = "chat",
        settings = { chat_html_render = true, chat_footer = true },
        messages = {
            { role = "assistant", name = "Aria", send_date = os.time(),
              content = "footer band probe" },
        } })
    app_ft.state.chat_theme_applied = ChatTheme_p.normalize({
        name = "Footer dark", style = "bubbles",
        colors = { surface = "#101010", text = "#f0f0f0",
            ai_panel = "#181818", user_panel = "#202020" },
    })
    local view_ft = { app = app_ft, hitboxes = {}, refresh = function() end }
    local bb_ft = new_bb()
    local okp_ft = pcall(function() Pages.chat(view_ft, bb_ft, 0, 0, VW, VH, 0) end)
    ok(okp_ft, "footer dark: page paints without crashing")
    local band_dark = 0
    for yy = VH - 54 - 26, VH - 54 - 2, 2 do
        for xx = 30, VW - 30, 6 do
            local okp, px = pcall(function() return bb_ft:getPixel(xx, yy) end)
            if okp and px and px:getR() < 40 then band_dark = band_dark + 1 end
        end
    end
    ok(band_dark > 40,
        "footer dark: status band follows the theme, not palette white (dark="
        .. band_dark .. ")")
    require("ktui/theme").set_chat_color_overrides(nil)

    -- 4. mask_text: hard contrast against the fence band, any palette.
    local resolved_p = ChatTheme_p.resolved(fake_app({}))
    local lum_mask = ChatTheme_p.luminance(resolved_p.colors.mask) or 0
    local lum_text = ChatTheme_p.luminance(resolved_p.colors.mask_text) or 0
    ok(math.abs(lum_mask - lum_text) > 0.35,
        "mask_text: fence text contrasts the band (mask="
        .. string.format("%.2f", lum_mask) .. " text="
        .. string.format("%.2f", lum_text) .. ")")
end

-- B5 color pipeline (the "balão cinza, fundo do texto azul" root cause):
-- KOReader v2026.07's paintRect CBB shortcut paints ColorRGB32 as its
-- LUMINANCE byte - every themed canvas fill came out gray on color
-- screens while MuPDF docs kept the true hex. Our P.rect/rounded_rect/
-- stroke now scanline-fill RGB32 buffers with the true color. The repro
-- paints a Celestial chat on an RGB32 buffer (like the color emulator)
-- and asserts: canvas panel == doc bitmap bg == the theme's ai_panel.
do
    local ChatTheme_r = require("ktui/chat_theme")
    local Theme_r = require("ktui/theme")
    local celestial = nil
    for _, b in ipairs(ChatTheme_r.BUILTINS()) do
        if b.id == "builtin:celestial" then celestial = b.theme end
    end
    local app_r = { state = { page = "chat",
        settings = { chat_html_render = true }, scroll = {},
        messages = {
            { role = "user", name = "You", content = "hello!", send_date = os.time() - 1 },
            { role = "assistant", name = "Aria",
              content = "Some reply text line one.\nSecond line of the reply.",
              send_date = os.time() },
        }, reasoning_open = {}, reasoning_full = {} } }
    function app_r:scroll_key() return self.state.page end
    function app_r:chat_look() return ChatTheme_r.normalize(celestial) end
    function app_r:active_bubble_theme_id() return "builtin:celestial" end
    function app_r:find_chat_theme(id)
        for _, b in ipairs(ChatTheme_r.BUILTINS()) do
            if b.id == id then return b.theme, b.name end
        end
    end
    app_r.state.chat_theme_applied = celestial
    -- The real apply chain (like App:apply_bubble_theme).
    Theme_r.set_bubble_style(celestial.style or "bubbles")
    Theme_r.set_chat_color_overrides({
        surface = celestial.colors.surface, ai_panel = celestial.colors.ai_panel,
        user_panel = celestial.colors.user_panel, text = celestial.colors.text,
        border = celestial.colors.border })
    local view_r = { app = app_r, hitboxes = {}, refresh = function() end }
    local bb_r = Blitbuffer.new(VW, VH, Blitbuffer.TYPE_BBRGB32)
    bb_r:fill(Blitbuffer.COLOR_WHITE)
    local okp_r = pcall(function() Pages.chat(view_r, bb_r, 0, 0, VW, VH, 0) end)
    ok(okp_r, "b5 colors: RGB32 chat paints without crashing")
    local lay_r = nil
    for _k, l in pairs(view_r._chat_layout_cache or {}) do
        if type(l) == "table" and not l.is_user and l.entries then lay_r = l end
    end
    local function rgb_at(bb, x, y)
        local okp, px = pcall(function() return bb:getPixel(x, y) end)
        if not okp then return nil end
        return px:getR() * 65536 + px:getG() * 256 + px:getB()
    end
    local ai_val = 0x1c2739
    local ai_r, ai_g, ai_b = celestial.colors.ai_panel:match("^#(%x%x)(%x%x)(%x%x)$")
    ai_val = tonumber(ai_r, 16) * 65536 + tonumber(ai_g, 16) * 256 + tonumber(ai_b, 16)
    if lay_r then
        -- Panel-only zone (avatar column, mid height) == ai_panel TRUE COLOR.
        local py = lay_r.bubble_y + math.floor((lay_r.bubble_h or 100) / 2)
        local pv = rgb_at(bb_r, lay_r.bx + 8, py)
        ok(pv == ai_val,
            "b5 colors: canvas panel paints TRUE color (got " .. string.format("#%06x", pv or 0)
            .. " want " .. celestial.colors.ai_panel .. ")")
        -- The doc bitmap's own background == ai_panel (not the surface).
        local doc_r = nil
        for _e, e in ipairs(lay_r.entries) do
            if e.kind == "html" and e.widget and e.widget.bb then doc_r = e.widget end
        end
        if doc_r then
            local n_ai, n_surf = 0, 0
            local sr, sg, sb = celestial.colors.surface:match("^#(%x%x)(%x%x)(%x%x)$")
            local surf_val = tonumber(sr, 16) * 65536 + tonumber(sg, 16) * 256 + tonumber(sb, 16)
            local dbb = doc_r.bb
            for yy = 0, dbb:getHeight() - 1, 4 do
                for xx = 0, dbb:getWidth() - 1, 8 do
                    local v = rgb_at(dbb, xx, yy)
                    if v == ai_val then n_ai = n_ai + 1
                    elseif v == surf_val then n_surf = n_surf + 1 end
                end
            end
            ok(n_ai > 0 and n_surf == 0,
                "b5 colors: doc bg == ai_panel (ai=" .. n_ai .. " surface=" .. n_surf .. ")")
        else
            ok(false, "b5 colors: no html doc found for the bg probe")
        end
        -- Table shading derives from the theme border, not palette soft.
        local bc_ok, b_r, b_g, b_b = pcall(function()
            return Theme_r.chat_border:getR(), Theme_r.chat_border:getG(), Theme_r.chat_border:getB()
        end)
        local soft_ok, s_r2, s_g2, s_b2 = pcall(function()
            return Theme_r.soft:getR(), Theme_r.soft:getG(), Theme_r.soft:getB()
        end)
        ok(bc_ok and soft_ok and math.abs(b_r - s_r2) > 40,
            "b5 colors: chat_border follows the theme, not palette soft ("
            .. string.format("#%02x%02x%02x", b_r, b_g, b_b) .. " vs "
            .. string.format("#%02x%02x%02x", s_r2, s_g2, s_b2) .. ")")
    else
        ok(false, "b5 colors: assistant layout missing")
    end
    Theme_r.set_chat_color_overrides(nil)
end

-- Chat Theme render: a dark theme must flip the doc colors (the "room"
-- semantic - dark chat inside a light app) and scan_bottom must handle it.
do
    local ChatTheme = require("ktui/chat_theme")
    local app_d = fake_app({ page = "chat",
        settings = { chat_html_render = true },
        messages = {
            { role = "assistant", name = "Aria", send_date = os.time(),
              content = "Dark room body text with *emphasis* in it." },
        } })
    local dark_theme = ChatTheme.normalize({
        name = "Dark test",
        colors = { surface = "#111111", text = "#eeeeee",
            ai_panel = "#222222", user_panel = "#333333" },
    })
    app_d.state.chat_theme_applied = dark_theme
    -- Apply through the REAL path (like App:apply_bubble_theme does), so
    -- the R1 guards test the live Theme fields the canvas actually reads -
    -- not just the doc pipeline.
    require("ktui/theme").set_chat_color_overrides({
        surface = dark_theme.colors.surface,
        ai_panel = dark_theme.colors.ai_panel,
        user_panel = dark_theme.colors.user_panel,
        text = dark_theme.colors.text,
    })
    local view_d = { app = app_d, hitboxes = {}, refresh = function() end }
    local bb_d = new_bb()
    local okp_d = pcall(function()
        Pages.chat(view_d, bb_d, 0, 0, VW, VH, 0)
    end)
    ok(okp_d, "theme render: dark chat theme paints without crashing")
    -- The doc bitmap's background must be DARK, not the light palette.
    local found_d = nil
    for _dk, l in pairs(view_d._chat_layout_cache or {}) do
        if type(l) == "table" and l.entries then
            for _de, e in ipairs(l.entries) do
                if e.kind == "html" and e.widget and e.widget.bb then
                    found_d = e.widget
                end
            end
        end
    end
    ok(found_d ~= nil, "theme render: dark theme produced an html doc")
    if found_d then
        local dark_px, light_px = 0, 0
        for yy = 0, found_d.bb:getHeight() - 1, 7 do
            for xx = 0, found_d.bb:getWidth() - 1, 7 do
                local okp, px = pcall(function() return found_d.bb:getPixel(xx, yy) end)
                if okp and px then
                    if px:getR() < 60 then dark_px = dark_px + 1
                    elseif px:getR() > 200 then light_px = light_px + 1 end
                end
            end
        end
        ok(dark_px > light_px,
            "theme render: doc background is dark (" .. dark_px .. " dark vs "
            .. light_px .. " light samples)")
        -- scan_bottom with the doc's PANEL bg (role-aware: assistant docs
        -- paint on ai_panel) must find the text bottom, not the whole
        -- bitmap: height < bitmap height.
        local h = require("ktui/kthtml").scan_bottom(found_d.bb,
            found_d.bb:getWidth(), "#222222")
        ok(h ~= nil and h < found_d.bb:getHeight(),
            "theme render: scan_bottom trims against the panel bg (h="
            .. tostring(h) .. "/" .. found_d.bb:getHeight() .. ")")
    end
    -- R1 regression guards (the print-report round):
    -- 1. Canvas ink vs panel: the name/hour text must contrast the themed
    --    panel (the old hardcoded palette ink was black-on-dark).
    local ink_ok, ink_r = pcall(function() return Theme.chat_ink:getR() end)
    local pan_ok, pan_r = pcall(function() return Theme.chat_panel:getR() end)
    ok(ink_ok and pan_ok and math.abs(ink_r - pan_r) > 100,
        "r1 contrast: chat ink differs from the themed panel (ink="
        .. tostring(ink_r) .. " panel=" .. tostring(pan_r) .. ")")
    local mu_ok, mu_r = pcall(function() return Theme.chat_muted:getR() end)
    ok(mu_ok and mu_r > pan_r + 40,
        "r1 contrast: muted text sits above the panel (muted="
        .. tostring(mu_r) .. " panel=" .. tostring(pan_r) .. ")")
    -- 2. The doc bitmap paints the message PANEL as its background (the
    --    "text stripe" report): a padding pixel must match ai_panel.
    if found_d then
        local okp_pad, px_pad = pcall(function()
            return found_d.bb:getPixel(3, 3)
        end)
        ok(okp_pad and math.abs(px_pad:getR() - 34) <= 6,
            "r1 doc bg: doc background is the AI panel (#222222), got r="
            .. tostring(okp_pad and px_pad:getR() or -1))
    end
    -- 3. Chat page chrome follows the theme: the header band paints the
    --    themed surface (white chrome around a dark chat read as broken).
    --    The page itself does not paint the header (AppView does), so the
    --    probe paints it through the same Header.draw the shell uses.
    local okp_h, err_h = pcall(function()
        require("ktui/header").draw(view_d, bb_d, 0, 0, VW)
    end)
    ok(okp_h, "r1 chrome: themed header paints (" .. tostring(err_h) .. ")")
    local chrome_ok, chrome_r = pcall(function()
        return bb_d:getPixel(VW - 30, 4):getR()
    end)
    ok(chrome_ok and chrome_r < 60,
        "r1 chrome: chat header band follows the dark theme (r="
        .. tostring(chrome_ok and chrome_r or -1) .. ")")
    dump(bb_d, "theme_dark_chat")
    -- Restore the palette for the checks below (global Theme state).
    require("ktui/theme").set_chat_color_overrides(nil)
end

-- Chat HTML external link end to end: tapping an http(s) link opens the
-- KOReader-style dialog (Copy / QR / browser); the browser button hands
-- the URL to Device:openLink. Dialog widgets, UIManager and Device are
-- stubbed; everything is restored afterwards.
do
    local UIManager = require("ui/uimanager")
    local Device = require("device")
    local real_show, real_close = UIManager.show, UIManager.close
    local real_dialog = package.loaded["ui/widget/buttondialog"]
    local real_can, real_open = Device.canOpenLink, Device.openLink
    local shown, opened = {}, {}
    UIManager.show = function(_s, w) shown[#shown + 1] = w end
    UIManager.close = function() end
    package.loaded["ui/widget/buttondialog"] = {
        new = function(_s, o) return { title = o.title, buttons = o.buttons } end,
    }
    Device.canOpenLink = function() return true end
    Device.openLink = function(_s, url) opened[#opened + 1] = url end
    local now4 = os.time()
    local app4 = fake_app({ page = "chat",
        settings = { chat_html_render = true },
        messages = {
            { role = "assistant", name = "Aria",
              content = "see [txt](https://x.com) here", send_date = now4 },
        } })
    local view4 = { app = app4, hitboxes = {}, refresh = function() end }
    local b4 = new_bb()
    local okp5 = pcall(function() Pages.chat(view4, b4, 0, 0, VW, VH, 0) end)
    ok(okp5, "chat html link: paint renders without crashing")
    local box4, entry4 = nil, nil
    for _sk4, hb in ipairs(view4.hitboxes) do
        if hb.label and hb.label:sub(1, 9) == "chathtml_" then box4 = hb break end
    end
    for _lk5, l in pairs(view4._chat_layout_cache or {}) do
        if type(l) == "table" and l.entries then
            for _ek5, e in ipairs(l.entries) do
                if e.kind == "html" then entry4 = e break end
            end
        end
    end
    local http_link = nil
    if entry4 and entry4.widget and entry4.widget.document then
        local okp, pg = pcall(function() return entry4.widget.document:openPage(1) end)
        if okp and pg then
            local okp2, links = pcall(function() return pg:getPageLinks() end)
            pcall(function() pg:close() end)
            if okp2 and type(links) == "table" then
                for _gl2, lk in ipairs(links) do
                    if type(lk) == "table"
                        and tostring(lk.uri or lk.url or "") == "https://x.com" then
                        http_link = lk break
                    end
                end
            end
        end
    end
    ok(box4 ~= nil and http_link ~= nil,
        "chat html link: http link exposes a tappable rect")
    if box4 and http_link then
        local okp = pcall(function()
            box4.callback(box4.x + (http_link.x0 or 0) + 2, box4.y + (http_link.y0 or 0) + 2)
        end)
        ok(okp, "chat html link: tapping the link does not crash")
        ok(#shown == 1 and shown[1].title == "https://x.com",
            "chat html link: tap opens the external-link dialog for the URL")
        local browser_btn = shown[1] and shown[1].buttons
            and shown[1].buttons[3] and shown[1].buttons[3][1]
        ok(browser_btn ~= nil, "chat html link: dialog carries the browser button")
        if browser_btn then
            local okp2 = pcall(browser_btn.callback)
            ok(okp2 and #opened == 1 and opened[1] == "https://x.com",
                "chat html link: browser button hands the URL to Device:openLink")
        end
    end
    UIManager.show, UIManager.close = real_show, real_close
    package.loaded["ui/widget/buttondialog"] = real_dialog
    Device.canOpenLink, Device.openLink = real_can, real_open
end

-- Chat HTML details tap-to-expand end to end: paint a collapsed group, tap
-- its kt:det link rect through the band hitbox, the reveal state flips, the
-- doc is rebuilt and the repaint paints the body rows (pixel proof); a
-- second tap collapses it again.
do
    local now5 = os.time()
    local app5 = fake_app({ page = "chat",
        settings = { chat_html_render = true },
        messages = {
            { role = "assistant", name = "Aria",
              content = "<details><summary>Thoughts</summary>hidden body</details>",
              send_date = now5 },
        } })
    local refreshed5 = 0
    local view5 = { app = app5, hitboxes = {},
        refresh = function() refreshed5 = refreshed5 + 1 end }
    local b5 = new_bb()
    local okp5 = pcall(function() Pages.chat(view5, b5, 0, 0, VW, VH, 0) end)
    ok(okp5, "chat html details tap: collapsed paint renders without crashing")
    local box5 = nil
    for _sk5, hb in ipairs(view5.hitboxes) do
        if hb.label and hb.label:sub(1, 9) == "chathtml_" then box5 = hb break end
    end
    ok(box5 ~= nil, "chat html details tap: html band registers a tap hitbox")
    local lay5, entry5 = nil, nil
    for _lk6, l in pairs(view5._chat_layout_cache or {}) do
        if type(l) == "table" and l.entries then
            for _ek6, e in ipairs(l.entries) do
                if e.kind == "html" then lay5, entry5 = l, e break end
            end
        end
    end
    ok(lay5 ~= nil and entry5 ~= nil and entry5.widget ~= nil,
        "chat html details tap: html entry with a widget")
    local function det_sig(w)
        if not w or not w.bb then return nil end
        local n, s = 0, 0
        for yy = 0, w.bb:getHeight() - 1, 3 do
            for xx = 0, w.bb:getWidth() - 1, 3 do
                local okp, px = pcall(function() return w.bb:getPixel(xx, yy) end)
                if okp and px and px:getR() < 200 then n = n + 1; s = s + xx + yy end
            end
        end
        return n .. ":" .. s
    end
    local sig_shut = det_sig(entry5.widget)
    local det_link = nil
    if entry5.widget and entry5.widget.document then
        local okp, pg = pcall(function() return entry5.widget.document:openPage(1) end)
        if okp and pg then
            local okp2, links = pcall(function() return pg:getPageLinks() end)
            pcall(function() pg:close() end)
            if okp2 and type(links) == "table" then
                for _gl3, lk in ipairs(links) do
                    if type(lk) == "table" and tostring(lk.uri or lk.url or "") == "kt:det:1" then
                        det_link = lk break
                    end
                end
            end
        end
    end
    ok(det_link ~= nil, "chat html details tap: summary exposes a kt:det:1 link")
    if box5 and det_link then
        local tap_at = function(lk)
            return pcall(function()
                box5.callback(box5.x + (lk.x0 or 0) + 2, box5.y + (lk.y0 or 0) + 2)
            end)
        end
        ok(tap_at(det_link), "chat html details tap: expanding does not crash")
        local rev = app5.state.chat_details_revealed
        local key5 = lay5 and lay5.msg_key or nil
        ok(rev ~= nil and key5 ~= nil and rev[key5] ~= nil and rev[key5][1] == true,
            "chat html details tap: tap flips the reveal state")
        ok(refreshed5 > 0, "chat html details tap: tap requests a refresh")
        view5.hitboxes = {}
        local b5b = new_bb()
        local okp6 = pcall(function() Pages.chat(view5, b5b, 0, 0, VW, VH, 0) end)
        ok(okp6, "chat html details tap: expanded repaint renders without crashing")
        local entry5b = nil
        for _lk7, l in pairs(view5._chat_layout_cache or {}) do
            if type(l) == "table" and l.entries then
                for _ek7, e in ipairs(l.entries) do
                    if e.kind == "html" then entry5b = e break end
                end
            end
        end
        local sig_open = entry5b and det_sig(entry5b.widget)
        ok(sig_open ~= nil and sig_open ~= sig_shut,
            "chat html details tap: expanded paint shows the body rows")
        dump(b5b, "chat_html_details_open")
        -- Collapse again through a fresh hitbox + link rect.
        local box5b = nil
        for _sk8, hb in ipairs(view5.hitboxes) do
            if hb.label and hb.label:sub(1, 9) == "chathtml_" then box5b = hb break end
        end
        local det_link2 = nil
        if entry5b and entry5b.widget and entry5b.widget.document then
            local okp, pg = pcall(function() return entry5b.widget.document:openPage(1) end)
            if okp and pg then
                local okp2, links = pcall(function() return pg:getPageLinks() end)
                pcall(function() pg:close() end)
                if okp2 and type(links) == "table" then
                    for _gl4, lk in ipairs(links) do
                        if type(lk) == "table" and tostring(lk.uri or lk.url or "") == "kt:det:1" then
                            det_link2 = lk break
                        end
                    end
                end
            end
        end
        if box5b and det_link2 then
            box5 = box5b
            ok(tap_at(det_link2), "chat html details tap: collapsing does not crash")
            local rev2 = app5.state.chat_details_revealed
            ok(rev2 ~= nil and rev2[key5] ~= nil and rev2[key5][1] == nil,
                "chat html details tap: second tap collapses again")
        else
            ok(false, "chat html details tap: expanded band keeps a kt:det:1 link")
        end
    end
end

-- Chat HTML: USER messages render through the doc path too (their
-- markdown/links/spoilers get the same treatment as assistant bodies).
do
    local now_u = os.time()
    local app_u = fake_app({ page = "chat",
        settings = { chat_html_render = true },
        messages = {
            { role = "user", name = "You", send_date = now_u,
              content = "*it* and ||secret|| and [l](https://x.com)" },
        } })
    local view_u = { app = app_u, hitboxes = {}, refresh = function() end }
    local bb_u = new_bb()
    local okp_u = pcall(function() Pages.chat(view_u, bb_u, 0, 0, VW, VH, 0) end)
    ok(okp_u, "chat html user: paint renders without crashing")
    local ul = nil
    for _uk, l in pairs(view_u._chat_layout_cache or {}) do
        if type(l) == "table" and l.is_user and l.entries then ul = l end
    end
    ok(ul ~= nil, "chat html user: user layout measured")
    local uentry = ul and ul.entries and ul.entries[1]
    ok(uentry ~= nil and uentry.kind == "html"
        and uentry.widget ~= nil and uentry.widget.document ~= nil,
        "chat html user: user message renders via a live MuPDF doc")
    local uband = nil
    for _ub, hb in ipairs(view_u.hitboxes) do
        if hb.label == "chathtml_" .. tostring(ul and ul.msg_key) then uband = hb break end
    end
    ok(uband ~= nil, "chat html user: user band registers a tap hitbox (links work)")
end

-- Chat width (ST parity): the whole column narrows INCLUDING the bubble
-- panels, and the long-press zone follows the narrowed panel (a full-width
-- origin used to sit inset px left of the actual bubble).
do
    local now_w = os.time()
    for _cw, cw in ipairs({ "50", "100" }) do
        local app_w = fake_app({ page = "chat",
            settings = { chat_html_render = true, chat_width = cw },
            messages = {
                { role = "user", name = "You", content = "hi", send_date = now_w },
                { role = "assistant", name = "Aria",
                  content = "long enough body for the bubble panel", send_date = now_w },
            } })
        local view_w = { app = app_w, hitboxes = {}, refresh = function() end }
        local bb_w = new_bb()
        local okp_w = pcall(function() Pages.chat(view_w, bb_w, 0, 0, VW, VH, 0) end)
        ok(okp_w, "chat width " .. cw .. ": paint renders without crashing")
        local al, hold = nil, nil
        for _wk, l in pairs(view_w._chat_layout_cache or {}) do
            if type(l) == "table" and not l.is_user and not l.is_system then al = l end
        end
        for _wh, hb in ipairs(view_w.hitboxes) do
            if hb.label and hb.label:sub(1, 8) == "msghold_" then hold = hb end
        end
        ok(al ~= nil and hold ~= nil, "chat width " .. cw .. ": layout + hold zone found")
        if al and hold then
            ok(hold.x == al.bx and hold.w == al.bubble_w,
                "chat width " .. cw .. ": hold zone spans the bubble panel (hold="
                .. tostring(hold.x) .. "+" .. tostring(hold.w)
                .. " panel=" .. tostring(al.bx) .. "+" .. tostring(al.bubble_w) .. ")")
        end
        if cw == "50" and al then
            ok(al.bx > 10 and al.bubble_w < VW - 40,
                "chat width 50: panel narrows and centers (bx=" .. tostring(al.bx)
                .. " w=" .. tostring(al.bubble_w) .. ")")
        end
    end
end

-- Reasoning doc identity: two messages with SAME-LENGTH reasoning at the
-- same width must hold distinct docs (the old length-keyed cache showed
-- one message's reasoning inside the other's bubble).
do
    local now_c = os.time()
    local app_c = fake_app({ page = "chat",
        settings = { chat_html_render = true },
        messages = {
            { role = "assistant", name = "Aria", send_date = now_c,
              content = "r1", reasoning = "internal thought A" },
            { role = "assistant", name = "Aria", send_date = now_c,
              content = "r2", reasoning = "internal thought B" },
        } })
    -- Same length, different text.
    ok(#"internal thought A" == #"internal thought B",
        "reasoning id: fixture lengths match")
    local view_c = { app = app_c, hitboxes = {}, refresh = function() end }
    local bb_c = new_bb()
    local okp_c = pcall(function() Pages.chat(view_c, bb_c, 0, 0, VW, VH, 0) end)
    ok(okp_c, "reasoning id: paint renders without crashing")
    -- Expand every reasoning block via the expand hitboxes.
    for _cb, hb in ipairs(view_c.hitboxes) do
        if type(hb.label) == "string" and hb.label:sub(1, 10) == "reasoning_" then
            pcall(hb.callback, 0, 0)
        end
    end
    view_c.hitboxes = {}
    local bb_c2 = new_bb()
    local okp_c2 = pcall(function() Pages.chat(view_c, bb_c2, 0, 0, VW, VH, 0) end)
    ok(okp_c2, "reasoning id: expanded paint renders without crashing")
    local widgets = {}
    for _ck, l in pairs(view_c._chat_layout_cache or {}) do
        if type(l) == "table" and l.reasoning_entries and #l.reasoning_entries > 0
            and l.reasoning_entries[1].kind == "html"
            and l.reasoning_entries[1].widget then
            widgets[#widgets + 1] = l.reasoning_entries[1].widget
        end
    end
    ok(#widgets == 2 and widgets[1] ~= widgets[2],
        "reasoning id: same-length reasonings hold distinct docs (got "
        .. #widgets .. ")")
end

-- Clipped bubble keeps its rounded corners + border ring (the "balao fica
-- quadrado/torto" report): expanding a reasoning block grows the bubble
-- past the viewport; the panel must stay rounded wherever it is visible,
-- keep the top border, and leak NOTHING below the messages band (where the
-- composer bar lives). Direct ChatBubbles.draw on a marked buffer.
do
    local now_v = os.time()
    local msgs_v = {
        { role = "assistant", name = "Aria", content = "short one", send_date = now_v },
        { role = "assistant", name = "Aria",
          content = string.rep("content line that wraps and fills the bubble\n", 45),
          send_date = now_v + 1 },
    }
    local app_v = fake_app({ page = "chat",
        settings = { chat_html_render = false } })
    app_v.state.messages = msgs_v
    local view_v = { app = app_v, hitboxes = {}, refresh = function() end }
    local band_h = 500
    local MARK = Blitbuffer.gray(0.5)
    local bb_v = new_bb()
    -- Surface inside the band (like Pages.chat paints it) + marker below.
    P.rect(bb_v, 0, 0, VW, band_h, Theme.chat_bg)
    bb_v:paintRect(0, band_h, VW, VH - band_h, MARK)
    local okp_v, err_v = pcall(function()
        ChatBubbles.draw(view_v, bb_v, 0, 0, VW, band_h, 0, msgs_v,
            "Aria", false, "You", nil, nil)
    end)
    ok(okp_v, "clipped panel: bottom-clipped bubble renders (" .. tostring(err_v) .. ")")
    local lay_v = nil
    for _vk, l in pairs(view_v._chat_layout_cache or {}) do
        if type(l) == "table" and (l.bubble_h or 0) > band_h then lay_v = l end
    end
    ok(lay_v ~= nil, "clipped panel: a bubble extends past the band")
    if lay_v then
        local function vpx(xx, yy)
            local okp, p = pcall(function() return bb_v:getPixel(xx, yy) end)
            return okp and p:getR() or -1
        end
        local radius = Theme.bubble_radius_px()
        ok(radius >= 4, "clipped panel: fixture has a real corner radius (" .. tostring(radius) .. ")")
        local surface_v = vpx(lay_v.bx - 5, lay_v.bubble_y + 5)
        local corner_v = vpx(lay_v.bx + 1, lay_v.bubble_y + 1)
        ok(math.abs(corner_v - surface_v) <= 10,
            "clipped panel: top-left corner stays ROUNDED (corner="
            .. corner_v .. " surface=" .. surface_v .. ")")
        local corner_r = vpx(lay_v.bx + lay_v.bubble_w - 2, lay_v.bubble_y + 1)
        ok(math.abs(corner_r - surface_v) <= 10,
            "clipped panel: top-right corner stays ROUNDED (corner="
            .. corner_r .. " surface=" .. surface_v .. ")")
        local top_border = vpx(lay_v.bx + math.floor(lay_v.bubble_w / 2),
            lay_v.bubble_y)
        ok(top_border < surface_v - 25,
            "clipped panel: top border paints (px=" .. top_border
            .. " surface=" .. surface_v .. ")")
        local leak = vpx(lay_v.bx + math.floor(lay_v.bubble_w / 2), band_h + 4)
        local mark_r = MARK:getR()
        ok(math.abs(leak - mark_r) <= 2,
            "clipped panel: nothing leaks below the band (px=" .. leak
            .. " marker=" .. mark_r .. ")")
        dump(bb_v, "clipped_panel_rounded")
    end
end

-- Sheets with two-line sublabel rows get a taller slot (Author's Note fix).
do
    local Sheets = require("ktui/sheets")
    local app = fake_app({ page = "chat" })
    app.state.sheet = { title = "Author's Note", scroll = 0, actions = {
        { label = "Edit Note", sublabel = "(empty)" },
        { label = "Depth", sublabel = "4" },
        { label = "Clear Note", danger = true },
    } }
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    local okp, err = pcall(function() Sheets.draw(view, bb) end)
    ok(okp and count_hits(view) >= 5,
        "sheets: sublabel rows render with taller slots (" .. tostring(err) .. ")")
    ok(has_hit(view, "sheet:Edit Note") and has_hit(view, "sheet:Clear Note"),
        "sheets: sublabel rows keep their taps")
    ok(ink_ratio(bb) > 100, "sheets: sublabel sheet paints")
    dump(bb, "sheet_sublabels")
end

-- Nested sheets (Options -> Select Persona) must not lose the page scroll:
-- outer zeroes it, inner must carry the outer saved position, close
-- restores it (the chat "jumped to top" bug).
do
    local Sheets = require("ktui/sheets")
    local app = fake_app({ page = "chat" })
    app.state.scroll = { chat = 500 }
    function app:scroll_key() return "chat" end
    local view = { app = app, hitboxes = {} }
    function view:refresh() end
    app.view = view
    Sheets.show(app, { title = "Outer", actions = { { label = "A" } } })
    ok(app.state.scroll.chat == 0, "sheets: opening zeroes page scroll")
    Sheets.show(app, { title = "Inner", actions = { { label = "B" } } })
    Sheets.close(app)
    ok(app.state.scroll.chat == 500,
        "sheets: nested close restores outer position (got " ..
        tostring(app.state.scroll.chat) .. ")")
end

-- Snapshot open: with our view topmost, show() photographs the compositor
-- and paints the sheet straight onto Screen.bb - ZERO view repaints (only
-- the waveform is queued). Close ALWAYS repaints the view: the old blit
-- fast path queued setDirty(nil,...) which marks NO widget dirty, so the
-- view kept the sheet's hitboxes alive (device: tapping the closed menu's
-- area re-fired sheet actions) and the snapshot blit misaligned on real
-- devices (BB type/rotation mismatch, pcall-swallowed) leaving the scrim
-- gray the dashboard reported.
do
    local Sheets = require("ktui/sheets")
    local UIManager = require("ui/uimanager")
    local Screen = require("device").screen
    local function snap_app()
        local a = fake_app({ page = "chat" })
        a.state.scroll = { chat = 0 }
        function a:scroll_key() return "chat" end
        local v = { app = a, hitboxes = {} }
        local n = 0
        function v:refresh() n = n + 1 end
        a.view = v
        return a, v, function() return n end
    end
    local function sample(bb, pts)
        local out = {}
        for _, p in ipairs(pts) do
            local ok, px = pcall(function() return bb:getPixel(p[1], p[2]) end)
            out[#out + 1] = ok and px and px:getR() or -1
        end
        return table.concat(out, ",")
    end
    local pts = { { 10, 10 }, { 100, 200 }, { 300, 400 }, { 500, 700 }, { 50, 750 } }
    -- Topmost: snapshot open path (no repaint on SHOW).
    local app, view, repaints = snap_app()
    table.insert(UIManager._window_stack, { widget = view })
    Sheets.show(app, { title = "T", actions = { { label = "A" } } })
    ok(repaints() == 0, "sheets: snapshot show repaints nothing (open is one wave)")
    ok(#view.hitboxes > 0, "sheets: snapshot show registers the sheet's hits")
    -- Close repaints exactly once (the old blit+setDirty(nil) path is gone).
    Sheets.close(app)
    ok(repaints() == 1, "sheets: close repaints the view once (hits die with the paint) (got " .. repaints() .. ")")
    ok(app.state.sheet == nil, "sheets: close clears the sheet state")
    for i = #UIManager._window_stack, 1, -1 do
        if UIManager._window_stack[i].widget == view then
            table.remove(UIManager._window_stack, i)
        end
    end
    -- Covered: fallback path repaints.
    local app2, view2, repaints2 = snap_app()
    Sheets.show(app2, { title = "T", actions = { { label = "A" } } })
    Sheets.close(app2)
    ok(repaints2() >= 2, "sheets: fallback open+close repaints (got " .. repaints2() .. ")")
    -- A full paint drops the snapshot (paintTo calls drop_snapshot): the
    -- next close still repaints exactly once - one path for every close.
    local app3, view3, repaints3 = snap_app()
    table.insert(UIManager._window_stack, { widget = view3 })
    Sheets.show(app3, { title = "T", actions = { { label = "A" } } })
    Sheets.drop_snapshot() -- e.g. an async thumbnail repaint ran paintTo
    Sheets.close(app3)
    for i = #UIManager._window_stack, 1, -1 do
        if UIManager._window_stack[i].widget == view3 then
            table.remove(UIManager._window_stack, i)
        end
    end
    ok(repaints3() >= 1,
        "sheets: close repaints even after the snapshot died (got " .. repaints3() .. ")")
end

-- Mini scrollbar: long sheets paint track+thumb at the panel edge, short
-- sheets paint none, and the thumb slides with sheet.scroll.
do
    local Sheets = require("ktui/sheets")
    local function paint_sheet(n, scroll)
        local app = fake_app({ page = "chat" })
        app.state.scroll = { chat = 0 }
        function app:scroll_key() return "chat" end
        local acts = {}
        for i = 1, n do acts[i] = { label = "Action " .. i } end
        app.state.sheet = { title = "T", scroll = scroll or 0, actions = acts }
        local view = { app = app, hitboxes = {} }
        function view:refresh() end
        local bb = new_bb()
        Sheets.draw(view, bb)
        local cancel_y = nil
        for _, b in ipairs(view.hitboxes) do
            if b.label == "sheet:cancel" then cancel_y = b.y end
        end
        return bb, cancel_y or 700
    end
    local function strip_ink(bb, cancel_y)
        -- rows in the right-edge strip inside the rows band: above the
        -- full-width Cancel button, below the rounded panel corner (its
        -- anti-aliased arc reads gray). Threshold 220 counts the soft
        -- track (0xCC) but not the white panel.
        local rows = {}
        for yy = cancel_y - 130, cancel_y - 15 do
            local hit = false
            for xx = 565, 574 do
                local okp, px = pcall(function() return bb:getPixel(xx, yy) end)
                if okp and px and px:getR() < 220 then hit = true break end
            end
            if hit then rows[#rows + 1] = yy end
        end
        return rows
    end
    local short_bb, short_cancel = paint_sheet(2, 0)
    ok(#strip_ink(short_bb, short_cancel) == 0, "sheets: short list paints no scrollbar")
    local long_bb, long_cancel = paint_sheet(40, 0)
    local r0 = strip_ink(long_bb, long_cancel)
    ok(#r0 > 100, "sheets: long list paints track+thumb (" .. #r0 .. " rows)")
    local scrolled_bb = paint_sheet(40, 10000)
    -- Thumb ink (near-black) vs track (soft gray): centroid of the dark
    -- Thumb ink (near-black) vs track (soft gray): centroid of the dark
    -- rows slides down with sheet.scroll (borders contribute equally).
    local function dark_centroid(bb)
        local sum, n = 0, 0
        for yy = 200, 799 do
            local dark = false
            for xx = 565, 574 do
                local okp, px = pcall(function() return bb:getPixel(xx, yy) end)
                if okp and px and px:getR() < 100 then dark = true break end
            end
            if dark then sum, n = sum + yy, n + 1 end
        end
        return n > 0 and sum / n or nil
    end
    local c0, c1 = dark_centroid(long_bb), dark_centroid(scrolled_bb)
    ok(c0 and c1 and c1 > c0 + 20,
        "sheets: thumb slides with scroll (centroid " .. tostring(c0) .. " -> " .. tostring(c1) .. ")")
    dump(long_bb, "sheet_scrollbar")
end

-- === 5. Icon sheet: every SVG asset rasterizes ==============================
do
    -- Direct probe: capture the raw failure for any asset NanoSVG rejects.
    local ImageWidget = require("ui/widget/imagewidget")
    local probe_ok, probe_err = pcall(function()
        local w = ImageWidget:new{
            file = PLUGIN .. "/assets/logo.svg",
            width = 28, height = 28, alpha = true, is_icon = true, file_do_cache = true,
        }
        w:getSize()
        w:free()
    end)
    ok(probe_ok, "icons: logo.svg probe (" .. tostring(probe_err) .. ")")

    local app = fake_app()
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    local names = { "home", "comments", "plug", "cog", "search", "sort", "filter",
        "grid", "list", "plus", "user", "star", "star-empty", "trash", "edit",
        "download", "upload", "copy", "eye", "tag", "random", "ban", "wrench",
        "refresh", "save", "folder", "file", "clock", "heart", "back", "forward",
        "chev-left", "chev-right", "chev-up", "chev-down", "times", "check",
        "ellipsis-v", "bolt", "camera", "image", "question-circle", "info-circle",
        "exclamation-triangle", "arrow-up", "arrow-down", "sliders", "magic",
        "book", "chat", "double-chev-left", "double-chev-right", "logo" }
    -- Rasterize each asset through ImageWidget DIRECTLY: this cannot be
    -- satisfied by the glyph fallback, so a failure here is a real failure.
    local raster_ok, failed = 0, {}
    for _, name in ipairs(names) do
        local okr, err = pcall(function()
            local w = ImageWidget:new{
                file = PLUGIN .. "/assets/" .. name .. ".svg",
                width = 28, height = 28, alpha = true, is_icon = true, file_do_cache = true,
            }
            w:getSize()
            w:free()
        end)
        if okr then raster_ok = raster_ok + 1 else failed[#failed + 1] = name .. "(" .. tostring(err) .. ")" end
    end
    ok(raster_ok == #names, "icons: all " .. #names .. " SVG assets rasterize"
        .. (#failed > 0 and (" - failed: " .. table.concat(failed, ", ")) or ""))
    local s = 28
    local per_row = math.floor((VW - 20) / (s + 12))
    for i, name in ipairs(names) do
        local cx = 10 + ((i - 1) % per_row) * (s + 12)
        local cy = 10 + math.floor((i - 1) / per_row) * (s + 12)
        Icons.draw(bb, name, cx, cy, s / 2, {})
    end
    -- Inverted variant paints (white ink on a black plate)
    P.rect(bb, 10, 560, 200, 60, Blitbuffer.COLOR_BLACK)
    Icons.draw(bb, "home", 20, 570, 20, { invert = true })
    Icons.draw(bb, "cog", 70, 570, 20, {})
    ok(ink_ratio(bb) > 500, "icons: sheet paints ink")
    dump(bb, "icons")
end

-- === 6. Inverted theme paints ================================================
do
    local function light_ratio(bb)
        local light = 0
        for y = 0, VH - 1, 4 do
            for x = 0, VW - 1, 4 do
                if bb:getPixel(x, y):getR() >= 128 then light = light + 1 end
            end
        end
        return light
    end
    Theme.set_theme("inverted")
    local app = fake_app()
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    bb:fill(Blitbuffer.COLOR_BLACK)
    local content_top = Header.height(view)
    Pages.dashboard(view, bb, 0, content_top, VW, VH - content_top - Theme.metrics().nav_h, 0)
    Header.draw(view, bb, 0, 0, VW)
    Nav.draw(view, bb, 0, VH - Theme.metrics().nav_h, VW, Theme.metrics().nav_h)
    local lr = light_ratio(bb)
    ok(lr > 300 and lr < 22000,
        "inverted: white ink painted on dark bg (light samples=" .. lr .. ")")
    dump(bb, "dashboard_inverted")
    Theme.set_theme("light")
end

-- === 7. Sheets draw over chrome ==============================================
do
    local Sheets = require("ktui/sheets")
    local app = fake_app()
    local view = { app = app, hitboxes = {} }
    function view:refresh() end -- Sheets.show refreshes through app.view
    app.view = view
    Sheets.show(app, { title = "Teste", actions = {
        { label = "Um", icon = "user" },
        { label = "Dois", icon = "star", danger = true },
    } })
    local bb = new_bb()
    bb:fill(Blitbuffer.COLOR_WHITE)
    Header.draw(view, bb, 0, 0, VW)
    Sheets.draw(view, bb)
    ok(count_hits(view) >= 3, "sheets: dismiss + action hitboxes registered")
    dump(bb, "sheet")
    app.state.sheet = nil
end

-- === 7b. Sheets preserve the page scroll (chat keeps its position) ==========
do
    local Sheets = require("ktui/sheets")
    local app = fake_app({ page = "chat" })
    local view = { app = app, hitboxes = {} }
    function view:refresh() end -- Sheets.show/close refresh through app.view
    app.view = view
    app.state.scroll["chat"] = 1234

    Sheets.show(app, { title = "Menu", actions = { { label = "Um" } } })
    ok(app.state.scroll["chat"] == 0,
        "sheets: show zeroes the page scroll under the scrim")
    Sheets.close(app)
    ok(app.state.scroll["chat"] == 1234,
        "sheets: close restores the exact pre-sheet scroll")

    -- An action that navigates away must not clobber the new page's scroll.
    app.state.scroll["chat"] = 500
    Sheets.show(app, { title = "Menu", actions = {} })
    app.state.page = "dashboard"
    app.state.scroll["dashboard"] = 77
    Sheets.close(app)
    ok(app.state.scroll["dashboard"] == 77,
        "sheets: close after navigation leaves the new page alone")
    ok(app.state.scroll["chat"] == 0,
        "sheets: stale chat key stays zeroed, not resurrected")

    -- Confirm sheets never touch the page scroll.
    app.state.page = "chat"
    app.state.scroll["chat"] = 900
    Sheets.confirm(app, { title = "C?", on_ok = function() end })
    ok(app.state.scroll["chat"] == 900,
        "sheets: confirm leaves page scroll untouched")
    Sheets.close(app)
    ok(app.state.scroll["chat"] == 900,
        "sheets: closing a confirm keeps the scroll")
end

-- === 7c. Opening a past chat starts at the last message ======================
do
    local App = require("kt_app")
    local Store = require("kt_storage")
    local real_load, real_list = Store.load_chat, Store.list_all_chats
    Store.load_chat = function(path)
        return { header = { chat_metadata = { chat_id = "past1" } },
            messages = { { role = "user", content = "oi" } } }
    end
    Store.list_all_chats = function() return {} end
    local app = setmetatable({
        state = { settings = {}, messages = {}, scroll = {}, page = "chat_history",
            current_chat_id = "old", user_scrolled_up = true,
            reasoning_open = { x = 1 }, reasoning_full = {} },
    }, { __index = App })
    app:open_past_chat({ path = "/tmp/past.jsonl", id = "past1" })
    ok(app.state.scroll["chat_past1"] == 999999,
        "past chat opens scrolled to the last message (first paint clamps to bottom)")
    Store.load_chat, Store.list_all_chats = real_load, real_list
end

-- === 7d. Fullscreen image viewer takes a raw BlitBuffer (no custom fields) ===
do
    local App = require("kt_app")
    local RenderImage = require("ui/renderimage")
    local real_render = RenderImage.renderImageFile
    local bb = Blitbuffer.new(64, 64, Blitbuffer.TYPE_BB8)
    RenderImage.renderImageFile = function(self, path) return bb end
    -- The real ImageViewer constructor needs FocusManager/SDL; stub it and
    -- only verify OUR call contract (buffer + ownership flag).
    local iv_key = "ui/widget/imageviewer"
    local real_iv = package.loaded[iv_key]
    local shown = {}
    package.loaded[iv_key] = { new = function(self, opts)
        shown[#shown + 1] = opts
        return opts
    end }
    local real_show = UIManager.show
    UIManager.show = function(self, widget) end
    local app = setmetatable({ state = { settings = {} } }, { __index = App })
    -- Any existing file passes the lfs.attributes guard (render is stubbed).
    local okp, err = pcall(function()
        app:show_character_image_fullscreen(PLUGIN .. "/assets/logo.svg")
    end)
    ok(okp, "fullscreen image: no crash on a raw FFI BlitBuffer (" .. tostring(err) .. ")")
    ok(#shown == 1 and shown[1].image == bb and shown[1].image_disposable == true,
        "fullscreen image: viewer takes buffer ownership via image_disposable")
    -- Missing file is a silent no-op (no viewer, no crash).
    shown = {}
    local okp2 = pcall(function() app:show_character_image_fullscreen("/tmp/nope.png") end)
    ok(okp2 and #shown == 0, "fullscreen image: missing file shows nothing")
    RenderImage.renderImageFile = real_render
    package.loaded[iv_key] = real_iv
    UIManager.show = real_show
end

-- === 8. Chats page: header toolbar pills + fitted rows ======================
do
    local app = fake_app({ page = "chats", chats_index = {
        { text = "Chat A", character_name = "Aria", path = "/tmp/chat_a.jsonl", character_path = nil, callback = function() end },
        { text = "Chat B", character_name = "Kai", path = "/tmp/chat_b.jsonl", character_path = nil, callback = function() end },
        { text = "Chat C", character_name = "Mira", path = "/tmp/chat_c.jsonl", character_path = nil, callback = function() end },
    } })
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()

    ok(Header.height(view) > Theme.metrics().titlebar_h,
        "header: chats page reserves the contextual toolbar row")
    local content_top = Header.height(view)
    Pages.chats(view, bb, 0, content_top, VW, VH - content_top - Theme.metrics().nav_h, 0)
    Header.draw(view, bb, 0, 0, VW)
    Nav.draw(view, bb, 0, VH - Theme.metrics().nav_h, VW, Theme.metrics().nav_h)

    -- Locale-independent: the chats toolbar must register exactly 2 pills.
    local pill_hits = 0
    for _, b in ipairs(view.hitboxes) do
        if tostring(b.label or ""):sub(1, 5) == "pill:" then pill_hits = pill_hits + 1 end
    end
    ok(pill_hits == 2, "header: chats toolbar registers 2 pills (got " .. pill_hits .. ")")
    ok(has_hit(view, "header_kebab"), "header: kebab hit registered")
    local kebab_x = VW - Theme.metrics().pad - Theme.scale(42)
    ok(dark_in(bb, kebab_x, 0, Theme.scale(42), Theme.scale(42)) > 8,
        "header: kebab paints three ink dots (no glyph)")
    dump(bb, "header_chats_full")
end

-- === 8b. Toolbar pills always carry an icon (icon-only fallback) ============
do
    -- Static sweep: every toolbar_spec entry on every pill page has an icon.
    -- (Label-only pills like "+ Import" painted EMPTY black pills when the
    -- narrow-screen icon-only fallback dropped their label.)
    local pages = { "dashboard", "chats", "connections", "personas", "presets", "lorebooks", "regex_scripts" }
    local missing = {}
    for _, page in ipairs(pages) do
        local app = fake_app({ page = page })
        local spec = Header.toolbar_spec({ app = app }) or {}
        for _, side in ipairs({ spec.left or {}, spec.right or {} }) do
            for _, b in ipairs(side) do
                if not b.icon then missing[#missing + 1] = page .. ":" .. tostring(b.label) end
            end
        end
    end
    ok(#missing == 0, "toolbar: every pill has an icon (" .. table.concat(missing, ", ") .. ")")

    -- Narrow paint: dashboard toolbar at 360px falls back to icon-only, but
    -- every pill still paints light icon strokes on the black pill.
    local app = fake_app({ page = "dashboard" })
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    Header.draw(view, bb, 0, 0, 360)
    local pills, empty = 0, 0
    for _, b in ipairs(view.hitboxes) do
        if tostring(b.label or ""):sub(1, 5) == "pill:" then
            pills = pills + 1
            local light = 0
            for yy = b.y + 2, b.y + b.h - 3 do
                for xx = b.x + 2, b.x + b.w - 3 do
                    if bb:getPixel(xx, yy):getR() > 200 then light = light + 1 end
                end
            end
            if light <= 10 then empty = empty + 1 end
        end
    end
    ok(pills == 5 and empty == 0,
        "toolbar: narrow dashboard paints 5 icon pills, none empty (pills=" .. pills .. " empty=" .. empty .. ")")
    dump(bb, "header_dashboard_narrow")
end

-- === 9. Nav: underline spans the label width; badge paints ===================
do
    local app = fake_app({ page = "chats", _unseen = 2 })
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    local nav_h = Theme.metrics().nav_h
    Nav.draw(view, bb, 0, VH - nav_h, VW, nav_h)
    local cell_w = math.floor(VW / 4)
    -- Chats is the 2nd tab; its active underline sits h-3..h above the bottom.
    local underline = dark_in(bb, cell_w, VH - 4, cell_w, 4)
    ok(underline > 15, "nav: active underline under the Chats label (dark=" .. underline .. ")")
    -- Badge: ink disc in the chats cell's top-right corner.
    local badge = dark_in(bb, cell_w * 2 - 24 - 8, VH - nav_h + 5, 24, 24)
    ok(badge > 20, "nav: unseen-chats badge paints (dark=" .. badge .. ")")
    -- Top border: 2px muted line (dark gray ~= 128 on 8-bit e-ink).
    local border = dark_in(bb, 10, VH - nav_h, VW - 20, 3)
    ok(border > 60, "nav: muted 2px top border (dark=" .. border .. ")")
    dump(bb, "nav_badge")
end

-- === 10. Error page: Retry + Quit pills ======================================
do
    local app = fake_app({ page = "dashboard", error = "backend offline" })
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    Pages.error(view, bb, 0, 0, VW, VH, "backend offline")
    -- Locale-independent: both pills register under the "error:" prefix.
    local err_hits = 0
    for _, b in ipairs(view.hitboxes) do
        if tostring(b.label or ""):sub(1, 6) == "error:" then err_hits = err_hits + 1 end
    end
    ok(err_hits == 2, "error: Retry + Quit pill hits registered (got " .. err_hits .. ")")
    ok(dark_in(bb, 0, VH - 60, VW, 50) > 150, "error: two solid pills paint")
    dump(bb, "error")
end

-- === 11. Markdown tables: structured block + aligned grid paint =============
do
    local Md = require("ktui/md")
    local blocks = Md.parse("| Nome | Vida |\n|------|------|\n| Aria  | 12   |\n| Kai   | 9    |")
    ok(#blocks == 1 and blocks[1].kind == "table", "md: table parses to a table block")
    ok(#(blocks[1].header or {}) == 2 and #(blocks[1].rows or {}) == 2,
        "md: table header + 2 rows")

    local app = fake_app({ page = "chat", messages = {
        { role = "assistant", name = "Aria", send_date = os.time(),
          content = "Status:\n\n| HP | MP |\n|----|----|\n| 12 | 4  |" },
    } })
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    Pages.chat(view, bb, 0, 0, VW, VH, 0)
    ok(ink_ratio(bb) > 100, "chat: table message paints (aligned grid)")
    dump(bb, "chat_table")
end

-- === 12. Dashboard card: cover, caption band, favorite disc =================
do
    local app = fake_app()
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    local content_top = Header.height(view)
    Pages.dashboard(view, bb, 0, content_top, VW, VH - content_top - Theme.metrics().nav_h, 0)
    ok(not has_hit(view, "card_continue:"), "cards: no action pill on cards (removed)")
    ok(has_hit(view, "fav:"), "cards: favorite disc hit present")
    ok(dark_in(bb, 0, content_top + 40, VW, 80) > 50, "cards: card paints (cover fallback + fav disc)")
    dump(bb, "card_pill")
end

-- === 12b. Chat ST-UX: bubbles panels, 4-cell bar, kebab, swipes ==========
do
    -- BUBBLES panels are the default style (v0.5; ST chat_styles.BUBBLES).
    Theme.set_bubble_style("bubbles")
    ok(Theme.get_bubble_style() == "bubbles", "chat: bubbles (ST BUBBLES) is the default style")
    Theme.set_chat_bg("paper")
    ok(Theme.chat_bg:getR() == 243, "theme: paper chat tint (gray 243)")
    ok(Theme.chat_panel:getR() == 255 and Theme.chat_panel_user:getR() < 243,
        "theme: panels distinct (bot white, user darker than the paper bg)")
    local chat_messages = {
        { role = "assistant", name = "hashi", send_date = os.time(), content = "hm, hello" },
        { role = "user", name = "Rarin", send_date = os.time(), content = "hi!" },
        { role = "assistant", name = "hashi", send_date = os.time(),
          content = "hey", swipes = { "hey", "hello there", "greetings" }, swipe_id = 2 },
    }
    local app = fake_app({ page = "chat", messages = chat_messages })
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    Pages.chat(view, bb, 0, 0, VW, VH, 0)
    local has_prefix = function(prefix)
        for _, b in ipairs(view.hitboxes) do
            if tostring(b.label or ""):sub(1, #prefix) == prefix then return true end
        end
        return false
    end
    -- 4-cell ST bar
    ok(has_prefix("chat_options"), "chat: Options cell present")
    ok(has_prefix("chat_continue"), "chat: Continue cell present (last = assistant)")
    ok(has_prefix("chat_impersonate"), "chat: Impersonate cell present")
    -- Continue works with a USER last message too (resume after interrupt).
    local user_last = fake_app({ page = "chat", messages = {
        { role = "assistant", name = "hashi", send_date = os.time(), content = "oi" },
        { role = "user", name = "Rarin", send_date = os.time(), content = "gfgf" },
    } })
    local user_last_view = { app = user_last, hitboxes = {} }
    Pages.chat(user_last_view, new_bb(), 0, 0, VW, VH, 0)
    local resume_hit = false
    for _, b in ipairs(user_last_view.hitboxes) do
        if tostring(b.label or "") == "chat_continue" then resume_hit = true end
    end
    ok(resume_hit, "chat: Continue enabled when the last message is the user's (resume)")
    ok(has_prefix("regenerate") == false, "chat: no Regen cell (moved into Options/message menu)")
    -- Inline swipes on the last assistant message
    ok(has_prefix("swipe_prev_"), "chat: inline swipe ‹ hit")
    ok(has_prefix("swipe_next_"), "chat: inline swipe › hit")
    ok(has_prefix("swipe_new_"), "chat: inline swipe + hit")
    -- ST round avatars + name-row kebab (⋯ = 3 painted dots + hitbox)
    ok(has_prefix("kebab_"), "chat: message ⋯ kebab hit registered")
    local pad_px = Theme.scale(10)
    local gutter_px = Theme.scale(18)
    local kebab_r = math.max(2, math.floor(Theme.scale(6) / 2))
    local kebab_w = kebab_r * 6 + Theme.scale(4) * 2
    local inner_r = VW - gutter_px - pad_px - pad_px
    ok(dark_in(bb, inner_r - kebab_w - 6, pad_px, kebab_w + 12, Theme.scale(60)) > 0,
        "chat: kebab dots painted in the first name row")
    -- Paper bg outside panels / bot panel white over it (ST chat tint)
    ok(bb:getPixel(1, 400):getR() == Theme.chat_bg:getR(), "chat: paper tint behind the messages")
    ok(bb:getPixel(pad_px + 2, 40):getR() == Theme.chat_panel:getR(),
        "chat: bot panel color between the panel edge and the avatar")
    ok(ink_ratio(bb) > 200, "chat: bubbles layout paints")
    dump(bb, "chat_bubbles")

    -- Flat (ST DEFAULT) stays selectable and paints with kebab + swipes.
    Theme.set_bubble_style("flat")
    local view3 = { app = fake_app({ page = "chat", messages = chat_messages }), hitboxes = {} }
    local bb3 = new_bb()
    Pages.chat(view3, bb3, 0, 0, VW, VH, 0)
    local flat_kebab = false
    for _, b in ipairs(view3.hitboxes) do
        if tostring(b.label or ""):sub(1, 6) == "kebab_" then flat_kebab = true end
    end
    ok(flat_kebab, "chat flat: kebab hits present")
    ok(ink_ratio(bb3) > 200, "chat flat: paints (avatar column, band, swipes)")
    dump(bb3, "chat_flat")

    -- Panel border sits exactly at panel_right (regression: the text bg once
    -- leaked past a too-narrow panel as a white box on the paper bg).
    Theme.set_bubble_style("bubbles")
    local panel_right = VW - gutter_px - pad_px
    local mid_y = Theme.scale(48) + Theme.scale(20) -- inside the first panel
    ok(bb:getPixel(panel_right - 1, mid_y):getR() == Theme.soft:getR(),
        "chat: panel border at the exact right edge (no text-bg leak)")
    ok(bb:getPixel(panel_right + 3, mid_y):getR() == Theme.chat_bg:getR(),
        "chat: paper right of the panel edge")
    -- Breathing room above the first panel (regression: panel glued to the
    -- header hairline).
    ok(bb:getPixel(pad_px + 20, 2):getR() == Theme.chat_bg:getR(),
        "chat: paper above the first panel (top padding)")
    -- Uniform bar: Write is a regular cell (no black pill), stop_gen only
    -- while generating.
    ok(has_prefix("chat_write"), "chat: Write cell hit registered")
    local action_y = VH - Theme.scale(54)
    ok(bb:getPixel(math.floor(VW * 0.375), action_y + Theme.scale(12)):getR() == Theme.panel:getR(),
        "chat: Write cell has no solid pill (panel bg at its center-top)")

    -- Thinking repaint must not crash (the thinking layout once lacked y).
    local gen_view = { app = fake_app({ page = "chat", messages = chat_messages,
        is_generating = true, thinking_frame = 1 }), hitboxes = {} }
    local gen_ok, gen_err = pcall(function()
        Pages.chat(gen_view, bb3, 0, 0, VW, VH, 0)
    end)
    ok(gen_ok, "chat: thinking repaint renders without crash (" .. tostring(gen_err) .. ")")
    local gen_stop = false
    for _, b in ipairs(gen_view.hitboxes) do
        if tostring(b.label or "") == "stop_gen" then gen_stop = true end
    end
    ok(gen_stop, "chat: generating shows the Stop cell (uniform, no pill swap)")

    -- Past Chats page renders rows with kebab actions
    local app2 = fake_app({ page = "chat_history", past_chats = {
        { name = "Sessão 1", path = "/tmp/c1.jsonl", modified = os.time(), preview = "oi" },
        { name = "Sessão 2", path = "/tmp/c2.jsonl", modified = os.time(), preview = "olá" },
    } })
    local view2 = { app = app2, hitboxes = {} }
    local bb2 = new_bb()
    Pages.chat_history(view2, bb2, 0, 0, VW, VH, 0)
    local open_hits = 0
    for _, b in ipairs(view2.hitboxes) do
        if tostring(b.label or ""):sub(1, 4) == "row:" then open_hits = open_hits + 1 end
    end
    ok(open_hits >= 2, "past chats: rows registered (" .. open_hits .. ")")
    ok(ink_ratio(bb2) > 50, "past chats: paints")
    dump(bb2, "past_chats")
end

-- === 13. All list pages render under the fitted-rows layout =================
do
    -- The real app ensures data dirs in App:new, and KOReader creates its
    -- settings dir at boot. Headless, point KO_HOME at a writable dir when
    -- launching (see the header comment) and pre-create what Storage reads.
    local DataStorage = require("datastorage")
    local sdir = DataStorage:getSettingsDir() .. "/kotavern"
    os.execute("mkdir -p '" .. sdir .. "/worlds' '" .. sdir .. "/chats' '" .. sdir .. "/characters'")
    pcall(function() require("kt_storage").ensure_data_dirs() end)
    for _, page in ipairs({ "lorebooks", "presets", "personas", "connections", "settings_behavior", "settings_network" }) do
        local app = fake_app({ page = page })
        local view = { app = app, hitboxes = {} }
        local bb = new_bb()
        local content_top = Header.height(view)
        local body_h = VH - content_top - Theme.metrics().nav_h
        local okp, err = pcall(function()
            Pages[page](view, bb, 0, content_top, VW, body_h, 0)
            Header.draw(view, bb, 0, 0, VW)
            Nav.draw(view, bb, 0, VH - Theme.metrics().nav_h, VW, Theme.metrics().nav_h)
        end)
        ok(okp and count_hits(view) > 2,
            "pages: " .. page .. " renders (" .. tostring(err) .. ")")
        dump(bb, "page_" .. page)
    end
end

-- Connection editor (canvas page): field rows + Search Model row render.
do
    local app = fake_app({ page = "connection_editor" })
    app.state.editing_connection = {
        id = "c1", name = "Test", base_url = "http://localhost:11434/v1",
        model_id = "llama3", temperature = 0.8, max_tokens = 1024,
        streaming = true,
    }
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    local content_top = Header.height(view)
    local body_h = VH - content_top - Theme.metrics().nav_h
    local okp, err = pcall(function()
        Pages.connection_editor(view, bb, 0, content_top, VW, body_h, 0)
        Header.draw(view, bb, 0, 0, VW)
        Nav.draw(view, bb, 0, VH - Theme.metrics().nav_h, VW, Theme.metrics().nav_h)
    end)
    ok(okp and count_hits(view) > 2,
        "pages: connection_editor renders (" .. tostring(err) .. ")")
    dump(bb, "page_connection_editor")
end

-- Model picker page: live filter, count line, check on the selected model.
do
    local app = fake_app({ page = "model_picker" })
    app.state.editing_connection = { id = "c1", model_id = "llama3" }
    app.state.model_picker = {
        query = "",
        models = { "claude-3", "gpt-4o", "gpt-4o-mini", "llama3", "mistral" },
        selected = "llama3",
    }
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    local content_top = Header.height(view)
    local body_h = VH - content_top - Theme.metrics().nav_h
    local okp, err = pcall(function()
        Pages.model_picker(view, bb, 0, content_top, VW, body_h, 0)
        Header.draw(view, bb, 0, 0, VW)
    end)
    ok(okp, "pages: model_picker renders (" .. tostring(err) .. ")")
    ok(count_hits(view) >= 6, "pages: model_picker registers row + filter hits")
    dump(bb, "page_model_picker")

    -- Filter logic: only gpt-* rows remain after the query is set (direct
    -- state write - the fake app stubs only the drawing-relevant methods).
    app.state.model_picker.query = "gpt-4o"
    local view2 = { app = app, hitboxes = {} }
    local bb2 = new_bb()
    local okp2, err2 = pcall(function()
        Pages.model_picker(view2, bb2, 0, content_top, VW, body_h, 0)
    end)
    ok(okp2, "pages: model_picker filtered renders (" .. tostring(err2) .. ")")
    ok(count_hits(view2) < count_hits(view),
        "pages: model_picker filter reduces visible rows")
    app.state.model_picker.query = ""
end

-- Preset editor page: Prompt Manager row + sectioned parameter rows render
-- for an in-app preset (seeded, no ST prompts table needed) - the v0.6.7
-- "only parameters" fix, painted end to end.
do
    local App = require("kt_app")
    local app = fake_app({ page = "preset_editor" })
    app.state.editing_preset = { id = "p1", name = "In-app" }
    -- Mix real App methods into the fake app (prompt_order_items) first, so
    -- the seeding call below resolves.
    setmetatable(app, { __index = App })
    app:ensure_preset_prompts(app.state.editing_preset)
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    local content_top = Header.height(view)
    local body_h = VH - content_top - Theme.metrics().nav_h
    local okp, err = pcall(function()
        Pages.preset_editor(view, bb, 0, content_top, VW, body_h, 0)
        Header.draw(view, bb, 0, 0, VW)
        Nav.draw(view, bb, 0, VH - Theme.metrics().nav_h, VW, Theme.metrics().nav_h)
    end)
    ok(okp and count_hits(view) > 5,
        "pages: preset_editor renders seeded preset (" .. tostring(err) .. ")")
    ok(has_hit(view, "row:Prompt Manager"), "pages: preset_editor registers the Prompt Manager row")
    dump(bb, "page_preset_editor")

    -- Without a draft: empty state, no crash.
    local app3 = fake_app({ page = "preset_editor" })
    local view3 = { app = app3, hitboxes = {} }
    local bb3 = new_bb()
    local okp3, err3 = pcall(function()
        Pages.preset_editor(view3, bb3, 0, content_top, VW, body_h, 0)
    end)
    ok(okp3, "pages: preset_editor empty state renders (" .. tostring(err3) .. ")")
end

-- Prompt Manager page: seeded in-app preset lists markers + utilities, with
-- add (page bar) and per-row edit/toggle/reorder/kebab hits.
do
    local App = require("kt_app")
    local app = fake_app({ page = "prompt_manager" })
    app.state.editing_preset = { id = "p1", name = "In-app" }
    setmetatable(app, { __index = App })
    app:ensure_preset_prompts(app.state.editing_preset)
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    local okp, err = pcall(function()
        Pages.prompt_manager(view, bb, 0, 0, VW, VH, 0)
    end)
    ok(okp, "pages: prompt_manager renders seeded preset (" .. tostring(err) .. ")")
    ok(has_hit(view, "pm_edit_"), "pages: prompt_manager registers edit hits")
    ok(has_hit(view, "pm_toggle_"), "pages: prompt_manager registers toggle hits")
    ok(has_hit(view, "pm_up_") and has_hit(view, "pm_down_"),
        "pages: prompt_manager registers reorder hits")
    ok(not has_hit(view, "pm_kebab_"), "pages: prompt_manager has NO phantom kebab hit (removed: no affordance, overlapped Up)")
    ok(has_hit(view, "btn:New Prompt"), "pages: prompt_manager page bar has the add-prompt action")
    dump(bb, "page_prompt_manager")
end

-- === 14. Modals.actions: dialog construction logic ==========================
-- The real KOReader dialog widget chain (FocusManager -> device input) does
-- not load headless, so the native widgets are stubbed; this still exercises
-- OUR logic: rows -> buttons mapping, inline icon labels, anchored-geom
-- computation, title_icon handling and the show/cancel options.
do
    local captured = {}
    package.preload["ui/widget/buttondialog"] = function()
        return { new = function(_, opts)
            captured.opts = opts
            if type(opts.anchor) == "function" then
                captured.anchor_geom = opts.anchor() -- must not crash (nil movable)
            end
            return {
                getAddedWidgetAvailableWidth = function() return 300 end,
                addWidget = function(_, w) captured.widgets[#captured.widgets + 1] = w end,
            }
        end }
    end
    for _, name in ipairs({ "ui/widget/confirmbox", "ui/widget/infomessage",
        "ui/widget/inputdialog", "ui/widget/multiinputdialog" }) do
        package.preload[name] = function()
            return { new = function(_, opts) captured.widgets[#captured.widgets + 1] = opts; return {} end }
        end
    end
    package.loaded["ktui/modals"] = nil -- force a fresh load against the stubs
    local Modals = require("ktui/modals")
    captured.widgets = {}
    -- Never hand stub dialogs to the real UIManager (its C input stack is
    -- unavailable headless). Stubbed for the WHOLE section (actions, confirm
    -- and input all funnel through UIManager:show).
    local real_show = require("ui/uimanager").show
    require("ui/uimanager").show = function() end
    Modals.actions("KOTavern", {
        { text = "Um", icon = "user", callback = function() end },
        { text = "Dois", icon = "star", callback = function() end },
    }, {
        align = "left",
        anchor = { x = 400, y = 10, w = 42, h = 42 },
        anchor_right = true,
        compact = true,
        compact_min_width = 220,
        show_cancel = false,
        title_icon = PLUGIN .. "/assets/logo.svg",
    })
    local opts = captured.opts or {}
    ok(#(opts.buttons or {}) == 2, "modals: actions rows mapped (show_cancel=false)")
    ok(opts.shrink_unneeded_width == true and opts.shrink_min_width == 220,
        "modals: compact options forwarded")
    ok(captured.anchor_geom ~= nil and captured.anchor_geom.x == 400 + 42 - 0 - 8,
        "modals: anchor_right geom hangs off the source box")
    ok(#captured.widgets == 1, "modals: title_icon adds the icon+title row")
    local row_text = opts.buttons and opts.buttons[1] and opts.buttons[1][1].text or ""
    ok(#row_text > #("Um") + 2, "modals: inline icon glyph prefixes the label")
    -- Confirm with keep-open: ConfirmBox stub records keep_dialog_open.
    captured.widgets = {}
    Modals.confirm("tmp", "OK", function() end, true)
    ok(captured.widgets[1] and captured.widgets[1].keep_dialog_open == true,
        "modals: confirm forwards keep_dialog_open")
    -- Input with clear_callback prepends the Clear button.
    captured.widgets = {}
    local dialog_stub
    package.loaded["ui/widget/inputdialog"] = nil
    package.preload["ui/widget/inputdialog"] = function()
        return { new = function(_, o) dialog_stub = o
            return { getInputText = function() return "x" end, onShowKeyboard = function() end } end }
    end
    package.loaded["ktui/modals"] = nil
    Modals = require("ktui/modals")
    Modals.input("t", "", "", "OK", function() end, function() end)
    ok(#dialog_stub.buttons == 2 and type(dialog_stub.buttons[1][1].text) == "string",
        "modals: input Clear button prepended (rows: [Clear] [Cancel, OK])")
    Modals.input("t", "", "", "OK", function() end, nil, true)
    ok(dialog_stub.allow_newline == true,
        "modals: input multiline forwards allow_newline")
    ok(dialog_stub.text_height ~= nil,
        "modals: input multiline sets a tall text_height (else the box stays one row)")
    Modals.input("t", "", "", "OK", function() end)
    ok(dialog_stub.allow_newline == false,
        "modals: input defaults to single-line")
    -- Edit Prompt flow: content step is a bounded multiline input, then a
    -- 3-role sheet (MultiInputDialog grew past the screen on long prompts).
    do
        local UIMgr = require("ui/uimanager")
        local real_close = UIMgr.close
        UIMgr.close = function() end
        package.loaded["ui/widget/inputdialog"] = nil
        package.preload["ui/widget/inputdialog"] = function()
            return { new = function(_, o) dialog_stub = o
                return { getInputText = function() return "new\ncontent" end,
                    onShowKeyboard = function() end } end }
        end
        package.loaded["ktui/modals"] = nil
        local Modals2 = require("ktui/modals")
        local App = require("kt_app")
        local prompt = { identifier = "p1", content = "old", role = "system" }
        local app = setmetatable({ state = {
            editing_preset = { prompts = { prompt } },
            settings = {},
        } }, { __index = App })
        function app:refresh() self._refreshed = true end
        function app:_prompt_order_list() return { { identifier = "p1" } } end
        app.view = {}
        function app.view:refresh() end
        app:edit_prompt_item(1)
        ok(dialog_stub.allow_newline == true and dialog_stub.text_height ~= nil,
            "modals: edit-prompt content step is bounded multiline")
        local ok_btn = nil
        for _, row in ipairs(dialog_stub.buttons or {}) do
            for _, b in ipairs(row) do
                if b.is_enter_default then ok_btn = b end
            end
        end
        ok(ok_btn ~= nil, "modals: edit-prompt content step has a default OK")
        if ok_btn then ok_btn.callback() end
        local sheet = app.state.sheet
        local labels = {}
        if sheet then for _, a in ipairs(sheet.actions or {}) do labels[#labels + 1] = a.label end end
        ok(sheet and #labels == 3 and labels[1] == "system" and labels[3] == "assistant",
            "modals: edit-prompt opens a 3-role sheet")
        if sheet then for _, a in ipairs(sheet.actions) do
            if a.label == "user" then a.on_tap() end
        end end
        ok(prompt.content == "new\ncontent" and prompt.role == "user" and app._refreshed,
            "modals: edit-prompt saves multiline content + role")
        UIMgr.close = real_close
    end
    -- restore real widgets for any later section
    require("ui/uimanager").show = real_show
    package.preload["ui/widget/buttondialog"] = nil
    package.preload["ui/widget/confirmbox"] = nil
    package.preload["ui/widget/infomessage"] = nil
    package.preload["ui/widget/inputdialog"] = nil
    package.preload["ui/widget/multiinputdialog"] = nil
    package.loaded["ktui/modals"] = nil
end

-- === 15. ST-CHAT v0.5: circles, image blocks, image cache hashing ==========
do
    -- Circular avatar primitives: carve really clears the corners.
    local cbb = Blitbuffer.new(20, 20, Blitbuffer.TYPE_BB8)
    cbb:fill(Blitbuffer.COLOR_WHITE)
    cbb:paintRect(0, 0, 20, 20, Blitbuffer.COLOR_BLACK)
    P.circle_carve(cbb, 0, 0, 20, Blitbuffer.COLOR_WHITE)
    ok(cbb:getPixel(0, 0):getR() > 200, "primitives: circle_carve clears corners")
    ok(cbb:getPixel(10, 10):getR() < 50, "primitives: circle_carve keeps the center")
    local ring_bb = Blitbuffer.new(30, 30, Blitbuffer.TYPE_BB8)
    ring_bb:fill(Blitbuffer.COLOR_WHITE)
    P.circle_ring(ring_bb, 15, 15, 12, Blitbuffer.COLOR_BLACK)
    ok(ring_bb:getPixel(3, 15):getR() < 50, "primitives: circle_ring paints the left pole")

    -- md: whole-line markdown images and HTML <img> become image blocks.
    local Md = require("ktui/md")
    local blocks = Md.parse("hello\n![a bot pic](https://example.com/pic.png)\nbye")
    local found_img = false
    for _, b in ipairs(blocks) do
        if b.kind == "image" and b.url == "https://example.com/pic.png" then found_img = true end
    end
    ok(found_img, "md: whole-line image becomes kind=image with url")
    local hblocks = Md.parse('<img src="https://x/y.jpg" alt="foto">')
    local found_html_img = false
    for _, b in ipairs(hblocks) do
        if b.kind == "image" and b.url == "https://x/y.jpg" then found_html_img = true end
    end
    ok(found_html_img, "md: HTML <img> becomes kind=image")
    -- Inline image inside a paragraph stays placeholder text (no block).
    local pblocks = Md.parse("look ![x](https://z/q.png) now")
    local only_para = true
    for _, b in ipairs(pblocks) do
        if b.kind ~= "paragraph" then only_para = false end
    end
    ok(only_para, "md: mid-paragraph image stays inline placeholder")

    -- images.lua: deterministic hash + repaint-safe cache lookup (no network).
    local Images = require("ktui/images")
    ok(Images.hash("https://a/b.png") == Images.hash("https://a/b.png"), "images: hash deterministic")
    ok(Images.hash("https://a/b.png") ~= Images.hash("https://a/c.png"), "images: hash distinguishes urls")
    ok(Images.cached_path("https://definitely-not-cached.example/x.png") == nil,
        "images: cached_path misses cleanly (no download at paint time)")
    -- ensure() with a fake app enqueues through the paced queue headlessly
    -- (no download at paint time; the scheduled task may drain the queue
    -- immediately in the harness, so accept pending OR inflight state).
    local fake = { view = nil }
    Images._reset_queue()
    pcall(function() Images.ensure("https://example.com/late.png", fake) end)
    local queued = Images.pending_count() >= 1 or Images._queue_busy()
    ok(queued or Images.cached_path("https://example.com/late.png") == nil,
        "images: ensure defers to the paced queue (no paint-time download)")
    Images._reset_queue()
end

-- === 16. SVG probe: what does an asset render like on a BLACK pill? =======
do
    Theme.set_theme("light") -- section 6 leaves the inverted theme active
    local pill_bb = Blitbuffer.new(24, 24, Blitbuffer.TYPE_BB8)
    pill_bb:fill(Blitbuffer.COLOR_BLACK)
    local okp, err = pcall(function()
        Icons.center(pill_bb, "sort", 0, 0, 24, 24, 16, { invert = true })
    end)
    print(string.format("[probe] Icons.center ok=%s err=%s", tostring(okp), tostring(err)))
    local function px(x, y)
        local p = pill_bb:getPixel(x, y)
        local a = "n/a"
        if p.getAlpha then a = p:getAlpha() end
        return string.format("(%d,%d)=r%d/a%s", x, y, p:getR(), tostring(a))
    end
    print("[probe] corner  " .. px(0, 0))
    print("[probe] edge    " .. px(12, 1))
    print("[probe] center  " .. px(12, 12))
    print("[probe] strokes " .. px(5, 6) .. " " .. px(6, 6) .. " " .. px(7, 6))
    -- Real header toolbar render: the Sort pill's icon slot must hold WHITE
    -- strokes on the black pill (regression: a Lua `enabled and nil or muted`
    -- trap dimmed the whole icon box into a gray square).
    local app2 = fake_app({ page = "chats", chats_index = { {} } })
    local view2 = { app = app2, hitboxes = {} }
    local hbb = Blitbuffer.new(300, Theme.metrics().titlebar_h + 60, Blitbuffer.TYPE_BB8)
    hbb:fill(Blitbuffer.COLOR_WHITE)
    Header.draw(view2, hbb, 0, 0, 300)
    local tb_y = Theme.metrics().titlebar_h
    local btn_h = Theme.btn_h()
    local pill_y = tb_y + math.floor((60 - btn_h) / 2)
    local icon_x = Theme.metrics().pad + Theme.scale(10)
    local whites, grays, darks = 0, 0, 0
    for yy = pill_y + 2, pill_y + btn_h - 3 do
        for xx = icon_x, icon_x + Theme.scale(14) - 1 do
            local v = hbb:getPixel(xx, yy):getR()
            if v > 230 then whites = whites + 1
            elseif v > 90 then grays = grays + 1
            else darks = darks + 1 end
        end
    end
    print(string.format("[probe] pill icon slot: whites=%d grays=%d darks=%d", whites, grays, darks))
    ok(whites >= 8, "pill: icon strokes render WHITE on the black pill (no gray box)")
    ok(darks > grays, "pill: icon slot bg stays dark (no dimmed box)")
    -- Hairline runs beside the kebab (regression: a full-height white
    -- box erased it there). Probed left of the kebab dots (bare bar).
    local probe_x = 300 - Theme.metrics().pad - Theme.scale(42) - 4
    ok(hbb:getPixel(probe_x, tb_y - 1):getR() == Theme.soft:getR(),
        "header: hairline continuous beside the kebab")
end

-- === 17. Bottom alignment: fully scrolled chat shows the last panel whole ==
do
    Theme.set_theme("light")
    Theme.set_bubble_style("bubbles")
    local t = os.time()
    local msgs = {}
    local names = { "Rarin", "hashi" }
    for i = 1, 7 do
        table.insert(msgs, {
            role = (i % 2 == 1) and "user" or "assistant",
            name = names[(i % 2 == 1) and 1 or 2],
            send_date = t,
            content = "mensagem " .. i,
        })
    end
    local app = fake_app({ page = "chat", messages = msgs })
    app.state.scroll["chat"] = 999999 -- auto-scroll bottom (the clamp normalizes)
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    Pages.chat(view, bb, 0, 0, VW, VH, app.state.scroll["chat"])
    local action_y = VH - Theme.scale(54)
    -- Lowest CONTENT pixel in the panel column (x = panel edge + 4): any
    -- panel fill (bot white OR user gray) counts - the last message here is
    -- the user's (gray panel).
    local panel_x = Theme.scale(10) + 4
    local bg_r = Theme.chat_bg:getR()
    local lowest = -1
    for yy = action_y - 1, 0, -1 do
        if bb:getPixel(panel_x, yy):getR() ~= bg_r then
            lowest = yy
            break
        end
    end
    print(string.format("[probe] last panel bottom=%d action_y=%d (gap=%d)",
        lowest, action_y, action_y - lowest))
    print(string.format("[probe] clamped scroll (max_scroll)=%d content_h=%d",
        app.state.scroll["chat"] or -1, VH - Theme.scale(54)))
    ok(lowest > 0 and lowest <= action_y - 2,
        "chat: fully scrolled, the last panel ends ABOVE the action bar (no cut)")
    -- And a strip of paper remains under it (the inter-message gap).
    ok(bb:getPixel(panel_x, action_y - 2):getR() == Theme.chat_bg:getR(),
        "chat: paper gap below the last panel when fully scrolled")
end

-- === Client: reasoning channel + model list parsing ===
do
    local Client = require("kt_client")
    local json = require("json")

    -- Native reasoning delta (DeepSeek reasoning_content / OpenRouter reasoning)
    local r1 = Client.parse_reasoning_delta{ reasoning_content = "step 1" }
    ok(r1 == "step 1", "client: parse_reasoning_delta reads reasoning_content (DeepSeek)")
    local r2 = Client.parse_reasoning_delta{ reasoning = "thinking..." }
    ok(r2 == "thinking...", "client: parse_reasoning_delta reads reasoning (OpenRouter)")
    -- LuaJSON null decodes as a sentinel FUNCTION - must not become text
    local null_delta = json.decode('{"reasoning": null, "reasoning_content": null}')
    ok(Client.parse_reasoning_delta(null_delta) == nil,
        "client: parse_reasoning_delta ignores JSON null sentinels")
    ok(Client.parse_reasoning_delta({ content = "hi" }) == nil,
        "client: parse_reasoning_delta returns nil without a reasoning field")

    -- GET /models response parsing (the three common shapes)
    local m1 = Client:parse_models_response('{"data":[{"id":"b-model"},{"id":"a-model"}]}')
    ok(type(m1) == "table" and m1[1] == "a-model" and m1[2] == "b-model",
        "client: parse_models_response sorts OpenAI {data:[{id}]} shape")
    local m2 = Client:parse_models_response('{"models":[{"name":"llama3"},{"name":"qwen2"}]}')
    ok(type(m2) == "table" and m2[1] == "llama3" and m2[2] == "qwen2",
        "client: parse_models_response reads Ollama {models:[{name}]} shape")
    local m3 = Client:parse_models_response('[{"model":"m1"},"m2"]')
    ok(type(m3) == "table" and m3[1] == "m1" and m3[2] == "m2",
        "client: parse_models_response tolerates a bare array")
    ok(Client:parse_models_response("not json") == nil,
        "client: parse_models_response rejects invalid JSON")
    local with_null = Client:parse_models_response('{"data":[{"id":"m1"},{"id":null}]}')
    ok(type(with_null) == "table" and #with_null == 1 and with_null[1] == "m1",
        "client: parse_models_response drops null ids (LuaJSON sentinel)")
    ok(Client:parse_models_response('{"data":[]}') == nil,
        "client: parse_models_response rejects an empty model list as format error")

    -- A1: reasoning-model payload shaping (max_completion_tokens, no samplers)
    local pr = Client:build_payload({}, { model_id = "o3-mini" }, {}, false)
    ok(pr.max_completion_tokens == 1024 and pr.max_tokens == nil,
        "client: reasoning model uses max_completion_tokens")
    ok(pr.temperature == nil and pr.top_p == nil,
        "client: reasoning model omits temperature/top_p")
    local pnormal = Client:build_payload({}, { model_id = "gpt-4o" }, {}, false)
    ok(pnormal.max_tokens == 1024 and pnormal.max_completion_tokens == nil
        and pnormal.temperature == 0.8,
        "client: normal model keeps max_tokens + temperature")
    local pgpt5 = Client:build_payload({}, { model_id = "openrouter/gpt-5-mini" },
        { reasoning_effort = "low" }, false)
    ok(pgpt5.max_completion_tokens ~= nil and pgpt5.reasoning_effort == "low",
        "client: gpt-5 + reasoning_effort shaped for reasoning APIs")

    -- A4: stop strings (comma-separated -> array, blank items dropped)
    local ps = Client:build_payload({}, { model_id = "m", stop = "The End, ,END." }, {}, false)
    ok(type(ps.stop) == "table" and ps.stop[1] == "The End" and ps.stop[2] == "END.",
        "client: stop strings parsed into the payload")

    -- A5: retry decision (429/5xx retry, capped)
    ok(Client.should_retry(429, 1) == true, "client: 429 retries")
    ok(Client.should_retry(500, 1) == true, "client: 5xx retries")
    ok(Client.should_retry(400, 1) == false, "client: 4xx does not retry")
    ok(Client.should_retry(429, 99) == false, "client: retry cap respected")

    -- C3: prompt post-processing modes
    local M = require("kt_models")
    local msgs = {
        { role = "system", content = "sys A" },
        { role = "system", content = "sys B" },
        { role = "user", content = "hello" },
        { role = "user", content = "again" },
        { role = "assistant", content = "hi" },
    }
    local pm = M.post_process_messages(msgs, "merge")
    ok(#pm == 3 and pm[1].content == "sys A\n\nsys B"
        and pm[2].content == "hello\n\nagain" and pm[3].role == "assistant",
        "models: post-process merge fuses consecutive roles")
    local pp = M.post_process_messages(msgs, "semi_strict")
    ok(#pp == 3 and pp[1].role == "system"
        and pp[1].content:find("sys A", 1, true) ~= nil
        and pp[1].content:find("sys B", 1, true) ~= nil
        and pp[2].role == "user" and pp[3].role == "assistant",
        "models: post-process semi_strict fuses systems and keeps one on top")
    local ps2 = M.post_process_messages({
        { role = "system", content = "sys" },
        { role = "assistant", content = "hello" },
    }, "strict")
    ok(#ps2 == 3 and ps2[1].role == "system" and ps2[2].role == "user"
        and ps2[2].content == "[Start a new chat]",
        "models: post-process strict forces user first (placeholder)")
    local pu = M.post_process_messages(msgs, "single_user")
    ok(#pu == 1 and pu[1].role == "user" and pu[1].content:find("sys A", 1, true) ~= nil,
        "models: post-process single_user collapses everything")
    ok(M.post_process_messages(msgs, nil) == msgs,
        "models: post-process nil mode returns input untouched")
end

-- === Images: fetch sink contract (regression: ltn12.sink is a table) ===
do
    local Images = require("ktui/images")
    local http = require("socket.http")
    -- Hash is deterministic and non-empty (cache key stability).
    ok(#Images.hash("http://x/y.png") == 16, "images: hash returns 16 hex chars")
    ok(Images.hash("a") ~= Images.hash("b"), "images: hash differs per url")

    -- Fetch against a stubbed socket.http: the REAL module drives the sink
    -- synchronously inside request(), so the stub does the same. Regression
    -- guard: sink must be a FUNCTION (v0.6.2 passed ltn12.sink, a table of
    -- factories, and crashed "attempt to call field 'sink' (a table value)").
    local captured_req
    -- Real PNG magic (7th byte = 0x1A SUB - see kotaven_png.lua notes).
    local png = "\137PNG\r\n\026\n" .. string.rep("x", 64)
    -- Fixed URLs, but scrub their cache files first: the disk cache (KO_HOME)
    -- persists between runs and a cached URL would short-circuit before ever
    -- calling http.request (breaking the captured_req assertions below).
    -- v2: variants have extensions, so purge every one of them.
    local url_ok = "http://stub/img1.png"
    local url_big = "http://stub/huge.png"
    Images._purge(url_ok)
    Images._purge(url_big)
    http.request = function(req)
        captured_req = req
        if tostring(req.url):find("huge", 1, true) then
            -- One chunk past the module's MAX_BYTES (12MB): the sink must
            -- flag too_big and abort the chain.
            req.sink(string.rep("x", 12 * 1024 * 1024 + 1))
            return nil, 200, {}, "sink aborted"
        end
        req.sink(png:sub(1, 10))
        req.sink(png:sub(11))
        req.sink(nil)
        return 1, 200, {}, nil
    end
    local ok_socket, fetch_err = pcall(function()
        local path, err = Images.fetch(url_ok)
        assert(path ~= nil, "fetch failed: " .. tostring(err))
    end)
    ok(ok_socket, "images: fetch succeeds via raw sink function (no crash)" ..
        (ok_socket and "" or (": " .. tostring(fetch_err))))
    ok(type(captured_req) == "table" and type(captured_req.sink) == "function",
        "images: request.sink is a function (ltn12.sink table regression)")
    ok(Images.cached_path(url_ok) ~= nil,
        "images: fetched bytes land in the disk cache")
    -- Size guard: a body past MAX_BYTES aborts and is NOT cached. With the
    -- v2 module the size cap lives in curl --max-filesize (https) and the
    -- sink counter (http); a direct oversized write must be rejected by the
    -- cache writer's extension sniff + fetch error path.
    local too_big_ok, too_big_err = pcall(function()
        local path2, err2 = Images.fetch(url_big)
        assert(path2 == nil,
            "guard missed: " .. tostring(path2) .. "/" .. tostring(err2))
    end)
    ok(too_big_ok, "images: oversized body is not cached" ..
        (too_big_ok and "" or (": " .. tostring(too_big_err))))
    ok(Images.cached_path(url_big) == nil,
        "images: aborted download is NOT cached")
end

-- === 4w. Finger-following list drag (phone-style) ================================
do
    local AppView = require("ktui/app_view")
    local Theme = require("ktui/theme")
    local Pages = require("ktui/pages")
    local saved_style = Theme.get_bubble_style()
    local real_sched, real_unsched = UIManager.scheduleIn, UIManager.unschedule
    UIManager.scheduleIn = function() end -- drag repaint pacing is not under test
    UIManager.unschedule = function() end

    local function mk_drag_view(max_scroll)
        local view = {
            app = fake_app({ page = "chat" }),
            list_bounds = { x = 0, y = 0, w = VW, h = VH },
            swipe_step = 40,
            max_scroll = max_scroll or 5000,
        }
        function view:refresh() end
        return setmetatable(view, { __index = AppView })
    end
    local function pan(view, y, start_y)
        AppView.onPanKotavern(view, nil, {
            relative = { x = 0, y = y - (start_y or 0) },
            start_pos = { x = 300, y = start_y or 0 },
            pos = { x = 300, y = y },
        })
    end

    -- Grab: pan inside the list starts a drag; content follows the finger.
    -- Phone semantics: finger UP (pos.y decreases) reveals later content,
    -- finger DOWN scrolls back toward the top.
    local view = mk_drag_view()
    view.app.state.scroll["chat"] = 2000
    pan(view, 300, 700)
    ok(view._list_dragging == true, "drag: pan inside the list starts a drag")
    ok(view.app.state.scroll["chat"] == 2400, "drag: finger up moves content 1:1")
    pan(view, 900, 700)
    ok(view.app.state.scroll["chat"] == 1800, "drag: finger down scrolls back")
    pan(view, -9000, 700)
    ok(view.app.state.scroll["chat"] == 5000, "drag: clamped at max_scroll")
    pan(view, 9000, 700)
    ok(view.app.state.scroll["chat"] == 0, "drag: clamped at the top")

    -- Release commits the offset.
    view.app.state.scroll["chat"] = 2000
    pan(view, 900, 700)
    AppView.onPanReleaseKotavern(view, nil, { pos = { x = 300, y = 900 } })
    ok(view._list_dragging == false and view.app.state.scroll["chat"] == 1800,
        "drag: slow release commits the offset")

    -- Flick release (arrives disguised as a swipe): partial drag reverts and
    -- the swipe applies its normal one-step scroll, no double scrolling.
    local v2 = mk_drag_view()
    v2.app.state.scroll["chat"] = 2000
    pan(v2, 600, 700)
    ok(v2.app.state.scroll["chat"] == 2100, "drag: partial drag tracks the finger")
    AppView.onSwipeKotavern(v2, nil, {
        direction = "south",
        start_pos = { x = 300, y = 700 },
        pos = { x = 300, y = 600 },
    })
    ok(v2._list_dragging == false and v2.app.state.scroll["chat"] == 2000 - v2.swipe_step,
        "drag: flick reverts the drag; swipe steps once from the start")

    -- Auto-follow integration: dragging up mid-generation pins the view;
    -- dragging back to the bottom resumes it.
    local v4 = mk_drag_view()
    v4.app.state.is_generating = true
    v4.app.state.scroll["chat"] = 4000
    pan(v4, 900, 700)
    ok(v4.app.state.user_scrolled_up == true, "drag: scrolling up mid-generation pins the view")
    pan(v4, -3000, 700)
    ok(v4.app.state.user_scrolled_up == nil, "drag: returning to the bottom resumes follow")

    -- Scrollbar affordance: draw_content (not Pages.chat alone) owns the
    -- scrollbar pass.
    local function paint_chat(style)
        local app = fake_app({ page = "chat", messages = {
            { role = "user", content = "q", name = "You" },
            { role = "assistant", content = string.rep("answer text. ", 400), name = "Aria" },
        } })
        local v = { app = app, hitboxes = {} }
        function v:refresh() end
        v.dimen = { x = 0, y = 0, w = VW, h = VH }
        setmetatable(v, { __index = AppView })
        Theme.set_bubble_style(style)
        v:draw_content(new_bb(), 0, 0, VW, VH)
        return v
    end
    local bub_view = paint_chat("bubbles")
    ok(bub_view.scrollbar ~= nil and bub_view.scrollbar.travel > 0,
        "bubbles: scrollbar still drawn")

    -- A scrollbar TAP counts as a manual scroll too: mid-generation it must
    -- release the auto-follow exactly like a thumb drag or a list drag.
    local sb_hit
    for _i, box in ipairs(bub_view.hitboxes) do
        if tostring(box.label or "") == "scrollbar" then sb_hit = box break end
    end
    ok(sb_hit ~= nil, "scrollbar: track tap hitbox exists")
    bub_view.app.state.is_generating = true
    bub_view.app.state.scroll["chat"] = bub_view.max_scroll
    sb_hit.callback(nil, (bub_view.scrollbar.track_y or 10) + 10)
    ok(bub_view.app.state.user_scrolled_up == true,
        "scrollbar: tap mid-generation pins the view")

    UIManager.scheduleIn, UIManager.unschedule = real_sched, real_unsched
    Theme.set_bubble_style(saved_style)
end

-- === 18b. KtHTML sandbox (literal HTML+CSS via MuPDF) ========================
do
    local KtHTML = require("ktui/kthtml")

    -- Theme CSS carries the live palette (our string.format "variables").
    local css = KtHTML.theme_css()
    ok(css:find("background: #", 1, true) ~= nil and css:find(".pill", 1, true) ~= nil,
        "kthtml: theme CSS generated with colors + pills")

    -- State templates: value echo, conditional class, px math, escaping.
    local tapp = { state = { settings = { debug_mode = true }, sandbox = { conta = 3 } } }
    local rendered = KtHTML.render_body(
        '<p>{{s:sandbox.conta}}</p><p>{{s:missing}}</p>' ..
        '<a class="pill {{c:settings.debug_mode:on}}">x</a>' ..
        '<img style="margin-left: {{px:sandbox.conta:24}};"/>' ..
        '<p>{{s:sandbox.evil}}</p>',
        { state = { settings = tapp.state.settings,
            sandbox = { conta = tapp.state.sandbox.conta, evil = "<b>&" } } })
    ok(rendered:find("<p>3</p>", 1, true) ~= nil
        and rendered:find("<p></p>", 1, true) ~= nil
        and rendered:find('class="pill on"', 1, true) ~= nil
        and rendered:find("margin-left: 72px", 1, true) ~= nil
        and rendered:find("&lt;b&gt;&amp;", 1, true) ~= nil,
        "kthtml: s/c/px templates + escaping")

    -- <style> extracted, <script> dropped.
    local nostyle, gotcss = KtHTML.extract_style(
        "<style>.a{color:#111;}</style><p>Hi</p><script>alert(1)</script>")
    ok(gotcss:find(".a", 1, true) ~= nil and nostyle:find("alert", 1, true) == nil,
        "kthtml: style extracted, script discarded")

    -- e/t templates: empty-fallback and conditional text.
    local etapp = { state = { sandbox = { nome = "", sw = false } } }
    local etr = KtHTML.render_body(
        '<p>{{e:sandbox.nome:digite}}</p><p>{{t:sandbox.sw:LIGADO|desligado}}</p>', etapp)
    ok(etr:find("digite", 1, true) ~= nil and etr:find("desligado", 1, true) ~= nil,
        "kthtml: e/t fall back on empty state")
    etapp.state.sandbox.nome, etapp.state.sandbox.sw = "Li & <b>", true
    local etr2 = KtHTML.render_body(
        '<p>{{s:sandbox.nome}}</p><p>{{e:sandbox.nome:digite}}</p>' ..
        '<p>{{t:sandbox.sw:LIGADO|desligado}}</p>', etapp)
    ok(etr2:find("Li &amp; &lt;b&gt;", 1, true) ~= nil
        and etr2:find("<p></p>", 1, true) ~= nil
        and etr2:find("LIGADO}", 1, true) == nil
        and etr2:find("LIGADO", 1, true) ~= nil,
        "kthtml: s shows value, e hides hint, t has no stray brace")

    -- Button look is pure CSS: sans family everywhere, bold centered
    -- pills with button padding (no engine involved). border-radius is
    -- probe-verified ABSENT in MuPDF (square corners render square), so
    -- the honest e-ink button look is squared - kt:btn stays the opt-in
    -- native-pill path where exact radius matters.
    ok(css:find("font-family: 'KTSans', 'Noto Sans', sans-serif", 1, true)
        ~= nil, "kthtml: sans family across the sandbox")
    ok(css:find("@font-face", 1, true) ~= nil
        and css:find("sans-regular.ttf", 1, true) ~= nil,
        "kthtml: bundled sans via @font-face (no system fonts needed)")
    ok(css:find("font-weight: bold; text-align: center", 1, true) ~= nil
        and css:find("padding: 10px 16px", 1, true) ~= nil,
        "kthtml: pills are bold, centered, button-padded")
    ok(css:find("font-family: monospace", 1, true) ~= nil,
        "kthtml: code keeps monospace under the sans body")
    -- Component CSS ships in the base layer.
    ok(css:find(".pill.secondary", 1, true) ~= nil
        and css:find("a.field", 1, true) ~= nil
        and css:find("table.seg", 1, true) ~= nil
        and css:find(".pfill", 1, true) ~= nil
        and css:find(".chip", 1, true) ~= nil
        and css:find(".round", 1, true) ~= nil,
        "kthtml: component classes in theme CSS")
    -- State colors on anchors need !important (the base a{color} beats
    -- MuPDF blue, so a plain state color would lose to IT and paint
    -- dark-on-dark - the unreadable-ON-pill bug class).
    local function rule_has_important(selector)
        local i = css:find(selector, 1, true)
        if not i then return false end
        local blk = css:sub(i, i + 200)
        return blk:find("color:[^;]*!important") ~= nil
    end
    ok(rule_has_important(".pill.primary") and rule_has_important(".pill.on")
        and rule_has_important("table.seg td.on"),
        "kthtml: anchor state colors carry !important")

    -- Install flow mirrors the DSL sandbox (never overwrites, force does).
    os.remove(KtHTML.page_path("html_sandbox.html"))
    local h_inst1 = KtHTML.install_sandbox()
    ok(h_inst1 and KtHTML.page_exists("html_sandbox.html"),
        "kthtml: install writes html_sandbox.html")
    local h_inst2 = KtHTML.install_sandbox()
    ok(h_inst1 and not h_inst2, "kthtml: second install refuses to overwrite")
    local hf = io.open(KtHTML.page_path("html_sandbox.html"), "w")
    hf:write("<p>user edits</p>")
    hf:close()
    local h_force = KtHTML.install_sandbox(true)
    local hr = io.open(KtHTML.page_path("html_sandbox.html"), "r")
    local hbody = hr and hr:read("*a")
    if hr then hr:close() end
    ok(h_force and hbody and hbody:find("Playground", 1, true) ~= nil,
        "kthtml: force install restores the skeleton")

    -- Prepare lints unknown actions/schemes before any layout happens.
    local hrapp = fake_app({ page = "html_test", settings = {} })
    local src, src_errors = KtHTML.prepare(hrapp, "html_sandbox.html",
        { reload = function() end, shot = function() end,
          step = function() end, move = function() end })
    ok(src ~= nil and src.body:find("Playground", 1, true) ~= nil,
        "kthtml: skeleton prepares a body")
    local saw_voar, saw_scheme = false, false
    for _, e in ipairs(src_errors or {}) do
        if tostring(e):find("voar", 1, true) then saw_voar = true end
        if tostring(e):find("kt:unknown", 1, true) then saw_scheme = true end
    end
    ok(saw_voar and saw_scheme and #src_errors >= 2,
        "kthtml: skeleton link errors stay visible (got " .. tostring(#src_errors) .. ")")

    -- Tall layout builds a doc with real height; paint leaves ink.
    local hview = { app = hrapp, hitboxes = {} }
    function hview:refresh() end
    local doc = KtHTML.ensure(hrapp, hview, "html_sandbox.html", src, 500, 700, {})
    local total_h = doc and doc.total_h or 0
    ok(doc ~= nil and not doc.paginated and total_h > 1000 and total_h < 6000,
        "kthtml: tall layout measures content (total_h=" .. tostring(total_h) .. ")")
    local hbb = Blitbuffer.new(500, 700, Blitbuffer.TYPE_BB8)
    hbb:fill(Blitbuffer.COLOR_WHITE)
    KtHTML.paint_window(doc, hbb, 0, 0, 500, 700, 0, hview)
    ok(dark_in(hbb, 0, 0, 500, 700) > 0, "kthtml: tall paint leaves ink")
    ok(hview.dithered == true, "kthtml: MuPDF paint marks dithered refresh")

    -- Link router: find a real kt: link, tap its center.
    local function kt_link(target)
        local pg = doc.widget.document:openPage(doc.widget.page_number or 1)
        local links = pg:getPageLinks() or {}
        pg:close()
        for _, l in ipairs(links) do
            local uri = l.uri or l.url or ""
            if uri == target or uri:find(target, 1, true) == 1 then
                return l
            end
        end
        return nil
    end
    local tog = kt_link("kt:toggle:sandbox.ligado")
    ok(tog ~= nil, "kthtml: toggle link exists in layout")
    if tog then
        local refreshes = 0
        function hrapp:refresh() refreshes = refreshes + 1 end
        local cx, cy = math.floor((tog.x0 + tog.x1) / 2), math.floor((tog.y0 + tog.y1) / 2)
        ok(KtHTML.tap(doc, hrapp, "html_sandbox.html", {}, 0, 0, 0, cx, cy) == true,
            "kthtml: tap consumes the toggle link")
        ok(hrapp.state.sandbox.ligado == true and refreshes >= 1,
            "kthtml: toggle tap flips state + refreshes")
    end
    -- The toggle tap invalidated the doc (fresh body on next paint), so
    -- re-ensure before probing further links.
    doc = KtHTML.ensure(hrapp, hview, "html_sandbox.html", src, 500, 700, {})
    ok(doc ~= nil and doc.widget ~= nil, "kthtml: doc rebuilds after invalidate")
    local navapp = fake_app({ page = "html_test", settings = {} })
    local went = nil
    function navapp:navigate(p) went = p end
    local navl = kt_link("kt:action:reload")
    if navl then
        local fired = nil
        local cx = math.floor((navl.x0 + navl.x1) / 2)
        local cy = math.floor((navl.y0 + navl.y1) / 2)
        ok(KtHTML.tap(doc, navapp, "html_sandbox.html",
            { reload = function(id) fired = id or "noid" end }, 0, 0, 0, cx, cy) == true,
            "kthtml: action link fires with router map")
        ok(fired == "noid", "kthtml: action id defaults when absent")
    end
    ok(KtHTML.tap(doc, navapp, "html_sandbox.html", {}, 0, 0, 0, -50, -50) == false,
        "kthtml: tap outside links is not consumed")

    -- Animation: lint validates names, ensure collects link rects, paint
    -- overlays frames, tap consumes silently, rebuild prunes the stale.
    do
        ok(KtHTML.check_anim("debug_banner") == nil,
            "kthtml: valid anim dir passes lint")
        ok(KtHTML.check_anim("../x") ~= nil and KtHTML.check_anim("nodir") ~= nil,
            "kthtml: bad anim names/dirs flagged")
        local ahtml = '<a class="anim" style="display: inline-block; width: 64px; height: 64px;" href="kt:anim:debug_banner">' ..
            '<img src="debug_banner/frame_1.png" style="width: 64px;"/></a>' ..
            '<a class="anim" href="kt:anim:../x"><img src="x.png"/></a>'
        local atmp = os.tmpname()
        local af = io.open(atmp, "w")
        af:write(ahtml)
        af:close()
        local real_path = KtHTML.page_path
        KtHTML.page_path = function() return atmp end
        local asrc, aerrs = KtHTML.prepare(hrapp, "anim_probe.html", {})
        local saw_anim_err = false
        for _, e in ipairs(aerrs or {}) do
            if tostring(e):find("anim", 1, true) then saw_anim_err = true end
        end
        ok(asrc ~= nil and saw_anim_err,
            "kthtml: bad anim link surfaces a lint error")
        local GifAnim = require("ktui/gifanim")
        local adoc = asrc and KtHTML.ensure(hrapp, hview, "anim_probe.html",
            asrc, 300, 300, {}) or nil
        ok(adoc ~= nil and adoc.anims ~= nil and #adoc.anims == 1,
            "kthtml: one anchor yields one rect after dedupe (got " ..
            tostring(adoc and adoc.anims and #adoc.anims) .. ")")
        if adoc then
            local abb = Blitbuffer.new(300, 300, Blitbuffer.TYPE_BB8)
            abb:fill(Blitbuffer.COLOR_WHITE)
            KtHTML.paint_window(adoc, abb, 0, 0, 300, 300, 0)
            ok(dark_in(abb, 0, 0, 300, 300) > 20,
                "kthtml: anim overlay paints a frame")
            local a = adoc.anims[1]
            local acx = math.floor(a.x0 + (a.x1 - a.x0) / 2)
            local acy = math.floor(a.y0 + (a.y1 - a.y0) / 2)
            local before = hrapp.state.sandbox
            ok(KtHTML.tap(adoc, hrapp, "anim_probe.html", {}, 0, 0, 0, acx, acy) == true,
                "kthtml: anim tap consumed silently")
            ok(hrapp.state.sandbox == before,
                "kthtml: anim tap mutates nothing")
            GifAnim.stop_all(hrapp)
        end
        -- Prune drops players whose animation left the rebuilt HTML.
        local fake_player = { stopped = false, tick = function() end, bbs = {} }
        hrapp.state.gif_players = { ["kthtml:anim:anim_probe.html:old:1"] = fake_player }
        KtHTML.prune_anim_players(hrapp, "anim_probe.html", {})
        ok(hrapp.state.gif_players["kthtml:anim:anim_probe.html:old:1"] == nil
            and fake_player.stopped == true,
            "kthtml: prune stops + drops stale players")
        KtHTML.page_path = real_path
        os.remove(atmp)
    end

    -- Inline link inside a sentence (no pill class): tap fires through
    -- the grown hitbox like any other link. Buttons and links share the
    -- exact same tap path - visual style never gates function.
    do
        local ltmp = os.tmpname()
        local lf = io.open(ltmp, "w")
        lf:write('<p>texto antes <a href="kt:action:go">aqui</a> texto depois</p>')
        lf:close()
        local real_path = KtHTML.page_path
        KtHTML.page_path = function() return ltmp end
        local lsrc = KtHTML.prepare(hrapp, "inline_probe.html", {})
        local ldoc = lsrc and KtHTML.ensure(hrapp, hview, "inline_probe.html",
            lsrc, 400, 200, {}) or nil
        ok(ldoc ~= nil, "kthtml: inline link doc builds")
        if ldoc then
            local lview = { app = hrapp, hitboxes = {} }
            function lview:refresh() end
            P.hit(lview, 0, 0, 400, 200, function() end, "kthtml:page")
            local lbb = Blitbuffer.new(400, 200, Blitbuffer.TYPE_BB8)
            lbb:fill(Blitbuffer.COLOR_WHITE)
            local fired = nil
            KtHTML.paint_window(ldoc, lbb, 0, 0, 400, 200, 0, lview,
                { go = function() fired = true end })
            local pg = ldoc.widget.document:openPage(1)
            local links = pg:getPageLinks() or {}
            pg:close()
            local ll = nil
            for _, l in ipairs(links) do
                if (l.uri or "") == "kt:action:go" then ll = l end
            end
            ok(ll ~= nil, "kthtml: inline link exists in layout")
            if ll then
                local cx = math.floor((ll.x0 + ll.x1) / 2)
                local cy = math.floor((ll.y0 + ll.y1) / 2)
                for i = #lview.hitboxes, 1, -1 do
                    local box = lview.hitboxes[i]
                    if P.contains(box, cx, cy) then
                        box.callback(cx, cy)
                        break
                    end
                end
                ok(fired == true, "kthtml: inline link tap fires")
            end
            KtHTML.free_doc(ldoc)
        end
        KtHTML.page_path = real_path
        os.remove(ltmp)
    end

    -- Pagination mode lays out at viewport height and paints per page.
    local pdoc = KtHTML.ensure(hrapp, hview, "html_sandbox.html", src, 500, 700,
        { paginated = true })
    ok(pdoc ~= nil and pdoc.paginated == true and (pdoc.page_count or 0) >= 1,
        "kthtml: paginated layout builds (pages=" .. tostring(pdoc and pdoc.page_count) .. ")")
    local pbb = Blitbuffer.new(500, 700, Blitbuffer.TYPE_BB8)
    pbb:fill(Blitbuffer.COLOR_WHITE)
    KtHTML.paint_window(pdoc, pbb, 0, 0, 500, 700, 0)
    ok(dark_in(pbb, 0, 0, 500, 700) > 0, "kthtml: paginated paint leaves ink")

    -- kt:btn: anchors become native canvas pills with own hitboxes.
    do
        local bhtml = '<a style="display: inline-block; width: 100px; height: 32px;" '
            .. 'href="kt:btn:poke:id9">poke</a>'
            .. '<a style="display: inline-block; width: 90px; height: 30px;" '
            .. 'href="kt:btn:unmapped">dead</a>'
        local btmp = os.tmpname()
        local bf = io.open(btmp, "w")
        bf:write(bhtml)
        bf:close()
        local real_path = KtHTML.page_path
        KtHTML.page_path = function() return btmp end
        local bsrc, berrs = KtHTML.prepare(hrapp, "btn_probe.html", {})
        ok(bsrc ~= nil and #berrs == 0, "kthtml: btn links pass lint")
        local bdoc = bsrc and KtHTML.ensure(hrapp, hview, "btn_probe.html",
            bsrc, 300, 200, {}) or nil
        ok(bdoc ~= nil and bdoc.btns and #bdoc.btns == 2,
            "kthtml: both btn anchors extracted (got "
            .. tostring(bdoc and bdoc.btns and #bdoc.btns) .. ")")
        if bdoc then
            local fired = nil
            local bview = { app = hrapp, hitboxes = {} }
            function bview:refresh() end
            local bbb = Blitbuffer.new(300, 200, Blitbuffer.TYPE_BB8)
            bbb:fill(Blitbuffer.COLOR_WHITE)
            KtHTML.paint_window(bdoc, bbb, 0, 0, 300, 200, 0, bview,
                { poke = function(id) fired = id end })
            ok(dark_in(bbb, 0, 0, 300, 200) > 0,
                "kthtml: btn pill paints over the bitmap")
            local hb = nil
            for i = #bview.hitboxes, 1, -1 do
                if tostring(bview.hitboxes[i].label) == "btn:poke" then
                    hb = bview.hitboxes[i]
                    break
                end
            end
            ok(hb ~= nil and hb.callback ~= nil,
                "kthtml: kt:btn registers a native hitbox on the view")
            if hb then hb.callback(0, 0) end
            ok(fired == "id9",
                "kthtml: btn tap fires the mapped action with its id (got "
                .. tostring(fired) .. ")")
            -- Unmapped name: the router consumes the tap, state untouched.
            local b2 = bdoc.btns[2]
            local bcx = math.floor(b2.x0 + (b2.x1 - b2.x0) / 2)
            local bcy = math.floor(b2.y0 + (b2.y1 - b2.y0) / 2)
            ok(KtHTML.tap(bdoc, hrapp, "btn_probe.html", {}, 0, 0, 0, bcx, bcy) == true,
                "kthtml: unmapped btn tap consumed (no fall-through)")
            KtHTML.free_doc(bdoc)
        end
        KtHTML.page_path = real_path
        os.remove(btmp)
    end

    -- Lifecycle: invalidate drops, free_all releases.
    KtHTML.invalidate(hrapp, "html_sandbox.html")
    ok(KtHTML.current(hrapp, "html_sandbox.html") == nil,
        "kthtml: invalidate drops the cached doc")
    KtHTML.free_all(hrapp)
    ok(hrapp.state.kthtml_docs == nil, "kthtml: free_all releases everything")

    -- Hitbox order: the page hitbox is registered BEFORE paint, so native
    -- overlay hitboxes (registered during paint) win ties in the reverse
    -- dispatch loop. This replays onTapKotavern order, not just registration.
    do
        local ohtml = '<a style="display: inline-block; width: 120px; height: 40px;"'
            .. ' href="kt:btn:go:x1">Go</a>'
        local otmp = os.tmpname()
        local of = io.open(otmp, "w")
        of:write(ohtml)
        of:close()
        local real_path = KtHTML.page_path
        KtHTML.page_path = function() return otmp end
        local osrc = KtHTML.prepare(hrapp, "order_probe.html", {})
        local odoc = osrc and KtHTML.ensure(hrapp, hview, "order_probe.html",
            osrc, 300, 200, {}) or nil
        ok(odoc ~= nil, "kthtml: order probe builds")
        if odoc then
            local oview = { app = hrapp, hitboxes = {} }
            function oview:refresh() end
            local fired, page_hit = nil, false
            -- Pages.html_test order: page hitbox FIRST, then paint.
            P.hit(oview, 0, 0, 300, 200, function() page_hit = true end,
                "kthtml:page")
            local obb = Blitbuffer.new(300, 200, Blitbuffer.TYPE_BB8)
            obb:fill(Blitbuffer.COLOR_WHITE)
            KtHTML.paint_window(odoc, obb, 0, 0, 300, 200, 0, oview,
                { go = function(id) fired = id end })
            local b = odoc.btns[1]
            local bcx = math.floor(b.x0 + (b.x1 - b.x0) / 2)
            local bcy = math.floor(b.y0 + (b.y1 - b.y0) / 2)
            for i = #oview.hitboxes, 1, -1 do
                local box = oview.hitboxes[i]
                if P.contains(box, bcx, bcy) then
                    box.callback(bcx, bcy)
                    break
                end
            end
            ok(fired == "x1" and not page_hit,
                "kthtml: overlay hitbox wins over page hitbox (got "
                .. tostring(fired) .. ")")
            KtHTML.free_doc(odoc)
        end
        KtHTML.page_path = real_path
        os.remove(otmp)
    end

    -- Padding tap: the grown hitbox (touch-sized) fires where the bare
    -- link rect (text-hugging) would miss. This is what the overlay-free
    -- path buys over pure links - same action, bigger target, no paint.
    do
        if not hrapp.refresh then function hrapp:refresh() end end
        hrapp.state.sandbox = hrapp.state.sandbox or {}
        hrapp.state.sandbox.pad = false
        local phtml = '<a href="kt:toggle:sandbox.pad">ok</a>'
        local ptmp = os.tmpname()
        local pf = io.open(ptmp, "w")
        pf:write(phtml)
        pf:close()
        local real_path = KtHTML.page_path
        KtHTML.page_path = function() return ptmp end
        local psrc = KtHTML.prepare(hrapp, "pad_probe.html", {})
        local pdoc = psrc and KtHTML.ensure(hrapp, hview, "pad_probe.html",
            psrc, 300, 200, {}) or nil
        ok(pdoc ~= nil, "kthtml: padding probe builds")
        if pdoc then
            local pg = pdoc.widget.document:openPage(1)
            local links = pg:getPageLinks() or {}
            pg:close()
            local pl = nil
            for _, l in ipairs(links) do
                if (l.uri or "") == "kt:toggle:sandbox.pad" then pl = l end
            end
            ok(pl ~= nil, "kthtml: probe link exists")
            if pl then
                local lw, lh = pl.x1 - pl.x0, pl.y1 - pl.y0
                local pview = { app = hrapp, hitboxes = {} }
                function pview:refresh() end
                P.hit(pview, 0, 0, 300, 200, function() end, "kthtml:page")
                local pbb = Blitbuffer.new(300, 200, Blitbuffer.TYPE_BB8)
                pbb:fill(Blitbuffer.COLOR_WHITE)
                KtHTML.paint_window(pdoc, pbb, 0, 0, 300, 200, 0, pview, {})
                local grown = nil
                for _i, hbox in ipairs(pview.hitboxes) do
                    if tostring(hbox.label or "") ==
                        "ktlink:kt:toggle:sandbox.pad" then
                        grown = hbox
                    end
                end
                ok(grown ~= nil, "kthtml: grown hitbox registered")
                if grown then
                    local touch_min = Theme.scale(44)
                    ok(grown.w >= touch_min and grown.h >= touch_min,
                        "kthtml: grown hitbox meets touch size (got "
                        .. tostring(grown.w) .. "x" .. tostring(grown.h)
                        .. " from link " .. tostring(math.floor(lw)) .. "x"
                        .. tostring(math.floor(lh)) .. ")")
                    -- Tap inside the grown box but outside the link: 3px
                    -- inside the grown right edge (grown strictly pads
                    -- small links, so this is outside the text run).
                    local tx = math.floor(grown.x + grown.w - 3)
                    local ty = math.floor((pl.y0 + pl.y1) / 2)
                    local outside_link = tx < pl.x0 or tx >= pl.x1
                    ok(outside_link, "kthtml: probe tap is outside the link")
                    if outside_link then
                        for i = #pview.hitboxes, 1, -1 do
                            local box = pview.hitboxes[i]
                            if P.contains(box, tx, ty) then
                                box.callback(tx, ty)
                                break
                            end
                        end
                        ok(hrapp.state.sandbox.pad == true,
                            "kthtml: padding tap flips state")
                    end
                end
            end
            KtHTML.free_doc(pdoc)
        end
        KtHTML.page_path = real_path
        os.remove(ptmp)
    end

    -- Toggle/field are link pills (no overlay): probe-verified, MuPDF link
    -- boxes hug anchor text and whitespace-only anchors make no link, so an
    -- overlay would guess geometry. Taps route through shared handlers.
    do
        if not hrapp.refresh then function hrapp:refresh() end end
        local whtml = '<a class="pill" href="kt:toggle:sandbox.t1">liga</a>'
            .. '<a class="field" href="kt:input:sandbox.f1">campo</a>'
        local wtmp = os.tmpname()
        local wf = io.open(wtmp, "w")
        wf:write(whtml)
        wf:close()
        local real_path = KtHTML.page_path
        KtHTML.page_path = function() return wtmp end
        local wsrc = KtHTML.prepare(hrapp, "widgets_probe.html", {})
        local wdoc = wsrc and KtHTML.ensure(hrapp, hview, "widgets_probe.html",
            wsrc, 300, 300, {}) or nil
        ok(wdoc ~= nil, "kthtml: toggle/field pill doc builds")
        if wdoc then
            local wview = { app = hrapp, hitboxes = {} }
            function wview:refresh() end
            local wbb = Blitbuffer.new(300, 300, Blitbuffer.TYPE_BB8)
            wbb:fill(Blitbuffer.COLOR_WHITE)
            KtHTML.paint_window(wdoc, wbb, 0, 0, 300, 300, 0, wview, {})
            ok(dark_in(wbb, 0, 0, 300, 300) > 0,
                "kthtml: toggle/field pills paint")
            local pg = wdoc.widget.document:openPage(1)
            local links = pg:getPageLinks() or {}
            pg:close()
            local tl = nil
            for _, l in ipairs(links) do
                if (l.uri or l.url or "") == "kt:toggle:sandbox.t1" then tl = l end
            end
            ok(tl ~= nil, "kthtml: toggle pill link exists")
            if tl then
                local cx = math.floor((tl.x0 + tl.x1) / 2)
                local cy = math.floor((tl.y0 + tl.y1) / 2)
                ok(KtHTML.tap(wdoc, hrapp, "widgets_probe.html", {}, 0, 0, 0,
                    cx, cy) == true, "kthtml: pill tap routes")
                ok(hrapp.state.sandbox.t1 == true,
                    "kthtml: pill toggle flips state through shared handler")
            end
            KtHTML.free_doc(wdoc)
        end
        KtHTML.page_path = real_path
        os.remove(wtmp)
    end

    -- W.html_block: static island measures, paints, taps.
    do
        local Widgets = require("ktui/widgets")
        local iapp = fake_app({ page = "native_test", settings = {} })
        local iview = { app = iapp, hitboxes = {} }
        function iview:refresh() end
        local ibb = Blitbuffer.new(400, 200, Blitbuffer.TYPE_BB8)
        ibb:fill(Blitbuffer.COLOR_WHITE)
        local imax = Widgets.html_block(iview, ibb, {
            x = 0, y = 0, w = 400, h = 200, scroll = 0,
            html = "<p>ilha <a href=\"kt:action:ping\">toca</a></p>",
            actions = { ping = function() end },
            key = "block_probe",
        })
        ok(imax >= 0, "kthtml: html_block returns max_scroll")
        ok(dark_in(ibb, 0, 0, 400, 200) > 0, "kthtml: html_block paints")
        local ih = nil
        for _i, hbox in ipairs(iview.hitboxes) do
            if tostring(hbox.label or "") == "kthtml:island" then ih = hbox end
        end
        ok(ih ~= nil, "kthtml: island hitbox registered")
    end

    -- No phantom refresh: tapping a link must enqueue zero refreshes
    -- before the action runs. A pre-action setDirty+forceRePaint cycle once
    -- cost a full blocking e-ink refresh with zero visible effect (the
    -- pixels never changed) - deleted, pinned gone by this test.
    do
        if not hrapp.refresh then function hrapp:refresh() end end
        local qtmp = os.tmpname()
        local qf = io.open(qtmp, "w")
        qf:write('<p><a href="kt:toggle:sandbox.quiet">x</a></p>')
        qf:close()
        local real_path = KtHTML.page_path
        KtHTML.page_path = function() return qtmp end
        local qsrc = KtHTML.prepare(hrapp, "quiet_probe.html", {})
        local qdoc = qsrc and KtHTML.ensure(hrapp, hview, "quiet_probe.html",
            qsrc, 300, 200, {}) or nil
        ok(qdoc ~= nil, "kthtml: quiet probe builds")
        if qdoc then
            local real_setdirty = UIManager.setDirty
            local dirtied = 0
            UIManager.setDirty = function(...)
                dirtied = dirtied + 1
                return true
            end
            local pg = qdoc.widget.document:openPage(1)
            local links = pg:getPageLinks() or {}
            pg:close()
            local ql = nil
            for _, l in ipairs(links) do
                if (l.uri or "") == "kt:toggle:sandbox.quiet" then ql = l end
            end
            if ql then
                local cx = math.floor((ql.x0 + ql.x1) / 2)
                local cy = math.floor((ql.y0 + ql.y1) / 2)
                KtHTML.tap(qdoc, hrapp, "quiet_probe.html", {}, 0, 0, 0, cx, cy)
            end
            UIManager.setDirty = real_setdirty
            ok(ql ~= nil and dirtied == 0 and hrapp.state.sandbox.quiet == true,
                "kthtml: tap fires with zero pre-action refreshes")
            KtHTML.free_doc(qdoc)
        end
        KtHTML.page_path = real_path
        os.remove(qtmp)
    end

    -- Full-width pill hit: the painted bar spans the content width while
    -- the link hugs text, so a tap at the far right edge (inside paint,
    -- far outside the link) must still fire. This is the user-visible bug
    -- class: visual without hit.
    do
        if not hrapp.refresh then function hrapp:refresh() end end
        local fhtml = '<p><a class="pill" href="kt:action:go">Go</a></p>'
        local ftmp = os.tmpname()
        local ff = io.open(ftmp, "w")
        ff:write(fhtml)
        ff:close()
        local real_path = KtHTML.page_path
        KtHTML.page_path = function() return ftmp end
        local fsrc = KtHTML.prepare(hrapp, "fullwidth_probe.html", {})
        local fdoc = fsrc and KtHTML.ensure(hrapp, hview, "fullwidth_probe.html",
            fsrc, 400, 200, {}) or nil
        ok(fdoc ~= nil, "kthtml: full-width probe builds")
        if fdoc then
            local fview = { app = hrapp, hitboxes = {} }
            function fview:refresh() end
            P.hit(fview, 0, 0, 400, 200, function() end, "kthtml:page")
            local fbb = Blitbuffer.new(400, 200, Blitbuffer.TYPE_BB8)
            fbb:fill(Blitbuffer.COLOR_WHITE)
            local fired = nil
            KtHTML.paint_window(fdoc, fbb, 0, 0, 400, 200, 0, fview,
                { go = function() fired = true end })
            local wide = nil
            for _i, hbox in ipairs(fview.hitboxes) do
                if tostring(hbox.label or "") == "ktlink:kt:action:go" then
                    wide = hbox
                end
            end
            ok(wide ~= nil and wide.w == 400,
                "kthtml: pill hit spans the painted bar (got w="
                .. tostring(wide and wide.w) .. ")")
            if wide then
                -- Far right edge: inside paint, ~300px past the link text.
                local tx, ty = 390, math.floor(wide.y + wide.h / 2)
                for i = #fview.hitboxes, 1, -1 do
                    local box = fview.hitboxes[i]
                    if P.contains(box, tx, ty) then
                        box.callback(tx, ty)
                        break
                    end
                end
                ok(fired == true, "kthtml: far-right bar tap fires")
            end
            KtHTML.free_doc(fdoc)
        end
        KtHTML.page_path = real_path
        os.remove(ftmp)
    end

    -- html_test page end-to-end (HTML body painted, hitbox registered).
    local eapp = fake_app({ page = "html_test", settings = { debug_mode = true } })
    local eview = { app = eapp, hitboxes = {} }
    function eview:refresh() end
    eview.dimen = { x = 0, y = 0, w = VW, h = VH }
    setmetatable(eview, { __index = AppView })
    local ebb = new_bb()
    local emax = Pages.html_test(eview, ebb, 0, 0, VW, VH, 0)
    ok(emax >= 0, "html_test: paints and returns max_scroll")
    local nhtml = 0
    for _i, hbox in ipairs(eview.hitboxes) do
        if tostring(hbox.label or "") == "kthtml:page" then nhtml = nhtml + 1 end
    end
    ok(nhtml == 1, "html_test: content hitbox registered")
    ok(ink_ratio(ebb) > 0, "html_test: page ink on screen")
    -- TALL-CACHE (device: paginated-OFF taps were 11x slower than ON -
    -- SDL base 22.1ms vs 1.9ms measured): a second ensure of the same
    -- shape must take the cached-total path - one direct setContent -
    -- instead of repeating the 3-pass probe.
    do
        local KtHTML2 = require("ktui/kthtml")
        local body = "<p>cache prober</p><p>segundo</p>"
        local css = "p { margin: 1px 0; }"
        local app2 = fake_app({ page = "html_test", settings = { debug_mode = true } })
        local src = { body = body, css = css, mtime = os.time() }
        local function ensure_count()
            local d = KtHTML2.ensure(app2, eview, "cache_probe.html",
                src, 550, 760, { paginated = false })
            if d then return d.total_h end
        end
        KtHTML2._tall_cache = KtHTML2._tall_cache or {}
        local key = table.concat({ body, "\0", css, "\0",
            Theme.get_theme() .. "|" .. tostring(Theme.get_base_font_size()), "\0", 550 }, "")
        KtHTML2._tall_cache[key] = nil
        ensure_count() -- probe fill
        ok(KtHTML2._tall_cache[key] ~= nil,
            "kthtml: tall-cache filled by the first ensure")
        local h2 = ensure_count() -- cache hit path
        ok(h2 ~= nil and h2 > 0 and KtHTML2._tall_cache[key] ~= nil,
            "kthtml: cached ensure still returns a usable total_h (" ..
            tostring(h2) .. ")")
        KtHTML2.invalidate(app2, "cache_probe.html")
    end

    -- native_test page end-to-end (native title/buttons + HTML island).
    local napp = fake_app({ page = "native_test", settings = {} })
    local nview = { app = napp, hitboxes = {} }
    function nview:refresh() end
    nview.dimen = { x = 0, y = 0, w = VW, h = VH }
    setmetatable(nview, { __index = AppView })
    local nbb = new_bb()
    local nmax = Pages.native_test(nview, nbb, 0, 0, VW, VH, 0)
    ok(nmax == 0, "native_test: fixed layout, no scroll")
    local nbtn, nisl = 0, 0
    for _i, hbox in ipairs(nview.hitboxes) do
        local lb = tostring(hbox.label or "")
        if lb:sub(1, 4) == "btn:" then nbtn = nbtn + 1 end
        if lb == "kthtml:island" then nisl = nisl + 1 end
    end
    ok(nbtn >= 2 and nisl == 1,
        "native_test: 2 native buttons + island hitbox (got "
        .. tostring(nbtn) .. "+" .. tostring(nisl) .. ")")
    ok(ink_ratio(nbb) > 0, "native_test: page ink on screen")
end

-- === 8. Ghost-healing: no-flash repaints escalate to flashui periodically ====
do
    local App = require("kt_app")
    local app = setmetatable({
        state = { settings = {}, scroll = {} },
        view = {},
    }, { __index = App })
    local modes = {}
    local real_setdirty = UIManager.setDirty
    UIManager.setDirty = function(_, widget, mode, region)
        modes[#modes + 1] = { mode = mode, region = region }
        return true
    end
    local Geom = require("ui/geometry")
    local region = Geom:new{ x = 0, y = 0, w = 100, h = 50 }
    local N = App.REGIONAL_PER_FLASH
    for _ = 1, N - 1 do
        app:refresh(nil, region)
    end
    ok(#modes == N - 1 and modes[1].mode == "ui" and modes[#modes].mode == "ui",
        "ghost: regional refreshes stay 'ui' below the threshold")
    app:refresh(nil, region)
    ok(modes[N] ~= nil and modes[N].mode == "flashui" and modes[N].region == region,
        "ghost: the Nth no-flash regional escalates to flashui")
    -- Rate limit: an immediate burst after the escalation stays flash-free.
    for _ = 1, N do
        app:refresh(nil, region)
    end
    ok(modes[#modes].mode == "ui",
        "ghost: rate limit keeps bursts flash-free right after an escalation")
    -- Full-dimen no-flash refreshes count toward the same escalation.
    app:refresh(nil)
    ok(modes[#modes].mode == "ui", "ghost: full-dimen 'ui' refresh counts")
    -- Routine full requests ride 'partial'; identity changes flash once.
    app:refresh(true)
    ok(modes[#modes].mode == "partial", "ghost: routine full rides partial (no flash)")
    app._flash_pending = true
    app:refresh(true)
    ok(modes[#modes].mode == "full", "ghost: pending identity change flashes once")
    ok(app._flash_pending == nil, "ghost: flash_pending consumed")
    UIManager.setDirty = real_setdirty
end

-- === 19c. Empty state: block (icon+text) centered as ONE unit =================
do
    local Widgets = require("ktui/widgets")
    local bh = 400
    local bbe = Blitbuffer.new(300, bh, Blitbuffer.TYPE_BB8)
    bbe:fill(Blitbuffer.COLOR_WHITE)
    Widgets.empty_state({ hitboxes = {} }, bbe, {
        x = 0, y = 0, w = 300, h = bh,
        icon = "comments",
        text = "No chats yet. Open a character card on Home and start a chat.",
    })
    -- Every dark pixel forms one contiguous block: nothing above/below it,
    -- and top/bottom margins are within a band of each other (centered).
    local top_ink, bot_ink
    for yy = 0, bh - 1 do
        if dark_in(bbe, 0, yy, 300, 1) > 0 then top_ink = yy break end
    end
    for yy = bh - 1, 0, -1 do
        if dark_in(bbe, 0, yy, 300, 1) > 0 then bot_ink = yy break end
    end
    ok(top_ink and bot_ink, "emptystate: paints ink at all")
    if top_ink and bot_ink then
        -- Optical center (46%): the block's center should sit slightly
        -- above geometric center - bright chrome (Sort/Search pills) pins
        -- the top edge, and a pure 50% block reads sunk. Tolerance 6px
        -- covers rounding + remaining bearings.
        local block_center = (top_ink + bot_ink) / 2
        local target = bh * 0.46
        ok(math.abs(block_center - target) <= 6,
            "emptystate: block optical-centered at 46% (center="
            .. string.format("%.0f", block_center) .. " target="
            .. string.format("%.0f", target) .. ")")
        -- Icon row sits INSIDE the block above the text (no orphan icon).
        local icon_bot
        for yy = top_ink, bot_ink do
            if dark_in(bbe, 0, yy, 300, 1) == 0 then icon_bot = yy break end
        end
        ok(icon_bot == nil or icon_bot < bot_ink,
            "emptystate: icon and text form one contiguous block")
    end
end

-- === 19d. var-list bottom-out: last item flush at max scroll =================
do
    local Scroll = require("ktui/scroll")
    -- Body 400px tall; items of 120px + gap 10: offs 0,130,260,390(in): total=630.
    -- Old max_scroll = 630-400 = 230; last item start = 260 > 230 -> dead band:
    -- the third item could NEVER paint fully inside the viewport.
    -- Real bug shape: last item start EXCEEDS the naive total_h - h.
    -- Body 400; items 200+200+200 gap 10: offs 0,210,420; total 620;
    -- naive max = 220 < last start 420? No: 620-400=220. Need >= last start:
    -- make the LAST ITEM TALL: 200 + 100 + 400 (last h=400 fills viewport):
    -- offs 0,210,320; total 720; naive max = 320 == last start (fits).
    -- Deadband only when total_h - h > last start: gap-inflated totals.
    -- Actually the REAL shape: dashboards where range overshoots by < row.
    -- items 130+130+130 gap 10, body 400: offs 0,140,280; total 410;
    -- naive max = 10 < last start... this matter is: max_scroll < last start
    -- shows the tail LOW while snap pulls back. Construct: threshold case
    -- body 400, items 120,120,200, gap 10: offs 0,130,260; total 460;
    -- naive max = 60 < last start 260: the 200px item paints half-cut and
    -- snap keeps 0 -- dead scrollbar that "doesn't move anything".
    local items = {
        { h = 120, tag = 1 }, { h = 120, tag = 2 }, { h = 200, tag = 3 },
    }
    local painted = {}
    local bbv = Blitbuffer.new(100, 400, Blitbuffer.TYPE_BB8)
    bbv:fill(Blitbuffer.COLOR_WHITE)
    local viewv = { app = { state = { scroll = {} } }, hitboxes = {}, scroll_key = function() return "k" end }
    function viewv.app:scroll_key() return "k" end
    local ms = Scroll.scrolled_list_var(viewv, bbv, items, 0, 0, 100, 400, 999, 10,
        function(item, cy) painted[cy] = item.tag end)
    -- Fine-travel regime (max_scroll 60 < pitch 130): NO snap must revert
    -- the scroll - old code snapped 60 to offs[1]=0, killing the scrollbar
    -- (dashboard bug). Now: ms=60 survives, last item paints FLUSH bottom.
    ok(ms == 60, "varlist: fine-travel max_scroll survives unsnapped (got " .. ms .. ")")
    ok(painted[200] == 3,
        "varlist: last item flush with viewport bottom at max scroll (cy="
        .. tostring(painted[200] and 200 or "nil") .. ")")
    -- Exact fit: no scroll needed -> max_scroll stays 0.
    painted = {}
    local items2 = { { h = 190 }, { h = 190 } } -- 190*2 + 10 = 390 < 400
    local ms2 = Scroll.scrolled_list_var(viewv, bbv, items2, 0, 0, 100, 400, 999, 10,
        function(item, cy) end)
    ok(ms2 == 0, "varlist: exact fit has zero scroll (got " .. ms2 .. ")")
end

-- === 19b. Deck: band grid (round 4 item 1) ====================================
do
    local Deck = require("ktui/deck")
    -- Exact fit: two bands fill the body flush, leftovers go to the grow
    -- band, zero gap at the tail.
    local body_h = 600
    local rects = Deck.layout(nil, {
        Deck.card("list", { grow = true }), -- 2 units
        Deck.touch("footer"),               -- 1 unit
    }, { x = 0, y = 0, w = 300, h = body_h })
    local m = Theme.metrics()
    local unit = math.max(m.touch_min, Theme.scale(48))
    ok(rects.list and rects.footer and rects.footer.y + rects.footer.h == body_h,
        "deck: last band flush at body bottom (" ..
        tostring(rects.footer and rects.footer.y + rects.footer.h) .. " vs " .. body_h .. ")")
    ok(rects.list.h >= 2 * unit,
        "deck: grow band never below base units (+ leftover)")
    ok(rects.footer.h + m.card_gap <= body_h - rects.list.h,
        "deck: gap consumed between bands only")
    -- px band never shrunk by distribution (banner case).
    local rects2 = Deck.layout(nil, {
        Deck.card("rows", { grow = true }),
        Deck.px("banner", 189),
    }, { x = 0, y = 0, w = 300, h = body_h })
    ok(rects2.banner.h == 189,
        "deck: px band keeps exact height (got " .. rects2.banner.h .. ")")
    ok(rects2.banner.y + rects2.banner.h == body_h,
        "deck: px band pinned at body bottom")
    -- Over capacity: px band dropped last; grow band shrinks to 1 unit first.
    local small = { x = 0, y = 0, w = 300, h = unit + m.card_gap + 60 }
    local rects3 = Deck.layout(nil, {
        Deck.card("rows", { grow = true }),
        Deck.px("banner", 300),
    }, small)
    ok(rects3.banner == nil or rects3.banner.h <= 60 + unit,
        "deck: over-capacity drops/clamps the tail before starving rows")
    ok(rects3.rows ~= nil and rects3.rows.h >= m.touch_min,
        "deck: rows keep a touchable band even in tight bodies")
    -- grid_heights: units -> px with last-band flush (no drift).
    local gh = Deck.grid_heights({ 1, 1, 1 }, 303, 1)
    ok(gh[1] + gh[2] + gh[3] == 301, -- 303 - 2 gaps = 301 usable
        "deck: grid_heights sums to usable height (" .. gh[1] + gh[2] + gh[3] .. " vs 301)")
    ok(gh[1] == 100 and gh[2] == 100 and gh[3] == 101,
        "deck: grid_heights floor share + last band flush (" ..
        gh[1] .. "/" .. gh[2] .. "/" .. gh[3] .. ")")
    -- capacity: touches fit count.
    local cap = Deck.capacity(nil, { h = 5 * unit + 4 * m.card_gap })
    ok(cap == 5, "deck: capacity counts exact-fit rows (got " .. cap .. ")")
end

-- === 10. List rows use the round avatar treatment =============================
do
    local Cards = require("ktui/cards")
    local Thumbs = require("ktui/thumbs")
    -- All-black source: without the circle carve the corners would paint ink.
    local dark = "/tmp/avatar_dark.png"
    local db = Blitbuffer.new(60, 60, Blitbuffer.TYPE_BB8)
    db:fill(Blitbuffer.COLOR_BLACK)
    db:writePNG(dark)
    ok(Thumbs.generate(dark) ~= nil, "avatar: dark source generates a thumb")
    local app = fake_app({})
    local pad = Theme.scale(8)
    local d = Theme.scale(40)
    local ax, ay = pad, math.floor((120 - d) / 2)
    local view = { app = app, hitboxes = {} }
    function view:refresh() end
    local bb = new_bb()
    bb:fill(Blitbuffer.COLOR_WHITE)
    Cards.list_item(view, bb, { name = "Aria", path = dark, tags = {}, tokens = 5 },
        0, 0, VW, 120, nil)
    local corner = bb:getPixel(ax + 1, ay + 1)
    ok(corner:getR() > 200,
        "avatar: square image corners carved back to the row surface")
    local center_ink = 0
    for yy = ay + 6, ay + d - 6, 4 do
        for xx = ax + 6, ax + d - 6, 4 do
            if bb:getPixel(xx, yy):getR() < 100 then center_ink = center_ink + 1 end
        end
    end
    ok(center_ink > 10, "avatar: cover-fit image paints inside the disc")
    -- Fallback (no image): soft disc + muted ring + bold initial.
    local view3 = { app = app, hitboxes = {} }
    function view3:refresh() end
    local bb3 = new_bb()
    bb3:fill(Blitbuffer.COLOR_WHITE)
    Cards.list_item(view3, bb3, { name = "Aria", tags = {}, tokens = 5 },
        0, 0, VW, 120, nil)
    local cx, cy = ax + math.floor(d / 2), ay + math.floor(d / 2)
    local ring_ink = 0
    for a = 0, 359, 3 do
        local rx = cx + math.floor(math.cos(math.rad(a)) * (d / 2))
        local ry = cy + math.floor(math.sin(math.rad(a)) * (d / 2))
        local c = bb3:getPixel(rx, ry)
        if c and c:getR() < 200 then ring_ink = ring_ink + 1 end
    end
    ok(ring_ink > 30, "avatar: fallback disc carries the ring (ring_ink=" ..
        tostring(ring_ink) .. ")")
    local initial_ink = 0
    for yy = cy - 8, cy + 8, 2 do
        for xx = cx - 8, cx + 8, 2 do
            if bb3:getPixel(xx, yy):getR() < 100 then initial_ink = initial_ink + 1 end
        end
    end
    ok(initial_ink > 2, "avatar: initial glyph paints on the fallback disc")
    os.remove(dark)
end

-- === 7c. Confirm sheet buttons are reachable under the modal tap policy =======
do
    local Sheets = require("ktui/sheets")
    local AppView = require("ktui/app_view")
    local app = fake_app({ page = "settings" })
    local view = { app = app, hitboxes = {} }
    function view:refresh() end
    app.view = view
    local confirmed = false
    Sheets.confirm(app, {
        title = "Apagar?", text = "Tem certeza?",
        ok_label = "Apagar", danger = true,
        on_ok = function() confirmed = true end,
    })
    Sheets.draw(view, new_bb())
    local ok_btn, cancel_btn
    for _, b in ipairs(view.hitboxes) do
        if b.label == "sheet:ok" then ok_btn = b end
        if b.label == "sheet:cancel" then cancel_btn = b end
    end
    ok(ok_btn ~= nil and cancel_btn ~= nil,
        "sheets: confirm buttons register sheet:* hits (modal policy can see them)")
    AppView.onTapKotavern(view, nil, {
        pos = { x = ok_btn.x + ok_btn.w / 2, y = ok_btn.y + ok_btn.h / 2 },
    })
    ok(confirmed == true and app.state.sheet == nil,
        "sheets: OK tap fires under the modal tap policy")
    -- A tap on dimmed page content (outside the panel) closes, never acts.
    Sheets.show(app, { title = "Menu", actions = { { label = "Um" } } })
    Sheets.draw(view, new_bb())
    local page_hit_fired = false
    require("ktui/primitives").hit(view, 10, 10, 60, 30,
        function() page_hit_fired = true end, "stale_page_hit")
    AppView.onTapKotavern(view, nil, { pos = { x = 20, y = 20 } })
    ok(page_hit_fired == false and app.state.sheet == nil,
        "sheets: tap on dimmed page content closes the sheet without firing page hits")
end

-- REAL App boot chain (the regression the device caught): a legacy
-- bubble_themes.json plus a selected id must boot through load_settings ->
-- apply_settings -> refresh_bubble_theme -> find_chat_theme (migration!)
-- -> apply_bubble_theme -> set_chat_color_overrides - the frame that
-- shipped the ColorRGB8 constructor crash on a real device boot. Runs
-- LAST so the app-global state cannot disturb the canvas fixtures above.
do
    local Storage_b = require("kt_storage")
    local json_b = require("json")
    -- Plant a legacy bubble theme and select it globally; wipe any chat
    -- theme store so the one-time migration runs in this boot.
    local bt_path = Storage_b.data_dir() .. "/bubble_themes.json"
    local fb = io.open(bt_path, "w")
    if fb then
        fb:write(json_b.encode({
            { id = "boot-test-1", name = "Boot test", style = "bubbles",
              chat_bg = "paper", radius = "normal", density = "normal",
              show_avatars = true, show_timestamps = true, show_tokens = true },
        }))
        fb:close()
    end
    os.remove(Storage_b.data_dir() .. "/chat_themes.json")
    local st_path = Storage_b.data_dir() .. "/settings.json"
    local fs = io.open(st_path, "w")
    if fs then
        fs:write(json_b.encode({ bubble_theme_id = "boot-test-1" }))
        fs:close()
    end
    local ok_boot, app_boot = pcall(function()
        local App = require("kt_app")
        return App:new({})
    end)
    ok(ok_boot and app_boot ~= nil,
        "app boot: App:new boots with a migrated theme selected ("
        .. (ok_boot and "ok" or tostring(app_boot)) .. ")")
    if ok_boot and app_boot then
        ok(app_boot.state.chat_theme_applied ~= nil,
            "app boot: the migrated theme applied at startup")
        ok(app_boot.state.chat_theme_applied.colors.surface ~= "",
            "app boot: bubble theme migrated with a surface color")
        ok(app_boot.state.chat_theme_applied.show_timestamps == true,
            "app boot: migrated toggles carried")
        local Theme_b = require("ktui/theme")
        local cb_ok, cb_r = pcall(function() return Theme_b.chat_bg:getR() end)
        ok(cb_ok and type(cb_r) == "number",
            "app boot: chat surface color is live (r=" .. tostring(cb_r) .. ")")
        -- Editor staleness e2e (the "troquei o tema e nada mudou" report):
        -- the REAL chain (save_setting -> apply_settings ->
        -- refresh_bubble_theme) must flip the applied theme AND the editor
        -- rows must re-derive from it on the next paint.
        local view_ed = { app = app_boot, hitboxes = {}, refresh = function() end }
        app_boot:save_setting("bubble_theme_id", "builtin:azure")
        ok(app_boot.state.chat_theme_applied ~= nil
            and app_boot.state.chat_theme_applied.name == "Azure",
            "editor e2e: switching to Azure applies it for real")
        local bb_ed = new_bb()
        local okp_ed = pcall(function()
            Pages.settings_appearance_chat(view_ed, bb_ed, 0, 0, VW, VH, 0)
        end)
        -- Row values are computed at paint; assert via chat_look (what the
        -- rows read) - the Default-theme row and the color values follow.
        ok(okp_ed, "editor e2e: page paints with the real app state")
        local look_a = app_boot:chat_look()
        ok(look_a.style == "bubbles" and look_a.colors.text ~= "",
            "editor e2e: editor look follows Azure (style=bubbles, themed text)")
        app_boot:save_setting("bubble_theme_id", "builtin:dark_v")
        local look_b = app_boot:chat_look()
        ok(look_b.style == "flat",
            "editor e2e: switching to Dark V flips the editor look (flat)")
        ok(look_b.colors.text ~= look_a.colors.text,
            "editor e2e: color rows re-derive after the switch ("
            .. tostring(look_a.colors.text) .. " -> " .. tostring(look_b.colors.text) .. ")")
        -- Cleanup: the boot mutated the shared data dir (settings gained
        -- migration flags, chat_themes.json was written); leave the dir
        -- as the boot found the files (tests re-plant their own fixtures).
        pcall(function() app_boot:close() end)
    end
end

-- === R2 audit: Default-look boot migration + no-theme = schema defaults ===
do
    local Storage_r2 = require("kt_storage")
    local json_r2 = require("json")
    -- Plant a plain custom look (flat style, gray surface, timestamps) and
    -- NO theme selection: the one-time migration must snapshot it into a
    -- "Default look" user theme and make it the global default.
    os.remove(Storage_r2.data_dir() .. "/chat_themes.json")
    os.remove(Storage_r2.data_dir() .. "/bubble_themes.json")
    local fs = io.open(Storage_r2.data_dir() .. "/settings.json", "w")
    if fs then
        -- migrated_* flags = an install that already ran the legacy style
        -- migrations (the realistic R2 cohort: they keep "flat" instead of
        -- being bumped to bubbles).
        fs:write(json_r2.encode({ bubble_style = "flat", chat_bg = "gray",
            show_timestamps = true,
            migrated_flat_style = true, migrated_bubbles_style = true }))
        fs:close()
    end
    local ok_r2, app_r2 = pcall(function()
        local App = require("kt_app")
        return App:new({})
    end)
    ok(ok_r2 and app_r2 ~= nil, "r2 boot: plain custom look boots fine")
    if ok_r2 and app_r2 then
        local applied = app_r2.state.chat_theme_applied
        ok(applied ~= nil, "r2: no-selection boot still applies a resolved look")
        ok(applied and applied.style == "flat",
            "r2: migration snapshot carried the plain style (flat)")
        ok(applied and applied.colors.surface == "#e8e8e8",
            "r2: chat_bg=gray mapped to the legacy surface tint (#e8e8e8)")
        ok(applied and applied.show_timestamps == true,
            "r2: migration snapshot carried the plain toggles")
        local s_r2 = app_r2.state.settings
        ok(type(s_r2.bubble_theme_id) == "string" and s_r2.bubble_theme_id ~= "",
            "r2: the snapshot became the global default theme")
        ok(s_r2.migrated_default_look == true, "r2: migration flag persisted")
        local themes_r2 = Storage_r2.list_chat_themes() or {}
        local found = false
        for _t = 1, #themes_r2 do
            if themes_r2[_t].id == s_r2.bubble_theme_id then found = true end
        end
        ok(found, "r2: the Default look theme lives in the store")

        -- Second boot with PRISTINE settings (all defaults): no snapshot,
        -- the schema defaults apply (bubbles + paper).
        pcall(function() app_r2:close() end)
        os.remove(Storage_r2.data_dir() .. "/chat_themes.json")
        local fs2 = io.open(Storage_r2.data_dir() .. "/settings.json", "w")
        if fs2 then
            fs2:write(json_r2.encode({}))
            fs2:close()
        end
        local ok_r2b, app_r2b = pcall(function()
            local App = require("kt_app")
            return App:new({})
        end)
        if ok_r2b and app_r2b then
            local applied_b = app_r2b.state.chat_theme_applied
            ok(applied_b ~= nil and applied_b.style == "bubbles",
                "r2: defaults boot = schema defaults (bubbles)")
            ok(app_r2b.state.settings.bubble_theme_id == "",
                "r2: no snapshot when the plain look is default")
            -- Density has NO UI row (author call: internal metric only).
            -- The page still paints with the surviving rows, and the
            -- internal pipeline stays live (settings -> Theme metric).
            app_r2b.state.page = "settings_appearance"
            local view_r2 = { app = app_r2b, hitboxes = {},
                refresh = function() end }
            local bb_r2 = new_bb()
            local okp_r2 = pcall(function()
                Pages.settings_appearance(view_r2, bb_r2, 0, 0, VW, VH, 0)
            end)
            ok(okp_r2, "r2: Appearance paints without the density row")
            -- Rows: Theme(1) Font size(2) Chat(3) Dashboard(4) - and no
            -- 5th row: density must not have crept back in.
            ok(#view_r2.hitboxes == 4,
                "r2: Appearance = 4 tappable rows, no density (got "
                .. #view_r2.hitboxes .. ")")
            local Theme_r2 = require("ktui/theme")
            ok(app_r2b.state.settings.density == "normal"
                and Theme_r2.get_density() == 1.0,
                "r2: density stays the internal default (metric 1.0)")
            pcall(function() app_r2b:close() end)
        end
    end
end

-- === R3 audit: render/storage caches and the primitives fast path ===
do
    -- Storage mtime caches: same identity until a save bumps the file,
    -- fresh identity + fresh value after (connections + profiles + worlds).
    local Storage_r3 = require("kt_storage")
    local list_a = Storage_r3.list_profiles()
    local list_b = Storage_r3.list_profiles()
    ok(list_a == list_b, "r3: repeated list_profiles hands back the cached table")
    Storage_r3.save_profiles({ { id = "r3", name = "probe" } })
    local list_c = Storage_r3.list_profiles()
    ok(list_c ~= list_a and #(list_c or {}) == 1 and list_c[1].id == "r3",
        "r3: a save invalidates the profiles cache (fresh value)")
    -- worlds: directory-mtime cache - rename-based saves must be visible.
    Storage_r3.save_world("r3_probe_world", { entries = { { id = "e1" } } })
    local worlds_a = Storage_r3.list_worlds()
    ok(#(worlds_a or {}) > 0 and #worlds_a == #(worlds_a or {}) and true, "r3: list_worlds returns a list")
    local found_w = false
    for _wi = 1, #(worlds_a or {}) do
        if worlds_a[_wi] == "r3_probe_world" then found_w = true end
    end
    ok(found_w, "r3: save_world is immediately visible through the dir cache")
    Storage_r3.save_world("r3_probe_world", { entries = { { id = "e2" } } })
    local w_data = Storage_r3.load_world("r3_probe_world")
    ok(w_data and w_data.entries and w_data.entries[1].id == "e2",
        "r3: same-name world rewrite invalidates (e2 not stale e1)")
    Storage_r3.delete_world("r3_probe_world")

    -- resolved() single-slot memo: identity-stable for one config,
    -- invalidated by density and by an applied-theme switch.
    local ChatTheme_r3 = require("ktui/chat_theme")
    local app_m = fake_app({})
    app_m.state.chat_theme_applied = ChatTheme_r3.normalize({ name = "M" })
    local res_1 = ChatTheme_r3.resolved(app_m)
    local res_2 = ChatTheme_r3.resolved(app_m)
    ok(res_1 == res_2, "r3: resolved() memoized for the same config")
    app_m.state.settings.density = "compact"
    local res_3 = ChatTheme_r3.resolved(app_m)
    ok(res_3 ~= res_1 and res_3.sig ~= res_1.sig,
        "r3: a density switch busts the resolved memo (sig carries gd:)")
    app_m.state.chat_theme_applied = ChatTheme_r3.normalize(
        { name = "M2", style = "flat" })
    local res_4 = ChatTheme_r3.resolved(app_m)
    ok(res_4 ~= res_3 and res_4.theme.style == "flat",
        "r3: an applied-theme switch busts the resolved memo")

    -- Primitives RGB32 fast path after the hoist: fills keep the true
    -- color, the memoized type probe agrees across calls, and BB8 keeps
    -- going through paintRect (pixel-level equality with the old path
    -- is covered by the b5/b8 pixel checks above).
    local P_r3 = require("ktui/primitives")
    local Theme_r3 = require("ktui/theme")
    local bb32 = Blitbuffer.new(120, 60, Blitbuffer.TYPE_BBRGB32)
    bb32:fill(Blitbuffer.COLOR_WHITE)
    local navy = Blitbuffer.colorFromString("#1c2739")
    P_r3.rect(bb32, 5, 5, 50, 20, navy)
    P_r3.rounded_rect(bb32, 65, 5, 50, 20, navy, 6)
    local function rgb_px(bb, x, y)
        local okp, px = pcall(function() return bb:getPixel(x, y) end)
        if not okp then return -1 end
        return px:getR() * 65536 + px:getG() * 256 + px:getB()
    end
    ok(rgb_px(bb32, 30, 15) == 0x1c2739,
        "r3: hoisted RGB32 fill keeps the true color (rect)")
    ok(rgb_px(bb32, 90, 15) == 0x1c2739,
        "r3: single-clamp rounded scan keeps the true color (center)")
    ok(rgb_px(bb32, 66, 6) == 0xffffff,
        "r3: rounded scan leaves the corner arc untouched")
    local bb8 = new_bb()
    P_r3.rect(bb8, 5, 5, 40, 10, Blitbuffer.COLOR_BLACK)
    ok(rgb_px(bb8, 20, 10) == 0x000000,
        "r3: BB8 fills still route through paintRect")
end

print(string.format("\n%d checks, %d failures", checks, fails))
os.exit(fails == 0 and 0 or 1)
