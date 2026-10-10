-- Per-page content renderers for AppView.
-- Pattern: ZenPM canvas-based rendering. All rows/buttons/bars come from
-- ui/widgets.lua so every page shares the same visual language.

local P = require("ktui/primitives")
local Theme = require("ktui/theme")
local Scroll = require("ktui/scroll")
local Cards = require("ktui/cards")
local Icons = require("ktui/icons")
local Geom = require("ktui/geom")
local Widgets = require("ktui/widgets")
local Sheets = require("ktui/sheets")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Blitbuffer = require("ffi/blitbuffer")
local Util = require("kotaven_util")
local Constants = require("kt_constants")
local _ = require("gettext")

local Pages = {}

-- === Error page ===
-- ZenPM-style: message at the top, two solid ink pills pinned to the bottom
-- (Retry / Quit). No dead ends: the user can always leave the plugin.
function Pages.error(view, bb, x, y, w, h, message)
    P.rect(bb, x, y, w, h, Theme.bg)
    local m = Theme.metrics()
    local pad = m.pad
    local pill_h = Theme.btn_h()
    local gap = Theme.scale(10)
    local pill_w = math.floor((w - pad * 2 - gap) / 2)
    local pill_y = y + h - pill_h - Theme.scale(18)

    P.paragraph(bb, message or _("Error"), x + pad, y + Theme.scale(16),
        w - pad * 2, math.max(pill_y - y - Theme.scale(24), Theme.line_h("default")),
        "default", { color = Theme.muted })

    local function draw_pill(px, label, on_tap)
        P.box(bb, px, pill_y, pill_w, pill_h, {
            border = false, background = Theme.ink, radius = math.floor(pill_h / 2),
        })
        P.center_text_box(bb, label, px, pill_y, pill_w, pill_h, "small",
            { bold = true, color = Theme.button_text })
        P.hit(view, px, pill_y, pill_w, pill_h, on_tap, "error:" .. tostring(label))
    end
    draw_pill(x + pad, _("Retry"), function()
        view.app.state.error = nil
        view:refresh(true)
    end)
    draw_pill(x + pad + pill_w + gap, _("Quit"), function()
        view:onClose()
    end)
    Scroll.set_list_bounds(view, x, y, w, h, h)
end

-- === Dashboard ===
-- (The Search/Sort/Filter/View/Import toolbar moved into the header as
-- contextual pills - see ui/header.lua. The page body is now all content.)

-- Deck-fitted TEXT rows (round 4): natural content height, stretch to close
-- the viewport exactly but at a SOFTER cap (1.25×, down from 1.6×) - the
-- 1.6× balloon was the "rows look bloated on tall screens" complaint.
-- Touch floor preserved. Delegates to ktui/deck for the fitted math.
local function fit_row_h(list_h, natural_h, gap)
    gap = gap or Theme.metrics().card_gap -- some callers pass no gap
    local rows = math.max(1, math.floor((list_h + gap) / (natural_h + gap)))
    local fitted = math.floor((list_h - gap * (rows - 1)) / rows)
    local Deck = require("ktui/deck")
    return math.max(natural_h,
        math.min(math.floor(natural_h * Deck.ROW_STRETCH_CAP + 0.5), fitted))
end

