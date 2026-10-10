-- ktui/geom.lua: pure layout math. ZERO requires (no device, widgets or
-- theme): every pixel number arrives as an argument, so this file unit-tests
-- with plain lua, headless, no KOReader runtime. Paint code measures, calls
-- here, paints. New geometry lives HERE; paint files only call.
-- (Pattern ported from bookshelf.koplugin's ListGeom/BandMetrics split:
-- one pure module + one thin adapter that injects settings/screen numbers.)

local Geom = {}

--- Centered offset of a `block_h` block inside `h` (never above `min_top`,
--- default 0). Every "center this stack in this box" site uses this one
--- floor rule instead of hand-rolled variants that drift by 1px.
function Geom.center_offset(h, block_h, min_top)
    return math.max(min_top or 0, math.floor(((h or 0) - (block_h or 0)) / 2))
end

--- Vertical text stack. `lines` = array of { h = px } (ONE entry per ENABLED
--- line: fixed slots keep siblings aligned; missing content paints "" but
--- keeps its slot). Returns block_h (pads included, no trailing gap) and
--- ys[i] relative to the block top.
function Geom.stack(lines, gap, pad)
    gap = gap or 0
    pad = pad or 0
    local ys, y = {}, pad
    for i, ln in ipairs(lines or {}) do
        ys[i] = y
        y = y + (ln.h or 0) + gap
    end
    local n = #(lines or {})
    local block_h = 2 * pad
    if n > 0 then
        block_h = block_h + (y - pad - gap)
    end
    return block_h, ys
end

--- Split `total` px over `n` slots differing by at most 1px (floor remainder
--- spread 1px over the FIRST slots, never dumped on the last). Returns the
--- widths array (sums exactly to `total`).
function Geom.distribute_remainder(total, n)
    total = math.max(0, math.floor(total or 0))
    n = math.max(1, math.floor(n or 1))
    local base = math.floor(total / n)
    local rem = total - base * n
    local widths = {}
    for i = 1, n do
        widths[i] = base + (i <= rem and 1 or 0)
    end
    return widths
end

--- Largest icon size in [min_s, max_s] whose measured height plus `label_h`
--- fits `avail`. `measure_h(s)` is injected (e.g. Icons.text_size(name, s).h)
--- so this stays pure. Iterates down like the hand-rolled loops it replaces.
function Geom.fit_icon(avail, label_h, min_s, max_s, measure_h)
    min_s = math.max(1, math.floor(min_s or 1))
    max_s = math.max(min_s, math.floor(max_s or min_s))
    local picked = min_s
    for s = max_s, min_s, -1 do
        if measure_h(s) + (label_h or 0) <= (avail or 0) then
            picked = s
            break
        end
    end
    return picked
end

--- Right-to-left slot composition (row right strips, toolbar clusters...).
--- `slots` = widths in layout order (first = rightmost). Returns xs[i] (left
--- edges) and text_right (cursor after the last slot: where content ends).
--- Example: row_slots(w, pad, { kebab=34, toggle=52 }) places the toggle
--- left of the kebab and reports where the title/value must stop.
function Geom.row_slots(total_w, pad, slots)
    local cursor = (total_w or 0) - (pad or 0)
    local xs = {}
    for i, sw in ipairs(slots or {}) do
        cursor = cursor - (sw or 0)
        xs[i] = cursor
    end
    return xs, cursor
end

--- Dashboard grid cap: the desired height capped at what fills exactly 2
--- rows (so 6 cards fit with zero scroll on any screen), never below the
--- readability floor. Depends on the viewport, never on the item count, so
--- sizes stay identical across counts and overflow scrolls at full height.
function Geom.cap_two_rows(list_h, gap, desired, min_h)
    min_h = math.max(1, math.floor(min_h or 1))
    local cap = math.floor(((list_h or 0) - (gap or 0)) / 2)
    if cap > 0 then
        return math.min(desired or cap, math.max(min_h, cap))
    end
    return desired
end

--- Greedy width pagination (ported from bookshelf's chip_pages, adapted to
--- plain arrays). `widths` = item widths, `spacing` between, `avail` usable,
--- `chev_w` = chevron width (0 = no chevron). Returns pages[] { first, last }
--- (1-based, always >= 1 item per page) and multi (more than one page).
--- Tested but WIRED NOWHERE: the toolbar keeps its icon-only fallback by
--- user decision; this is the alternative if labels must survive narrowing.
function Geom.paginate(widths, spacing, avail, chev_w)
    widths = widths or {}
    spacing = spacing or 0
    avail = avail or 0
    chev_w = chev_w or 0
    local n = #widths
    local pages = {}
    if n == 0 then
        return pages, false
    end
    local i = 1
    while i <= n do
        local first = i
        -- Reserve chevron space when more pages may follow / precede; if
        -- everything remaining fits without the right chevron, drop it.
        local reserve_left = (first > 1 and chev_w > 0) and (chev_w + spacing) or 0
        local reserve_right = chev_w + (chev_w > 0 and spacing or 0)
        local rest = 0
        for k = i, n do rest = rest + (k > i and spacing or 0) + widths[k] end
        if rest <= avail - reserve_left then reserve_right = 0 end
        local used = widths[i]
        i = i + 1
        while i <= n do
            local cap = avail - reserve_left - reserve_right
            if used + spacing + widths[i] <= cap then
                used = used + spacing + widths[i]
                i = i + 1
            else
                break
            end
        end
        pages[#pages + 1] = { first = first, last = i - 1 }
    end
    -- Contract: a single over-wide item still gets its own page.
    return pages, #pages > 1
end

return Geom
