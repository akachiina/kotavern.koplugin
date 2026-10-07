-- Title bar and contextual toolbar rendering for AppView.
-- ZenPM-parity chrome: per-page titles with live counts (filtered pages show
-- "n/total"), a drawn 3-dot actions kebab opening a native anchored
-- ButtonDialog (KOReader widget, hangs below the dots), a 46px back chevron
-- on detail pages, and - on every list page - a contextual toolbar of solid
-- black pills (Sort/Search/page actions) drawn in the header, so page bodies
-- are all content. List pages with more pills than fit the row fall back to
-- icon-only pills (same measure, no labels).
-- The header also records view.koreader_menu_zone (the title bar) so AppView
-- can pass taps/swipes through to KOReader's own menu.

local P = require("ktui/primitives")
local Theme = require("ktui/theme")
local Icons = require("ktui/icons")
local Widgets = require("ktui/widgets")
local Constants = require("kt_constants")
local _ = require("gettext")

local Header = {}

-- Pill geometry (ZenPM header metrics): 42px-high pills, icon slot 24, gaps 6.
local PILL_H = 42
local PILL_ICON = 24
local PILL_GAP = 6
-- Toolbar = pill row + breathing room (matches the old pill_toolbar_h()).
local TOOLBAR_TOTAL = 58

local function toolbar_h()
    return Theme.btn_h() + Theme.scale(16)
end

-- Total header height for the current page (AppView sizes its content with
-- this; keep it in sync with Header.draw).
function Header.height(view)
    local m = Theme.metrics()
    if view and view.app and Header.toolbar_spec(view) then
        return m.titlebar_h + toolbar_h()
    end
    return m.titlebar_h
end

-- ---------------------------------------------------------------------------
-- Page titles (with live counts; filtered pages show "n/total")
-- ---------------------------------------------------------------------------

