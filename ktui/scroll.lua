-- Scrollable list engine + scrollbar drag for AppView.
-- Copied from ZenPM (zenpm.koplugin/ui/scroll.lua)

local Device = require("device")
local P = require("ktui/primitives")
local Theme = require("ktui/theme")
local Screen = Device.screen

local Scroll = {}

local function snap_scroll(value, step, max_scroll)
    if step and step > 0 then
        value = math.floor(value / step + 0.5) * step
    end
    return math.max(0, math.min(value, max_scroll))
end

function Scroll.set_list_bounds(view, x, y, w, h, step)
    view.list_bounds = { x = x, y = y, w = w, h = h }
    view.scroll_step = step
end

function Scroll.draw_scrollbar(view, bb, max_scroll, scroll)
    if not view.list_bounds or not max_scroll or max_scroll <= 0 then
        return
    end
    local b = view.list_bounds
    local margin = Theme.scale(9)
    local track_w = math.max(Theme.scale(1), 1)
    local thumb_w = math.max(Theme.scale(7), track_w + 2)
    local touch_w = math.max(Theme.scale(28), 28)
    local thumb_x = b.x + b.w - margin - thumb_w
    local track_x = thumb_x + math.floor((thumb_w - track_w) / 2)
    local track_y = b.y + margin
    local track_h = b.h - margin * 2
    if track_h <= Theme.scale(24) then
        return
    end

    scroll = math.max(0, math.min(scroll or 0, max_scroll))
    local total_h = max_scroll + b.h
    local thumb_h = math.max(Theme.scale(28), math.floor(track_h * b.h / total_h))
    thumb_h = math.min(track_h, thumb_h)
    local travel = track_h - thumb_h
    local thumb_y = track_y
    if travel > 0 then
        thumb_y = track_y + math.floor(travel * scroll / max_scroll)
    end

    -- Draw track and thumb
    P.rounded_rect(bb, track_x, track_y, track_w, track_h, Theme.ink, math.floor(track_w / 2))
    P.rounded_rect(bb, thumb_x, thumb_y, thumb_w, thumb_h, Theme.ink, math.floor(thumb_w / 2))

    view.scrollbar = {
        zone = { x = thumb_x - touch_w + thumb_w, y = b.y, w = touch_w, h = b.h },
        track_x = track_x,
        track_y = track_y,
        track_w = track_w,
        track_h = track_h,
        thumb_x = thumb_x,
        thumb_w = thumb_w,
        thumb_h = thumb_h,
        travel = travel,
        max_scroll = max_scroll,
        step = view.scroll_step,
        region = { x = b.x, y = b.y, w = b.w, h = b.h },
        _thumb_y = thumb_y,
    }

    P.hit(view, thumb_x - touch_w + thumb_w, b.y, touch_w, b.h, function(_, tap_y)
        if travel <= 0 then
            return
        end
        local ratio = (tap_y - track_y - math.floor(thumb_h / 2)) / travel
        ratio = math.max(0, math.min(1, ratio))
        view.app.state.scroll[view.app:scroll_key()] =
            snap_scroll(max_scroll * ratio, view.scroll_step, max_scroll)
        view:refresh()
    end, "scrollbar")
end

function Scroll.apply_y(view, pos_y)
    local sb = view.scrollbar
    if not sb or sb.travel <= 0 then
        return false
    end
    local ratio = (pos_y - sb.track_y - math.floor(sb.thumb_h / 2)) / sb.travel
    ratio = math.max(0, math.min(1, ratio))
    local key = view.app:scroll_key()
    local new_scroll = snap_scroll(sb.max_scroll * ratio, sb.step, sb.max_scroll)
    if new_scroll == view.app.state.scroll[key] then
        return false
    end
    view.app.state.scroll[key] = new_scroll
    return true
end

