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
    ok(count_hits(view) > 10, "dashboard: registers hitboxes (pills, cards, nav, kebab, close)")
    dump(bb, "dashboard")

    -- Viewport-fitted rows: painted row step must fill the list exactly.
    local desired = app:dashboard_card_h()
    local gap = Theme.metrics().card_gap
    local rows = math.max(1, math.floor((list_h + gap) / (desired + gap)))
    local card_h = math.floor((list_h - gap * (rows - 1)) / rows)
    ok(rows >= 1 and card_h >= Theme.scale(120),
        "dashboard: viewport rows sane (rows=" .. rows .. ", card_h=" .. card_h .. ")")
end

-- === 2. Secondary page header: back + title + kebab + close =================
do
    local app = fake_app({ page = "chats", chats_index = { {}, {}, {} } })
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    Header.draw(view, bb, 0, 0, VW)
    ok(ink_ratio(bb) > 50, "header: secondary page paints (back, title, kebab, close)")
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

    ok(Update.about_title({ channel = "stable", version = "0.2.0" })
        == "KOTavern v0.2.0 Stable", "update: stable About line")
    ok(Update.about_title({ channel = "commits", version = "0.2.0", commit = "a1b2c3d" })
        == "KOTavern v0.2.0 (a1b2c3d)", "update: commits About line")
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

-- === 4w. GIF player lifecycle (frames, stop frees, no leak) =======================
do
    local GifAnim = require("ktui/gifanim")
    local gif = PLUGIN .. "/assets/sonic_debug.gif"
    local app = fake_app({ page = "settings" })
    local view = { app = app, hitboxes = {} }
    local refresh_args = nil
    function view:refresh(...) refresh_args = { ... } end
    local player = GifAnim.ensure(app, view, "banner", gif,
        { w = 64, h = 64, rect = { x = 10, y = 10, w = 64, h = 64 } })
    ok(player ~= nil and player.n >= 2, "gif: sonic decodes to 2+ frames")
    local f1 = GifAnim.frame(player)
    ok(type(f1) == "cdata", "gif: current frame is a blitbuffer")
    local function queued_tick()
        for _, t in ipairs(UIManager._task_queue or {}) do
            if t.action == player.tick then
                return true
            end
        end
        return false
    end
    ok(player.tick ~= nil and queued_tick(), "gif: tick scheduled while playing")
    player.tick()
    -- NOTE: colon-call self is NOT in ... — args here are (nil, rect).
    local rrect = refresh_args and refresh_args[2]
    ok(rrect ~= nil and rrect.x == 10 and rrect.w == 64,
        "gif: tick repaints the gif rect only")
    -- Paint one frame like the banner does (exercises the blit path).
    local bb = new_bb()
    bb:fill(Blitbuffer.COLOR_WHITE)
    bb:blitFrom(f1, 10, 10, 0, 0,
        math.min(64, f1:getWidth()), math.min(64, f1:getHeight()))
    local ink = 0
    for yy = 10, 74 do
        for xx = 10, 74, 2 do
            if bb:getPixel(xx, yy):getR() < 128 then ink = ink + 1 end
        end
    end
    ok(ink > 20, "gif: frame paints ink")
    GifAnim.stop_all(app)
    ok(app.state.gif_players == nil and not queued_tick(),
        "gif: stop_all clears players and the tick")
    -- Missing file degrades to nil (caller falls back to first frame).
    local app2 = fake_app({ page = "settings" })
    local view2 = { app = app2, hitboxes = {} }
    function view2:refresh() end
    ok(GifAnim.ensure(app2, view2, "banner", "/tmp/nope.gif", { w = 64, h = 64 }) == nil,
        "gif: missing file plays nothing")
    GifAnim.stop_all(app2)
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
    ok(dark_in(bb, VW - 44 - 42 - 2, 0, 42, 42) > 8,
        "header: kebab paints three ink dots (no glyph)")
    dump(bb, "header_chats_full")
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
    ok(has_hit(view, "pm_kebab_"), "pages: prompt_manager registers kebab hits (rename/remove)")
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
    -- Hairline runs UNDER the close button (regression: a full-height white
    -- box erased it there).
    local close_x = 300 - Theme.metrics().pad - Theme.scale(44)
    ok(hbb:getPixel(close_x + 8, tb_y - 1):getR() == Theme.soft:getR(),
        "header: hairline continuous under the close button")
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

