-- KtBookSheet: the painted action sheet for book mode.
--
-- The canvas sheets (ktui/sheets.lua) paint into the plugin's app view, which
-- is NOT on the window stack while the native reader is up - so book mode
-- gets its own standalone widget. It is shown via UIManager:show() directly
-- (topmost window), painted with the same primitives as the canvas UI
-- (P/Theme/Icons) so the look matches, and handles its own taps and swipes
-- through touch zones.
--
-- Layout mirrors ktui/sheets.lua: bottom panel, small muted title, optional
-- message paragraph, section headers + action rows with SVG icons, a slim
-- scrollbar when content overflows, and a Cancel button. Tap outside the
-- panel (or Cancel, or swipe down at the top) dismisses. No emoji: the row
-- icons are the plugin's own SVG assets.

local UIManager = require("ui/uimanager")
local InputContainer = require("ui/widget/container/inputcontainer")
local Geom = require("ui/geometry")
local logger = require("logger")
local P = require("ktui/primitives")
local Theme = require("ktui/theme")
local Icons = require("ktui/icons")
local Widgets = require("ktui/widgets")

local BookSheet = InputContainer:extend{
    name = "kotavern_booksheet",
    -- Pre-translated strings (set by the caller).
    title = nil,
    text = nil,
    cancel_label = nil,
    -- { { title = "...", actions = { { label, icon, cb, enabled } } } }
    sections = nil,
    scroll = 0,
}

-- Only one sheet can exist at a time (the reader can only ever be covered by
-- one); static so a stale instance is always dropped before a new show().
local current = nil

function BookSheet:init()
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Theme.metrics().screen_w,
        h = Theme.metrics().screen_h,
    }
    self.covers_fullscreen = true
    self.modal = true
    -- MODAL CONTRACT: consume EVERY gesture while the sheet is up.
    -- InputContainer:onGesture only stops propagation when a registered
    -- touch zone matches the gesture TYPE - gestures we do not register
    -- (double_tap, pinch, spread, hold_release, pan_release, multiswipe,
    -- two_finger_*) would otherwise fall through the window stack and reach
    -- the reader underneath (page turns, highlight menus, Gestures-plugin
    -- actions like "close book"). That was the reported "taps sometimes
    -- send me back to the plugin" leak. stop_events_propagation closes it.
    self.stop_events_propagation = true
    -- Hit rects are rebuilt on every paint; taps walk them in REVERSE order
    -- (last registered wins, same dispatch contract as the canvas hitboxes).
    self._hits = {}
    self:registerTouchZones({
        {
            id = "kt_sheet_tap",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges) return self:onTap(ges) end,
        },
        {
            id = "kt_sheet_swipe",
            ges = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges) return self:onSwipe(ges) end,
        },
        -- Pan / hold are swallowed while the sheet is modal (they would
        -- otherwise fall through to the reader underneath: partial page
        -- pans, highlight long-press menus).
        {
            id = "kt_sheet_pan",
            ges = "pan",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function() return true end,
        },
        {
            id = "kt_sheet_hold",
            ges = "hold",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function() return true end,
        },
    })
end

-- Small vertical drifts (fat-fingered taps) must not dismiss: a real close
-- gesture is a deliberate flick. GestureDetector reports swipe distance in
-- pixels.
local SWIPE_MIN = 40

function BookSheet:dismiss()
    if current == self then current = nil end
    logger.info("kotavern/sheet: dismiss")
    UIManager:close(self)
end

function BookSheet:onTap(ges)
    local pos = ges and ges.pos
    if not pos then return true end
    for i = #self._hits, 1, -1 do
        local hit = self._hits[i]
        if P.contains(hit, pos.x, pos.y) then
            logger.info("kotavern/sheet: row tap at y=", pos.y)
            hit.cb()
            return true
        end
    end
    -- Missed every hit: outside the panel dismisses (tap-anywhere-to-close);
    -- a tap on empty panel space is swallowed (the sheet is modal, the
    -- reader must not turn the page underneath it).
    local g = self._geom
    if g and (pos.x < g.px or pos.x > g.px + g.pw or pos.y < g.py or pos.y > g.py + g.ph) then
        self:dismiss()
    end
    return true