local function page_title(view)
    local state = view.app.state
    local page = state.page
    local Storage = require("kt_storage")
    if page == "dashboard" then
        return _("%s %s %s"):format(_("Welcome"), _("to"), _("KOTavern"))
    elseif page == "css_test" then
        return _("CSS Test")
    elseif page == "chats" then
        local visible = view.app:chats_visible()
        local total = tostring(#(state.chats_index or {}))
        if (state.chats_query or "") ~= "" then
            return _("Chats") .. " (" .. tostring(#visible) .. "/" .. total .. ")"
        end
        return _("Chats") .. " (" .. total .. ")"
    elseif page == "connections" then
        return _("API Connections") .. " (" .. tostring(#(Storage.list_connections() or {})) .. ")"
    elseif page == "personas" then
        local data = Storage.list_personas()
        return _("Personas") .. " (" .. tostring(#(data and data.list or {})) .. ")"
    elseif page == "presets" then
        return _("Presets") .. " (" .. tostring(#(Storage.list_presets() or {})) .. ")"
    elseif page == "lorebooks" then
        local ok, worlds = pcall(Storage.list_worlds)
        return _("Lorebooks") .. " (" .. tostring(ok and #worlds or 0) .. ")"
    elseif page == "preset_editor" then
        return _("Edit Preset")
    elseif page == "prompt_manager" then
        return _("Prompt Manager")
    elseif page == "regex_scripts" then
        return _("Regex Scripts") .. " (" .. tostring(#(state.settings.regex_scripts or {})) .. ")"
    elseif page == "settings" or page:sub(1, 9) == "settings_" then
        local names = {
            settings = _("Settings"),
            settings_appearance = _("Appearance"),
            settings_dashboard = _("Dashboard"),
            settings_behavior = _("Behavior"),
            settings_network = _("Network"),
            settings_language = _("Language"),
            settings_data = _("Data"),
            settings_debug = _("Debug"),
            css_test = _("CSS Test"),
        }
        return names[page] or _("Settings")
    elseif page == "character_editor" then
        return _("Edit Character")
    elseif page == "character_view" then
        return (state.viewing_character and state.viewing_character.name) or _("Character")
    elseif page == "character_greetings" then
        return _("Alternate Greetings")
    elseif page == "lorebook_editor" then
        return (state.editing_world and state.editing_world.name) or _("Lorebook")
    elseif page == "lorebook_entry" then
        return _("Edit Entry")
    elseif page == "chat" then
        return state.current_character or _("Chat")
    elseif page == "chat_history" then
        return _("Past Chats") .. " (" .. tostring(#(state.past_chats or {})) .. ")"
    end
    return _("KOTavern")
end

-- ---------------------------------------------------------------------------
-- Global actions kebab (3 drawn dots -> native anchored menu)
-- ---------------------------------------------------------------------------

local function show_global_actions(view, anchor_box)
    local Modals = require("ktui/modals")
    local Geom = require("ui/geometry")
    local app = view.app
    Modals.actions(_("KOTavern"), {
        { text = _("Import character"), icon = "plus", callback = function()
            app:show_import()
        end },
        { text = _("Import chat"), icon = "upload", callback = function()
            app:show_import_chat()
        end },
        { text = _("New persona"), icon = "user", callback = function()
            app:edit_persona(nil)
        end },
        { text = _("New preset"), icon = "sliders", callback = function()
            app:edit_preset(nil)
        end },
        { text = _("New connection"), icon = "plug", callback = function()
            app:edit_connection(nil)
        end },
        { text = _("Check for updates"), icon = "download", callback = function()
            app:check_updates_now()
        end },
        { text = _("About / version"), icon = "info-circle", callback = function()
            local Update = require("kt_update")
            local build = Update.installed_build(
                app.state and app.state.settings and app.state.settings.installed_build)
            Modals.info(Update.about_title(build)
                .. "\nSillyTavern-compatible AI chat for KOReader."
                .. "\n" .. _("Developed by akachiina · GitHub"))
        end },
        { text = _("Quit"), icon = "times", callback = function()
            view:onClose()
        end },
    }, {
        align = "left",
        anchor = Geom:new{ x = anchor_box.x, y = anchor_box.y, w = anchor_box.w, h = anchor_box.h },
        anchor_right = true,
        compact = true,
        compact_min_width = 220,
        show_cancel = false,
        title_icon = Constants.PLUGIN_DIR .. "/assets/logo.svg",
    })
end

-- Three ink dots, ZenPM-style: no glyph, no asset - plain circles on a 42px
-- invisible hit square (dot 6, first row vertically centered in a 24 band).
local function draw_kebab(view, bb, x, y, s)
    local dot = Theme.scale(6)
    local cx = x + math.floor((s - dot) / 2)
    local first_y = y + math.floor((s - Theme.scale(24)) / 2)
    for i = 0, 2 do
        P.box(bb, cx, first_y + i * Theme.scale(9), dot, dot, {
            border = false,
            background = Theme.ink,
            radius = math.floor(dot / 2),
        })
    end
    P.hit(view, x, y, s, s, function()
        show_global_actions(view, { x = x, y = y, w = s, h = s })
    end, "header_kebab")
    return s
end

-- ---------------------------------------------------------------------------
-- Pills (solid black, measured contents; ZenPM header metrics)
-- ---------------------------------------------------------------------------

-- One pill: icon slot + label, both measured. width = 10 + icon + 6 + text + 14.
local function pill_width(label, icon)
    local w = Theme.scale(10) + Theme.scale(14)
    local text_w = 0
    if label and label ~= "" then
        text_w = P.text_size(label, Theme.scale(256), "small", { bold = true }).w
        w = w + text_w + (icon and Theme.scale(PILL_GAP) or 0)
    end
    if icon then
        w = w + Theme.scale(PILL_ICON)
    end
    return w
end

-- opts: x, y, icon, label, enabled (default true), on_tap, hit_id
-- Returns the drawn width.
local function draw_pill(view, bb, o)
    local h = Theme.btn_h()
    local w = o.w or pill_width(o.label, o.icon)
    local enabled = o.enabled ~= false
    P.box(bb, o.x, o.y, w, h, {
        border = not enabled,
        border_size = 1,
        border_color = Theme.soft,
        background = enabled and Theme.ink or Theme.bg,
        radius = math.floor(h / 2),
    })
    local color = enabled and Theme.button_text or Theme.muted
    local cx = o.x + Theme.scale(10)
    if o.icon then
        -- The solid pill is Theme.ink (black on light, WHITE on inverted):
        -- invert the SVG so its strokes read as button_text on the pill.
        -- Disabled pills sit on the page background: no invert, muted glyph.
        -- NOTE: build the opts table explicitly - `enabled and nil or muted`
        -- ALWAYS yields muted (Lua and/or trap) and dimmed the icon box into
        -- a gray square on the black pill.
        local icon_opts
        if enabled then
            icon_opts = { invert = (Theme.get_theme() ~= "inverted") }
        else
            icon_opts = { color = Theme.muted }
        end
        Icons.center(bb, o.icon, cx, o.y, Theme.scale(PILL_ICON), h, Theme.scale(12), icon_opts)
        cx = cx + Theme.scale(PILL_ICON) + (o.label and o.label ~= "" and Theme.scale(PILL_GAP) or 0)
    end
    if o.label and o.label ~= "" then
        P.vcenter_text(bb, o.label, cx, o.y, w - (cx - o.x) - Theme.scale(14), h, "small",
            { bold = true, color = color })
    end
    if enabled then
        P.hit(view, o.x, o.y, w, h, o.on_tap, o.hit_id or "pill:" .. tostring(o.label or o.icon))
    end
    return w
end

-- ---------------------------------------------------------------------------
-- Contextual toolbar spec (which pills each list page gets)
-- ---------------------------------------------------------------------------

-- Returns { left = {...}, right = {...} } or nil. Right pills are drawn
-- right-to-left (last entry = rightmost, matching ZenPM's page-action slot).
function Header.toolbar_spec(view)
    local app = view.app
    local state = app.state
    local page = state.page

    if page == "dashboard" then
        return {
            left = {
                { icon = "sort", label = _("Sort"), on_tap = function() app:show_dashboard_sort() end },
                { icon = "filter", label = _("Filter"), on_tap = function() app:show_dashboard_filter() end },
                { icon = (state.settings.dashboard_view == "list") and "list" or "grid",
                  label = _("View"), on_tap = function() app:toggle_dashboard_view() end },
            },
            right = {
                { icon = "search", label = _("Search"), on_tap = function() app:show_dashboard_search() end },
                { label = "+ " .. _("Import"), on_tap = function() app:show_import() end },
            },
        }
    elseif page == "chats" then
        return {
            left = {
                { icon = "sort", label = _("Sort"), on_tap = function() app:show_chats_sort() end },
            },
            right = {
                { icon = "search", label = _("Search"), on_tap = function() app:show_chats_search() end },
            },
        }
    elseif page == "connections" then
        return {
            right = {
                { label = "+ " .. _("New Connection"), on_tap = function() app:edit_connection(nil) end },
            },
        }
    elseif page == "personas" then
        return {
            right = {
                { label = "+ " .. _("New Persona"), on_tap = function() app:edit_persona(nil) end },
            },
        }
    elseif page == "presets" then
        return {
            right = {
                { label = _("Import"), on_tap = function() app:import_preset() end },
                { label = "+ " .. _("New Preset"), on_tap = function() app:edit_preset(nil) end },
            },
        }
    elseif page == "lorebooks" then
        return {
            right = {
                { label = _("Import"), on_tap = function() app:import_lorebook() end },
                { label = "+ " .. _("New Lorebook"), on_tap = function() app:new_lorebook() end },
            },
        }
    elseif page == "regex_scripts" then
        return {
            right = {
                { label = "+ " .. _("New Script"), on_tap = function() app:new_regex_script() end },
            },
        }
    end
    return nil
end

-- Left pills then right pills; when they would collide, every pill falls back
-- to icon-only (labels dropped, same hit targets) - narrow screens keep all
-- actions reachable.
local function draw_toolbar(view, bb, x, y, w)
    local spec = Header.toolbar_spec(view)
    if not spec then
        return 0
    end
    local m = Theme.metrics()
    local gap = Theme.scale(PILL_GAP)
    local left, right = spec.left or {}, spec.right or {}

    local function widths(pills, labeled)
        local total = gap * math.max(0, #pills - 1)
        for i, b in ipairs(pills) do
            if labeled then
                total = total + pill_width(b.label, b.icon)
            else
                total = total + (b.icon and Theme.scale(PILL_ICON) + Theme.scale(20) or Theme.scale(34))
            end
        end
        return total
    end

    local labeled = widths(left, true) + widths(right, true) + gap <= w

    -- ZenPM centers the controls in the toolbar band (toolbar_y), never
    -- top-sticks them: pill row is vertically balanced with equal margins.
    local py = y + math.floor((toolbar_h() - Theme.btn_h()) / 2)
    local cx = x + m.pad
    for _, b in ipairs(left) do
        -- NOTE: `labeled and nil or X` would ALWAYS yield X (Lua and/or trap);
        -- build the opts explicitly.
        local opts = { x = cx, y = py, icon = b.icon, on_tap = b.on_tap }
        if labeled then
            opts.label = b.label
        else
            opts.w = Theme.scale(PILL_ICON) + Theme.scale(20)
        end
        cx = cx + draw_pill(view, bb, opts) + gap
    end
    -- Right cluster: right-to-left so the LAST spec entry is rightmost.
    local rx = x + w - m.pad
    for i = #right, 1, -1 do
        local b = right[i]
        local bw = labeled and pill_width(b.label, b.icon) or Theme.scale(PILL_ICON) + Theme.scale(20)
        rx = rx - bw
        draw_pill(view, bb, {
            x = rx, y = py, icon = b.icon,
            label = labeled and b.label or nil,
            w = bw,
            on_tap = b.on_tap,
        })
        rx = rx - gap
    end
    return toolbar_h()
end

-- ---------------------------------------------------------------------------
-- Title bar + header entry point
-- ---------------------------------------------------------------------------

function Header.draw(view, bb, x, y, w)
    local m = Theme.metrics()
    local h = m.titlebar_h
    local pad = m.pad
    local state = view.app.state
    local page = state.page

    -- Background
    P.box(bb, x, y, w, h, { border = false, background = Theme.panel })
    P.rect(bb, x, y + h - Theme.scale(1), w, Theme.scale(1), Theme.soft)

    -- Right side: kebab dots + close. Registered after the title swallow below
    -- so they win their own zones (hitboxes are checked in reverse order).
    local kebab_s = Theme.scale(42)
    local close_w = Theme.scale(44)
    local close_x = x + w - pad - close_w
    local kebab_x = close_x - kebab_s - Theme.scale(2)

    -- Brand/title. The swallow hit covers ONLY the text zone: taps on the bare
    -- title area must still reach AppView's KOReader-menu passthrough.
    local title_x = x + pad
    if page == "dashboard" then
        local logo_s = Theme.scale(34)
        local ly = y + math.floor((h - logo_s) / 2)
        if not P.image(bb, Constants.PLUGIN_DIR .. "/assets/logo.svg", x + pad, ly, logo_s, logo_s, { is_icon = true }) then
            P.center_text_box(bb, "K", x + pad, ly, logo_s, logo_s, "title", { bold = true })
        end
        title_x = x + pad + logo_s + Theme.scale(14)
        P.vcenter_text(bb, page_title(view), title_x, y, math.max(0, kebab_x - Theme.scale(6) - title_x), h, "title", { bold = true })
    else
        -- ZenPM back: dedicated 46px square, CENTERED in the titlebar band
        -- (not full-height), with a chevron SVG. No background box: the
        -- titlebar is already uniform, and a box here bleeds past edges.
        local back_s = Theme.scale(46)
        local by = y + math.floor((h - back_s) / 2)
        Icons.center(bb, "chev-left", x + pad, by, back_s, back_s, Theme.scale(16), { color = Theme.ink })
        P.hit(view, x + pad, by, back_s, back_s, function() view.app:go_back() end, "back")
        title_x = x + pad + back_s + Theme.scale(6)
        local title_text = Widgets.sanitize(page_title(view))
        if title_text == "" then title_text = _("Untitled") end
        P.vcenter_text(bb, title_text, title_x, y, math.max(0, kebab_x - Theme.scale(6) - title_x), h, "heading", { bold = true })
    end

    -- Title-zone swallow (see comment above).
    if kebab_x - Theme.scale(6) > title_x then
        P.hit(view, title_x, y, kebab_x - Theme.scale(6) - title_x, h, function() end, "header_title")
    end

    -- Kebab (3 drawn dots) + close. No background boxes: a full-height box
    -- under the close button ERASED the hairline (the white notch the user
    -- reported); icons sit directly on the uniform titlebar.
    draw_kebab(view, bb, kebab_x, y + math.floor((h - kebab_s) / 2), kebab_s)

    Icons.center(bb, "times", close_x, y, close_w, h, Theme.scale(15), { color = Theme.ink })
    P.hit(view, close_x, y, w - close_x, h, function()
        view:onClose()
    end, "close")

    -- KOReader menu passthrough zone: the whole title bar.
    view.koreader_menu_zone = { x = x, y = y, w = w, h = h }

    -- Contextual pill toolbar under the title bar (list pages only).
    local bar_h = draw_toolbar(view, bb, x, y + h, w)
    if bar_h > 0 then
        return y + h + toolbar_h()
    end
    return y + h
end

return Header
