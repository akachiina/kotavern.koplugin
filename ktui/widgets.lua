-- Design system: unified components for the canvas UI.
-- Every list row, button, bar and header in the app comes from here so
-- spacing, borders and hit targets are consistent across pages.

local P = require("ktui/primitives")
local Theme = require("ktui/theme")
local Icons = require("ktui/icons")
local Geom = require("ktui/geom")
local _ = require("gettext")

local W = {}

-- === Text sanitization ===

-- Truncate to at most max_bytes WITHOUT splitting a UTF-8 sequence, then
-- append an ellipsis. Byte-based :sub() on multi-byte strings paints tofu.
function W.truncate(text, max_bytes)
    text = tostring(text or "")
    if #text <= max_bytes then
        return text
    end
    local cut = math.max(0, max_bytes - 3)
    -- back off to a UTF-8 lead byte (0xxxxxxx or 11xxxxxx)
    while cut > 0 and text:byte(cut + 1) and text:byte(cut + 1) >= 0x80 and text:byte(cut + 1) < 0xC0 do
        cut = cut - 1
    end
    return text:sub(1, cut) .. "…"
end

-- First UTF-8 codepoint as a string (avatar initials): byte :sub(1,1) slices
-- multibyte characters into invalid sequences that render as tofu.
function W.first_glyph(text)
    text = tostring(text or "")
    if text == "" then return "" end
    local b = text:byte(1)
    local len = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 1
    return text:sub(1, len)
end