function Pages.dashboard(view, bb, x, y, w, h, scroll)
    P.rect(bb, x, y, w, h, Theme.bg)

    local app = view.app
    local m = Theme.metrics()
    local pad = m.pad
    local card_gap = m.card_gap
    local gutter = Theme.scrollbar_w()
    local cols = app:dashboard_columns() or 3
    local card_w = math.floor((w - pad * 2 - (cols - 1) * card_gap - gutter) / cols)
    local desired_card_h = app:dashboard_card_h()
    -- Rich 3-line row: name + tags + meta. Grows with the measured lines so
    -- nothing ever overflows at any DPI/font size.
    local list_row_h = math.max(Theme.scale(84),
        Theme.line_h("small") + Theme.line_h("chip") + Theme.line_h("tiny") + Theme.scale(8))

    local items = app:dashboard_items()
    local view_mode = app.state.settings.dashboard_view == "list" and "list" or "grid"
    local query_active = (app.state.dashboard_query or "") ~= ""
    local filter_active = (app.state.dashboard_filter or "all") ~= "all"

    -- Content starts right under the header (the toolbar lives there now).
    local list_top = y + Theme.scale(6)

    -- Item count line when filtering/searching (measured height)
    if query_active or filter_active then
        P.text(bb, tostring(#items) .. " " .. _("characters"), x + pad, list_top + Theme.scale(2), w - pad * 2, "tiny", { color = Theme.muted })
        list_top = list_top + Theme.line_h("tiny") + Theme.scale(8)
    end

    if #items == 0 then
        local remaining = h - (list_top - y)
        if query_active or filter_active then
            Widgets.empty_state(view, bb, {
                x = x, y = list_top, w = w, h = math.max(remaining, Theme.scale(200)),
                icon = "search",
                text = _("No characters match."),
                action = { label = _("Clear"), on_tap = function()
                    app:set_dashboard_query("")
                    app:set_dashboard_filter("all")
                end },
            })
        else
            Widgets.empty_state(view, bb, {
                x = x, y = list_top, w = w, h = math.max(remaining, Theme.scale(200)),
                icon = "user",
                text = _("No characters yet. Import a character card to start."),
                action = { label = _("Import"), icon = "plus", on_tap = function()
                    app:show_import()
                end },
            })
        end
        Scroll.set_list_bounds(view, x, list_top, w, h - (list_top - y), h - (list_top - y))
        return 0
    end

    local list_h = h - (list_top - y)
    -- Fixed card heights (ST-style): the desired height from Settings →
    -- Dashboard, CAPPED at what fills exactly 2 rows - so 6 cards always fit
    -- with zero scroll. The row count still comes from the content and the
    -- overflow SCROLLS at the same height. (Cap depends only on the
    -- viewport, never on the count: sizes stay identical across 6/7/8+.)
    local card_h = Geom.cap_two_rows(list_h, card_gap, desired_card_h,
        math.floor(card_w * 0.9))
    if os.getenv("KT_DEBUG_GRID") then
        print("DBG grid: rows=" .. math.max(1, math.ceil(#items / cols))
            .. " card_h=" .. card_h
            .. " list_h=" .. list_h .. " desired=" .. desired_card_h
            .. " card_w=" .. card_w)
    end
    -- NOTE: scrolled_list takes the ITEM height (it adds the gap itself):
    -- grid rows pass card_h, list rows list_row_h. Passing step (h + gap)
    -- double-counts the gap and inflates max_scroll by N*gaps.
    local max_scroll
    if view_mode == "grid" then
        -- scrolled_list advances cy per item, so group cards into rows: each
        -- drawn row contains up to `cols` cards side by side.
        local rows = {}
        for i = 1, #items, cols do
            local row = {}
            for c = 0, cols - 1 do
                row[c + 1] = items[i + c]
            end
            table.insert(rows, row)
        end
        max_scroll = Scroll.scrolled_list(view, bb, rows, x, list_top, w, list_h, scroll, card_h, card_gap, function(row, cy, scrollable)
            for c = 0, cols - 1 do
                local card = row[c + 1]
                if card then
                    local cx = x + pad + c * (card_w + card_gap)
                    Cards.character(view, bb, card, cx, cy, card_w, card_h)
                end
            end
        end)
    else
        max_scroll = Scroll.scrolled_list(view, bb, items, x, list_top, w, list_h, scroll, list_row_h, card_gap, function(item, cy, scrollable)
            local row_gutter = scrollable and gutter or 0
            Cards.list_item(view, bb, item, x + pad, cy, w - pad * 2 - row_gutter, list_row_h)
        end)
    end

    return max_scroll
end

-- === Settings ===
-- Generic settings page: rows (with compact section headers, toggles, values
-- and chevrons) in a variable-height scrolled list.
function Pages.settings_section(view, bb, x, y, w, h, scroll, rows)
    local m = Theme.metrics()
    local pad = m.pad
    local gap = m.card_gap
    local small_lh = Theme.line_h("small")
    local header_h = small_lh + Theme.scale(12)
    local row_h = math.max(m.touch_min, small_lh + Theme.scale(14))
    local gutter = Theme.scrollbar_w()

    -- Expand the row spec into variable-height items. Deck rule (round 4,
    -- item 1): when the WHOLE list fits in the viewport, rows absorb the
    -- leftover evenly (settings rows breathe; sections keep their size +
    -- breathing share) - when it doesn't, measured heights keep scrolling.
    local items = {}
    local n_sections, n_rows = 0, 0
    for _, row in ipairs(rows) do
        if row.section then
            n_sections = n_sections + 1
            table.insert(items, { h = header_h, section = true, text = row.text })
        else
            n_rows = n_rows + 1
            table.insert(items, {
                h = row.subtext
                    and math.max(row_h, Theme.line_h("small") * 2 + Theme.scale(14))
                    or row_h,
                icon = row.icon,
                title = row.text,
                subtitle = row.subtext,
                value_fn = row.value,
                toggle = row.toggle,
                callback = row.callback,
                enabled = row.enabled,
            })
        end
    end
    local list_y = y + Theme.scale(4)
    local list_h = h - Theme.scale(8)
    -- Deck grow (round 4, item 1) WITH A CEILING: rows may grow to at most
    -- 1.35x their natural height (comfortable tap targets, not the
    -- comically tall panels the unbounded grow painted when a page has few
    -- rows - Language with ONE row became a full-screen button). The
    -- remaining leftover stays as breathing room AFTER the last row
    -- (e-ink friendly, matches ZenPM's fixed-row look).
    local declared = 0
    for _, it in ipairs(items) do declared = declared + it.h end
    local grow_extra = list_h - (declared + (#items - 1) * gap)
    if grow_extra > 0 and n_rows > 0 then
        local per_item = math.floor(grow_extra / #items)
        for _, it in ipairs(items) do
            if not it.section then
                -- Cap: at most 1.35x natural height per row (tap targets,
                -- not full-screen buttons). Unused leftover becomes tail
                -- breathing room (nothing paints there; no stretched panel).
                local max_add = math.floor(it.h * 0.35 + 0.5)
                it.h = it.h + math.min(per_item, max_add)
            end
        end
    end
    return Scroll.scrolled_list_var(view, bb, items, x, list_y, w, list_h, scroll, gap, function(item, item_y, scrollable)
        local row_x = x + pad
        local row_w = w - pad * 2 - (scrollable and gutter or 0)

        if item.section then
            Widgets.section_header(view, bb, row_x, item_y, row_w, item.text)
            return
        end

        local raw = item.value_fn and item.value_fn() or nil
        -- Boolean values drive the toggle only; passing them through would
        -- paint tostring(true)/tostring(false) in the value text slot
        -- (W.row paints any truthy non-"" value). Normalize to nil here
        -- (W.row also guards with a type check as a second line of defense).
        local value = (type(raw) == "boolean") and nil or raw
        local toggled = raw == true
        Widgets.row(view, bb, {
            x = row_x, y = item_y, w = row_w, h = item.h,
            icon = item.icon,
            title = item.title,
            subtitle = item.subtitle,
            value = value,
            chevron = not item.toggle and value == nil,
            toggle = item.toggle,
            toggle_value = item.toggle and toggled,
            on_toggle = item.callback,
            on_tap = item.callback,
            enabled = item.enabled,
        })
    end)
end

-- Settings main menu: categories that open submenus (SillyTavern-style).
function Pages.settings(view, bb, x, y, w, h, scroll)
    local app = view.app
    local Storage = require("kt_storage")
    local rows = {
        {
            text = _("Personas"), icon = "user",
            value = function()
                local data = Storage.list_personas()
                local active_id = data.active
                local count = #(data.list or {})
                for _, p in ipairs(data.list or {}) do
                    if p.id == active_id then
                        return (p.name or "?") .. " (" .. tostring(count) .. ")"
                    end
                end
                return count == 0 and _("None") or tostring(count)
            end,
            callback = function()
                app:navigate("personas")
            end,
        },
        { text = _("Appearance"), icon = "magic", callback = function() app:navigate("settings_appearance") end },
        { text = _("Behavior"), icon = "wrench", callback = function() app:navigate("settings_behavior") end },
        { text = _("Network"), icon = "bolt", callback = function() app:navigate("settings_network") end },
        { text = _("Language"), icon = "comments", callback = function() app:navigate("settings_language") end },
        { text = _("Presets"), icon = "sliders", callback = function() app:navigate("presets") end },
        { text = _("Data"), icon = "folder", callback = function() app:navigate("settings_data") end },
        { text = _("Updates"), icon = "download", callback = function() app:navigate("settings_updates") end },
    }
    -- Debug Mode category: only exists while the mode is armed (triple-tap
    -- "Installed" on Updates). Holds the experimental/dangerous options.
    if app.state.settings.debug_mode then
        rows[#rows + 1] = {
            text = _("Debug"), icon = "wrench",
            callback = function() app:navigate("settings_debug") end,
        }
    end

    -- Easter egg (debug builds): animated memento pinned under the
    -- settings categories. Its band is an ABSOLUTE px band so the list
    -- never slides beneath the GIF (kept from the round-2 fix).
    local band_h = 0
    local banner = nil
    if app.state.settings.debug_mode then
        local m0 = Theme.metrics()
        local pad0 = m0.pad
        local img_s0 = Theme.scale(150)
        local gap0 = Theme.scale(12)
        local tiny_lh0 = Theme.line_h("tiny")
        local t1 = _("You are in Debug Mode!")
        local t2 = _("Debug Mode active - experimental features enabled.")
        local note_w0 = math.max(8, w - pad0 * 2 - img_s0 - gap0)
        local fit1 = Widgets.fit_text(t1, note_w0, "tiny", { bold = true })
        local sub_lines = math.max(1, P.paragraph_line_count(t2, note_w0, "tiny"))
        local text_h0 = tiny_lh0 + Theme.scale(3) + sub_lines * tiny_lh0
        local block_h = math.max(img_s0, text_h0)
        band_h = block_h + pad0 * 2
        banner = { img_s = img_s0, gap = gap0, tiny_lh = tiny_lh0,
            fit1 = fit1, sub_lines = sub_lines, t2 = t2,
            note_w = note_w0, text_h = text_h0, block_h = block_h }
    end

    -- Deck bands (round 4, item 1): the page DECLARES bands, the deck
    -- distributes pixels. List band grows (leftover space goes to rows,
    -- never to a stray gap); the GIF banner (when armed) is an absolute
    -- px band at the bottom.
    local Deck = require("ktui/deck")
    local band_defs = {
        Deck.card("rows", { grow = true, max = h }),
    }
    if banner then band_defs[#band_defs + 1] = Deck.px("banner", band_h) end
    local rects = Deck.layout(view, band_defs, { x = x, y = y, w = w, h = h })

    -- Rows: same painter as before, but fed by the deck's rect.
    local rrows = rects.rows
    local max_scroll = Pages.settings_section(view, bb, x, rrows.y, w,
        rrows.h, scroll, rows)

    if banner then
        local GifAnim = require("ktui/gifanim")
        local m = Theme.metrics()
        local pad = m.pad
        local img_s = banner.img_s
        local gap = banner.gap
        local tiny_lh = banner.tiny_lh
        local col_w = banner.note_w
        local block_w = img_s + gap + col_w
        local block_h = banner.block_h
        -- The deck pinned this band at the bottom of the body (rects.banner).
        local band_y = rects.banner.y
        local bx = x + math.max(pad, math.floor((w - block_w) / 2))
        local by = band_y + pad
        -- Pre-composited full frames (tools/gen_debug_banner.py): the raw
        -- GIF's delta sub-rects cannot play through KOReader's giflib (only
        -- frame 0 shows the body, the rest render as white boxes).
        local gif_dir = Constants.PLUGIN_DIR .. "/assets/debug_banner"
        local player = GifAnim.ensure(app, view, "debug_banner", gif_dir,
            { w = img_s, h = img_s, rect = { x = bx, y = by, w = img_s, h = img_s } })
        -- The GIF paints through the shared frame painter (bg clear kills
        -- the trail the raw blit used to leave between frames) and marks the
        -- view for a dithered refresh - bitmaps under a no-dither waveform
        -- are the classic gray-ghosting source.
        if not (player and GifAnim.draw(player, bb, bx, by, img_s, img_s)) then
            P.image(bb, gif_dir .. "/frame_1.png", bx, by, img_s, img_s, { cover = true })
        end
        view.dithered = true
        local text_h = banner.text_h
        local ty = by + math.floor((block_h - text_h) / 2)
        P.text(bb, banner.fit1, bx + img_s + gap, ty, col_w + 2, "tiny", { bold = true })
        P.paragraph(bb, banner.t2, bx + img_s + gap, ty + tiny_lh + Theme.scale(3), col_w,
            banner.sub_lines * tiny_lh, "tiny", { color = Theme.muted })
    end
    return max_scroll
end

-- Settings > Appearance: theme/font/density/chat-style/appearance toggles.
function Pages.settings_appearance(view, bb, x, y, w, h, scroll)
    local app = view.app
    local density_labels = {
        compact = _("Compact"),
        normal = _("Normal"),
        spacious = _("Spacious"),
    }
    local bubble_labels = {
        bubbles = _("Bubbles (ST)"),
        st = _("SillyTavern"),
        flat = _("Flat"),
        rounded = _("Rounded"),
        square = _("Square"),
        none = _("None"),
    }
    local rows = {
        {
            text = _("Theme"),
            value = function()
                return app.state.settings.theme == "inverted" and _("Inverted") or _("Light")
            end,
            callback = function()
                app:choose_setting("theme", _("Theme"), {
                    { label = _("Light"), value = "light" },
                    { label = _("Inverted"), value = "inverted" },
                })
            end,
        },
        {
            text = _("Font size"),
            value = function() return tostring(app.state.settings.base_font_size) end,
            callback = function() app:prompt_base_font_size() end,
        },
        {
            text = _("Density"),
            value = function() return density_labels[app.state.settings.density] or app.state.settings.density end,
            callback = function()
                app:choose_setting("density", _("Density"), {
                    { label = _("Compact"), value = "compact" },
                    { label = _("Normal"), value = "normal" },
                    { label = _("Spacious"), value = "spacious" },
                })
            end,
        },
        {
            text = _("Chat style"),
            value = function() return bubble_labels[app.state.settings.bubble_style] or app.state.settings.bubble_style end,
            callback = function()
                app:choose_setting("bubble_style", _("Chat style"), {
                    { label = _("Bubbles (ST)"), value = "bubbles" },
                    { label = _("Flat"), value = "flat" },
                })
            end,
        },
        {
            text = _("Chat background"),
            value = function()
                local labels = { ["paper"] = _("Paper"), ["gray"] = _("Light gray"), ["none"] = _("None") }
                return labels[app.state.settings.chat_bg] or app.state.settings.chat_bg
            end,
            callback = function()
                app:choose_setting("chat_bg", _("Chat background"), {
                    { label = _("Paper"), value = "paper" },
                    { label = _("Light gray"), value = "gray" },
                    { label = _("None"), value = "none" },
                })
            end,
        },
        {
            text = _("Inline images"),
            toggle = true,
            value = function() return app.state.settings.show_inline_images end,
            callback = function() app:toggle_setting("show_inline_images") end,
        },
        {
            text = _("Show avatars"),
            toggle = true,
            value = function() return app.state.settings.show_avatars end,
            callback = function() app:toggle_setting("show_avatars") end,
        },
        {
            text = _("Avatar size"),
            value = function()
                local labels = { ["small"] = _("Small"), ["normal"] = _("Normal"), ["large"] = _("Large") }
                return labels[app.state.settings.avatar_size] or app.state.settings.avatar_size
            end,
            callback = function()
                app:choose_setting("avatar_size", _("Avatar size"), {
                    { label = _("Small"), value = "small" },
                    { label = _("Normal"), value = "normal" },
                    { label = _("Large"), value = "large" },
                })
            end,
        },
        {
            text = _("Outline user bubbles"),
            toggle = true,
            value = function() return app.state.settings.outline_user_bubbles end,
            callback = function() app:toggle_setting("outline_user_bubbles") end,
        },
        {
            text = _("Show timestamps"),
            toggle = true,
            value = function() return app.state.settings.show_timestamps end,
            callback = function() app:toggle_setting("show_timestamps") end,
        },
        {
            text = _("Show token counts"),
            toggle = true,
            value = function() return app.state.settings.show_tokens end,
            callback = function() app:toggle_setting("show_tokens") end,
        },
        { text = _("Dashboard"), callback = function() app:navigate("settings_dashboard") end },
    }
    return Pages.settings_section(view, bb, x, y, w, h, scroll, rows)
end

-- Dashboard customization: grid layout, card height, what to show on the
-- cards and the caption band style.
function Pages.settings_dashboard(view, bb, x, y, w, h, scroll)
    local app = view.app
    local height_labels = {
        short = _("Short"),
        normal = _("Normal"),
        tall = _("Tall"),
    }
    local view_labels = {
        grid = _("Grid"),
        list = _("List"),
    }
    local caption_labels = {
        soft = _("Semi-transparent"),
        solid = _("Solid"),
        none = _("None"),
    }
    local star_labels = {
        always = _("Always visible"),
        fav = _("Only when favorite"),
        none = _("Hidden"),
    }
    local rows = {
        { text = _("Grid"), section = true },
        {
            text = _("Columns"),
            value = function()
                return tostring(app:dashboard_columns())
            end,
            callback = function()
                app:choose_setting("dashboard_columns", _("Columns"), {
                    { label = "2", value = 2 },
                    { label = "3", value = 3 },
                    { label = "4", value = 4 },
                })
            end,
        },
        {
            text = _("Card height"),
            value = function()
                return height_labels[app.state.settings.dashboard_card_h] or app.state.settings.dashboard_card_h
            end,
            callback = function()
                app:choose_setting("dashboard_card_h", _("Card height"), {
                    { label = _("Short"), value = "short" },
                    { label = _("Normal"), value = "normal" },
                    { label = _("Tall"), value = "tall" },
                })
            end,
        },
        {
            text = _("Default view"),
            value = function()
                return view_labels[app.state.settings.dashboard_view] or app.state.settings.dashboard_view
            end,
            callback = function()
                app:choose_setting("dashboard_view", _("Default view"), {
                    { label = _("Grid"), value = "grid" },
                    { label = _("List"), value = "list" },
                })
            end,
        },
        { text = _("Show on cards"), section = true },
        {
            text = _("Covers"),
            toggle = true,
            value = function() return app.state.settings.show_covers end,
            callback = function() app:toggle_setting("show_covers") end,
        },
        {
            text = _("Name"),
            toggle = true,
            value = function() return app.state.settings.dashboard_show_name end,
            callback = function() app:toggle_setting("dashboard_show_name") end,
        },
        {
            text = _("Tags"),
            toggle = true,
            value = function() return app.state.settings.dashboard_show_tags end,
            callback = function() app:toggle_setting("dashboard_show_tags") end,
        },
        {
            text = _("Tokens & creator"),
            toggle = true,
            value = function() return app.state.settings.dashboard_show_meta end,
            callback = function() app:toggle_setting("dashboard_show_meta") end,
        },
        {
            text = _("Favorite star"),
            value = function()
                local mode = app.state.settings.dashboard_star
                    or (app.state.settings.dashboard_show_star == false and "none" or "always")
                return star_labels[mode] or mode
            end,
            callback = function()
                app:choose_setting("dashboard_star", _("Favorite star"), {
                    { label = _("Always visible"), value = "always" },
                    { label = _("Only when favorite"), value = "fav" },
                    { label = _("Hidden"), value = "none" },
                })
            end,
        },
        { text = _("Caption band"), section = true },
        {
            text = _("Style"),
            value = function()
                return caption_labels[app.state.settings.dashboard_caption] or app.state.settings.dashboard_caption
            end,
            callback = function()
                app:choose_setting("dashboard_caption", _("Caption band"), {
                    { label = _("Semi-transparent"), value = "soft" },
                    { label = _("Solid"), value = "solid" },
                    { label = _("None"), value = "none" },
                })
            end,
        },
        { text = _("Restore defaults"), callback = function() app:reset_dashboard_settings() end },
    }
    return Pages.settings_section(view, bb, x, y, w, h, scroll, rows)
end

function Pages.settings_behavior(view, bb, x, y, w, h, scroll)
    local app = view.app
    local rows = {
        {
            text = _("Streaming"),
            toggle = true,
            value = function() return app.state.settings.streaming end,
            callback = function() app:toggle_setting("streaming") end,
        },
        {
            text = _("Stream update interval"),
            value = function()
                return tostring(math.floor((tonumber(app.state.settings.stream_chunk_interval) or 0.3) * 1000)) .. " ms"
            end,
            callback = function() app:prompt_chunk_interval() end,
        },
        {
            text = _("Stream refresh"),
            subtext = _("How often the screen repaints while streaming"),
            value = function()
                return app:stream_refresh_label()
            end,
            callback = function() app:choose_stream_refresh() end,
        },
        {
            text = _("Trim incomplete sentences"),
            toggle = true,
            value = function() return app.state.settings.trim_sentences end,
            callback = function() app:toggle_setting("trim_sentences") end,
        },
        {
            text = _("Auto-continue"),
            subtext = _("Chain a Continue when the reply hits the token limit"),
            toggle = true,
            value = function() return app.state.settings.auto_continue == true end,
            callback = function() app:toggle_setting("auto_continue") end,
        },
        {
            text = _("Auto-continue target"),
            value = function()
                local n = tonumber(app.state.settings.auto_continue_length) or 200
                return n == 0 and _("Always (no limit)") or tostring(n) .. " tok"
            end,
            callback = function() app:prompt_auto_continue_length() end,
        },
        {
            text = _("Reasoning auto-parse"),
            subtext = _("Strip think tags into the collapsible reasoning block"),
            toggle = true,
            value = function() return app.state.settings.reasoning_auto_parse ~= false end,
            callback = function() app:toggle_setting("reasoning_auto_parse") end,
        },
        {
            text = _("Reasoning prefix"),
            value = function()
                return tostring(app.state.settings.reasoning_prefix or "<think>")
            end,
            callback = function()
                app:prompt_setting("reasoning_prefix", _("Reasoning prefix"), "<think>")
            end,
        },
        {
            text = _("Reasoning suffix"),
            value = function()
                return tostring(app.state.settings.reasoning_suffix or "</think>")
            end,
            callback = function()
                app:prompt_setting("reasoning_suffix", _("Reasoning suffix"), "</think>")
            end,
        },
        {
            text = _("Collapse newlines"),
            toggle = true,
            value = function() return app.state.settings.collapse_newlines end,
            callback = function() app:toggle_setting("collapse_newlines") end,
        },
        {
            text = _("Regex scripts"),
            value = function()
                local n = #(app.state.settings.regex_scripts or {})
                return n == 0 and _("None") or tostring(n)
            end,
            callback = function() app:navigate("regex_scripts") end,
        },
        {
            text = _("Send when empty"),
            subtext = _("Placeholder sent if you submit an empty message (ST send_if_empty)"),
            value = function()
                local v = app.state.settings.send_if_empty
                return (type(v) == "string" and v ~= "") and v or _("Off")
            end,
            callback = function()
                app:prompt_send_if_empty()
            end,
        },
    }
    return Pages.settings_section(view, bb, x, y, w, h, scroll, rows)
end

function Pages.settings_network(view, bb, x, y, w, h, scroll)
    local app = view.app
    local backend_labels = {
        curl_bg = _("Background (curl)"),
        curl_sync = _("Sync curl"),
        http_sync = _("Sync socket"),
    }
    local rows = {
        {
            text = _("Request backend"),
            value = function()
                return backend_labels[app.state.settings.api_backend] or app.state.settings.api_backend
            end,
            callback = function()
                app:choose_setting("api_backend", _("Request backend"), {
                    { label = _("Background (curl)"), value = "curl_bg" },
                    { label = _("Sync curl"), value = "curl_sync" },
                    { label = _("Sync socket"), value = "http_sync" },
                })
            end,
        },
        {
            text = _("Request timeout"),
            value = function()
                local t = tonumber(app.state.settings.api_timeout) or 30
                return tostring(t) .. "s"
            end,
            callback = function()
                app:choose_setting("api_timeout", _("Request timeout"), {
                    { label = "15s", value = 15 },
                    { label = "30s", value = 30 },
                    { label = "60s", value = 60 },
                    { label = "120s", value = 120 },
                })
            end,
        },
        {
            text = _("Stream idle timeout"),
            value = function()
                local t = tonumber(app.state.settings.stream_timeout) or 120
                return tostring(t) .. "s"
            end,
            callback = function()
                app:choose_setting("stream_timeout", _("Stream idle timeout"), {
                    { label = "60s", value = 60 },
                    { label = "120s", value = 120 },
                    { label = "240s", value = 240 },
                    { label = "600s", value = 600 },
                })
            end,
        },
        {
            text = _("Retries (429/5xx)"),
            value = function()
                local r = tonumber(app.state.settings.api_retries)
                if r == nil then r = 1 end
                return tostring(r)
            end,
            callback = function()
                app:choose_setting("api_retries", _("Retries (429/5xx)"), {
                    { label = _("Off"), value = 0 },
                    { label = "1", value = 1 },
                    { label = "2", value = 2 },
                    { label = "3", value = 3 },
                })
            end,
        },
    }
    return Pages.settings_section(view, bb, x, y, w, h, scroll, rows)
end

function Pages.settings_language(view, bb, x, y, w, h, scroll)
    local app = view.app
    local rows = {
        {
            text = _("Language"),
            value = function()
                local lang = app:active_lang() or "en"
                local labels = {
                    ["pt_BR"] = _("Portuguese (Brazil)"),
                    ["pt"] = _("Portuguese (Brazil)"),
                    ["es"] = _("Spanish"),
                    ["en"] = _("English"),
                }
                local prefix = lang:match("^([a-zA-Z]+)")
                return labels[lang] or labels[prefix] or lang
            end,
            callback = function()
                app:choose_language()
            end,
        },
    }
    return Pages.settings_section(view, bb, x, y, w, h, scroll, rows)
end

function Pages.settings_data(view, bb, x, y, w, h, scroll)
    local app = view.app
    local Storage = require("kt_storage")
    local rows = {
        { text = _("Import Character Card"), icon = "download", callback = function() app:show_import() end },
        { text = _("Import Chat"), icon = "download", callback = function() app:show_import_chat() end },
        { text = _("Lorebooks"), icon = "book", callback = function() app:show_lorebooks() end },
        { text = _("Quick Replies"), icon = "bolt",
            value = function()
                local n = #(app.state.settings.quick_replies or {})
                return n == 0 and _("None") or tostring(n)
            end,
            callback = function() app:manage_quick_replies() end },
        { text = _("Storage usage"), icon = "save",
            value = function()
                local info = app:get_storage_info()
                return Storage.format_bytes(info.total)
            end,
            callback = function() app:navigate("data_storage") end },
    }
    return Pages.settings_section(view, bb, x, y, w, h, scroll, rows)
end

-- Storage usage: per-category bars (bytes + share + file count) plus
-- backup export/import and data-folder actions.
function Pages.data_storage(view, bb, x, y, w, h, scroll)
    local app = view.app
    local Storage = require("kt_storage")
    local m = Theme.metrics()
    local pad = m.pad
    local info = app:get_storage_info()
    local total = math.max(info.total or 0, 1)
    local ls = Theme.line_h("small")
    local lt = Theme.line_h("tiny")
    local bar_h = ls + lt + Theme.scale(8) + Theme.scale(14)
    local action_h = math.max(m.touch_min, ls + lt + Theme.scale(14))
    local gap = Theme.scale(6)

    -- Deck band heights (round 4, item 1): when the WHOLE page fits in
    -- the viewport, the 4 action rows absorb the leftover space evenly
    -- (rows breathe - the "Refresh cut by nav / scroll that doesn't move"
    -- shape dies here). When it doesn't fit, measured heights preserve the
    -- scroll behavior unchanged.
    local items = {
        { kind = "total", h = ls + lt + Theme.scale(14) },
    }
    for _, c in ipairs(info.cats or {}) do
        items[#items + 1] = { kind = "bar", cat = c, h = bar_h }
    end
    local n_actions = 4
    items[#items + 1] = { kind = "action", title = _("Export backup"), icon = "download",
        h = action_h, cb = function() app:export_backup() end }
    items[#items + 1] = { kind = "action", title = _("Import backup"), icon = "upload",
        h = action_h, cb = function() app:import_backup() end }
    items[#items + 1] = { kind = "action", title = _("Data folder"), icon = "folder",
        value = info.root, h = action_h, cb = function() app:move_data_root() end }
    items[#items + 1] = { kind = "action", title = _("Refresh"), icon = "refresh",
        h = action_h, cb = function() app:refresh_storage() end }
    local stats_h = items[1].h + #info.cats * bar_h
    local total_fit = stats_h + n_actions * action_h + (#items - 1) * gap
    local grow_extra = h - total_fit
    if grow_extra > 0 then
        local per_action = math.floor(grow_extra / n_actions)
        for i = #items - 3, #items do
            items[i].h = action_h + per_action
        end
    end

    local gutter = Theme.scrollbar_w()
    return Scroll.scrolled_list_var(view, bb, items, x, y, w, h, scroll, gap,
        function(item, cy, scrollable)
        local row_w = w - pad * 2 - (scrollable and gutter or 0)
        local rx = x + pad
        if item.kind == "total" then
            P.text(bb, Storage.format_bytes(info.total), rx, cy, row_w, "small", { bold = true })
            P.text(bb, Widgets.truncate(info.root or "", 80), rx, cy + ls + Theme.scale(2),
                row_w, "tiny", { color = Theme.muted })
        elseif item.kind == "bar" then
            local c = item.cat
            local share = math.max(0, math.min(1, (c.bytes or 0) / total))
            P.text(bb, _(c.msgid), rx, cy, row_w, "small", { bold = true })
            local bstr = Storage.format_bytes(c.bytes or 0)
            local bsz = P.text_size(bstr, row_w, "tiny")
            -- Baseline-align: title paints a small face, value a tiny one;
            -- both at cy put the tiny baseline noticeably ABOVE the bold
            -- baseline ("2 B" floated high vs "Presets" - the visible
            -- misalignment on the Data page). Tiny text baseline =
            -- baseline(small) shift + (ls - lt).
            P.text(bb, bstr, rx + row_w - math.min(bsz.w, row_w),
                cy + ls - lt, row_w, "tiny", { color = Theme.muted })
            local by = cy + ls + Theme.scale(4)
            local bw = row_w
            P.rect(bb, rx, by, bw, Theme.scale(8), Theme.soft)
            local fill = math.floor(bw * share)
            if fill > 0 then
                P.rect(bb, rx, by, fill, Theme.scale(8), Theme.ink)
            end
            local sub = tostring(math.floor(share * 100 + 0.5)) .. "% · "
                .. tostring(c.count or 0) .. " " .. _("files")
            P.text(bb, sub, rx, by + Theme.scale(8) + Theme.scale(2), row_w, "tiny",
                { color = Theme.muted })
        else
            Widgets.row(view, bb, {
                x = rx, y = cy, w = row_w, h = item.h,
                title = item.title,
                subtitle = item.value and Widgets.truncate(item.value, 60) or nil,
                chevron = true,
                on_tap = item.cb,
            })
        end
    end)
end

-- === Debug Mode ===
-- Experimental options + the CSS sandbox. Only reachable with debug_mode.
-- Debug category, both sandboxes: UI DSL (css_test) + KtHTML (html_test),
-- each with install/reset, plus pagination mode and the Debug Mode master
-- switch. Older native_test stays in code with no row: frozen, not deleted.
function Pages.settings_debug(view, bb, x, y, w, h, scroll)
    local app = view.app
    local rows = {
        { section = true, text = _("Experimental") },
        { text = _("Test CSS"), icon = "magic",
          subtext = _("Sandbox page painted by the UI DSL engine"),
          callback = function() app:navigate("css_test") end },
        { text = _("Install sandbox.html"), icon = "file",
          subtext = _("Write the demo screen into themes/pages/ (tap again to reset)"),
          value = function()
              if require("ktui/uidsl").sandbox_exists() then
                  return _("Installed")
              end
              return nil
          end,
          callback = function() app:install_sandbox_file() end },
        { text = _("Test HTML"), icon = "eye",
          subtext = _("Sandbox page painted by MuPDF from HTML"),
          callback = function() app:navigate("html_test") end },
        { text = _("Install html_sandbox.html"), icon = "file",
          subtext = _("Write the demo page into themes/pages/ (tap again to reset)"),
          value = function()
              if require("ktui/kthtml").page_exists("html_sandbox.html") then
                  return _("Installed")
              end
              return nil
          end,
          callback = function() app:install_html_sandbox_file() end },
        { text = _("HTML pagination"), icon = "sort", toggle = true,
          subtext = _("Page-turn scroll for the HTML sandbox"),
          value = function() return app.state.settings.html_pagination == true end,
          callback = function() app:toggle_setting("html_pagination") end },
        { section = true, text = _("Danger zone") },
        { text = _("Debug Mode"), icon = "wrench", toggle = true,
          subtext = _("Turning it off hides this category and the CSS overlay."),
          value = function() return app.state.settings.debug_mode == true end,
          callback = function() app:toggle_debug_mode() end },
    }
    return Pages.settings_section(view, bb, x, y, w, h, scroll, rows)
end

-- CSS sandbox: a page painted entirely by the UI DSL node engine. The body
-- is the USER file themes/pages/sandbox.html (HTML + optional <style>)
-- converted to nodes and decorated by theme sheet + inline style (the
-- "conversion" layer - the canvas UI stays the only renderer). Reload
-- re-applies settings (mtime cache busts file + CSS); Shot dumps a viewport
-- PNG. Errors (missing file, bad values, unknown props/actions) surface on
-- the page itself - there is no silent fallback.
function Pages.css_test(view, bb, x, y, w, h, scroll)
    local app = view.app
    local UiDSL = require("ktui/uidsl")
    local max_scroll = 0

    -- Reload/Shot toolbar under the header. Painted AFTER the list (see
    -- below): the list allows partially-visible head items for smooth
    -- scrolling and UiDSL.paint has no clip rect, so a head item painted at
    -- cy < list_y would otherwise bleed over the buttons and a full refresh
    -- (e.g. Shot) would push that bleed to the screen. The opaque strip
    -- plus last-painted order matches the header/nav chrome convention.
    local btn_h = Theme.btn_h()
    local m = Theme.metrics()
    local pad = m.pad
    local list_y = y + btn_h + Theme.scale(8)
    local list_h = h - btn_h - Theme.scale(8)
    local btn_w = math.floor((w - pad * 2 - Theme.scale(12)) / 2)
    local reload_cb = function()
        app:apply_settings()
        -- Force a full tree rebuild (not just a repaint): the sandbox_tree
        -- cache also keys on appearance settings now, but an explicit
        -- Reload must never serve stale geometry under any circumstance.
        app.state.css_force_rebuild = true
        app:refresh(true)
        UIManager:show(InfoMessage:new{
            text = _("CSS reloaded"), timeout = 2 })
    end
    local shot_cb = function() app:debug_page_shot() end

    -- Sandbox body: themes/pages/sandbox.html (user file) -> node tree ->
    -- decorated by theme sheet + inline <style> -> painted with the canvas
    -- primitives. Actions come from the app (Lua is the "JS" here).
    local actions = {
        reload = function(id)
            app:apply_settings()
            app.state.css_force_rebuild = true
            app:refresh(true)
            UIManager:show(InfoMessage:new{
                text = _("CSS reloaded"), timeout = 2 })
        end,
        shot = function(id)
            app:debug_page_shot()
        end,
        -- Same verbs as the KtHTML sandbox (html_test): one action
        -- catalog for both engines, authors learn once. No invalidate
        -- needed here: bind values re-resolve on every sandbox_tree hit.
        step = function(id)
            app.state.sandbox = app.state.sandbox or {}
            local n = tonumber(app.state.sandbox.conta) or 0
            n = math.max(0, math.min(9, n + (tonumber(id) or 0)))
            app.state.sandbox.conta = n
            app:refresh(true)
        end,
        move = function(id)
            app.state.sandbox = app.state.sandbox or {}
            local n = tonumber(app.state.sandbox.pos) or 0
            n = math.max(0, math.min(8, n + (tonumber(id) or 0)))
            app.state.sandbox.pos = n
            app:refresh(true)
        end,
    }
    local Storage = require("kt_storage")
    local vars = {
        shot = Storage.data_dir() .. "/kotavern_css_test.png",
        sonic = Constants.PLUGIN_DIR .. "/assets/sonic_debug.gif",
        sonic_frames = Constants.PLUGIN_DIR .. "/assets/debug_banner",
    }
    -- sandbox_tree caches by file mtime + theme sheet identity: edits land
    -- on Reload without re-parsing on every scroll repaint.
    local force = app.state.css_force_rebuild == true
    app.state.css_force_rebuild = nil
    local tree, merged, sandbox_errors =
        UiDSL.sandbox_tree(app, actions, vars, force)
    
    -- Errors surface right here (sandbox = error surface too): theme
    -- palette problems first, then sandbox.html ones (missing file, bad
    -- values, unknown props/actions). No silent fallbacks.
    local errors = {}
    for _, e in ipairs(app.state.debug_theme_errors or {}) do
        errors[#errors + 1] = e
    end
    for _, e in ipairs(sandbox_errors or {}) do
        errors[#errors + 1] = e
    end

    local node_h = {}
    local gap = Theme.scale(10)
    local total_h = 0
    local inner_w = w - pad * 2 - Theme.scrollbar_w()
    for i = 1, #tree.children do
        node_h[i] = UiDSL.measure(tree.children[i], inner_w)
        total_h = total_h + node_h[i] + ((i > 1) and gap or 0)
    end
    -- Island renders resolve during measure above: collect their
    -- warnings/errors AFTER measuring, then reserve the strip.
    for _, e in ipairs(UiDSL.html_errors(tree)) do
        errors[#errors + 1] = e
    end

    -- Reserve space for errors at the bottom if any exist.
    local err_h = 0
    if #errors > 0 then
        err_h = Theme.line_h("tiny") + Theme.scale(8)
        list_h = list_h - err_h
    end
    max_scroll = math.max(0, total_h - list_h)
    local inner_scroll = math.max(0, math.min(scroll or 0, max_scroll))
    if app.state.scroll and app.scroll_key then
        app.state.scroll[app:scroll_key()] = inner_scroll
    end
    Scroll.set_list_bounds(view, x, list_y, w, list_h, nil)
    
    -- Clear the list background FIRST to wipe old scrolled content
    P.rect(bb, x, list_y, w, list_h, Theme.bg)

    local cy = list_y - inner_scroll
    for i = 1, #tree.children do
        local node = tree.children[i]
        if cy + node_h[i] > list_y and cy < list_y + list_h then
            -- Clip = the node's own visible band, NOT the whole list: a
            -- node that overlaps the toolbar strip only paints inside its
            -- slice - bleed under the toolbar is gone by construction, no
            -- opaque overpaint needed (round 3, item 1.2).
            local top_i = math.max(cy, list_y)
            local bot_i = math.min(cy + node_h[i], list_y + list_h)
            UiDSL.paint(node, bb, x + pad, cy, inner_w, view,
                { x = x, y = top_i, w = w, h = math.max(0, bot_i - top_i) })
        end
        cy = cy + node_h[i] + gap
    end
    -- Toolbar ABOVE the list items in registration order: hitboxes register
    -- last so they win the reverse hit test in AppView:onTapKotavern (the
    -- overpaint rect is now belt-and-suspenders; nothing bleeds anymore).
    P.rect(bb, x, y, w, list_y - y, Theme.bg)
    Widgets.button(view, bb, { x = x + pad, y = y + Theme.scale(4), w = btn_w, h = btn_h,
        icon = "refresh", label = _("Reload"), on_tap = reload_cb })
    Widgets.button(view, bb, { x = x + pad + btn_w + Theme.scale(12), y = y + Theme.scale(4), w = btn_w, h = btn_h,
        icon = "camera", label = _("Shot"), on_tap = shot_cb })
    -- Declare the painted-over band so DIRECT animation ticks skip it
    -- (GifAnim clips against chrome_region too - a sonic scrolled under the
    -- toolbar must not blit its frame back on top of the buttons).
    view.chrome_region = { x = x, y = y, w = w, h = list_y - y }

    -- Paint errors in their reserved bottom strip with a solid background.
    if #errors > 0 then
        local err_y = list_y + list_h
        P.rect(bb, x, err_y, w, err_h, Theme.bg)
        P.text(bb, _("CSS problems:") .. " " .. table.concat(errors, "; "),
            x + pad, err_y + Theme.scale(4),
            w - pad * 2, "tiny", { color = Theme.muted })
    end
    return max_scroll
end

-- HTML sandbox: a page painted from a LITERAL html+css user file
-- (themes/pages/html_sandbox.html) through MuPDF's HtmlBoxWidget. No custom
-- parser: the file is real HTML, links use the kt: scheme (nav/back/toggle
-- /input/action) and taps re-render the doc, one refresh per tap. Dogfoods
-- the kt: router itself (Reload/Shot are page links, no native toolbar).
function Pages.html_test(view, bb, x, y, w, h, scroll)
    local app = view.app
    local KtHTML = require("ktui/kthtml")
    local max_scroll = 0
    local m = Theme.metrics()
    local pad = m.pad
    local list_y = y
    local list_h = h
    local inner_w = w - pad * 2 - Theme.scrollbar_w()
    local paginated = app.state.settings.html_pagination == true

    local actions = {
        reload = function()
            app:apply_settings()
            KtHTML.invalidate(app, "html_sandbox.html")
            app:refresh(true)
            UIManager:show(InfoMessage:new{
                text = _("HTML reloaded"), timeout = 2 })
        end,
        shot = function() app:debug_page_shot() end,
        step = function(id)
            app.state.sandbox = app.state.sandbox or {}
            local n = tonumber(app.state.sandbox.conta) or 0
            n = math.max(0, math.min(9, n + (tonumber(id) or 0)))
            app.state.sandbox.conta = n
            KtHTML.invalidate(app, "html_sandbox.html")
            app:refresh(true)
        end,
        move = function(id)
            app.state.sandbox = app.state.sandbox or {}
            local n = tonumber(app.state.sandbox.pos) or 0
            n = math.max(0, math.min(8, n + (tonumber(id) or 0)))
            app.state.sandbox.pos = n
            KtHTML.invalidate(app, "html_sandbox.html")
            app:refresh(true)
        end,
    }
    -- String-level prepare first (link lint), so the error strip is
    -- reserved BEFORE choosing the layout viewport.
    local src, src_errors = KtHTML.prepare(app, "html_sandbox.html", actions)
    local errors = {}
    for _, e in ipairs(src_errors or {}) do errors[#errors + 1] = e end

    local err_h = 0
    if #errors > 0 then
        err_h = Theme.line_h("tiny") + Theme.scale(8)
        list_h = list_h - err_h
    end

    local doc = src and KtHTML.ensure(app, view, "html_sandbox.html",
        src, inner_w, list_h, { paginated = paginated }) or nil
    local total_h = doc and KtHTML.content_h(doc, list_h) or 0
    max_scroll = math.max(0, total_h - list_h)
    local inner_scroll = math.max(0, math.min(scroll or 0, max_scroll))
    if app.state.scroll and app.scroll_key then
        app.state.scroll[app:scroll_key()] = inner_scroll
    end
    Scroll.set_list_bounds(view, x, list_y, w, list_h,
        (doc and doc.paginated) and list_h or nil)

    -- Clear the list background FIRST to wipe old scrolled content.
    P.rect(bb, x, list_y, w, list_h, Theme.bg)
    -- Content hitbox registered BEFORE paint on purpose: the native
    -- overlays (btn/toggle/field hitboxes registered during paint_window)
    -- must win ties over it, and the scrollbar registered later in
    -- draw_content wins over everything. Reverse-order hit test reads last
    -- registered first - this order is load-bearing, do not "fix" it.
    if doc then
        P.hit(view, x + pad, list_y, inner_w, list_h, function(tx, ty)
            local live = KtHTML.current(app, "html_sandbox.html")
            if live then
                return KtHTML.tap(live, app, "html_sandbox.html", actions,
                    x + pad, list_y, inner_scroll, tx, ty)
            end
            return false
        end, "kthtml:page")
        KtHTML.paint_window(doc, bb, x + pad, list_y, inner_w, list_h,
            inner_scroll, view, actions)
        view.dithered = true -- bitmap content, same hint as images
    end

    -- Errors in their reserved bottom strip with a solid background.
    if #errors > 0 then
        local err_y = list_y + list_h
        P.rect(bb, x, err_y, w, err_h, Theme.bg)
        P.text(bb, _("HTML problems:") .. " " .. table.concat(errors, "; "),
            x + pad, err_y + Theme.scale(4),
            w - pad * 2, "tiny", { color = Theme.muted })
    end
    return max_scroll
end

-- B-pattern demo: native layout (title + buttons) hosting one MuPDF island.
-- Proves canvas structure + HTML content compose with no hitbox conflicts:
-- the island registers its hitbox first, native buttons afterwards win ties.
function Pages.native_test(view, bb, x, y, w, h, scroll)
    local app = view.app
    local m = Theme.metrics()
    local pad = m.pad
    local btn_h = Theme.btn_h()
    local gap = Theme.scale(8)
    P.rect(bb, x, y, w, h, Theme.bg)
    P.text(bb, "Nativo + ilha HTML", x + pad, y + Theme.scale(6),
        w - pad * 2, "heading", { bold = true })
    local title_h = Theme.line_h("heading") + Theme.scale(6)
    local btn_y = y + h - btn_h - Theme.scale(6)
    local iy = y + title_h + gap
    local island_h = math.max(Theme.scale(60), btn_y - gap - iy)
    local inner_w = w - pad * 2 - Theme.scrollbar_w()
    local actions = { shot = function() app:debug_page_shot() end }
    local island_html = [[
<div class="card"><h2>Ilha HTML em pagina nativa</h2>
<p>Este bloco e um documento MuPDF dentro de layout canvas: titulo e botoes sao nativos, o resto e HTML de verdade com link funcional.</p>
<p><a class="pill" href="kt:action:shot">Capturar tela</a></p></div>]]
    Scroll.set_list_bounds(view, x, iy, w, island_h, nil)
    Widgets.html_block(view, bb, { x = x + pad, y = iy, w = inner_w,
        h = island_h, scroll = 0, html = island_html, actions = actions,
        key = "native_demo" })
    view.dithered = true
    local btn_w = math.floor((w - pad * 2 - Theme.scale(12)) / 2)
    Widgets.button(view, bb, { x = x + pad, y = btn_y, w = btn_w, h = btn_h,
        icon = "refresh", label = _("Reload"), on_tap = function()
            require("ktui/kthtml").invalidate(app, "native_demo")
            app:refresh(true)
        end })
    Widgets.button(view, bb, { x = x + pad + btn_w + Theme.scale(12),
        y = btn_y, w = btn_w, h = btn_h,
        icon = "camera", label = _("Shot"), on_tap = function()
            app:debug_page_shot()
        end })
    return 0
end

function Pages.settings_updates(view, bb, x, y, w, h, scroll)
    local app = view.app
    local Update = require("kt_update")
    local repo = Util.trim(tostring(app.state.settings.update_repo or ""))
    local shown_repo = repo ~= "" and repo or Update.default_repo()
    local installed = Update.installed_build(app.state.settings.installed_build)
    local rows = {
        { text = _("Update channel"), icon = "refresh",
            value = function() return app:update_channel_label() end,
            callback = function() app:choose_update_channel() end },
        { text = _("Repository"), icon = "plug",
            value = function() return shown_repo end,
            callback = function() app:prompt_update_repo() end },
        { text = _("Installed"), icon = "info-circle",
            value = function() return Update.about_title(installed) end,
            callback = function()
                -- Triple-tap arms Debug Mode (1.5s window, see kt_app).
                app:_debug_triple_tap()
            end },
        { text = _("Status"), icon = "bolt",
            value = function() return tostring(view.app.state.update_status or "-") end,
            callback = function() end },
        { text = _("Check for updates"), icon = "download",
            callback = function() app:check_updates_now() end },
    }
    return Pages.settings_section(view, bb, x, y, w, h, scroll, rows)
end

-- === Presets ===
function Pages.presets(view, bb, x, y, w, h, scroll)
    local Storage = require("kt_storage")
    P.rect(bb, x, y, w, h, Theme.bg)
    local m = Theme.metrics()
    local pad = m.pad
    local gutter = Theme.scrollbar_w()

    -- Import/New Preset pills moved to the header toolbar (see ui/header.lua).
    local list_top = y + Theme.scale(6)
    local presets = Storage.list_presets() or {}
    local default_id = view.app.state.settings and view.app.state.settings.default_preset_id

    if #presets == 0 then
        Widgets.empty_state(view, bb, {
            x = x, y = list_top, w = w, h = h - (list_top - y),
            icon = "sliders",
            text = _("No presets yet. Presets hold generation parameters (temperature, tokens...)."),
            action = { label = _("New Preset"), icon = "plus", on_tap = function() view.app:edit_preset(nil) end },
        })
        Scroll.set_list_bounds(view, x, y, w, h, h)
        return 0
    end

    local default_lh = Theme.line_h("default")
    local tiny_lh = Theme.line_h("tiny")
    local gap = Theme.scale(6)
    local row_h = fit_row_h(h - (list_top - y),
        math.max(Theme.metrics().touch_min, default_lh + tiny_lh + Theme.scale(14)), gap)

    local function preset_summary(preset)
        local parts = {}
        if preset.model_id and preset.model_id ~= "" then
            table.insert(parts, preset.model_id)
        end
        if preset.temperature then table.insert(parts, "T" .. tostring(preset.temperature)) end
        if preset.max_tokens then table.insert(parts, tostring(preset.max_tokens) .. " " .. _("tok")) end
        if preset.top_p then table.insert(parts, "P" .. tostring(preset.top_p)) end
        local summary = table.concat(parts, " · ")
        summary = Widgets.truncate(summary, 55)
        return summary
    end

    local function draw_item(preset, cy, scrollable)
        local row_w = w - pad * 2 - (scrollable and gutter or 0)
        Widgets.row(view, bb, {
            x = x + pad, y = cy, w = row_w, h = row_h,
            icon = "sliders",
            title = preset.name or "?",
            subtitle = preset_summary(preset),
            check = (default_id == preset.id),
            kebab = true,
            on_kebab = function() view.app:show_preset_actions(preset) end,
            on_tap = function() view.app:show_preset_actions(preset) end,
        })
    end

    local list_h = h - (list_top - y)
    return Scroll.scrolled_list(view, bb, presets, x, list_top, w, list_h, scroll, row_h, gap, draw_item)
end

-- === Personas ===
function Pages.personas(view, bb, x, y, w, h, scroll)
    P.rect(bb, x, y, w, h, Theme.bg)
    local m = Theme.metrics()
    local pad = m.pad
    local gutter = Theme.scrollbar_w()

    -- New Persona pill moved to the header toolbar (see ui/header.lua).
    local list_top = y + Theme.scale(6)
    local Storage = require("kt_storage")
    local data = Storage.list_personas()
    local personas = data.list or {}
    local active_id = data.active

    if #personas == 0 then
        Widgets.empty_state(view, bb, {
            x = x, y = list_top, w = w, h = h - (list_top - y),
            icon = "user",
            text = _("No personas yet. Personas tell the AI who you are."),
            action = { label = _("New Persona"), icon = "plus", on_tap = function() view.app:edit_persona(nil) end },
        })
        Scroll.set_list_bounds(view, x, y, w, h, h)
        return 0
    end

    local default_lh = Theme.line_h("default")
    local tiny_lh = Theme.line_h("tiny")
    local gap = Theme.scale(6)
    local row_h = fit_row_h(h - (list_top - y),
        math.max(Theme.metrics().touch_min, default_lh + tiny_lh + Theme.scale(14)), gap)

    local function draw_item(persona, cy, scrollable)
        local row_w = w - pad * 2 - (scrollable and gutter or 0)
        local row_x = x + pad
        local is_active = (persona.id == active_id)

        -- Card first (full width), then the avatar thumb INSIDE it, then the
        -- text row on top of the remaining width (no box of its own).
        P.box(bb, row_x, cy, row_w, row_h, {
            border = true, border_size = 1, border_color = Theme.soft,
            background = Theme.panel, radius = Theme.scale(6),
        })
        local thumb_size = math.max(Theme.scale(30), math.floor(row_h * 0.52))
        local tx = row_x + Theme.scale(10)
        local ty = cy + math.floor((row_h - thumb_size) / 2)
        local drawn = persona.avatar and persona.avatar ~= "" and P.image(bb, persona.avatar, tx, ty, thumb_size, thumb_size, { cover = true })
        if drawn then view.dithered = true end -- photo bitmap: dithered refresh
        if not drawn then
            P.rounded_rect(bb, tx, ty, thumb_size, thumb_size, Theme.soft, math.floor(thumb_size / 2))
            P.center_text_box(bb, Widgets.first_glyph(persona.name or "?"):upper(), tx, ty, thumb_size, thumb_size, "small", { bold = true })
        end

        local desc = Widgets.truncate((persona.description or ""):gsub("\n", " "), 60)
        Widgets.row(view, bb, {
            x = row_x + thumb_size + Theme.scale(14), y = cy,
            w = row_w - thumb_size - Theme.scale(14), h = row_h,
            style = "plain",
            title = persona.name or "?",
            subtitle = desc,
            check = is_active,
            kebab = true,
            on_kebab = function() view.app:show_persona_actions(persona) end,
            on_tap = function() view.app:show_persona_actions(persona) end,
        })
    end

    local list_h = h - (list_top - y)
    return Scroll.scrolled_list(view, bb, personas, x, list_top, w, list_h, scroll, row_h, gap, draw_item)
end

-- === Character Editor (ccv3 fields) ===
local function editor_field_rows(view, card, fields)
    local function field_value(key)
        local v = card[key]
        if key == "alternate_greetings" and type(v) == "table" then
            local n = #v
            return n == 1 and _("1 greeting") or tostring(n) .. " " .. _("greetings")
        elseif key == "tags" and type(v) == "table" then
            return table.concat(v, ", ")
        end
        return tostring(v or "")
    end
    local rows = {}
    for _i, field in ipairs(fields) do
        table.insert(rows, {
            title = _(field.title),
            preview = field_value(field.key),
            field = field,
        })
    end
    return rows
end

local function draw_editor_page(view, bb, x, y, w, h, scroll, opts)
    P.rect(bb, x, y, w, h, Theme.bg)
    local m = Theme.metrics()
    local pad = m.pad
    local gutter = Theme.scrollbar_w()

    local bar_h = Widgets.page_bar(view, bb, {
        x = x, y = y, w = w,
        title = opts.title,
        actions = {
            { label = _("Save"), icon = "save", kind = "primary", on_tap = opts.on_save },
        },
    })

    local list_top = y + bar_h + Theme.scale(2)
    local small_lh = Theme.line_h("small")
    local tiny_lh = Theme.line_h("tiny")
    local row_h = math.max(Theme.metrics().touch_min, small_lh + tiny_lh + Theme.scale(14))
    local gap = Theme.scale(6)

    local function draw_item(row, cy, scrollable)
        local row_w = w - pad * 2 - (scrollable and gutter or 0)
        -- Section header (preset editor): plain bold label, no card, no hit.
        if row.section then
            Widgets.row(view, bb, {
                x = x + pad, y = cy, w = row_w, h = row_h,
                title = row.title,
                style = "none",
            })
            return
        end
        local preview = Widgets.truncate((row.preview or ""):gsub("\n", " "), 48)
        if preview == "" then
            preview = _("(empty)")
        end
        Widgets.row(view, bb, {
            x = x + pad, y = cy, w = row_w, h = row_h,
            title = row.title,
            subtitle = preview,
            chevron = true,
            on_tap = row.on_tap,
        })
    end

    local list_h = h - (list_top - y)
    return Scroll.scrolled_list(view, bb, opts.rows, x, list_top, w, list_h, scroll, row_h, gap, draw_item)
end

function Pages.character_editor(view, bb, x, y, w, h, scroll)
    local editing = view.app.state.editing_character
    if not editing or not editing.card then
        P.rect(bb, x, y, w, h, Theme.bg)
        Widgets.empty_state(view, bb, {
            x = x, y = y, w = w, h = h,
            icon = "edit", text = _("Nothing to edit."),
        })
        Scroll.set_list_bounds(view, x, y, w, h, h)
        return 0
    end
    local card = editing.card
    local rows = {}
    for _, row in ipairs(editor_field_rows(view, card, view.app.CHARACTER_FIELDS)) do
        row.on_tap = function() view.app:edit_character_field(row.field.key) end
        table.insert(rows, row)
    end
    return draw_editor_page(view, bb, x, y, w, h, scroll, {
        title = _("Edit Character"),
        rows = rows,
        on_save = function() view.app:save_character_edit() end,
    })
end

-- === Preset editor (canvas page; per-field input like the character editor) ===
-- Rows: Prompt Manager on top, then the ST AI Response Configuration fields
-- grouped in sections. Between them sit the Prompt-Manager shortcut rows
-- (Continue Nudge, generation and context utility counts) - the v0.6.7 fix
-- for "editing a preset only shows the parameters": the prompt layout that
-- actually shapes the request is now reachable from the same page for EVERY
-- preset, not just ST imports that shipped a prompts table.
function Pages.preset_editor(view, bb, x, y, w, h, scroll)
    local draft = view.app.state.editing_preset
    if not draft then
        P.rect(bb, x, y, w, h, Theme.bg)
        Widgets.empty_state(view, bb, {
            x = x, y = y, w = w, h = h,
            icon = "sliders", text = _("Nothing to edit."),
        })
        Scroll.set_list_bounds(view, x, y, w, h, h)
        return 0
    end

    -- Active utility counts from the saved order (before/after chatHistory).
    local order = view.app:prompt_order_items() or {}
    local gen_n, ctx_n = 0, 0
    local seen_history = false
    for _j, it in ipairs(order) do
        if it.identifier == "chatHistory" then
            seen_history = true
        elseif it.enabled then
            local is_marker = it.prompt and it.prompt.marker
            if seen_history then
                if is_marker then ctx_n = ctx_n + 1 end
            else
                if not is_marker then gen_n = gen_n + 1 end
            end
        end
    end

    local rows = {}
    -- Prompt Manager entry: always available (edit_preset seeds the ST
    -- defaults on presets that lack prompts/prompt_order).
    table.insert(rows, {
        title = _("Prompt Manager"),
        preview = type(draft.prompts) == "table"
            and (tostring(#draft.prompts) .. " " .. _("prompts")) or _("Not configured"),
        on_tap = function() view.app:open_prompt_manager() end,
    })
    for _i, field in ipairs(view.app.PRESET_FIELDS) do
        -- Section headers are labels, not editable fields.
        if field.section then
            table.insert(rows, { section = true, title = _(field.title) })
        else
            local v = draft[field.key]
            local preview
            if field.boolean then
                preview = v == true and _("True") or (v == false and _("False") or _("Default"))
            elseif v == nil or v == "" then
                preview = ""
            else
                preview = tostring(v)
            end
            table.insert(rows, {
                title = _(field.title),
                preview = preview,
                on_tap = function() view.app:edit_preset_field(field.key) end,
            })
            -- Prompt-Manager companions, anchored to their section's last row.
            if field.key == "streaming" then
                -- End of Main: the Continue nudge is prompt scaffolding.
                local nudge = draft.continue_nudge_prompt
                table.insert(rows, {
                    title = _("Continue Nudge Prompt"),
                    preview = (type(nudge) == "string" and nudge ~= "") and nudge or "",
                    on_tap = function() view.app:edit_continue_nudge() end,
                })
            elseif field.key == "max_tokens" then
                -- End of Generation: jump into the generation-side utilities.
                table.insert(rows, {
                    title = _("Generation prompts"),
                    preview = tostring(gen_n) .. " " .. _("active"),
                    on_tap = function() view.app:open_prompt_manager() end,
                })
            elseif field.key == "openai_max_context" and ctx_n > 0 then
                -- End of Context: markers that carry context into the prompt.
                table.insert(rows, {
                    title = _("Context template prompts"),
                    preview = tostring(ctx_n) .. " " .. _("active"),
                    on_tap = function() view.app:open_prompt_manager() end,
                })
            end
        end
    end
    return draw_editor_page(view, bb, x, y, w, h, scroll, {
        title = _("Edit Preset"),
        rows = rows,
        on_save = function() view.app:save_preset_edit() end,
    })
end

-- === Regex scripts (display/prompt cleanup) ===
function Pages.regex_scripts(view, bb, x, y, w, h, scroll)
    P.rect(bb, x, y, w, h, Theme.bg)
    local m = Theme.metrics()
    local pad = m.pad
    local gutter = Theme.scrollbar_w()

    -- New Script pill moved to the header toolbar (see ui/header.lua).
    local list_top = y + Theme.scale(6)
    local scripts = view.app.state.settings.regex_scripts or {}
    if #scripts == 0 then
        Widgets.empty_state(view, bb, {
            x = x, y = list_top, w = w, h = h - (list_top - y),
            icon = "wrench",
            text = _("No regex scripts. They find/replace text in AI output or prompts (Lua patterns)."),
            action = { label = _("New Script"), icon = "plus", on_tap = function()
                view.app:new_regex_script()
            end },
        })
        Scroll.set_list_bounds(view, x, y, w, h, h)
        return 0
    end

    local small_lh = Theme.line_h("small")
    local tiny_lh = Theme.line_h("tiny")
    local row_h = fit_row_h(h - (list_top - y),
        math.max(m.touch_min, small_lh + tiny_lh + Theme.scale(14)))
    local gap = m.card_gap

    return Scroll.scrolled_list(view, bb, scripts, x, list_top, w, h - (list_top - y), scroll, row_h, gap, function(script, cy, scrollable)
        local row_w = w - pad * 2 - (scrollable and gutter or 0)
        local placement = script.placement == "prompt" and _("prompt")
            or (script.placement == "both" and _("both") or _("display"))
        Widgets.row(view, bb, {
            x = x + pad, y = cy, w = row_w, h = row_h,
            icon = script.disabled and "ban" or "wrench",
            title = script.scriptName or _("Script"),
            subtitle = placement,
            enabled = not script.disabled,
            toggle = true,
            toggle_value = not script.disabled,
            on_toggle = function()
                view.app:toggle_regex_script(script)
            end,
            kebab = true,
            on_kebab = function()
                view.app:show_regex_script_actions(script)
            end,
            on_tap = function()
                view.app:edit_regex_script(script)
            end,
        })
    end)
end

-- === Character view (profile page) ===
-- Layout: page bar (Start Chat + actions menu), large cover (tap → fullscreen
-- viewer), then the card text sections below in a variable-height band.
local _cv_scratch = nil
local _cv_scratch_w, _cv_scratch_h = 0, 0

local function cv_scratch(w, h, bb)
    local t = bb:getType()
    if not _cv_scratch or w > _cv_scratch_w or h > _cv_scratch_h or _cv_scratch:getType() ~= t then
        _cv_scratch = Blitbuffer.new(w, h, t)
        _cv_scratch_w, _cv_scratch_h = w, h
    end
    return _cv_scratch
end

-- Creator Notes rich text: markdown blocks from Md.parse laid out as paint
-- items (measure and paint share this so heights always agree). Inline bold
-- comes from Md.inline (PTF, same as chat bubbles).
local function notes_layout(text, w)
    local Md = require("ktui/md")
    local body_lh = Theme.line_h("default")
    local tiny_lh = Theme.line_h("tiny")
    local gap = Theme.scale(4)
    local items = {}
    text = tostring(text or "")
    if text:match("^%s*$") then
        return items
    end
    local function add_text(t, opts)
        opts = opts or {}
        local lines = math.max(1, P.paragraph_line_count(t, opts.w or w, "default", { bold = opts.bold }))
        items[#items + 1] = { kind = "text", text = t, w = opts.w or w,
            bold = opts.bold, color = opts.color, h = lines * body_lh }
    end
    for _, b in ipairs(Md.parse(text)) do
        if b.kind == "rule" then
            items[#items + 1] = { kind = "rule", w = w, h = Theme.scale(10) }
        elseif b.kind == "image" then
            local t = (b.alt and b.alt ~= "") and ("[" .. b.alt .. "]") or "[image]"
            items[#items + 1] = { kind = "text", text = t, w = w,
                color = Theme.muted, h = tiny_lh }
        elseif b.kind == "table" then
            local rows = {}
            if type(b.header) == "table" then
                rows[#rows + 1] = table.concat(b.header, " | ")
            end
            for _, row in ipairs(b.rows or {}) do
                rows[#rows + 1] = table.concat(row, " | ")
            end
            add_text(table.concat(rows, "\n"))
        elseif b.kind == "code" then
            items[#items + 1] = { kind = "pad", h = Theme.scale(4) }
            add_text(tostring(b.text or ""))
            items[#items + 1] = { kind = "pad", h = Theme.scale(4) }
        elseif b.kind == "heading" then
            add_text(Md.inline(tostring(b.text or "")), { bold = true })
        elseif b.kind == "quote" then
            local qw = math.max(8, w - Theme.scale(8))
            local lines = math.max(1, P.paragraph_line_count(Md.inline(tostring(b.text or "")),
                qw, "default"))
            items[#items + 1] = { kind = "quote", text = Md.inline(tostring(b.text or "")),
                w = qw, h = lines * body_lh }
        else
            add_text(Md.inline(tostring(b.text or "")))
        end
        items[#items + 1] = { kind = "pad", h = gap }
    end
    if #items > 0 and items[#items].kind == "pad" then
        items[#items] = nil
    end
    return items
end

local function notes_height(items)
    local h = 0
    for _, it in ipairs(items) do
        h = h + (it.h or 0)
    end
    if h > 0 then
        h = h + Theme.scale(10)
    end
    return h
end

-- Paint laid-out notes items at (x, oy) in the scratch buffer (already
-- filled); code blocks get a soft backdrop, quotes a left rule.
local function notes_paint(scratch, items, x, oy)
    local y = oy
    for _, it in ipairs(items) do
        if it.kind == "text" then
            P.paragraph(scratch, it.text, x, y, it.w, it.h, "default",
                { bold = it.bold, color = it.color })
        elseif it.kind == "quote" then
            P.rect(scratch, x, y, Theme.scale(2), it.h, Theme.muted)
            P.paragraph(scratch, it.text, x + Theme.scale(6), y, it.w, it.h, "default")
        elseif it.kind == "rule" then
            P.rect(scratch, x, y + math.floor(it.h / 2), it.w or 0, 1, Theme.muted)
        end
        y = y + (it.h or 0)
    end
end

function Pages.character_view(view, bb, x, y, w, h, scroll)
    P.rect(bb, x, y, w, h, Theme.bg)
    local profile = view.app.state.viewing_character
    if not profile or not profile.card then
        Widgets.empty_state(view, bb, {
            x = x, y = y, w = w, h = h,
            icon = "user", text = _("Nothing to view."),
        })
        Scroll.set_list_bounds(view, x, y, w, h, h)
        return 0
    end
    local card = profile.card
    local app = view.app
    local m = Theme.metrics()
    local pad = m.pad

    -- Page bar: Past Chats + actions menu + primary Start Chat
    local bar_h = Widgets.page_bar(view, bb, {
        x = x, y = y, w = w,
        actions = {
            { label = _("Past Chats"), icon = "clock", kind = "secondary", on_tap = function()
                app.state.current_character = card.name or profile.name
                app.state.current_character_file = profile.path
                app:show_past_chats()
            end },
            { label = _("Actions"), icon = "ellipsis-v", kind = "secondary", on_tap = function()
                local item = { path = profile.path, fav = require("kt_storage").is_favorite(profile.path) }
                app:show_character_actions(item)
            end },
            { label = _("Start Chat"), icon = "chat", kind = "primary", on_tap = function()
                app:start_new_chat(profile.path, card.name or profile.name)
            end },
        },
    })

    local top = y + bar_h
    local content_w = w - pad * 2

    -- Read view: curated fields only (prompt-technical ones live in the card
    -- editor). Labels are _() literals so the extractor covers them; open[]
    -- is keyed by stable id so switching language keeps the state.
    local sections = {}
    local function add_section(id, label, text)
        text = tostring(text or "")
        if text == "" then return end
        table.insert(sections, { id = id, label = label, text = text })
    end
    add_section("description", _("Description"), card.description)
    add_section("personality", _("Personality"), card.personality)
    add_section("scenario", _("Scenario"), card.scenario)
    add_section("first_mes", _("First Message"), card.first_mes)
    add_section("tags", _("Tags"), card.tags and #card.tags > 0 and table.concat(card.tags, ", ") or "")

    -- Measure per-section text heights (paragraph with the same face used at
    -- draw time, so measurement matches rendering).
    local label_lh = Theme.line_h("small")
    local body_lh = Theme.line_h("default")
    local section_gap = Theme.scale(12)

    -- Rich header (scrolls with the content): medium avatar + name/creator/
    -- tokens column, tag line below. Tap the avatar for fullscreen.
    local av_s = Theme.scale(120)
    local av_x = x + pad
    local av_y = top + Theme.scale(4)
    local col_x = av_x + av_s + Theme.scale(10)
    local col_w = math.max(8, x + w - pad - col_x)
    local head_text_h = label_lh
    local creator = tostring(card.creator or "")
    if creator ~= "" then
        head_text_h = head_text_h + Theme.scale(2) + Theme.line_h("tiny")
    end
    if (profile.tokens or 0) > 0 then
        head_text_h = head_text_h + Theme.scale(2) + Theme.line_h("tiny")
    end
    local header_h = math.max(av_s, head_text_h)
    local tags_line = ""
    if card.tags and #card.tags > 0 then
        tags_line = Widgets.fit_text(table.concat(card.tags, ", "), content_w, "tiny")
    end
    if tags_line ~= "" then
        header_h = header_h + Theme.scale(6) + Theme.line_h("tiny")
    end
    local view_top = av_y + header_h + Theme.scale(10)

    local avail = (y + h) - view_top
    local text_w = w - pad * 2 - Theme.scale(8)
    -- Collapsible sections (all closed per visit): open[sec.id] expands
    -- the full text; closed shows label + 1-line preview. Tap toggles.
    local open = view.app.state.character_view_open
    if type(open) ~= "table" then
        open = {}
        view.app.state.character_view_open = open
    end
    local tiny_lh = Theme.line_h("tiny")
    local block_h = {}
    local total_h = 0
    for i, sec in ipairs(sections) do
        local head = label_lh + Theme.scale(4)
        if open[sec.id] then
            local nlines = math.max(1, #(TextBoxWidget:new{
                text = sec.text,
                face = Theme.face("default"),
                width = math.max(text_w, 1),
                height = 1,
                height_adjust = true,
            }.vertical_string_list or {}))
            block_h[i] = head + nlines * body_lh
        else
            block_h[i] = head + tiny_lh + Theme.scale(2)
        end
        total_h = total_h + block_h[i] + section_gap
    end
    -- Creator Notes live at the top of the scrolling band (always visible,
    -- markdown rendered, no collapse). Laid out with the same width used at
    -- measure time; re-laid-out below once the gutter is known.
    local notes_text = tostring(card.creator_notes or "")
    local notes_items = notes_layout(notes_text, text_w)
    local notes_h = notes_height(notes_items)
    total_h = total_h + notes_h
    local max_scroll = math.max(0, total_h - avail)
    scroll = math.max(0, math.min(scroll or 0, max_scroll))
    view.app.state.scroll[view.app:scroll_key()] = scroll
    local scrollable = max_scroll > 0
    local gutter = scrollable and Theme.scrollbar_w() or 0
    content_w = w - pad * 2 - gutter
    text_w = content_w - Theme.scale(8)
    do
        local pre_h = notes_h
        notes_items = notes_layout(notes_text, text_w)
        notes_h = notes_height(notes_items)
        -- Gutter-narrowed re-layout may shift heights by a line or two
        -- (same pre-existing drift as section paragraphs); re-clamp scroll.
        total_h = total_h - pre_h + notes_h
        max_scroll = math.max(0, total_h - avail)
        scroll = math.max(0, math.min(scroll or 0, max_scroll))
        view.app.state.scroll[view.app:scroll_key()] = scroll
    end
    notes_items = notes_layout(notes_text, text_w)
    notes_h = notes_height(notes_items)

    -- Rich header, fixed above the scrolling sections: avatar + name /
    -- creator / tokens column, tag line below. Tap the avatar for fullscreen.
    if av_y <= y + h then
        P.box(bb, av_x, av_y, av_s, av_s, {
            border_color = Theme.soft, border_size = 1, radius = Theme.scale(8), background = Theme.panel,
        })
        local drawn = P.image(bb, profile.path, av_x, av_y, av_s, av_s, { cover = true })
        if drawn then view.dithered = true end -- photo bitmap: dithered refresh
        if not drawn then
            P.center_text_box(bb, Widgets.first_glyph(card.name or "?"):upper(),
                av_x, av_y, av_s, av_s, "title", { bold = true })
        end
        P.hit(view, av_x, av_y, av_s, av_s, function()
            view.app:show_character_image_fullscreen(profile.path)
        end, "cv_avatar")
        local ny = av_y
        P.text(bb, Widgets.fit_text(card.name or "?", col_w, "default", { bold = true }),
            col_x, ny, col_w, "default", { bold = true })
        ny = ny + label_lh + Theme.scale(2)
        if creator ~= "" then
            P.text(bb, Widgets.fit_text(creator, col_w, "tiny"), col_x, ny, col_w, "tiny",
                { color = Theme.muted })
            ny = ny + Theme.line_h("tiny") + Theme.scale(2)
        end
        if (profile.tokens or 0) > 0 then
            P.text(bb, "~" .. tostring(profile.tokens) .. " " .. _("tok"), col_x, ny, col_w,
                "tiny", { color = Theme.muted })
        end
        if tags_line ~= "" then
            P.text(bb, tags_line, x + pad, av_y + math.max(av_s, head_text_h) + Theme.scale(6),
                content_w, "tiny", { color = Theme.muted })
        end
    end

    -- Sections band (variable-height, scrolled). Creator Notes paint first
    -- (always visible, markdown), then the collapsible sections. Top-cut
    -- content clips through the scratch buffer exactly.
    local chev_s = Theme.scale(20)
    local cy = view_top - scroll
    local sec_x = x + pad
    if notes_h > 0 and text_w >= 8 and cy + notes_h > view_top and cy < view_top + avail then
        local scratch = cv_scratch(text_w, notes_h, bb)
        scratch:fill(Theme.bg)
        notes_paint(scratch, notes_items, 0, 0)
        local src_top = math.max(cy, view_top)
        local src_bot = math.min(cy + notes_h, view_top + avail)
        if src_bot > src_top then
            bb:blitFrom(scratch, sec_x, src_top, 0, src_top - cy, text_w, src_bot - src_top)
        end
        cy = cy + notes_h
    elseif notes_h > 0 then
        cy = cy + notes_h
    end
    for i, sec in ipairs(sections) do
        local is_open = open[sec.id] == true
        local head_h = label_lh + Theme.scale(4)
        if not is_open then
            head_h = head_h + tiny_lh + Theme.scale(2)
        end
        if cy + block_h[i] > view_top and cy < view_top + avail then
            local y_top = math.max(cy, view_top)
            local y_bot = math.min(cy + block_h[i], view_top + avail)
            -- Header hitbox first (wide): narrower hits below win their taps.
            local hy0 = math.max(cy, view_top)
            local hy1 = math.min(cy + head_h, view_top + avail)
            if hy1 > hy0 then
                P.hit(view, sec_x, hy0, content_w, hy1 - hy0, function()
                    open[sec.id] = not open[sec.id]
                    view:refresh()
                end, "cvsec:" .. tostring(sec.id))
            end
            local label_top = y_top
            P.text(bb, sec.label, sec_x, label_top, content_w - chev_s - Theme.scale(4),
                "small", { bold = true, color = Theme.muted })
            Icons.center(bb, is_open and "chev-down" or "chev-right",
                sec_x + content_w - chev_s, label_top, chev_s, label_lh, Theme.scale(8))
            if is_open then
                local para_h = block_h[i] - (label_lh + Theme.scale(4))
                local py = cy + label_lh + Theme.scale(4)
                if py + para_h <= view_top + avail and py >= view_top then
                    P.paragraph(bb, sec.text, x + pad, py, text_w, para_h, "default")
                else
                    local src_top = math.max(py, view_top)
                    local src_bot = math.min(py + para_h, view_top + avail)
                    if src_bot > src_top then
                        local scratch = cv_scratch(text_w, para_h, bb)
                        scratch:fill(Theme.bg)
                        local widget = TextBoxWidget:new{
                            text = sec.text,
                            face = Theme.face("default"),
                            fgcolor = Theme.ink,
                            width = text_w,
                            height = para_h,
                            height_adjust = true,
                            height_overflow_show_ellipsis = true,
                        }
                        widget:paintTo(scratch, 0, 0)
                        widget:free()
                        bb:blitFrom(scratch, x + pad, src_top, 0, src_top - py, text_w, src_bot - src_top)
                    end
                end
            else
                -- One-line preview, painted only when fully inside the band:
                -- a top-cut header keeps its label, never a stray line above.
                local py_prev = cy + label_lh + Theme.scale(4)
                if py_prev >= view_top then
                    local first = tostring(sec.text or ""):match("^([^\n]*)") or ""
                    local preview = Widgets.fit_text(first:gsub("%s+", " "), text_w, "tiny")
                    if preview ~= "" then
                        P.text(bb, preview, sec_x, py_prev,
                            text_w, "tiny", { color = Theme.muted })
                    end
                end
            end
        end
        cy = cy + block_h[i] + section_gap
    end

    Scroll.set_list_bounds(view, x, view_top, w, h - (view_top - y), Theme.line_h("default"))
    return max_scroll
end

-- === Alternate Greetings (sub-page of the card editor) ===
function Pages.character_greetings(view, bb, x, y, w, h, scroll)
    P.rect(bb, x, y, w, h, Theme.bg)
    local m = Theme.metrics()
    local pad = m.pad
    local gutter = Theme.scrollbar_w()
    local editing = view.app.state.editing_character
    if not editing or not editing.card then
        Widgets.empty_state(view, bb, {
            x = x, y = y, w = w, h = h,
            icon = "edit", text = _("Nothing to edit."),
        })
        Scroll.set_list_bounds(view, x, y, w, h, h)
        return 0
    end

    local bar_h = Widgets.page_bar(view, bb, {
        x = x, y = y, w = w,
        actions = {
            { label = _("New Greeting"), icon = "plus", kind = "primary", on_tap = function()
                view.app:add_character_greeting()
            end },
        },
    })

    -- Short helper: initial greeting of the card (first_mes) shown as a hint
    local first_mes = tostring(editing.card.first_mes or "")
    local hint_h = 0
    if first_mes ~= "" then
        local hint_w = w - pad * 2
        local lines = P.paragraph_line_count(_("Card first message: ") .. first_mes, hint_w, "tiny")
        hint_h = lines * Theme.line_h("tiny") + Theme.scale(8)
        P.paragraph(bb, _("Card first message: ") .. first_mes, x + pad, y + bar_h, hint_w,
            lines * Theme.line_h("tiny") + Theme.line_h("tiny"), "tiny", { color = Theme.muted })
    end

    local list_top = y + bar_h + hint_h + Theme.scale(4)
    local list_h = h - (list_top - y)
    local greetings = editing.card.alternate_greetings
    if type(greetings) ~= "table" then greetings = {} end

    if #greetings == 0 then
        Widgets.empty_state(view, bb, {
            x = x, y = list_top, w = w, h = math.max(list_h, Theme.scale(160)),
            icon = "comments",
            text = _("No alternate greetings yet. Add alternatives to the first message for new chats."),
            action = { label = _("New Greeting"), icon = "plus", on_tap = function()
                view.app:add_character_greeting()
            end },
        })
        Scroll.set_list_bounds(view, x, list_top, w, list_h, list_h)
        return 0
    end

    local tiny_lh = Theme.line_h("tiny")
    local small_lh = Theme.line_h("small")
    local row_h = math.max(Theme.metrics().touch_min, small_lh + tiny_lh + Theme.scale(14))
    local gap = Theme.scale(6)

    -- Wrap each greeting with its index so the draw callback can act on it
    local items = {}
    for i, g in ipairs(greetings) do
        table.insert(items, { text = g, index = i })
    end
    return Scroll.scrolled_list(view, bb, items, x, list_top, w, list_h, scroll, row_h, gap, function(item, cy, scrollable)
        local row_w = w - pad * 2 - (scrollable and gutter or 0)
        local row_x = x + pad
        local preview = Widgets.truncate((item.text or ""):gsub("\n", " "), 64)
        -- Row body (tap = edit) + visible trash button (delete)
        Widgets.row(view, bb, {
            x = row_x, y = cy, w = row_w - Theme.icon_btn() - Theme.scale(8), h = row_h,
            title = _("Greeting") .. " " .. item.index,
            subtitle = preview,
            chevron = true,
            on_tap = function() view.app:edit_character_greeting(item.index) end,
        })
        Widgets.icon_button(view, bb, {
            x = row_x + row_w - Theme.icon_btn(),
            y = cy + math.floor((row_h - Theme.icon_btn()) / 2),
            s = Theme.icon_btn(),
            icon = "trash",
            on_tap = function() view.app:delete_character_greeting(item.index) end,
        })
    end)
end

-- === Prompt Manager (preset prompts/prompt_order) ===
function Pages.prompt_manager(view, bb, x, y, w, h, scroll)
    P.rect(bb, x, y, w, h, Theme.bg)
    local m = Theme.metrics()
    local pad = m.pad
    local gutter = Theme.scrollbar_w()
    local preset = view.app.state.editing_preset
    local order_list = view.app:prompt_order_items()
    if not preset or not order_list then
        Widgets.empty_state(view, bb, { x = x, y = y, w = w, h = h, icon = "sliders", text = _("No prompts in this preset.") })
        Scroll.set_list_bounds(view, x, y, w, h, h)
        return 0
    end

    local bar_h = Widgets.page_bar(view, bb, {
        x = x, y = y, w = w,
        actions = {
            { label = _("New Prompt"), icon = "plus", on_tap = function()
                view.app:add_prompt_item()
            end },
            { label = _("Done"), icon = "check", kind = "primary", on_tap = function()
                view.app:go_back()
            end },
        },
    })

    local list_top = y + bar_h + Theme.scale(2)
    local small_lh = Theme.line_h("small")
    local tiny_lh = Theme.line_h("tiny")
    local row_h = math.max(m.touch_min, small_lh + tiny_lh + Theme.scale(14))
    local gap = m.card_gap
    local list_h = h - (list_top - y)

    return Scroll.scrolled_list(view, bb, order_list, x, list_top, w, list_h, scroll, row_h, gap, function(item, cy, scrollable)
        local row_w = w - pad * 2 - (scrollable and gutter or 0)
        local row_x = x + pad
        local is_marker = item.prompt and item.prompt.marker
        local subtitle
        if is_marker then
            subtitle = _("marker (dynamic content)")
        elseif item.prompt and item.prompt.content then
            subtitle = Widgets.truncate(item.prompt.content:gsub("\n", " "), 48)
        else
            subtitle = _("(empty)")
        end
        local icon = is_marker and "magic" or "comments"

        -- Row card + text + reorder buttons
        local btn_s = Theme.scale(30)
        local btn_gap = Theme.scale(2)
        local down_x = row_x + row_w - pad - btn_s
        local up_x = down_x - btn_s - btn_gap
        local toggle_w = Theme.scale(40)
        local toggle_x = up_x - toggle_w - Theme.scale(6)
        local body_right = toggle_x - Theme.scale(6)

        P.box(bb, row_x, cy, row_w, row_h, {
            border = true, border_size = 1, border_color = Theme.soft,
            background = Theme.panel, radius = Theme.scale(6),
        })

        local icon_size = Theme.scale(12)
        local isz = Icons.text_size(icon, icon_size)
        local tx = row_x + Theme.scale(10)
        Icons.draw(bb, icon, tx, cy + math.floor((row_h - isz.h) / 2), icon_size, { color = Theme.muted })
        tx = tx + isz.w + Theme.scale(8)

        local text_w = body_right - tx
        local block_h = small_lh + Theme.scale(1) + tiny_lh
        local by = cy + math.floor((row_h - block_h) / 2)
        local title_color = item.enabled and Theme.ink or Theme.muted
        P.text(bb, Widgets.sanitize(item.name or "?"), tx, by, text_w, "small", { bold = true, color = title_color })
        P.text(bb, subtitle, tx, by + small_lh + Theme.scale(1), text_w, "tiny", { color = Theme.muted })

        -- Row-wide edit hit FIRST (non-marker prompts); the narrow controls
        -- below register after and win their strips (reverse-order checking).
        -- NOTE: a kebab hit used to live here (rename/remove), but it had no
        -- painted affordance and overlapped the Up button by 22px (Up won, so
        -- only a ~2px sliver was live). Removed as dead; rename/remove belong
        -- on the edit screen if needed.
        if not is_marker then
            P.hit(view, row_x, cy, row_w, row_h, function()
                view.app:edit_prompt_item(item.index)
            end, "pm_edit_" .. item.index)
        end

        -- Toggle (enable/disable in the order)
        P.zen_toggle(bb, toggle_x, cy + math.floor((row_h - Theme.scale(22)) / 2), toggle_w, Theme.scale(22), item.enabled)
        P.hit(view, toggle_x, cy, toggle_w, row_h, function()
            view.app:toggle_prompt_item(item.index)
        end, "pm_toggle_" .. item.index)

        -- Up / Down
        local up_isz = Icons.text_size("chev-up", Theme.scale(11))
        Icons.draw(bb, "chev-up", up_x + math.floor((btn_s - up_isz.w) / 2), cy + math.floor((row_h - up_isz.h) / 2), Theme.scale(11), { color = Theme.ink })
        P.hit(view, up_x, cy, btn_s, row_h, function()
            view.app:move_prompt_item(item.index, -1)
        end, "pm_up_" .. item.index)
        local down_isz = Icons.text_size("chev-down", Theme.scale(11))
        Icons.draw(bb, "chev-down", down_x + math.floor((btn_s - down_isz.w) / 2), cy + math.floor((row_h - down_isz.h) / 2), Theme.scale(11), { color = Theme.ink })
        P.hit(view, down_x, cy, btn_s, row_h, function()
            view.app:move_prompt_item(item.index, 1)
        end, "pm_down_" .. item.index)
    end)
end

-- === Lorebooks (World Info) ===
-- lorebooks: world list; lorebook_editor: entries of one world;
-- lorebook_entry: single entry fields.

function Pages.lorebooks(view, bb, x, y, w, h, scroll)
    P.rect(bb, x, y, w, h, Theme.bg)
    local m = Theme.metrics()
    local pad = m.pad
    local gutter = Theme.scrollbar_w()

    -- Import/New Lorebook pills moved to the header toolbar (see ui/header.lua).
    local list_top = y + Theme.scale(6)
    local Storage = require("kt_storage")
    local WI = require("kt_world_info")
    local worlds = Storage.list_worlds() or {}

    -- Entry counts, memoized by mtime: parsing every world on every repaint
    -- (per row, inside the draw callback) dominated this page's frame cost.
    local lore_meta_cache = Pages._lore_meta_cache or {}
    Pages._lore_meta_cache = lore_meta_cache
    local function world_entry_count(name)
        local path = Storage.worlds_dir() .. "/" .. tostring(name) .. ".json"
        local ok_mt, mt = pcall(require("libs/libkoreader-lfs").attributes, path, "modification")
        local ent = lore_meta_cache[name]
        if ent and ent.mtime == mt then
            return ent.count
        end
        local world = Storage.load_world(name)
        local entries = world and WI.parse_world(world) or {}
        local count = #entries
        if ok_mt then
            lore_meta_cache[name] = { mtime = mt, count = count }
        end
        return count
    end

    -- Card-embedded book of the current character (import-on-activate)
    local character = nil
    if view.app._resolve_character_data then
        character = view.app:_resolve_character_data()
    end
    local card_book = type(character) == "table" and character.character_book
        and (character.name or "card") or nil

    if #worlds == 0 and not card_book then
        Widgets.empty_state(view, bb, {
            x = x, y = list_top, w = w, h = h - (list_top - y),
            icon = "book",
            text = _("No lorebooks yet. Lorebooks inject context when keywords match the conversation."),
            action = { label = _("New Lorebook"), icon = "plus", on_tap = function()
                view.app:new_lorebook()
            end },
        })
        Scroll.set_list_bounds(view, x, y, w, h, h)
        return 0
    end

    local active_name
    do
        local path = view.app.state.current_chat_path
        if path then
            -- Header-only read (mtime-cached): loading the whole chat here
            -- re-decoded every message on every repaint.
            local header = Storage.chat_header(path)
            local cfg = header and header.chat_metadata and header.chat_metadata.world_info
            active_name = type(cfg) == "table" and cfg.selected or nil
        end
    end

    local items = {}
    for _, name in ipairs(worlds) do
        table.insert(items, { kind = "world", name = name })
    end
    if card_book then
        table.insert(items, { kind = "card", name = card_book })
    end

    local default_lh = Theme.line_h("default")
    local tiny_lh = Theme.line_h("tiny")
    local row_h = fit_row_h(h - (list_top - y),
        math.max(m.touch_min, default_lh + tiny_lh + Theme.scale(14)))
    local gap = m.card_gap

    return Scroll.scrolled_list(view, bb, items, x, list_top, w, h - (list_top - y), scroll, row_h, gap, function(item, cy, scrollable)
        local row_w = w - pad * 2 - (scrollable and gutter or 0)
        local subtitle
        if item.kind == "card" then
            subtitle = _("From this character card")
        else
            local n = world_entry_count(item.name)
            subtitle = n == 1 and _("1 entry") or tostring(n) .. " " .. _("entries")
        end
        Widgets.row(view, bb, {
            x = x + pad, y = cy, w = row_w, h = row_h,
            icon = "book",
            title = (item.kind == "card" and "→ " or "") .. item.name,
            subtitle = subtitle,
            check = (active_name == item.name),
            kebab = true,
            on_kebab = function() view.app:show_lorebook_actions(item) end,
            on_tap = function() view.app:show_lorebook_actions(item) end,
        })
    end)
end

-- Entries list of the world being edited
function Pages.lorebook_editor(view, bb, x, y, w, h, scroll)
    P.rect(bb, x, y, w, h, Theme.bg)
    local m = Theme.metrics()
    local pad = m.pad
    local gutter = Theme.scrollbar_w()
    local editing = view.app.state.editing_world
    if not editing then
        Widgets.empty_state(view, bb, { x = x, y = y, w = w, h = h, icon = "book", text = _("Nothing to edit.") })
        Scroll.set_list_bounds(view, x, y, w, h, h)
        return 0
    end

    local bar_h = Widgets.page_bar(view, bb, {
        x = x, y = y, w = w,
        actions = {
            { label = _("Rename"), icon = "edit", kind = "secondary", on_tap = function()
                view.app:rename_lorebook()
            end },
            { label = _("Save"), icon = "save", kind = "primary", on_tap = function()
                view.app:save_lorebook()
            end },
        },
    })

    local list_top = y + bar_h + Theme.scale(2)
    local entries = editing.entries or {}
    if #entries == 0 then
        Widgets.empty_state(view, bb, {
            x = x, y = list_top, w = w, h = h - (list_top - y),
            icon = "book",
            text = _("No entries yet. Entries activate when their keywords match the conversation."),
            action = { label = _("New Entry"), icon = "plus", on_tap = function()
                view.app:new_world_entry()
            end },
        })
        Scroll.set_list_bounds(view, x, list_top, w, h - (list_top - y), h)
        return 0
    end

    local small_lh = Theme.line_h("small")
    local tiny_lh = Theme.line_h("tiny")
    local row_h = math.max(m.touch_min, small_lh + tiny_lh + Theme.scale(14))
    local gap = m.card_gap

    return Scroll.scrolled_list(view, bb, entries, x, list_top, w, h - (list_top - y), scroll, row_h, gap, function(entry, cy, scrollable)
        local row_w = w - pad * 2 - (scrollable and gutter or 0)
        local title = entry.comment and entry.comment ~= "" and entry.comment
            or (entry.key and entry.key[1]) or _("Entry")
        local bits = {}
        for _, k in ipairs(entry.key or {}) do
            table.insert(bits, k)
        end
        local subtitle = #bits > 0 and table.concat(bits, ", ") or _("(no keys)")
        if entry.constant then
            subtitle = subtitle .. " · " .. _("constant")
        end
        if entry.disable then
            subtitle = subtitle .. " · " .. _("disabled")
        end
        Widgets.row(view, bb, {
            x = x + pad, y = cy, w = row_w, h = row_h,
            icon = entry.disable and "ban" or "file",
            title = Widgets.truncate(title, 60),
            subtitle = Widgets.truncate(subtitle, 70),
            enabled = not entry.disable,
            chevron = true,
            on_tap = function() view.app:edit_world_entry(entry) end,
        })
    end)
end

-- Single entry editor
function Pages.lorebook_entry(view, bb, x, y, w, h, scroll)
    P.rect(bb, x, y, w, h, Theme.bg)
    local m = Theme.metrics()
    local pad = m.pad
    local entry = view.app.state.editing_entry
    if not entry then
        Widgets.empty_state(view, bb, { x = x, y = y, w = w, h = h, icon = "file", text = _("Nothing to edit.") })
        Scroll.set_list_bounds(view, x, y, w, h, h)
        return 0
    end

    local bar_h = Widgets.page_bar(view, bb, {
        x = x, y = y, w = w,
        actions = {
            { label = _("Save"), icon = "save", kind = "primary", on_tap = function()
                view.app:save_world_entry()
            end },
        },
    })

    local WI = require("kt_world_info")
    local logic_labels = { [_("AND any secondary")] = 0, [_("NOT all secondary")] = 1,
        [_("NOT any secondary")] = 2, [_("AND all secondary")] = 3 }
    local logic_label = _("AND any secondary")
    for label, v in pairs(logic_labels) do
        if v == (tonumber(entry.selectiveLogic) or 0) then logic_label = label end
    end
    local position_labels = { [_("Before character")] = 0, [_("After character")] = 1,
        [_("@ depth")] = 4 }
    local position_label = _("Before character")
    for label, v in pairs(position_labels) do
        if v == (tonumber(entry.position) or 0) then position_label = label end
    end
    local role_labels = { [_("system")] = 0, [_("user")] = 1, [_("assistant")] = 2 }
    local role_label = _("system")
    for label, v in pairs(role_labels) do
        if v == (tonumber(entry.role) or 0) then role_label = label end
    end

    local function keys_str(list)
        return type(list) == "table" and table.concat(list, ", ") or ""
    end

    local rows = {
        { title = _("Comment"), preview = entry.comment, on_tap = function() view.app:edit_world_entry_field("comment") end },
        { title = _("Keys (comma separated)"), preview = keys_str(entry.key), on_tap = function() view.app:edit_world_entry_field("key") end },
        { title = _("Secondary keys"), preview = keys_str(entry.keysecondary), on_tap = function() view.app:edit_world_entry_field("keysecondary") end },
        { title = _("Secondary logic"), preview = logic_label, on_tap = function() view.app:choose_world_entry_enum("selectiveLogic", logic_labels) end },
        { title = _("Content"), preview = entry.content, on_tap = function() view.app:edit_world_entry_field("content") end },
        { title = _("Insertion order"), preview = tostring(entry.order), on_tap = function() view.app:edit_world_entry_field("order", true) end },
        { title = _("Position"), preview = position_label, on_tap = function() view.app:choose_world_entry_enum("position", position_labels) end },
        { title = _("Depth"), preview = tostring(entry.depth), on_tap = function() view.app:edit_world_entry_field("depth", true) end },
        { title = _("Role @ depth"), preview = role_label, on_tap = function() view.app:choose_world_entry_enum("role", role_labels) end },
        { title = _("Constant (always on)"), toggle = true, value_fn = function() return entry.constant == true end,
          on_toggle = function() entry.constant = not entry.constant; view:refresh() end },
        { title = _("Probability (%)"), preview = tostring(entry.probability), on_tap = function() view.app:edit_world_entry_field("probability", true) end },
        { title = _("Case sensitive"), toggle = true, value_fn = function() return entry.caseSensitive == true end,
          on_toggle = function() entry.caseSensitive = not entry.caseSensitive; view:refresh() end },
        { title = _("Match whole words"), toggle = true, value_fn = function() return entry.matchWholeWords == true end,
          on_toggle = function() entry.matchWholeWords = not entry.matchWholeWords; view:refresh() end },
        { title = _("Prevent recursion"), toggle = true, value_fn = function() return entry.preventRecursion == true end,
          on_toggle = function() entry.preventRecursion = not entry.preventRecursion; view:refresh() end },
        { title = _("Exclude from recursion"), toggle = true, value_fn = function() return entry.excludeRecursion == true end,
          on_toggle = function() entry.excludeRecursion = not entry.excludeRecursion; view:refresh() end },
        { title = _("Delay until recursion"), toggle = true, value_fn = function() return entry.delayUntilRecursion == true end,
          on_toggle = function() entry.delayUntilRecursion = not entry.delayUntilRecursion; view:refresh() end },
        { title = _("Sticky (messages)"), preview = tostring(entry.sticky or 0), on_tap = function() view.app:edit_world_entry_field("sticky", true) end },
        { title = _("Cooldown (messages)"), preview = tostring(entry.cooldown or 0), on_tap = function() view.app:edit_world_entry_field("cooldown", true) end },
        { title = _("Delay (messages)"), preview = tostring(entry.delay or 0), on_tap = function() view.app:edit_world_entry_field("delay", true) end },
        { title = _("Disabled"), toggle = true, value_fn = function() return entry.disable == true end,
          on_toggle = function() entry.disable = not entry.disable; view:refresh() end },
    }

    local small_lh = Theme.line_h("small")
    local tiny_lh = Theme.line_h("tiny")
    local row_h = math.max(m.touch_min, small_lh + tiny_lh + Theme.scale(14))
    local gap = m.card_gap
    local gutter = Theme.scrollbar_w()
    local list_top = y + bar_h + Theme.scale(2)
    local list_h = h - (list_top - y)

    return Scroll.scrolled_list(view, bb, rows, x, list_top, w, list_h, scroll, row_h, gap, function(row, cy, scrollable)
        local row_w = w - pad * 2 - (scrollable and gutter or 0)
        local preview = Widgets.truncate((row.preview or ""):gsub("\n", " "), 48)
        if preview == "" then preview = _("(empty)") end
        Widgets.row(view, bb, {
            x = x + pad, y = cy, w = row_w, h = row_h,
            title = row.title,
            subtitle = row.toggle and "" or preview,
            toggle = row.toggle,
            toggle_value = row.toggle and row.value_fn() or nil,
            on_toggle = row.on_toggle,
            chevron = not row.toggle,
            on_tap = row.on_tap,
        })
    end)
end

-- === Chats ===
function Pages.chats(view, bb, x, y, w, h, scroll)
    P.rect(bb, x, y, w, h, Theme.bg)
    local m = Theme.metrics()
    local pad = m.pad
    local gutter = Theme.scrollbar_w()

    -- Search/Sort live in the header toolbar now (see ui/header.lua).
    local chats = view.app:chats_visible()
    local query = (view.app.state.chats_query or "")

    local list_top = y + Theme.scale(6)
    if #chats == 0 then
        Widgets.empty_state(view, bb, {
            x = x, y = list_top, w = w, h = h - (list_top - y),
            icon = "comments",
            text = query ~= "" and _("No chats match your search.")
                or _("No chats yet. Open a character card on Home and start a chat."),
        })
        Scroll.set_list_bounds(view, x, y, w, h, h)
        return 0
    end

    local items = {}
    local Storage = require("kt_storage")
    for _, chat in ipairs(chats) do
        -- Normalize to "" (never nil): list_item picks the legacy 2-line
        -- layout by key presence, so every chat row gets the same layout
        -- even with no character name and no preview yet.
        table.insert(items, {
            name = chat.text or chat.name or "Chat",
            path = chat.character_path, -- thumbnail image
            subtext = chat.character_name or "",
            meta = Storage.chat_preview(chat.path) or "",
            callback = chat.callback,
            chat_ref = chat,
        })
    end

    local gap = Theme.scale(6)
    local row_h = fit_row_h(h - (list_top - y),
        math.max(Theme.scale(58), Theme.line_h("small") + Theme.line_h("tiny") + Theme.scale(8)), gap)
    return Scroll.scrolled_list(view, bb, items, x, list_top, w, h - (list_top - y), scroll, row_h, gap, function(item, cy, scrollable)
        local row_gutter = scrollable and gutter or 0
        Cards.list_item(view, bb, item, x + pad, cy, w - pad * 2 - row_gutter, row_h, {
            { icon = "ellipsis-v", callback = function()
                    view.app:show_chat_list_actions(item.chat_ref)
                end,
            },
        })
    end)
end

-- === Connections ===
function Pages.connections(view, bb, x, y, w, h, scroll)
    P.rect(bb, x, y, w, h, Theme.bg)
    local m = Theme.metrics()
    local pad = m.pad
    local gutter = Theme.scrollbar_w()

    -- New Connection pill moved to the header toolbar (see ui/header.lua).
    local list_top = y + Theme.scale(6)
    local Storage = require("kt_storage")
    local connections = Storage.list_connections()

    if #connections == 0 then
        Widgets.empty_state(view, bb, {
            x = x, y = list_top, w = w, h = h - (list_top - y),
            icon = "plug",
            text = _("No API connections yet. Add one to start chatting!"),
            action = { label = _("New Connection"), icon = "plus", on_tap = function() view.app:edit_connection(nil) end },
        })
        Scroll.set_list_bounds(view, x, y, w, h, h)
        return 0
    end

    local default_lh = Theme.line_h("default")
    local tiny_lh = Theme.line_h("tiny")
    local gap = Theme.scale(6)
    local row_h = fit_row_h(h - (list_top - y),
        math.max(Theme.metrics().touch_min, default_lh + tiny_lh + Theme.scale(14)), gap)

    local function test_connection(conn)
        local Client = require("kt_client")
        local client = Client:new()
        UIManager:show(InfoMessage:new{ text = _("Testing connection...") })
        client:test_connection(conn, function(ok, result)
            if ok then
                UIManager:show(InfoMessage:new{ text = _("Connection working!"), timeout = 2 })
            else
                UIManager:show(InfoMessage:new{
                    text = view.app:report_api_error{
                        prefix = _("Failed: "),
                        connection = conn,
                        model = conn.model_id,
                        backend = "curl_sync(test)",
                        message = tostring(result),
                    },
                    timeout = 4,
                })
            end
        end)
    end

    local function conn_actions(conn)
        Sheets.show(view.app, {
            title = conn.name or _("Connection"),
            actions = {
                { label = _("Edit"), icon = "edit", on_tap = function() view.app:edit_connection(conn) end },
                { label = _("Test"), icon = "bolt", on_tap = function() test_connection(conn) end },
                { label = _("Delete"), icon = "trash", danger = true, on_tap = function()
                    Sheets.confirm(view.app, {
                        title = _("Delete connection"),
                        text = _("Delete ") .. (conn.name or "?") .. "?",
                        ok_label = _("Delete"), danger = true,
                        on_ok = function()
                            local new_list = {}
                            for _, c in ipairs(Storage.list_connections()) do
                                if c.id ~= conn.id then table.insert(new_list, c) end
                            end
                            Storage.save_connections(new_list)
                            view:refresh(true)
                        end,
                    })
                end },
            },
        })
    end

    local function draw_item(conn, cy, scrollable)
        local row_w = w - pad * 2 - (scrollable and gutter or 0)
        local row_x = x + pad

        -- Two visible icon buttons on the right (test + menu)
        local btn_s = Theme.icon_btn() - Theme.scale(4)
        local menu_x = row_x + row_w - pad - btn_s
        local test_x = menu_x - btn_s - Theme.scale(6)
        local body_right = test_x - Theme.scale(8)

        -- Row card
        P.box(bb, row_x, cy, row_w, row_h, {
            border = true, border_size = 1, border_color = Theme.soft,
            background = Theme.panel, radius = Theme.scale(6),
        })

        -- Plug icon
        local icon_size = Theme.scale(14)
        local isz = Icons.text_size("plug", icon_size)
        local tx = row_x + Theme.scale(12)
        Icons.draw(bb, "plug", tx, cy + math.floor((row_h - isz.h) / 2), icon_size, { color = Theme.muted })
        tx = tx + isz.w + Theme.scale(10)

        local text_w = body_right - tx
        local block_h = default_lh + Theme.scale(2) + tiny_lh
        local by = cy + math.floor((row_h - block_h) / 2)
        P.text(bb, Widgets.sanitize(conn.name or "?"), tx, by, text_w, "default", { bold = true })
        P.text(bb, conn.model_id or "?", tx, by + default_lh + Theme.scale(2), text_w, "tiny", { color = Theme.muted })

        -- Row hit FIRST; the two icon buttons below register after and win
        -- their squares (hitboxes are checked in reverse order).
        P.hit(view, row_x, cy, row_w, row_h, function() conn_actions(conn) end, "conn:" .. tostring(conn.id))
        Widgets.icon_button(view, bb, {
            x = test_x, y = cy + math.floor((row_h - btn_s) / 2), s = btn_s,
            icon = "bolt", on_tap = function() test_connection(conn) end,
        })
        Widgets.icon_button(view, bb, {
            x = menu_x, y = cy + math.floor((row_h - btn_s) / 2), s = btn_s,
            icon = "ellipsis-v", on_tap = function() conn_actions(conn) end,
        })
    end

    local list_h = h - (list_top - y)
    return Scroll.scrolled_list(view, bb, connections, x, list_top, w, list_h, scroll, row_h, gap, draw_item)
end

-- Connection editor (canvas page, mirrors preset_editor): field rows + a
-- "Search Model" row that hits the endpoint's GET /models (SillyTavern parity:
-- dropdown when available, manual ID otherwise).
function Pages.connection_editor(view, bb, x, y, w, h, scroll)
    local draft = view.app.state.editing_connection
    if not draft then
        P.rect(bb, x, y, w, h, Theme.bg)
        Widgets.empty_state(view, bb, {
            x = x, y = y, w = w, h = h,
            icon = "plug", text = _("Nothing to edit."),
        })
        Scroll.set_list_bounds(view, x, y, w, h, h)
        return 0
    end

    local rows = {}
    -- Provider quick-add: one tap fills the URL (SillyTavern source list).
    -- The preview names the matched preset (or the custom URL), so the row
    -- never reads "(empty)" with a provider configured.
    do
        local Client = require("kt_client")
        local pname = Client.provider_name(draft.base_url)
        table.insert(rows, {
            title = _("Provider"),
            preview = pname or draft.base_url or "",
            on_tap = function() view.app:pick_provider() end,
        })
    end
    -- Model search: the endpoint list is the fast path on e-ink; the
    -- manual ID row below stays available for endpoints without /models.
    table.insert(rows, {
        title = _("Search Model"),
        preview = (draft.model_id and draft.model_id ~= "") and draft.model_id or "",
        on_tap = function() view.app:search_connection_model() end,
    })
    local fields = view.app.CONNECTION_FIELDS
    if not fields then
        -- The App class owns the field list; fall back for callers without it
        -- (headless harness fake apps).
        local ok_app, App = pcall(require, "kt_app")
        fields = (ok_app and App.CONNECTION_FIELDS) or {}
    end
    for _i, field in ipairs(fields) do
        local v = draft[field.key]
        local preview
        if field.boolean then
            preview = v == true and _("True") or (v == false and _("False") or _("Default"))
        elseif v == nil or v == "" then
            preview = ""
        elseif field.key == "api_key" then
            -- Mask the key in the row preview (still editable in the dialog).
            preview = "***" .. tostring(v):sub(-4)
        else
            preview = tostring(v)
        end
        table.insert(rows, {
            title = _(field.title),
            preview = preview,
            on_tap = function() view.app:edit_connection_field(field.key) end,
        })
    end
    return draw_editor_page(view, bb, x, y, w, h, scroll, {
        title = _("Edit Connection"),
        rows = rows,
        on_save = function() view.app:save_connection_edit() end,
    })
end

-- Model picker (full page): header count + filter value, rows for every
-- model matching the live query, current selection check-marked. Rows come
-- from state.model_picker (filled by Client:list_models via the editor).
function Pages.model_picker(view, bb, x, y, w, h, scroll)
    local app = view.app
    local st = app.state.model_picker
    if not st then
        P.rect(bb, x, y, w, h, Theme.bg)
        Widgets.empty_state(view, bb, {
            x = x, y = y, w = w, h = h,
            icon = "search", text = _("No model list. Use Search Model."),
        })
        Scroll.set_list_bounds(view, x, y, w, h, h)
        return 0
    end

    local q = (st.query or ""):lower()
    local rows = {}
    for _, m in ipairs(st.models or {}) do
        if q == "" or m:lower():find(q, 1, true) then
            table.insert(rows, {
                label = m,
                checked = st.selected == m,
            })
        end
    end

    local m = Theme.metrics()
    local pad = m.pad
    P.rect(bb, x, y, w, h, Theme.bg)
    local row_h = math.max(Theme.metrics().touch_min, Theme.line_h("default") + Theme.scale(14))
    local gap = Theme.scale(6)

    local bar_h = Widgets.page_bar(view, bb, {
        x = x, y = y, w = w,
        title = _("Select Model"),
        actions = {
            { label = (st.query and st.query ~= "") and ("\"" .. st.query .. "\"") or _("Filter"),
              icon = "search", on_tap = function() app:show_model_search() end },
        },
    })
    local list_top = y + bar_h + Theme.scale(2)

    local count_line = tostring(#rows) .. " / " .. tostring(#(st.models or {}))
    P.text(bb, count_line, x + pad, list_top + Theme.scale(2), w - pad * 2, "tiny", { color = Theme.muted })
    list_top = list_top + Theme.line_h("tiny") + Theme.scale(6)

    if #rows == 0 then
        Widgets.empty_state(view, bb, {
            x = x, y = list_top, w = w, h = math.max(h - (list_top - y), Theme.scale(120)),
            icon = "search", text = _("No models match."),
        })
        Scroll.set_list_bounds(view, x, y, w, h, h)
        return 0
    end

    local list_h = h - (list_top - y)
    local function draw_item(row, cy, scrollable)
        local row_w = w - pad * 2 - (scrollable and Theme.scrollbar_w() or 0)
        Widgets.row(view, bb, {
            x = x + pad, y = cy, w = row_w, h = row_h,
            title = row.label,
            check = row.checked,
            on_tap = function() app:pick_model(row.label) end,
        })
    end
    return Scroll.scrolled_list(view, bb, rows, x, list_top, w, list_h, scroll, row_h, gap, draw_item)
end

-- === Past Chats (ST "Manage chat files") ===
-- Per-character chat list for swapping chats: current chat excluded, each row
-- shows name + date + message count/preview; actions per row.
function Pages.chat_history(view, bb, x, y, w, h, scroll)
    P.rect(bb, x, y, w, h, Theme.bg)
    local m = Theme.metrics()
    local pad = m.pad
    local gutter = Theme.scrollbar_w()

    local chats = view.app.state.past_chats or {}
    local list_top = y + Theme.scale(6)

    if #chats == 0 then
        Widgets.empty_state(view, bb, {
            x = x, y = list_top, w = w, h = h - (list_top - y),
            icon = "clock",
            text = _("No other chats for this character. Use Chat Options → Start new chat to begin one."),
        })
        Scroll.set_list_bounds(view, x, y, w, h, h)
        return 0
    end

    local small_lh = Theme.line_h("small")
    local tiny_lh = Theme.line_h("tiny")
    local row_h = fit_row_h(h - (list_top - y),
        math.max(m.touch_min, small_lh + tiny_lh + Theme.scale(14)))
    local gap = m.card_gap

    local function fmt_date(ts)
        if not ts or ts <= 0 then return "" end
        return os.date("%d/%m %H:%M", ts)
    end

    return Scroll.scrolled_list(view, bb, chats, x, list_top, w, h - (list_top - y), scroll, row_h, gap,
        function(chat, cy, scrollable)
            local row_w = w - pad * 2 - (scrollable and gutter or 0)
            Widgets.row(view, bb, {
                x = x + pad, y = cy, w = row_w, h = row_h,
                icon = "chat",
                title = Widgets.sanitize(chat.name or "Chat"),
                subtitle = fmt_date(chat.modified)
                    .. ((chat.preview and chat.preview ~= "") and (" · " .. Widgets.truncate(chat.preview, 60)) or ""),
                chevron = true,
                on_tap = function() view.app:open_past_chat(chat) end,
                kebab = true,
                on_kebab = function()
                    Sheets.show(view.app, {
                        title = chat.name or _("Chat"),
                        actions = {
                            { label = _("Open"), icon = "forward", on_tap = function()
                                view.app:open_past_chat(chat)
                            end },
                            { label = _("Rename"), icon = "edit", on_tap = function()
                                view.app:rename_chat(chat.path, function() view.app:show_past_chats() end)
                            end },
                            { label = _("Export Chat"), icon = "upload", on_tap = function()
                                view.app:export_chat(chat.path)
                            end },
                            { label = _("Export TXT"), icon = "file", on_tap = function()
                                view.app:export_chat_txt(chat.path)
                            end },
                            { label = _("Delete"), icon = "trash", danger = true, on_tap = function()
                                view.app:delete_past_chat(chat)
                            end },
                        },
                    })
                end,
            })
        end)
end

-- === Chat ===
function Pages.chat(view, bb, x, y, w, h, scroll)
    -- Chat surface tint (ST SmartThemeChatTintColor analog): paper/gray/
    -- none - set in Appearance.
    P.rect(bb, x, y, w, h, Theme.chat_bg)

    local state = view.app.state
    local messages = state.messages or {}
    local char_name = state.current_character or "?"
    local is_generating = state.is_generating

    -- Deck bands (round 4, item 1): the composer is an absolute px band
    -- pinned at the bottom; the message list takes the rest (grow). Same
    -- contract as the settings pilot - the page declares, the deck lays.
    local Deck = require("ktui/deck")
    local rects = Deck.layout(view, {
        Deck.card("messages", { grow = true }),
        Deck.px("composer", Theme.scale(54)),
    }, { x = x, y = y, w = w, h = h })
    local action_bar_h = rects.composer.h
    local content_h = rects.messages.h
    local action_y = rects.composer.y
    local pad = Theme.scale(10)
    -- Swipe step (a few text lines - zenpm row parity).
    local ChatBubblesHead = require("ktui/chat_bubbles")
    local line_step = ChatBubblesHead.line_step()
    view.swipe_step = line_step * 8

    -- Message area - drawn BEFORE the action bar. The blitbuffer has no
    -- clipping, so paint order is the only guarantee that long messages can
    -- never draw over the bar; and because hitboxes are checked in reverse
    -- registration order, registering the bar's hitboxes after the bubbles'
    -- makes the bar win every tap at the bottom edge.
    local max_scroll = 0
    if #messages == 0 then
        if state.chat_first_mes and state.chat_first_mes ~= "" then
            local preview_y = y + Theme.scale(12)
            local bubble_w = math.min(math.floor(w * 0.85), w - pad * 4)
            P.box(bb, x + pad, preview_y, bubble_w, Theme.scale(60), {
                border_color = Theme.soft, radius = Theme.scale(6), background = Theme.panel,
            })
            P.text(bb, char_name, x + pad + Theme.scale(10), preview_y + Theme.scale(4), bubble_w - Theme.scale(20), "tiny", { bold = true })
            local preview = Widgets.truncate(state.chat_first_mes, 200)
            P.paragraph(bb, preview, x + pad + Theme.scale(10), preview_y + Theme.scale(22),
                        bubble_w - Theme.scale(20), Theme.scale(32), "default")
        else
            Widgets.empty_state(view, bb, {
                x = x, y = y, w = w, h = content_h,
                icon = "chat",
                text = _("Starting a new conversation. Tap Write to send a message!"),
            })
        end
        Scroll.set_list_bounds(view, x, y, w, content_h, content_h)
    else
        local ChatBubbles = require("ktui/chat_bubbles")
        local user_name = view.app._active_persona_name and view.app:_active_persona_name() or "You"
        local char_image = (state.current_character_data and state.current_character_data.png_path)
            or state.current_character_file
        local total_h = ChatBubbles.draw(view, bb, x, y, w, content_h, scroll, messages, char_name, is_generating, user_name, char_image, state.thinking_frame)

        -- Snap the scrollbar to whole lines so it never sits between rows
        Scroll.set_list_bounds(view, x, y, w, content_h, ChatBubbles.line_step())
        max_scroll = math.max(0, total_h - content_h)
    end

    -- Bottom action bar - drawn after the message area so it always paints
    -- on top, and its hitboxes win over the bubbles' (checked in reverse
    -- registration order). ST send-form: ☰ Options · ✎ Write · → Continue ·
    -- 🎭 Impersonate. All four cells are the SAME icon+label style (no
    -- primary pill: a solid-black pill reads as noise on e-ink and its swap
    -- to STOP painted misaligned). While generating, Write becomes ⃠ Stop
    -- and Continue/Impersonate disable.
    local btn_w = math.floor(w / 4)
    local btn_h = action_bar_h

    P.box(bb, x, action_y, w, btn_h, { border = false, background = Theme.panel })
    P.rect(bb, x, action_y, w, Theme.scale(1), Theme.soft)

    -- Cell helper: icon + label centered, muted when disabled.
    local function bar_cell(cell_x, icon, label, enabled, on_tap, hit_id)
        local color = enabled and Theme.ink or Theme.muted
        local icon_size = Theme.scale(13)
        local isz = Icons.text_size(icon, icon_size)
        local lsz = P.text_size(label, nil, "tiny", { bold = true })
        local content_w = isz.w + Theme.scale(6) + lsz.w
        local cx0 = cell_x + math.floor((btn_w - content_w) / 2)
        local cy0 = action_y + math.floor((btn_h - math.max(isz.h, lsz.h)) / 2)
        Icons.draw(bb, icon, cx0, cy0, icon_size, { color = color })
        P.text(bb, label, cx0 + isz.w + Theme.scale(6),
            action_y + math.floor((btn_h - lsz.h) / 2), lsz.w + 2, "tiny", { bold = true, color = color })
        if enabled then
            P.hit(view, cell_x, action_y, btn_w, btn_h, on_tap, hit_id)
        end
    end

    -- 1. Options
    bar_cell(x, "bars", _("Options"), true, function()
        view.app:show_chat_options()
    end, "chat_options")
    P.rect(bb, x + btn_w, action_y, Theme.scale(1), btn_h, Theme.soft)

    -- 2. Write / ⃠ Stop while generating - uniform cell, same metrics as
    --    the other three (the old primary pill + STOP box swap was the
    --    "torto" the user saw).
    if is_generating then
        bar_cell(x + btn_w, "ban", _("Stop"), true, function()
            view.app:stop_generation()
        end, "stop_gen")
    else
        bar_cell(x + btn_w, "edit", _("Write"), true, function()
            view.app:send_message()
        end, "chat_write")
    end
    P.rect(bb, x + btn_w * 2, action_y, Theme.scale(1), btn_h, Theme.soft)

    -- 3. Continue: nudge the last assistant reply, or - when the last
    -- message is the user's (interrupted before the reply came) - simply
    -- trigger the generation (ST resume behavior).
    local can_continue = not is_generating and #messages > 0
    bar_cell(x + btn_w * 2, "forward", _("Continue"), can_continue, function()
        local last = messages[#messages]
        if last and last.role == "assistant" then
            view.app:continue_message(#messages)
        else
            view.app:generate_reply()
        end
    end, "chat_continue")
    P.rect(bb, x + btn_w * 3, action_y, Theme.scale(1), btn_h, Theme.soft)

    -- 4. Impersonate
    bar_cell(x + btn_w * 3, "user", _("Impersonate"), not is_generating, function()
        view.app:impersonate()
    end, "chat_impersonate")

    return max_scroll
end

return Pages
