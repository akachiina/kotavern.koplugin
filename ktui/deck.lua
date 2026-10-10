-- Deck: band-based layout grid (ZenOS-style, round 4 item 1).
--
-- The problem the deck removes: every ktui page invents its own vertical
-- geometry (fit_row_h stretching, measured bands, fixed Theme metrics,
-- line-sum recalc). Four decision styles in one app drift apart on every
-- screen ratio. The deck makes the OPPOSITE contract:
--
--   * a page DECLARES bands in units (1 unit ≈ one touch row),
--   * the deck converts units -> pixel rects for the current viewport,
--   * leftover space is distributed by PRIORITY (a "grow" tag), never by
--     the page hand-stretching a box;
--   * a band that doesn't fit the capacity is dropped from the page's
--     first screen (page scrolls, capacity must never shrink on its own).
--
-- ZenOS reference: modules/filebrowser/patches/home/components/registry.lua
-- (SIZE_UNITS 1/2/3/4/10, capacityUnits by aspect ratio, gridHeights with
-- floor rounding + remainder redistribution). We keep the núcleo only:
-- no presets, no user reordering - our pages call with a fixed list.
--
-- Usage (pages):
--   local rects = Deck.layout(view, {
--       Deck.touch("footer"),        -- 1 unit
--       Deck.s("rows", { grow = true }),
--       Deck.px("banner", banner_h), -- absolute height (e.g. measured GIF)
--   }, { x = x, y = y, w = w, h = h })
--   rects.rows  -> { x, y, w, h } px
--
-- Invariants the smoke suite checks (uidsl4:*):
--   * heights sum <= band height, last flush band (no drift),
--   * grow receives the leftover, non-grow keeps exactly its requested px,
--   * px bands are never shrunk by distribution (only clamped by capacity),
--   * zero gap consumption when list fits exactly.

local Deck = {}

-- Unit table: 1 unit = a comfortable touch row. s/m/l scale from it so a
-- tweak in row height reflows the whole deck at once.
Deck.UNITS = {
    xs = 1, -- strip / ticker row
    touch = 1, -- settings/nav row
    s = 2, -- compact card
    m = 3, -- standard card
    l = 4, -- tall card
    xl = 10, -- hero (takes a whole default screen)
}

-- Capacity: how many units the body of a 4:3 listing viewport holds. Kept
-- reference-based (like ZenOS) but resolved from the REAL body height at
-- layout time - callers pass body_h, capacity is only a floor estimate for
-- validation and datarange defaults.
Deck.REF_BODY_UNITS = 10

-- Row stretch ceiling (fit_row_h): how much taller than its natural height
-- a fitted row may grow to close the viewport. 1.25 keeps tracking-feel
-- without the 1.6× balloon ("rows look bloated on tall screens").
Deck.ROW_STRETCH_CAP = 1.25

local function unit_px(view)
    local Theme = require("ktui/theme")
    local m = Theme.metrics()
    -- 1 unit: touch target floor, but generous enough to be the atomic
    -- scroll step of a list (ties into Scroll behavior).
    return math.max(m.touch_min, Theme.scale(48))
end

local function gap_px(view)
    local Theme = require("ktui/theme")
    return Theme.metrics().card_gap
end

-- Band spec constructors ----------------------------------------------------

-- Fixed-ish band in units (grows later if tagged grow = true)
function Deck.u(tag, units, opts)
    return { tag = tag, units = math.max(1, tonumber(units) or 1),
        grow = opts and opts.grow or false,
        max = opts and opts.max or nil }
end
Deck.touch = function(tag, opts) return Deck.u(tag, 1, opts) end
Deck.xs = function(tag, opts) return Deck.u(tag, 1, opts) end
Deck.card = function(tag, opts) return Deck.u(tag, 2, opts) end
Deck.s = function(tag, opts) return Deck.u(tag, 2, opts) end
Deck.m = function(tag, opts) return Deck.u(tag, 3, opts) end
Deck.l = function(tag, opts) return Deck.u(tag, 4, opts) end
Deck.xl = function(tag, opts) return Deck.u(tag, 10, opts) end

-- Absolute-px band (never reflows with unit changes): measured content
-- (GIF banner, island) declares its EXACT height here.
function Deck.px(tag, px_h)
    return { tag = tag, px = math.max(1, math.floor(tonumber(px_h) or 1)),
        grow = false }
