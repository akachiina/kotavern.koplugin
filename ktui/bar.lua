-- Shared bar button: icon + label stack, auto-sized to fit the bar height.
-- Used by the bottom nav bar and the dashboard toolbar so both render icons
-- at the same size and nothing ever overflows the bar (the symbols.ttf glyphs
-- render ~1.9× the requested font size, so every bar MUST size from measured
-- heights instead of fixed offsets).

local P = require("ktui/primitives")
local Theme = require("ktui/theme")
local Icons = require("ktui/icons")
local Widgets = require("ktui/widgets")

local Bar = {}

-- Draw one bar item. opts:
--   max_icon / min_icon : icon font size bounds (Theme.scale units)
--   indicator           : reserve the bottom band and draw the active bar
--   label_bottom        : anchor the label at the bottom of the bar
-- Returns the chosen icon font size (so callers can be consistent).
function Bar.item(view, bb, x, y, w, h, item, opts)
    opts = opts or {}
    local pad = Theme.scale(2)
    -- TextWidget's box height is the font's line height, but glyph ink covers
    -- the full font bbox and paints up to ~5px below the box (descenders +
    -- bbox descent). This margin is in constant pixels (font metrics don't
    -- scale with DPI) so labels never touch the indicator band or exit the bar.
    local desc_room = 6
    local indicator_h = opts.indicator and Theme.scale(3) or 0
    local label_h = item.label and Theme.line_h("chrome") or 0

    -- Largest icon font whose measured glyph row fits next to the label.
    local max_icon = opts.max_icon or Theme.scale(16)
    local min_icon = opts.min_icon or Theme.scale(8)
    local avail = h - indicator_h - pad * 2 - desc_room
    local icon_font = min_icon
    for s = max_icon, min_icon, -1 do
        local icon_h = Icons.text_size(item.icon, s).h
        if icon_h + label_h <= avail then
            icon_font = s
            break
        end
    end

    local stack_h = Icons.text_size(item.icon, icon_font).h + label_h
    local top = y + pad + math.max(0, math.floor((avail - stack_h) / 2))

    local color = item.active and Theme.ink or Theme.muted
    local label_w = 0  -- drawn label width (for the active underline)

    if item.label then
        -- Labels must fit their cell (P.center_text does not clip). The nav
        -- label uses the tiny face (bigger than chrome) for legibility and
        -- shrinks with an ellipsis only as a last resort.
        local max_lw = w - Theme.scale(4)
        local label, label_role = item.label, "tiny"
        if P.text_size(label, nil, "tiny").w > max_lw then
            label = Widgets.fit_text(label, max_lw, "tiny")
        end
        local label_h = Theme.line_h(label_role)
        label_w = P.text_size(label, nil, label_role).w
        local icon_row = Icons.text_size(item.icon, icon_font).h
        if opts.label_bottom then
            -- Anchor the label a descender-margin above the indicator band, so
            -- its glyphs never touch the indicator and never exit the bar.
            local ly = y + h - indicator_h - label_h - desc_room
            Icons.center(bb, item.icon, x, top, w, ly - top, icon_font, { color = color })
            P.center_text(bb, label, x, ly, w, label_h, label_role, { color = color })
        else
            Icons.center(bb, item.icon, x, top, w, icon_row, icon_font, { color = color })
            P.center_text(bb, label, x, top + icon_row, w, label_h, label_role, { color = color })
        end
    else
        Icons.center(bb, item.icon, x, y, w, h - indicator_h, icon_font, { color = color })
    end

    if opts.indicator and item.active then
        -- ZenPM-style underline: a 3px bar spanning exactly the drawn label's
        -- width, centered under the text (fallback: a centered half-width bar
        -- for label-less items).
        local lw = (label_w > 0) and label_w or math.floor(w * 0.5)
        P.rect(bb, x + math.floor((w - lw) / 2), y + h - indicator_h, lw, indicator_h, Theme.ink)
    end

    P.hit(view, x, y, w, h, item.cb, "bar:" .. tostring(item.label or item.icon))

    return icon_font
end

return Bar