function Scroll.paint_drag_thumb(view, pos_y)
    local sb = view.scrollbar
    if not sb or sb.travel <= 0 then
        return nil
    end
    local thumb_y = math.max(sb.track_y,
        math.min(sb.track_y + sb.travel, pos_y - math.floor(sb.thumb_h / 2)))
    local prev_y = sb._thumb_y
    if prev_y == thumb_y then
        return nil
    end
    local function thumb_rect(ty)
        local pad = 1
        local top = math.max(sb.track_y, ty - pad)
        local bottom = math.min(sb.track_y + sb.track_h, ty + sb.thumb_h + pad)
        return { x = sb.thumb_x, y = top, w = sb.thumb_w, h = bottom - top }
    end

    local rects = { thumb_rect(thumb_y) }
    if prev_y then
        table.insert(rects, thumb_rect(prev_y))
    end

    for _i = 1, #rects do
        local rect = rects[_i]
        P.rect(Screen.bb, rect.x, rect.y, rect.w, rect.h, Theme.bg)
    end
    P.rounded_rect(Screen.bb, sb.track_x, sb.track_y, sb.track_w, sb.track_h, Theme.ink, math.floor(sb.track_w / 2))
    P.rounded_rect(Screen.bb, sb.thumb_x, thumb_y, sb.thumb_w, sb.thumb_h, Theme.ink, math.floor(sb.thumb_w / 2))
    sb._thumb_y = thumb_y

    return rects
end

function Scroll.scrolled_list(view, bb, items, x, y, w, h, scroll, item_h, gap, draw_item)
    Scroll.set_list_bounds(view, x, y, w, h, item_h + gap)
    P.rect(bb, x, y, w, h, Theme.bg)
    local total_h = 0
    for _ in ipairs(items or {}) do
        total_h = total_h + item_h + gap
    end
    if #(items or {}) > 0 then
        total_h = total_h - gap
    end
    local step = item_h + gap
    local max_scroll = math.max(0, total_h - h)
    if max_scroll > 0 then
        max_scroll = math.ceil(max_scroll / step) * step
    end
    scroll = snap_scroll(scroll or 0, step, max_scroll)
    if view.app and view.app.state and view.app.state.scroll and view.app.scroll_key then
        view.app.state.scroll[view.app:scroll_key()] = scroll
    end
    local scrollable = max_scroll > 0
    local cy = y - scroll
    for _, item in ipairs(items or {}) do
        -- Draw every item INTERSECTING the viewport (like scrolled_list_var):
        -- strict full-containment left a blank band up to one row tall at the
        -- bottom whenever list_h mod (item_h+gap) ~= 0. Partial bleed is fine:
        -- header/nav/action-bar chrome paints over it opaquely afterwards.
        if cy + item_h > y and cy < y + h then
            draw_item(item, cy, scrollable)
        end
        cy = cy + item_h + gap
    end
    return max_scroll
end

-- Scrolled list with PER-ITEM heights (items carry .h). Scroll snaps to the
-- nearest item start. Items intersecting the viewport are drawn (partial rows
-- bleed under the header/nav, which paint over them opaquely).
function Scroll.scrolled_list_var(view, bb, items, x, y, w, h, scroll, gap, draw_item)
    Scroll.set_list_bounds(view, x, y, w, h, nil)
    P.rect(bb, x, y, w, h, Theme.bg)
    local offs = { [1] = 0 }
    local total_h = 0
    for i, item in ipairs(items or {}) do
        total_h = offs[i] + (item.h or 0)
        offs[i + 1] = total_h + (gap or 0)
    end
    local max_scroll = math.max(0, total_h - h)
    -- Snap to the nearest item start (binary search over offsets)
    scroll = math.max(0, math.min(scroll or 0, max_scroll))
    if max_scroll > 0 then
        local lo, hi = 1, #offs
        while lo < hi do
            local mid = math.floor((lo + hi) / 2)
            if offs[mid] <= scroll then lo = mid + 1 else hi = mid end
        end
        local best = offs[lo]
        if lo > 1 and math.abs(offs[lo - 1] - scroll) < math.abs(best - scroll) then
            best = offs[lo - 1]
        end
        scroll = math.min(best, max_scroll)
    end
    if view.app and view.app.state and view.app.state.scroll and view.app.scroll_key then
        view.app.state.scroll[view.app:scroll_key()] = scroll
    end
    local scrollable = max_scroll > 0
    for i, item in ipairs(items or {}) do
        local cy = y + offs[i] - scroll
        local ih = item.h or 0
        if cy + ih > y and cy < y + h then
            draw_item(item, cy, scrollable)
        end
    end
    return max_scroll
end

return Scroll