end

-- Layout --------------------------------------------------------------------
-- Convert a band spec list into px rects for the current rect body. bands
-- that cannot fit the capacity are dropped FIRST (in list order) - pages
-- scroll; the deck never advertises a band smaller than its base unit.
function Deck.layout(view, bands, body)
    body = body or {}
    local bx = body.x or 0
    local by = body.y or 0
    local bw = body.w or 0
    local bh = body.h or 0
    local gap = gap_px(view)
    local unit = unit_px(view)

    local total_units, total_px = 0, 0
    for _, b in ipairs(bands or {}) do
        if b.px then
            total_px = total_px + b.px
        else
            total_units = total_units + b.units
        end
    end
    local total_gaps = math.max(0, #bands - 1) * gap
    -- Capacity cut: drop from the END (footers shouldn't starve list bands)
    -- unless grow bands are present, which absorb deficiency first.
    local over = (total_units * unit + total_px + total_gaps) - bh
    if over <= 0 then
        -- Fits exactly (or under): distribute leftover to grow bands by
        -- list order, capped at max.
        local leftover = -over
        local rects = {}
        local cy = by
        for _, b in ipairs(bands) do
            local h = b.px or (b.units * unit)
            if b.grow and not b.px and leftover > 0 then
                local want = b.max and (b.max - b.units * unit) or leftover
                local add = math.min(leftover, math.max(0, want))
                h = h + add
                leftover = leftover - add
            end
            if h > 0 then
                rects[b.tag] = { x = bx, y = cy, w = bw, h = h }
                cy = cy + h + gap
            end
        end
        return rects
    end

    -- Over capacity: subtract from grow bands first (they can shrink to
    -- base units); then drop non-grow bands from the list end.
    for i = #bands, 1, -1 do
        if over <= 0 then break end
        local b = bands[i]
        if b.grow and not b.px then
            local excess = b.units * unit - unit -- shrink to 1 unit min
            local cut = math.min(over, math.max(0, excess))
            b.units = b.units - cut / unit
            over = over - cut
        end
    end
    while over > 0 and #bands > 0 do
        local b = table.remove(bands) -- drop from the end
        local h = b.px or (b.units * unit)
        over = over - (h + gap)
    end

    -- Re-emit px rects with the shrunken/dropped list.
    local rects = {}
    local cy = by
    for _, b in ipairs(bands) do
        local h = b.px or (b.units * unit)
        if h > 0 then
            rects[b.tag] = { x = bx, y = cy, w = bw, h = math.floor(h) }
            cy = cy + math.floor(h) + gap
        end
    end
    return rects
end

-- Number of units the body fits (for pages that need to know capacity
-- before building their band list).
function Deck.capacity(view, body)
    local bh = (body and body.h) or 0
    local unit = unit_px(view)
    local gap = gap_px(view)
    -- Usable rows: floor((bh + gap) / (unit + gap)) - one gap is free at the end.
    return math.max(1, math.floor((bh + gap) / (unit + gap)))
end

-- GridHeights (ZenOS núcleo): given unit counts + a body height, produce
-- per-band pixel heights that fill the body EXACTLY (last band flush),
-- with floor rounding and remainder distributed to named recipients.
-- For lists that want px-exact stacking (scroll steps stay honest).
-- Returns heights in the SAME ORDER as unit_counts.
function Deck.grid_heights(unit_counts, body_h, gap, max_heights)
    local heights = {}
    local total = 0
    for _, u in ipairs(unit_counts or {}) do total = total + u end
    gap = math.max(0, math.floor(tonumber(gap) or 0))
    body_h = math.max(1, math.floor(tonumber(body_h) or 1))
    local usable = math.max(1, body_h - gap * math.max(0, #unit_counts - 1))
    local remaining = usable
    local used = 0
    for i, u in ipairs(unit_counts or {}) do
        local h = math.floor(usable * u / total + 0.5)
        if i == #unit_counts then
            h = remaining -- last band flush (absorbs the floor remainder)
        end
        local maximum = max_heights and tonumber(max_heights[i])
        if maximum and maximum > 0 and h > maximum then
            h = math.floor(maximum)
        end
        heights[i] = math.max(1, h)
        remaining = remaining - heights[i]
    end
    return heights
end

return Deck
