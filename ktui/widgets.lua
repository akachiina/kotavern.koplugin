-- Design system: unified components for the canvas UI.
-- Every list row, button, bar and header in the app comes from here so
-- spacing, borders and hit targets are consistent across pages.

local P = require("ktui/primitives")
local Theme = require("ktui/theme")
local Icons = require("ktui/icons")
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
        Icons.draw(bb, o.icon, tx + math.floor((slot_w - isz.w) / 2), y + math.floor((h - isz.h) / 2), icon_size, { color = color })
        tx = tx + slot_w
    end

    -- Right side: compose slots right-to-left
    local right = x + w - pad
    local kebab_w, toggle_w, chev_w, check_w = 0, 0, 0, 0
    if o.kebab then
        kebab_w = Theme.scale(34)
        local kx = right - kebab_w
        local icon_size = Theme.scale(12)
        local isz = Icons.text_size("ellipsis-v", icon_size)
        Icons.draw(bb, "ellipsis-v", kx + math.floor((kebab_w - isz.w) / 2), y + math.floor((h - isz.h) / 2), icon_size, { color = Theme.muted })
        right = kx
    end
    if o.toggle then
        toggle_w = Theme.scale(52)
        local tw_x = right - toggle_w
        P.zen_toggle(bb, tw_x, y + math.floor((h - Theme.scale(26)) / 2), toggle_w, Theme.scale(26), o.toggle_value and true or false)
        right = tw_x
    end
    if o.chevron then
        chev_w = Theme.scale(26)
        local cx = right - chev_w
        local icon_size = Theme.scale(11)
        local isz = Icons.text_size("chev-right", icon_size)
        Icons.draw(bb, "chev-right", cx + math.floor((chev_w - isz.w) / 2), y + math.floor((h - isz.h) / 2), icon_size, { color = Theme.muted })
        right = cx
    end
    if o.check then
        check_w = Theme.scale(26)
        local cx = right - check_w
        local icon_size = Theme.scale(12)
        local isz = Icons.text_size("check", icon_size)
        Icons.draw(bb, "check", cx + math.floor((check_w - isz.w) / 2), y + math.floor((h - isz.h) / 2), icon_size, { color = Theme.ink })
        right = cx
    end

    -- Value text (before the right slots)
    local text_right = right
    if o.value and o.value ~= "" then
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
        local by = y + math.floor((h - block_h) / 2)
        P.text(bb, W.sanitize(o.title), tx, by, text_w, "default", { bold = true, color = title_color })
        P.text(bb, o.subtitle, tx, by + title_lh + Theme.scale(2), text_w, "tiny", { color = Theme.muted })
    else
        P.vcenter_text(bb, W.sanitize(o.title), tx, y, text_w, h, "default", { bold = true, color = title_color })
    end

    -- Hits: whole row first, then sub-slots (registered later → checked first)
    if o.on_tap and o.enabled ~= false then
        P.hit(view, x, y, w, h, o.on_tap, "row:" .. tostring(o.title))
    end
    if o.toggle and o.on_toggle then
        P.hit(view, right, y, toggle_w, h, o.on_toggle, "row:toggle")
    end
    if o.kebab and o.on_kebab then
        P.hit(view, x + w - pad - kebab_w, y, kebab_w, h, o.on_kebab, "row:kebab")
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
    local tw = math.floor((o.w - gap * (n - 1)) / n)
    local x = o.x
    for i, tab in ipairs(o.tabs or {}) do
        local w = (i == n) and (o.w - (n - 1) * (tw + gap)) or tw
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
        x = x + tw + gap
    end
    return h
end

-- === Empty state ===

-- opts: x, y, w, h, icon, text, action = {label, on_tap}
-- Returns nothing (paints centered inside the area).
function W.empty_state(view, bb, o)
    local cy = o.y + math.floor(o.h / 2)
    if o.icon then
        local icon_size = Theme.scale(26)
        local isz = Icons.text_size(o.icon, icon_size)
        Icons.draw(bb, o.icon, o.x + math.floor((o.w - isz.w) / 2), cy - isz.h - Theme.scale(10), icon_size, { color = Theme.muted })
    end
    local lines = P.paragraph_line_count(o.text or "", o.w - Theme.scale(40), "small")
    local line_h = Theme.line_h("small")
    local text_h = lines * line_h
    -- Multiline paint (P.center_text is single-line and ellipsizes long
    -- texts instead of wrapping).
    local tx = o.x + Theme.scale(20)
    local tw = o.w - Theme.scale(40)
    P.paragraph(bb, o.text or "", tx, cy - math.floor(text_h / 2), tw, text_h, "small",
        { color = Theme.muted })
    if o.action and o.action.on_tap then
        local bw, bh = W.button_width(o.action.label, o.action.icon)
        W.button(view, bb, {
            x = o.x + math.floor((o.w - bw) / 2),
            y = cy + math.floor(text_h / 2) + Theme.scale(14),
            w = bw, h = bh,
            label = o.action.label, icon = o.action.icon,
            kind = "secondary", on_tap = o.action.on_tap,
        })
    end
end

return W