end

function BookSheet:onSwipe(ges)
    local direction = ges and ges.direction
    local distance = tonumber(ges and ges.distance) or 0
    local max_scroll = self._max_scroll or 0
    local step = math.floor((self._list_h or Theme.scale(200)) * 0.8)
    if direction == "north" then
        if max_scroll > 0 then
            self.scroll = math.min(max_scroll, (self.scroll or 0) + step)
            UIManager:setDirty(self, "partial")
        end
        return true
    elseif direction == "south" then
        if (self.scroll or 0) <= 0 then
            if distance >= SWIPE_MIN then
                self:dismiss()
            end
        else
            self.scroll = math.max(0, (self.scroll or 0) - step)
            UIManager:setDirty(self, "partial")
        end
        return true
    end
    -- Horizontal swipes: swallowed while modal (no page turns under the
    -- sheet).
    return true
end

-- Slim scrollbar affordance (copy of the canvas sheets' painter).
local function paint_scrollbar(bb, px, pw, pad, list_top, list_bottom,
    scroll, max_scroll)
    if max_scroll <= 0 then return end
    local band_h = list_bottom - list_top
    if band_h <= 0 then return end
    local track_x = px + pw - pad - Theme.scale(7)
    local track_w = Theme.scale(7)
    P.rect(bb, track_x, list_top, track_w, band_h, Theme.soft)
    local total = max_scroll + band_h
    local thumb_h = math.max(Theme.scale(12),
        math.floor(band_h * band_h / math.max(1, total)))
    thumb_h = math.min(band_h, thumb_h)
    local travel = band_h - thumb_h
    local thumb_y = list_top
        + (travel > 0 and math.floor(travel * scroll / max_scroll) or 0)
    P.rect(bb, track_x, thumb_y, track_w, thumb_h, Theme.ink)
end

function BookSheet:paintTo(bb, offx, offy)
    self._hits = {}
    local m = Theme.metrics()
    local sw, sh = m.screen_w, m.screen_h
    local margin = Theme.scale(14)
    local pad = Theme.scale(12)
    local px = margin
    local pw = sw - margin * 2

    local title_h = self.title and self.title ~= ""
        and (Theme.line_h("small") + Theme.scale(14)) or Theme.scale(6)
    local text_h = 0
    if self.text and self.text ~= "" then
        text_h = P.paragraph_height(self.text, pw - pad * 2, "small")
            + Theme.scale(10)
    end

    local row_h = math.max(Theme.scale(46), Theme.line_h("default") + Theme.scale(18))
    local sec_h = Theme.line_h("tiny") + Theme.scale(14)
    local btn_h = Theme.btn_h()
    local total_h = 0
    for i = 1, #self.sections do
        total_h = total_h + sec_h + #self.sections[i].actions * row_h
    end

    -- Keep the panel within ~72% of the screen height.
    local max_ph = math.floor(sh * 0.72)
    local needed = title_h + text_h + total_h + btn_h + Theme.scale(24)
    local ph = math.min(needed, max_ph)
    local py = sh - ph - Theme.scale(10)
    self._geom = { px = px, py = py, pw = pw, ph = ph }

    P.scrim(bb, 0, 0, sw, sh, 0.3)
    P.box(bb, px, py, pw, ph, {
        border = true, border_size = 1, border_color = Theme.soft,
        background = Theme.panel, radius = Theme.scale(10),
    })

    local cy = py + Theme.scale(6)

    if self.title and self.title ~= "" then
        P.text(bb, Widgets.sanitize(self.title), px + pad, cy, pw - pad * 2,
            "small", { bold = true, color = Theme.muted })
        cy = cy + title_h
    end

    if text_h > 0 then
        P.paragraph(bb, self.text, px + pad, cy, pw - pad * 2,
            text_h - Theme.scale(10), "small", { color = Theme.muted })
        cy = cy + text_h
    end

    -- Content band: scrollable region of section headers + action rows.
    local list_top = cy
    local list_bottom = py + ph - Theme.scale(12) - btn_h
    local list_h = math.max(row_h, list_bottom - list_top)
    local max_scroll = math.max(0, total_h - list_h)
    self._max_scroll = max_scroll
    self._list_h = list_h
    local scroll = math.min(self.scroll or 0, max_scroll)
    self.scroll = scroll
    local scrollable = max_scroll > 0
    local gutter = scrollable and (Theme.scale(7) + Theme.scale(4)) or 0

    P.rect(bb, px + 1, list_top - (scroll > 0 and Theme.scale(6) or 0),
        pw - 2, list_h + (scroll > 0 and Theme.scale(6) or 0), Theme.panel)
    local ay = list_top - scroll
    for si = 1, #self.sections do
        local sec = self.sections[si]
        -- Section header (non-clickable).
        if ay + sec_h > list_top and ay < list_bottom then
            P.text(bb, Widgets.sanitize(sec.title or ""), px + pad, ay,
                pw - pad * 2 - gutter, "tiny", { bold = true, color = Theme.muted })
        end
        ay = ay + sec_h
        for ai = 1, #sec.actions do
            local action = sec.actions[ai]
            -- Strict culling: partially visible rows are skipped (same rule
            -- as the canvas sheets - ink never bleeds over title or button).
            if ay >= list_top and ay + row_h <= list_bottom + 1 then
                local enabled = action.enabled ~= false
                local color = (not enabled) and Theme.muted
                    or (action.danger and Theme.danger or Theme.ink)
                local tx = px + pad
                local text_right = px + pw - pad - Theme.scale(30) - gutter
                if action.icon then
                    local icon_size = Theme.scale(13)
                    local isz = Icons.text_size(action.icon, icon_size)
                    Icons.draw(bb, action.icon, tx,
                        ay + math.floor((row_h - isz.h) / 2), icon_size,
                        { color = color })
                    tx = tx + isz.w + Theme.scale(12)
                end
                local label_w = text_right - tx
                P.vcenter_text(bb, Widgets.sanitize(action.label), tx, ay,
                    label_w, row_h, "default",
                    { bold = enabled, color = color })
                if enabled then
                    local cb = action.cb
                    table.insert(self._hits, {
                        x = px + 1, y = ay, w = pw - 2, h = row_h,
                        cb = function()
                            self:dismiss()
                            if cb then cb() end
                        end,
                    })
                end
            end
            ay = ay + row_h
        end
    end

    paint_scrollbar(bb, px, pw, pad, list_top, list_bottom, scroll, max_scroll)

    -- Cancel button (bottom, full width).
    local by = list_bottom
    P.box(bb, px + pad, by, pw - pad * 2, btn_h, {
        border = true, border_size = 1, border_color = Theme.soft,
        background = Theme.panel, radius = Theme.scale(6),
    })
    P.center_text_box(bb, self.cancel_label or "Cancel", px + pad, by,
        pw - pad * 2, btn_h, "default", { color = Theme.ink })
    table.insert(self._hits, {
        x = px + pad, y = by, w = pw - pad * 2, h = btn_h,
        cb = function() self:dismiss() end,
    })
end

-- Show a sheet. `opts`: { title, text, cancel_label, sections }.
function BookSheet.show(opts)
    opts = opts or {}
    if current then
        pcall(function() UIManager:close(current) end)
        current = nil
    end
    current = BookSheet:new{
        title = opts.title,
        text = opts.text,
        cancel_label = opts.cancel_label,
        sections = opts.sections or {},
    }
    UIManager:show(current)
    return current
end

-- True when a sheet is on screen (guards against stacking).
function BookSheet.is_open()
    return current ~= nil
end

return BookSheet