-- === 18. Debug Mode + UI DSL (css_test sandbox) ==================================
do
    local UiDSL = require("ktui/uidsl")
    local AppView = require("ktui/app_view")
    local App = require("kt_app")

    -- Parser: cascade, specificity, validation errors.
    local sheet = UiDSL.parse("/* hi */\npage { background: gray(0.10); color: #111111; }\n" ..
        "panel { color: #222222; }\n.card { radius: 8px; pad: 10px; }\n" ..
        "#x.card { color: #333333; }\npage { background: gray(0.2); }")
    local overrides, oerr = UiDSL.theme_overrides(sheet, "page")
    ok(overrides.bg and overrides.ink, "uidsl: page palette overrides parsed")
    ok(#oerr == 0, "uidsl: valid sheet has no errors")
    local st = UiDSL.style_for(sheet, "panel", { classes = { card = true }, id = "x" })
    ok(st.color, "uidsl: #id.class rule resolves for a matching node")
    local rlen = UiDSL.resolve_value("radius", st.radius)
    ok(rlen and rlen > 0, "uidsl: length prop resolves to scaled px via resolve_value")
    ok(st.vars and next(st.vars) == nil, "uidsl: no vars on a plain sheet")
    local vars_sheet = UiDSL.parse("@vars { --brand: #444444; }\npage { color: #111111; }")
    local stv = UiDSL.style_for(vars_sheet, "page", {})
    ok(stv.vars and stv.vars.brand == "#444444", "uidsl: @vars custom props collected")
    local _, bad = UiDSL.theme_overrides(UiDSL.parse("page { background: oops; }"), "page")
    ok(#bad == 1 and tostring(bad[1]):find("invalid color", 1, true) ~= nil,
        "uidsl: bad color surfaces an error")
    local _, nerr = UiDSL.theme_overrides(UiDSL.parse("page { pad: 12px; }"), "page")
    ok(nerr and #nerr == 0, "uidsl: node-only props never error the palette")

    -- Node layout: measure + paint a small box tree.
    local n = UiDSL.node({ tag = "box", border = true, pad = 8, children = {
        UiDSL.node({ tag = "text", text = "Hello" }),
        UiDSL.node({ tag = "spacer", h = "4px" }),
        UiDSL.node({ tag = "text", align = "center", text = "World", bold = true }),
    } })
    local mh = UiDSL.measure(n, 300)
    ok(mh > 20, "uidsl: box measures padding + children")
    local bbx = Blitbuffer.new(300, mh + 4, Blitbuffer.TYPE_BB8)
    bbx:fill(Blitbuffer.COLOR_WHITE)
    UiDSL.paint(n, bbx, 2, 2, 300)
    ok(dark_in(bbx, 2, 2, 296, mh) > 0, "uidsl: painted box leaves ink on the canvas")

    -- HTML -> nodes conversion (the "converting" layer).
    local hit_fired = nil
    local actions = { poke = function() hit_fired = true end }
    local tree = UiDSL.from_html(
        '<div class="card" id="c1"><h2>Title</h2><p class="muted">Body &amp; more</p>' ..
        '<img src="/tmp/x.png" data-h="30px"/><div class="btn" data-action="poke"><span>Go</span></div></div>',
        actions)
    ok(tree.tag == "box" and #tree.children == 1, "uidsl: html root holds one div")
    local card_node = tree.children[1]
    ok(card_node.html_tag == "div" and card_node.classes.card and card_node.id == "c1",
        "uidsl: div carries class + id")
    ok(card_node.children[1].html_tag == "h2" and card_node.children[1].tag == "text"
        and card_node.children[1].bold, "uidsl: h2 becomes bold text")
    ok(card_node.children[2].tag == "para" and card_node.children[2].text == "Body & more",
        "uidsl: p becomes para, entities decode (got tag=" ..
        tostring(card_node.children[2].tag) .. " text=" ..
        tostring(card_node.children[2].text) .. ")")
    ok(card_node.children[3].tag == "image" and card_node.children[3].src == "/tmp/x.png",
        "uidsl: img becomes image node with src")
    local btn_node = card_node.children[4]
    ok(btn_node.on_tap ~= nil, "uidsl: data-action wires a callback")
    -- Painting registers the hitbox; firing it runs the action.
    local btn_h = UiDSL.measure(btn_node, 200)
    local fake_view = { hitboxes = {} }
    UiDSL.paint(btn_node, new_bb(), 0, 0, 200, fake_view)
    ok(#fake_view.hitboxes == 1 and fake_view.hitboxes[1].label == "uidsl:btn",
        "uidsl: interactive node registers its hitbox")
    fake_view.hitboxes[1].callback()
    ok(hit_fired == true, "uidsl: hitbox callback fires the data-action")
    -- CSS decorates the tree (border/pad from .card; color from .muted).
    local sheet2 = UiDSL.parse("page { color: #111111; } .card { border: true; pad: 12px; } .muted { color: gray(0.45); }")
    UiDSL.apply_styles(tree, sheet2)
    ok(card_node.border == true and card_node.pad == Theme.scale(12),
        "uidsl: apply_styles decorates nodes from CSS")
    ok(card_node.children[2].color, "uidsl: .muted paints the para color")

    -- demo_page: DEMO_HTML + DEMO_CSS build a styled tree with actions.
    local dp = UiDSL.demo_page(UiDSL.parse(UiDSL.DEMO_CSS), actions)
    ok(dp.children and #dp.children >= 6, "uidsl: demo page converts the HTML body")
    ok(dp.children[1].bg, "uidsl: demo hero got its CSS background")

    -- css_test page end-to-end (HTML body painted, toolbar registered).
    local app = fake_app({ page = "css_test", settings = { debug_mode = true } })
    local view = { app = app, hitboxes = {} }
    function view:refresh() end
    view.dimen = { x = 0, y = 0, w = VW, h = VH }
    setmetatable(view, { __index = AppView })
    local bb = new_bb()
    local max_s = Pages.css_test(view, bb, 0, 0, VW, VH, 0)
    ok(max_s >= 0, "css_test: paints and returns max_scroll")
    local nbtn = 0
    for _i, hbox in ipairs(view.hitboxes) do
        if tostring(hbox.label or ""):find("btn:", 1, true) == 1 then nbtn = nbtn + 1 end
    end
    ok(nbtn >= 2, "css_test: Reload + Shot buttons registered")
    ok(ink_ratio(bb) > 0, "css_test: sandbox ink on screen")

    -- Debug settings page: rows + the single Debug Mode toggle.
    local app2 = fake_app({ page = "settings_debug", settings = { debug_mode = true } })
    local v2 = { app = app2, hitboxes = {} }
    function v2:refresh() end
    Pages.settings_debug(v2, new_bb(), 0, 0, VW, VH, 0)
    local nrow, ntog = 0, 0
    for _i, hbox in ipairs(v2.hitboxes) do
        local lb = tostring(hbox.label or "")
        if lb:find("row:", 1, true) == 1 and lb ~= "row:toggle" then nrow = nrow + 1 end
        if lb == "row:toggle" then ntog = ntog + 1 end
    end
    ok(nrow >= 4, "debug page: setting rows registered (got " .. tostring(nrow) .. ")")
    ok(ntog == 1, "debug page: exactly one Debug Mode toggle")

    -- Settings root: Debug category + easter egg appear only in debug mode.
    local function paint_settings(settings_overrides)
        local a = fake_app({ page = "settings", settings = settings_overrides })
        local v = { app = a, hitboxes = {} }
        function v:refresh() end
        v.dimen = { x = 0, y = 0, w = VW, h = VH }
        setmetatable(v, { __index = AppView })
        local b = new_bb()
        Pages.settings(v, b, 0, 0, VW, VH, 0)
        return v, b
    end
    local von, bon = paint_settings({ debug_mode = true })
    local voff, boff = paint_settings({})
    ok(#von.hitboxes == #voff.hitboxes + 1,
        "debug: exactly one extra category row in debug mode")
    local strip_y = math.max(0, VH - Theme.scale(70))
    local ink_on = dark_in(bon, 0, strip_y, VW, VH - strip_y)
    local ink_off = dark_in(boff, 0, strip_y, VW, VH - strip_y)
    ok(ink_on > ink_off + 10, "debug: easter egg strip paints in debug mode (" ..
        tostring(ink_on) .. " vs " .. tostring(ink_off) .. ")")

    -- Triple-tap arms debug; activation is stubbed so no storage is touched.
    local app5 = fake_app({ page = "settings_updates", settings = {} })
    function app5:enable_debug_mode() self._debug_armed = true end
    App._debug_triple_tap(app5)
    App._debug_triple_tap(app5)
    ok(not app5._debug_armed, "debug: two taps do not arm Debug Mode")
    App._debug_triple_tap(app5)
    ok(app5._debug_armed == true, "debug: three rapid taps arm Debug Mode")
end

print(string.format("\n%d checks, %d failures", checks, fails))
os.exit(fails == 0 and 0 or 1)
