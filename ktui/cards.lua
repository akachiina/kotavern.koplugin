-- Character card rendering for the dashboard.
-- Grid card (SillyTavern-style: full-bleed cover, caption band with name,
-- tags and meta, favorite star) and list row (thumbnail + name + meta).

local P = require("ktui/primitives")
local Theme = require("ktui/theme")
local Icons = require("ktui/icons")
local Widgets = require("ktui/widgets")
local _ = require("gettext")

local Cards = {}

local function format_tokens(n)
    n = tonumber(n) or 0
    if n >= 1000 then
        return string.format("~%.1fk %s", n / 1000, _("tok"))
    end
    return "~" .. tostring(n) .. " " .. _("tok")
end

-- Tags as one inline text line: "# female, human, ..." (chip font, muted).
local function tags_text(tags)
    local parts = {}
    for _, t in ipairs(tags or {}) do
        local tag = tostring(t)
        if tag ~= "" then
            table.insert(parts, tag)
        end
    end
    if #parts == 0 then
        return ""
    end
    return "# " .. table.concat(parts, ", ")
end

-- Meta line: token estimate (+ creator when present). Version is intentionally
-- not shown (it is metadata, not content sent to the LLM).
local function meta_text(item)
    local parts = {}
    if item.tokens and item.tokens > 0 then
        table.insert(parts, format_tokens(item.tokens))
    end
    if item.creator and item.creator ~= "" then
        table.insert(parts, item.creator)
    end
    return table.concat(parts, " · ")
end

-- Grid card (SillyTavern-style): full-bleed cover - the image IS the card -
-- with a caption band at the bottom (name, tags, meta) overlaid on it.
-- What to show (name/tags/meta/star) and the band style come from the
-- Settings → Dashboard page (dashboard_show_* / dashboard_caption).
function Cards.character(view, bb, item, x, y, w, h)
    local pad = Theme.scale(8)
    local inner_w = w - pad * 2
    local settings = (view.app and view.app.state and view.app.state.settings) or {}
    local show_covers = settings.show_covers ~= false
    local show_name = settings.dashboard_show_name ~= false
    local show_tags = settings.dashboard_show_tags ~= false
    local show_meta = settings.dashboard_show_meta ~= false
    -- "always" = outline star when not favorite (tap to toggle), filled when
    -- favorite; "fav" = only when favorite; "none" = hidden. Old settings
    -- files with dashboard_show_star=false map to "none".
    local star_mode = settings.dashboard_star
        or (settings.dashboard_show_star == false and "none" or "always")
    local caption = settings.dashboard_caption or "soft"

    -- Full-bleed cover: cover-fit (fills the whole card, cropping the
    -- overflow - no white bars), rounded fallback with the initial when
    -- there is no image (or covers are disabled).
    local has_image = false
    if show_covers and item.path and item.path:lower():match("%.png$") then
        has_image = P.image(bb, item.path, x, y, w, h, { cover = true })
    end
    if not has_image then
        P.rounded_rect(bb, x, y, w, h, Theme.soft, math.floor(Theme.metrics().radius))
        local initial = Widgets.first_glyph(item.name or "?"):upper()
        P.center_text_box(bb, initial, x, y, w, h - Theme.scale(40), "heading", { bold = true })
    end

    -- Caption band at the bottom. Iterated 4× with the user: a solid
    -- Theme.soft block covers the art ("bloco cinza"), no backdrop makes the
    -- text illegible over busy art, lighten 0.4 too transparent. Final:
    -- "soft" = lighten 0.7 (art faintly visible, text readable). "solid" and
    -- "none" are opt-in via Settings → Dashboard.
    local line_small = Theme.line_h("small")
    local line_tiny = Theme.line_h("tiny")
    local line_chip = Theme.line_h("chip")
    local meta = show_meta and meta_text(item) or ""
    local tags = show_tags and tags_text(item.tags) or ""

    local band_h = Theme.scale(8) -- top + bottom pads
    if show_name then
        band_h = band_h + line_small
    end
    if tags ~= "" then
        band_h = band_h + line_chip + Theme.scale(2)
    end
    if meta ~= "" then
        band_h = band_h + line_tiny + Theme.scale(2)
    end

    local band_y = y + h - band_h
    if band_h > 0 and caption ~= "none" then
        if caption == "solid" or Theme.get_theme() == "inverted" then
            P.rect(bb, x, band_y, w, band_h, Theme.soft)
        else
            P.dim(bb, x, band_y, w, band_h, 0.7)
        end
    end

    local cy = band_y + Theme.scale(4)
    if show_name then
        P.text(bb, item.display_name or item.name or "?", x + pad, cy, inner_w, "small", { bold = true })
        cy = cy + line_small + Theme.scale(2)
    end
    if tags ~= "" then
        P.text(bb, tags, x + pad, cy, inner_w, "chip", { color = Theme.muted })
        cy = cy + line_chip + Theme.scale(2)
    end
    if meta ~= "" then
        P.text(bb, meta, x + pad, cy, inner_w, "tiny", { color = Theme.muted })
    end

    -- Full-card hitbox FIRST: hitboxes are checked in reverse registration
    -- order, so the star badge below must come after it to win its corner.
    P.hit(view, x, y, w, h, function()
        view.app:show_character_actions(item)
    end, "char:" .. tostring(item.path))

    -- Favorite star over the cover: always visible in "always" mode (outline
    -- when not favorite), only when favorite in "fav" mode. ZenPM-style solid
    -- disc (ink circle, inverted icon) keeps it legible over any art.
    if star_mode ~= "none" and (star_mode == "always" or item.fav) then
        local badge = Theme.scale(30)
        local bx = x + w - Theme.scale(6) - badge
        local by = y + Theme.scale(6)
        P.box(bb, bx, by, badge, badge, {
            border = false,
            background = Theme.ink,
            radius = math.floor(badge / 2),
        })
        -- Star ink is black: invert it over the dark disc on the light theme.
        Icons.center(bb, item.fav and "star" or "star-empty", bx, by, badge, badge, Theme.scale(9),
            { invert = Theme.get_theme() ~= "inverted" })
        P.hit(view, bx, by, badge, badge, function()
            view.app:toggle_favorite(item)
        end, "fav:" .. tostring(item.path))
    end

    -- Frame on top of everything so borders stay crisp over the cover
    P.stroke(bb, x, y, w, h, math.max(1, Theme.scale(1)), Theme.soft)