-- Fit text into max_w pixels: UTF-8-safe char-by-char shrink + ellipsis.
function W.fit_text(text, max_w, role, opts)
    text = tostring(text or "")
    if max_w <= 0 then return "" end
    if P.text_size(text, nil, role, opts).w <= max_w then
        return text
    end
    -- decode char boundaries
    local bounds = { 0 }
    local i = 1
    while i <= #text do
        local b = text:byte(i)
        i = i + ((b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 1)
        bounds[#bounds + 1] = i
    end
    local lo, hi = 1, #bounds - 1
    while lo < hi do
        local mid = math.ceil((lo + hi) / 2)
        local candidate = text:sub(1, bounds[mid] - 1) .. "…"
        if P.text_size(candidate, nil, role, opts).w <= max_w then
            lo = mid
        else
            hi = mid - 1
        end
    end
    return text:sub(1, bounds[lo] - 1) .. "…"
end

-- Strip codepoints that render as tofu with the bundled fonts (emoji, PUA,
-- variation selectors, ZWJ) and collapse the whitespace left behind.
-- Pure-byte UTF-8 decode (luajit has no utf8 lib).
local function decode_cp(s, i)
    local b = s:byte(i)
    if b < 0x80 then return b, i end
    local len, cp
    if b >= 0xF0 then len, cp = 4, b % 8
    elseif b >= 0xE0 then len, cp = 3, b % 16
    elseif b >= 0xC0 then len, cp = 2, b % 32
    else return nil, i end
    for k = 1, len - 1 do
        local cb = s:byte(i + k)
        if not cb or cb < 0x80 or cb >= 0xC0 then return nil, i end
        cp = cp * 64 + (cb % 64)
    end
    return cp, i + len - 1
end

function W.sanitize(text)
    text = tostring(text or "")
    if text == "" then return "" end
    local out = {}
    local i = 1
    while i <= #text do
        local cp, ni = decode_cp(text, i)
        local keep = true
        if cp then
            if (cp >= 0x1F000) or (cp >= 0x2600 and cp <= 0x27BF)
                or (cp >= 0xFE00 and cp <= 0xFE0F) or cp == 0x200D
                or (cp >= 0xE000 and cp <= 0xF8FF) or (cp >= 0x2B00 and cp <= 0x2BFF)
                or cp == 0xFEFF or cp == 0x200B then
                keep = false
            end
        end
        if keep then
            out[#out + 1] = text:sub(i, ni)
        end
        i = ni + 1
    end
    local s = table.concat(out)
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- === Measure helpers ===

function W.button_width(label, icon, icon_size, h)
    h = h or Theme.btn_h()
    local w = Theme.scale(28)
    if icon then
        icon_size = icon_size or Theme.scale(14)
        w = w + Icons.text_size(icon, icon_size).w + Theme.scale(7)
    end
    if label and label ~= "" then
        -- +4px slack: exact-fit max_width makes TextWidget add a "…" on any
        -- rounding difference between measure and draw.
        w = w + P.text_size(label, nil, "small", { bold = true }).w + Theme.scale(4)
    end
    return w, h
end

-- === Button ===

-- Round avatar disc (ST round avatar, same look as the chat bubbles):
-- square cover-fit image with its corners carved back to the surface color
-- plus a 1px muted ring; text fallback is a soft disc with the bold initial.
-- Shared by chat bubbles and list rows (dashboard list mode, chats page) so
-- every character image in the app renders through the same circle treatment
-- instead of a whole shrunken image.
-- Returns true when an image was painted (callers flip dither hints on it).
function W.avatar(bb, x, y, size, image_file, name, carve_color)
    local drawn = false
    if image_file and image_file ~= "" then
        drawn = P.image(bb, image_file, x, y, size, size, { cover = true })
    end
    if drawn then
        P.circle_carve(bb, x, y, size, carve_color or Theme.bg)
        P.circle_ring(bb, x + size / 2, y + size / 2, size / 2, Theme.muted)
    else
        -- Fallback: filled circle with the initial (ST missing-avatar).
        P.rect(bb, x, y, size, size, Theme.soft)
        P.circle_carve(bb, x, y, size, carve_color or Theme.bg)
        P.circle_ring(bb, x + size / 2, y + size / 2, size / 2, Theme.muted)
        local initial = W.first_glyph(name or "?"):upper()
        P.center_text_box(bb, initial, x, y, size, size, "small", { bold = true })
    end
    return drawn
end

-- Pill button. opts:
--   x, y, w (nil = measured), h (default Theme.btn_h())
--   label, icon, icon_size
--   kind: "primary" (solid) | "secondary" (bordered) | "ghost" (no bg)
--   enabled (default true), on_tap
--   hit_label: overrides the hitbox label (sheets tag their buttons
--     "sheet:*" so the modal tap policy can tell them apart from page hits).
-- Returns the drawn width.
function W.button(view, bb, o)
    local h = o.h or Theme.btn_h()
    local icon_size = o.icon_size or Theme.scale(14)
    local w = o.w or W.button_width(o.label, o.icon, icon_size, h)
    local enabled = o.enabled ~= false
    local kind = o.kind or "primary"
    local radius = math.floor(h / 2)

    if not enabled then
        P.box(bb, o.x, o.y, w, h, {
            border = kind ~= "ghost", border_size = 1,
            border_color = Theme.soft, background = Theme.bg, radius = radius,
        })
        local tw = 0
        if o.icon then
            local isz = Icons.text_size(o.icon, icon_size)
            Icons.draw(bb, o.icon, o.x + Theme.scale(14), o.y + math.floor((h - isz.h) / 2), icon_size, { color = Theme.muted })
            tw = isz.w + Theme.scale(7)
        end
        if o.label and o.label ~= "" then
            P.vcenter_text(bb, o.label, o.x + Theme.scale(14) + tw, o.y, w - Theme.scale(28) - tw, h, "small", { bold = true, color = Theme.muted })
        end
        return w
    end

    if kind == "primary" then
        P.box(bb, o.x, o.y, w, h, { border = false, background = Theme.button_bg, radius = radius })
    elseif kind == "secondary" then
        P.box(bb, o.x, o.y, w, h, { border = true, border_size = 1, border_color = Theme.muted, background = Theme.panel, radius = radius })
    else
        P.box(bb, o.x, o.y, w, h, { border = false, background = Theme.panel, radius = radius })
    end

    local text_color = (kind == "primary") and Theme.button_text or Theme.ink
    -- SVG icon ink is black: invert it on the solid primary pill (white icon
    -- on black in the light theme) and on any pill under the inverted theme,
    -- per the same table Icons uses for page-background icons.
    local icon_invert = (kind == "primary") ~= (Theme.get_theme() == "inverted")
    local tx = o.x + Theme.scale(14)
    if o.icon then
        local isz = Icons.draw(bb, o.icon, tx, o.y + math.floor((h - Icons.text_size(o.icon, icon_size).h) / 2), icon_size, { invert = icon_invert })
        tx = tx + isz.w + Theme.scale(7)
    end
    if o.label and o.label ~= "" then
        P.vcenter_text(bb, o.label, tx, o.y, w - (tx - o.x) - Theme.scale(14), h, "small", { bold = true, color = text_color })
    end
    local hit_label = o.hit_label or ("btn:" .. tostring(o.label or o.icon))
    P.hit(view, o.x, o.y, w, h, o.on_tap, hit_label)
    return w
end

-- Square icon button with a visible soft background (affordance).
-- opts: x, y, s (default Theme.icon_btn()), icon, on_tap, enabled, color, bg
function W.icon_button(view, bb, o)
    local s = o.s or Theme.icon_btn()
    local enabled = o.enabled ~= false
    P.box(bb, o.x, o.y, s, s, {
        border = false,
        background = o.bg or Theme.soft,
        radius = Theme.scale(8),
    })
    local size = Theme.scale(13)
    local color = enabled and (o.color or Theme.ink) or Theme.muted
    local isz = Icons.text_size(o.icon, size)
    Icons.draw(bb, o.icon, o.x + math.floor((s - isz.w) / 2), o.y + math.floor((s - isz.h) / 2), size, { color = color })
    if enabled and o.on_tap then
        P.hit(view, o.x, o.y, s, s, o.on_tap, "iconbtn:" .. tostring(o.icon))
    end
    return s
end

-- === Section header ===

-- Small bold muted label above a group. Returns the height consumed.
function W.section_header(view, bb, x, y, w, text)
    local lh = Theme.line_h("small")
    P.text(bb, W.sanitize(text), x + Theme.scale(2), y + Theme.scale(4), w - Theme.scale(4), "small", { bold = true, color = Theme.muted })
    return lh + Theme.scale(10)
end

-- 1px soft divider line.
function W.divider(bb, x, y, w)
    P.rect(bb, x, y, w, math.max(1, Theme.scale(1)), Theme.soft)
end

-- === Row ===

-- Unified list row. opts:
--   x, y, w, h (nil = computed from content, min touch_min)
--   icon (glyph name), title, subtitle, value (right-aligned muted text)
--   chevron (bool), check (bool), toggle (bool) + toggle_value + on_toggle
--   kebab (bool) + on_kebab
--   on_tap (whole row), enabled, danger (title color), selected (bool)
--   style: "card" (default: soft border) | "plain" (no box)
-- Returns the drawn height.
function W.row(view, bb, o)
    local m = Theme.metrics()
    local pad = m.pad
    local title_lh = Theme.line_h("default")
    local sub_lh = o.subtitle and Theme.line_h("tiny") or 0
    local h = o.h or math.max(Theme.metrics().touch_min, title_lh + sub_lh + Theme.scale(14))
    local w = o.w
    local x, y = o.x, o.y
    local style = o.style or "card"

    if style == "card" then
        P.box(bb, x, y, w, h, {
            border = true, border_size = 1, border_color = Theme.soft,
            background = Theme.panel, radius = Theme.scale(6),
        })
    end

    -- Left icon slot
    local tx = x + pad
    if o.icon then
        local icon_size = Theme.scale(14)
        local isz = Icons.text_size(o.icon, icon_size)
        local slot_w = isz.w + Theme.scale(12)
        local color = o.enabled == false and Theme.muted or (o.danger and Theme.danger or Theme.ink)
        Icons.draw(bb, o.icon, tx + math.floor((slot_w - isz.w) / 2), y + Geom.center_offset(h, isz.h), icon_size, { color = color })
        tx = tx + slot_w
    end

    -- Right side: compose slots right-to-left in ONE place (geom): the xs
    -- double as paint positions and hit rects, so they cannot drift apart
    -- (the old code painted at tw_x but hit at a stale `right`).
    local kebab_w = o.kebab and Theme.scale(34) or 0
    local toggle_w = o.toggle and Theme.scale(52) or 0
    local chev_w = o.chevron and Theme.scale(26) or 0
    local check_w = o.check and Theme.scale(26) or 0
    local slot_xs, right = Geom.row_slots(x + w, pad,
        { kebab_w, toggle_w, chev_w, check_w })
    local kx, tw_x, cvx, chx = slot_xs[1], slot_xs[2], slot_xs[3], slot_xs[4]
    if o.kebab then
        local icon_size = Theme.scale(12)
        local isz = Icons.text_size("ellipsis-v", icon_size)
        Icons.draw(bb, "ellipsis-v", kx + math.floor((kebab_w - isz.w) / 2), y + Geom.center_offset(h, isz.h), icon_size, { color = Theme.muted })
    end
    if o.toggle then
        P.zen_toggle(bb, tw_x, y + Geom.center_offset(h, Theme.scale(26)), toggle_w, Theme.scale(26), o.toggle_value and true or false)
    end
    if o.chevron then
        local icon_size = Theme.scale(11)
        local isz = Icons.text_size("chev-right", icon_size)
        Icons.draw(bb, "chev-right", cvx + math.floor((chev_w - isz.w) / 2), y + Geom.center_offset(h, isz.h), icon_size, { color = Theme.muted })
    end
    if o.check then
        local icon_size = Theme.scale(12)
        local isz = Icons.text_size("check", icon_size)
        Icons.draw(bb, "check", chx + math.floor((check_w - isz.w) / 2), y + Geom.center_offset(h, isz.h), icon_size, { color = Theme.ink })
    end

    -- Value text (before the right slots). Only strings paint here: callers
    -- must normalize booleans/numbers to toggle state or formatted text,
    -- otherwise tostring(true) leaks into the row as a "true" label.
    local text_right = right
    if type(o.value) == "string" and o.value ~= "" then
        local vs = P.text_size(o.value, nil, "small", { color = Theme.muted })
        local max_vw = math.floor(w * 0.5)
        local vw = math.min(vs.w, max_vw)
        P.vcenter_text(bb, o.value, text_right - vw, y, vw, h, "small", { color = Theme.muted })
        text_right = text_right - vw - Theme.scale(8)
    end

    -- Title + subtitle
    local text_w = text_right - tx
    local title_color = o.enabled == false and Theme.muted or (o.danger and Theme.danger or Theme.ink)
    if o.subtitle then
        local block_h = title_lh + Theme.scale(2) + sub_lh
        local by = y + Geom.center_offset(h, block_h)
        P.text(bb, W.sanitize(o.title), tx, by, text_w, "default", { bold = true, color = title_color })
        P.text(bb, o.subtitle, tx, by + title_lh + Theme.scale(2), text_w, "tiny", { color = Theme.muted })
    else
        P.vcenter_text(bb, W.sanitize(o.title), tx, y, text_w, h, "default", { bold = true, color = title_color })
    end

    -- Hits: whole row first, then sub-slots (registered later → checked first).
    -- Sub-slots honor `enabled` like the row itself: a muted (disabled) row
    -- must not toggle/edit through its right strips.
    local interactive = o.enabled ~= false
    if o.on_tap and interactive then
        P.hit(view, x, y, w, h, o.on_tap, "row:" .. tostring(o.title))
    end
    if o.toggle and o.on_toggle and interactive then
        -- tw_x is the painted toggle rect (same xs as the paint above).
        P.hit(view, tw_x, y, toggle_w, h, o.on_toggle, "row:toggle")
    end
    if o.kebab and o.on_kebab and interactive then
        P.hit(view, kx, y, kebab_w, h, o.on_kebab, "row:kebab")
    end
    return h
end

-- === Page bar ===

-- Bar at the top of a page content area: title on the left, buttons on the
-- right (last action is rightmost). Replaces the floating centered pills.
-- opts: x, y, w, title, actions = { {label, icon, kind, enabled, on_tap}... }
-- The LAST action in the list is drawn rightmost (use it for the primary).
-- Returns the bar height.
function W.page_bar(view, bb, o)
    local m = Theme.metrics()
    local h = Theme.btn_h() + Theme.scale(12)
    local by = o.y + Theme.scale(6)

    -- Buttons end at the page padding (never flush with the screen edge -
    -- that reads as "cut off" next to the header's inset close button).
    local right = o.x + o.w - m.pad
    local actions = o.actions or {}
    for i = #actions, 1, -1 do
        local a = actions[i]
        local bw = W.button_width(a.label, a.icon, nil)
        right = right - bw
        W.button(view, bb, {
            x = right, y = by, w = bw, h = Theme.btn_h(),
            label = a.label, icon = a.icon,
            kind = a.kind or (i == #actions and "primary" or "secondary"),
            enabled = a.enabled, on_tap = a.on_tap,
        })
        right = right - Theme.scale(8)
    end

    if o.title and o.title ~= "" then
        local title_w = right - o.x - Theme.scale(4)
        if title_w > Theme.scale(40) then
            P.vcenter_text(bb, W.sanitize(o.title), o.x + Theme.scale(2), by, title_w, Theme.btn_h(), "heading", { bold = true })
        end
    end
    return h
end

-- === Segmented control ===

-- opts: x, y, w, h (default touch_min * 0.82), tabs = { {id, label}... },
-- active (id), on_select(id). Returns the height.
function W.segmented(view, bb, o)
    local h = o.h or Theme.scale(36)
    local n = #(o.tabs or {})
    if n == 0 then return 0 end
    local gap = Theme.scale(4)
    -- Spread the floor remainder 1px over the first tabs instead of dumping
    -- it all on the last tab (which came out visibly wider).
    local widths = Geom.distribute_remainder(o.w - gap * (n - 1), n)
    local x = o.x
    for i, tab in ipairs(o.tabs or {}) do
        local w = widths[i]
        local active = (tab.id == o.active)
        if active then
            P.box(bb, x, o.y, w, h, { border = false, background = Theme.button_bg, radius = math.floor(h / 2) })
            P.center_text_box(bb, tab.label, x, o.y, w, h, "small", { bold = true, color = Theme.button_text })
        else
            P.box(bb, x, o.y, w, h, { border = true, border_size = 1, border_color = Theme.soft, background = Theme.panel, radius = math.floor(h / 2) })
            P.center_text_box(bb, tab.label, x, o.y, w, h, "small", { color = Theme.muted })
        end
        local id = tab.id
        P.hit(view, x, o.y, w, h, function()
            if o.on_select then o.on_select(id) end
        end, "seg:" .. tostring(tab.label))
        x = x + w + gap
    end
    return h
end

-- === Empty state ===

-- opts: x, y, w, h, icon, text, action = {label, on_tap}
-- Returns nothing (paints centered inside the area).
-- Ink probe for the empty-state icon (memoized): paints the icon on a
-- scratch buffer once per (name, size) and records where its real pixels
-- start/end inside the widget box (glyph bearings are asymmetric and
-- font-metric boxes lie - see W.empty_state). Memo lives in module scope.
local empty_ink_cache = {}
local function _empty_ink_probe(icon, icon_size, key)
    local hit = empty_ink_cache[key]
    if hit then return hit[1], hit[2] end
    local box = icon_size * 2
    local ok, Blitbuffer = pcall(require, "ffi/blitbuffer")
    if not ok then return nil, nil end
    local sb = Blitbuffer.new(box, box, Blitbuffer.TYPE_BB8)
    sb:fill(Blitbuffer.COLOR_WHITE)
    Icons.draw(sb, icon, 0, 0, icon_size, { color = Theme.muted })
    local t, b
    for y = 0, box - 1 do
        for x = 0, box - 1 do
            local okp, px = pcall(function() return sb:getPixel(x, y) end)
            if okp and px and px:getR() < 200 then t = y break end
        end
        if t then break end
    end
    for y = box - 1, 0, -1 do
        for x = 0, box - 1 do
            local okp, px = pcall(function() return sb:getPixel(x, y) end)
            if okp and px and px:getR() < 200 then b = y break end
        end
        if b then break end
    end
    pcall(function() sb:free() end)
    if not t then return nil, nil end
    empty_ink_cache[key] = { t, b }
    return t, b
end

-- Text ink bounds for the EXACT text to paint (memoized by text+metrics).
-- Probes with 1-line glyphs ("axo") under-measure: multi-line runs carry
-- a different first-line bearing (TextBoxWidget pads its frame) and the
-- caller may end in a descender ("yet"). Painting the real text on a
-- scratch buffer is deterministic and cheap with the cache. Returns
-- tt0/tt1 = ink first/last row inside the allocated text_h box.
local text_ink_cache = {}
local function _text_ink_probe(text, tw, text_h, key)
    key = key .. "|" .. text_h
    local hit = text_ink_cache[key]
    if hit then return hit[1], hit[2] end
    local ok, Blitbuffer = pcall(require, "ffi/blitbuffer")
    if not ok then return nil, nil end
    local sb = Blitbuffer.new(math.max(8, tw), math.max(2, text_h),
        Blitbuffer.TYPE_BB8)
    sb:fill(Blitbuffer.COLOR_WHITE)
    P.paragraph(sb, text or "", 0, 0, tw, text_h, "small", { color = Theme.muted })
    local t, b
    for y = 0, text_h - 1 do
        for x = 0, tw - 1 do
            local okp, px = pcall(function() return sb:getPixel(x, y) end)
            if okp and px and px:getR() < 200 then t = y break end
        end
        if t then break end
    end
    for y = text_h - 1, 0, -1 do
        for x = 0, tw - 1 do
            local okp, px = pcall(function() return sb:getPixel(x, y) end)
            if okp and px and px:getR() < 200 then b = y break end
        end
        if b then break end
    end
    pcall(function() sb:free() end)
    if not t then return nil, nil end
    text_ink_cache[key] = { t, b }
    return t, b
end

function W.empty_state(view, bb, o)
    -- Center the WHOLE block (icon + text) as one visual unit, positioned
    -- by INK, not widget boxes (the eye sees ink; glyph boxes carry
    -- asymmetric bearings that make box-centered composites hang visibly
    -- shifted - the old version also anchored icon and text independently,
    -- splitting the block around the center line).
    --
    -- Layout rule: optical block height = icon ink height + gap + text ink
    -- height; the icon paints at the block top (its own bearing already
    -- measured by probe so the GLYPH's ink starts exactly at block_y), and
    -- the text's line y compensates its probe-measured top bearing.
    local icon_size = Theme.scale(26)
    local isz = o.icon and Icons.text_size(o.icon, icon_size) or nil
    local gap = o.icon and Theme.scale(10) or 0
    local tw = o.w - Theme.scale(40)
    local lines = P.paragraph_line_count(o.text or "", tw, "small")
    local line_h = Theme.line_h("small")
    local text_h = lines * line_h
    -- Icon ink bounds inside its widget box (probe, memoized).
    local it0, it1 = nil, nil
    if isz then
        it0, it1 = _empty_ink_probe(o.icon, icon_size,
            "emptystate:" .. o.icon .. ":" .. icon_size)
    end
    -- Text ink bounds for the REAL text (probe multiline, memoized): the
    -- composition is placed by ink so bearings never shift the center.
    local tt0, tt1 = _text_ink_probe(o.text, tw, text_h,
        "small|" .. tostring(o.text or ""))
    local icon_ink_h = (it0 and (it1 - it0 + 1)) or (isz and isz.h or 0)
    local text_ink_h = (tt0 and tt1) and (tt1 - tt0 + 1) or text_h
    local block_h = icon_ink_h + gap + text_ink_h
    -- Optical center: pure geometric center in a bright-chrome frame reads
    -- LOW (the dark Sort/Search pills pin the top edge; nothing balances
    -- them at the bottom). Classic composition fix - the block's center
    -- sits at ~46% of the body height, a hair above true center. Users
    -- perceive this as "centered" (probed visually: 50% reads sunk in the
    -- chats empty state).
    local optical_bias = math.floor(o.h * 0.04)
    local y0 = o.y + math.max(0, math.floor((o.h - block_h) / 2)) - optical_bias
    local tx = o.x + Theme.scale(20)
    if o.icon then
        -- Icon: paint so its INK top lands at y0 (subtract probe head).
        Icons.draw(bb, o.icon,
            o.x + math.floor((o.w - isz.w) / 2), y0 - (it0 or 0),
            icon_size, { color = Theme.muted })
    end
    -- Text box y so the block's text ink begins at y0 + icon_ink_h + gap.
    local text_y = y0 + icon_ink_h + gap - (tt0 or 0)
    -- H-center every line (align=center within the padded column): the
    -- old paint left-anchored the label at x+20 so long lines read "in a
    -- corner" while the icon floated centered above them.
    P.paragraph(bb, o.text or "", tx, text_y, tw, text_h, "small",
        { color = Theme.muted, align = "center" })
    if o.action and o.action.on_tap then
        local bw, bh = W.button_width(o.action.label, o.action.icon)
        W.button(view, bb, {
            x = o.x + math.floor((o.w - bw) / 2),
            y = y0 + block_h + Theme.scale(14),
            w = bw, h = bh,
            label = o.action.label, icon = o.action.icon,
            kind = "secondary", on_tap = o.action.on_tap,
        })
    end
end

-- === HTML island (MuPDF content inside native layout) ===

-- A literal-HTML block for native pages (the B pattern: native structure,
-- MuPDF content). o = { x, y, w, h, scroll, html, css, actions, key,
-- paginated, mtime }. Static content unless the caller invalidates:
-- templates render once per doc build, so state-driven islands must call
-- KtHTML.invalidate(app, key) after mutations (the kt: router already
-- does). Registers the island hitbox FIRST so overlay hitboxes painted
-- afterwards win ties (same load-bearing order as Pages.html_test).
-- Returns max_scroll for the caller's scrollbar.
function W.html_block(view, bb, o)
    local KtHTML = require("ktui/kthtml")
    local app = view.app
    local key = o.key or "block"
    local rendered = KtHTML.render_body(o.html or "", app)
    local css = KtHTML.theme_css() .. "\n" .. (o.css or "")
    local src = { body = rendered, css = css, mtime = o.mtime }
    local doc = KtHTML.ensure(app, view, key, src, o.w, o.h,
        { paginated = o.paginated })
    if not doc then return 0 end
    local total = KtHTML.content_h(doc, o.h)
    local max_scroll = math.max(0, total - o.h)
    local sc = math.max(0, math.min(o.scroll or 0, max_scroll))
    P.hit(view, o.x, o.y, o.w, o.h, function(tx, ty)
        local live = KtHTML.current(app, key)
        if live then
            return KtHTML.tap(live, app, key, o.actions,
                o.x, o.y, sc, tx, ty)
        end
        return false
    end, "kthtml:island")
    KtHTML.paint_window(doc, bb, o.x, o.y, o.w, o.h, sc, view, o.actions)
    return max_scroll
end

return W