end

-- List row: thumbnail + name + tags line + meta line (tokens · creator),
-- optional right-side action buttons. Action buttons are registered after
-- the row hitbox so they win.
function Cards.list_item(view, bb, item, x, y, w, h, actions)
    P.box(bb, x, y, w, h, {
        border_color = Theme.soft,
        radius = Theme.scale(4),
        background = Theme.panel,
    })

    local thumb = Theme.scale(40)
    local pad = Theme.scale(8)
    local has_image = false
    if item.path and item.path:lower():match("%.png$") then
        has_image = P.image(bb, item.path, x + pad, y + math.floor((h - thumb) / 2), thumb, thumb)
    end
    if not has_image then
        local initial = Widgets.first_glyph(item.name or "?"):upper()
        P.rounded_rect(bb, x + pad, y + math.floor((h - thumb) / 2), thumb, thumb, Theme.soft, math.floor(thumb / 2))
        P.center_text_box(bb, initial, x + pad, y + math.floor((h - thumb) / 2), thumb, thumb, "small", { bold = true })
    end

    local actions_w = actions and #actions * Theme.scale(36) or 0
    local text_x = x + pad * 2 + thumb
    local text_w = w - pad * 3 - thumb - actions_w - Theme.scale(12)
    if item.fav then
        text_w = text_w - Theme.scale(18)
    end

    -- Rich mode (dashboard): name + tags (# a, b, ...) + meta (tokens ·
    -- creator). Legacy mode (chats page passes subtext/meta): name + one
    -- combined summary line, so its rows keep their compact height.
    local settings = (view.app and view.app.state and view.app.state.settings) or {}
    local show_tags = settings.dashboard_show_tags ~= false
    local show_meta = settings.dashboard_show_meta ~= false
    local tags = show_tags and tags_text(item.tags) or ""
    local legacy = (item.subtext and item.subtext ~= "") or (item.meta and item.meta ~= "")
    local line_name = Theme.line_h("small")

    if legacy then
        local summary = item.subtext
        if item.meta and item.meta ~= "" then
            summary = (summary and summary ~= "" and (summary .. " · " .. item.meta)) or item.meta
        end
        local line_tiny = Theme.line_h("tiny")
        local block_h = line_name + Theme.scale(2) + line_tiny
        local top = y + math.max(Theme.scale(2), math.floor((h - block_h) / 2))
        P.text(bb, item.display_name or item.name or "?", text_x, top, text_w, "small", { bold = true })
        P.text(bb, summary or "", text_x, top + line_name + Theme.scale(2), text_w, "tiny", { color = Theme.muted })
    else
        local line_chip = Theme.line_h("chip")
        local line_tiny = Theme.line_h("tiny")
        local meta = (show_meta and meta_text(item) ~= "" and meta_text(item)) or ""
        local block_h = line_name + Theme.scale(2) + line_chip + Theme.scale(2) + line_tiny
        local top = y + math.max(Theme.scale(2), math.floor((h - block_h) / 2))
        P.text(bb, item.display_name or item.name or "?", text_x, top, text_w, "small", { bold = true })
        local cy = top + line_name + Theme.scale(2)
        if tags ~= "" then
            P.text(bb, tags, text_x, cy, text_w, "chip", { color = Theme.muted })
        end
        cy = cy + line_chip + Theme.scale(2)
        if meta ~= "" then
            P.text(bb, meta, text_x, cy, text_w, "tiny", { color = Theme.muted })
        end
    end

    -- Favorite star: center by the REAL painted size (Icons.text_size covers
    -- the 2x SVG raster and the glyph fallback). Centering by the requested
    -- size leaves the ink hanging below center ("torta").
    if item.fav then
        local isz = Icons.text_size("star", Theme.scale(14))
        local bx = x + w - pad - isz.w - actions_w
        local by = y + math.floor((h - isz.h) / 2)
        Icons.draw(bb, "star", bx, by, Theme.scale(14), { color = Theme.ink })
        P.hit(view, bx, by, isz.w, isz.h, function()
            view.app:toggle_favorite(item)
        end, "favlist:" .. tostring(item.name or item.path or ""))
    end

    P.hit(view, x, y, w, h, function()
        if item.callback then
            item.callback()
        elseif item.path then
            view.app:show_character_actions(item)
        end
    end, "list_item:" .. tostring(item.name or item.path or ""))

    if actions then
        local btn_s = Theme.scale(36)
        for i, a in ipairs(actions) do
            local bx = x + w - pad - btn_s * (#actions - i + 1)
            P.box(bb, bx, y + math.floor((h - btn_s) / 2), btn_s, btn_s, { border = false })
            Icons.center(bb, a.icon, bx, y + math.floor((h - btn_s) / 2), btn_s, btn_s, Theme.scale(18), { color = Theme.muted })
            P.hit(view, bx, y, btn_s, h, a.callback, "list_action:" .. tostring(a.icon) .. ":" .. tostring(item.name or ""))
        end
    end
end

function Cards.compact(view, bb, item, x, y, w, h, icon)
    -- Compact card for recent chats, etc.
    P.box(bb, x, y, w, h, {
        border = false,
        background = Theme.panel,
    })
    P.rect(bb, x, y + h - 1, w, 1, Theme.soft)

    if icon then
        P.text(bb, icon, x + Theme.scale(10), y + Theme.scale(10), Theme.scale(24), "small")
    end

    local text_x = x + (icon and Theme.scale(40) or Theme.scale(10))
    local label = item.text or item.name or "?"
    if item.subtext then
        P.text(bb, label, text_x, y + Theme.scale(6), w - text_x - Theme.scale(10), "small", { bold = true })
        P.text(bb, item.subtext, text_x, y + Theme.scale(22), w - text_x - Theme.scale(10), "tiny", { color = Theme.muted })
    else
        P.vcenter_text(bb, label, text_x, y, w - text_x - Theme.scale(10), h, "small")
    end

    P.hit(view, x, y, w, h, function()
        if item.callback then item.callback() end
    end, "compact:" .. tostring(item.name or ""))
end

return Cards
