-- Drawing primitives for canvas-based UI.
-- Adapted from ZenPM (zenpm.koplugin/ui/primitives.lua)

local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")

local Theme = require("ktui/theme")

local P = {}

function P.rect(bb, x, y, w, h, color)
    if w <= 0 or h <= 0 then
        return
    end
    bb:paintRect(x, y, w, h, color or Theme.bg)
end

function P.rounded_rect(bb, x, y, w, h, color, radius)
    if w <= 0 or h <= 0 then
        return
    end
    radius = radius or Theme.metrics().radius
    if bb.paintRoundedRect then
        local ok = pcall(function()
            bb:paintRoundedRect(x, y, w, h, color or Theme.bg, radius)
        end)
        if ok then
            return
        end
        ok = pcall(function()
            bb:paintRoundedRect(x, y, w, h, radius, color or Theme.bg)
        end)
        if ok then
            return
        end
    end
    P.rect(bb, x, y, w, h, color or Theme.bg)
end

function P.border(bb, x, y, w, h, size, color, radius, background)
    if w <= 0 or h <= 0 then
        return
    end
    size = size or 2
    radius = radius or Theme.metrics().radius
    color = color or Theme.border
    if bb.paintRoundedRect then
        P.rounded_rect(bb, x, y, w, h, color, radius)
        if w > size * 2 and h > size * 2 then
            P.rounded_rect(bb, x + size, y + size, w - size * 2, h - size * 2, background or Theme.panel, math.max(0, radius - size))
        end
    else
        bb:paintBorder(x, y, w, h, size, color, nil, true)
    end
end

function P.box(bb, x, y, w, h, opts)
    opts = opts or {}
    local background = opts.background or Theme.panel
    local radius = opts.radius
    if opts.border ~= false then
        P.border(bb, x, y, w, h, opts.border_size or 2, opts.border_color or Theme.border, radius, background)
    elseif radius ~= false then
        P.rounded_rect(bb, x, y, w, h, background, radius)
    else
        P.rect(bb, x, y, w, h, background)
    end
end

function P.stroke(bb, x, y, w, h, size, color)
    if w <= 0 or h <= 0 then
        return
    end
    bb:paintBorder(x, y, w, h, size or 2, color or Theme.border, nil, true)
end

-- Zen-style pill toggle (copied from ZenPM)
local function paint_zen_pill(bb, x, y, w, h, color)
    local radius = math.min(w, h) / 2
    for row = 0, h - 1 do
        local offset = (row + 0.5) - h * 0.5
        local inset = 0
        if math.abs(offset) < radius then
            inset = math.ceil(radius - math.sqrt(radius * radius - offset * offset))
        end
        local row_w = w - inset * 2
        if row_w > 0 then
            bb:paintRect(x + inset, y + row, row_w, 1, color)
        end
    end
end

local function paint_zen_circle(bb, x, y, radius, color)
    for row = -radius, radius do
        local half = math.floor(math.sqrt(radius * radius - row * row) + 0.5)
        if half > 0 then
            bb:paintRect(x - half, y + row, half * 2, 1, color)
        end
    end
end

-- Circular avatar helpers (ST round avatars, e-ink friendly): paint the
-- square image, then carve the 4 corners back to the background and lay a
-- 1px ring on top - no alpha compositing needed.

-- Paint the corner area of a size×size box outside its incircle with color.
function P.circle_carve(bb, x, y, size, color)
    if size <= 0 then return end
    local r = size / 2
    for row = 0, size - 1 do
        local dy = (row + 0.5) - r
        local half = math.sqrt(math.max(0, r * r - dy * dy))
        local inset = math.floor(r - half + 0.5)
        if inset > 0 then
            bb:paintRect(x, y + row, inset, 1, color)
            bb:paintRect(x + size - inset, y + row, inset, 1, color)
        end
    end
end

-- 1px (or 2px) circle outline centered at (cx, cy).
function P.circle_ring(bb, cx, cy, r, color, thickness)
    r = math.floor(r)
    if r <= 0 then return end
    thickness = thickness or 1
    for row = -r, r do
        local half = math.floor(math.sqrt(math.max(0, r * r - row * row)) + 0.5)
        if half > 0 then
            local y = cy + row
            bb:paintRect(cx - half, y, thickness, 1, color)
            bb:paintRect(cx + half - thickness, y, thickness, 1, color)
        end
    end
end

-- Filled disc centered at (cx, cy) (kebab dots, avatars fallbacks).
function P.circle(bb, cx, cy, r, color)
    r = math.max(1, math.floor(r))
    for row = -r, r do
        local half = math.floor(math.sqrt(math.max(0, r * r - row * row)) + 0.5)
        if half > 0 then
            bb:paintRect(cx - half, cy + row, half * 2, 1, color)
        end
    end
end

-- High-contrast pill toggle, theme-aware
function P.zen_toggle(bb, x, y, w, h, enabled)
    local border = Theme.scale(2)
    local pad = Theme.scale(3)
    local knob_radius = math.max(1, math.floor(h / 2) - pad)
    local center_y = y + math.floor(h / 2)
    if enabled then
        paint_zen_pill(bb, x, y, w, h, Theme.ink)
        paint_zen_circle(bb, x + w - pad - knob_radius, center_y, knob_radius, Theme.panel)
    else
        paint_zen_pill(bb, x, y, w, h, Theme.ink)
        paint_zen_pill(bb, x + border, y + border, w - border * 2, h - border * 2, Theme.panel)
        paint_zen_circle(bb, x + border + pad + knob_radius, center_y, knob_radius, Theme.ink)
    end
end

function P.text(bb, text, x, y, width, role, opts)
    opts = opts or {}
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = opts.face or Theme.face(role),
        bold = opts.bold,
        fgcolor = opts.color or Theme.ink,
        max_width = width,
    }
    widget:paintTo(bb, x, y)
    local size = widget:getSize()
    widget:free()
    return size
end

function P.text_size(text, width, role, opts)
    opts = opts or {}
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = opts.face or Theme.face(role),
        bold = opts.bold,
        fgcolor = opts.color or Theme.ink,
        max_width = width,
    }
    local size = widget:getSize()
    widget:free()
    return size
end

function P.paragraph(bb, text, x, y, width, height, role, opts)
    opts = opts or {}
    local widget = TextBoxWidget:new{
        text = tostring(text or ""),
        face = opts.face or Theme.face(role),
        bold = opts.bold,
        fgcolor = opts.color or Theme.ink,
        bgcolor = opts.bgcolor,
        width = width,
        height = height,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        line_height = opts.line_height,
    }
    widget:paintTo(bb, x, y)
    local size = widget:getSize()
    widget:free()
    return size
end

-- Paragraph scrolled by whole lines (no torn glyphs). Returns
-- (max_scroll_px, line_height_px) so callers can drive a scrollbar.
function P.scrollable_paragraph(bb, text, x, y, width, height, role, scroll, opts)
    opts = opts or {}
    local face = opts.face or Theme.face(role)
    local line_height = math.floor((1 + (opts.line_height or 0.3)) * face.size + 0.5)
    local top_line = math.floor((scroll or 0) / math.max(1, line_height)) + 1
    local widget = TextBoxWidget:new{
        text = tostring(text or ""),
        face = face,
        bold = opts.bold,
        fgcolor = opts.color or Theme.ink,
        bgcolor = opts.bgcolor,
        width = width,
        height = height,
        height_adjust = true,
        line_height = opts.line_height,
        virtual_line_num = top_line,
    }
    widget:paintTo(bb, x, y)
    local total_lines = #(widget.vertical_string_list or {})
    local visible_lines = widget.lines_per_page or total_lines
    line_height = widget.line_height_px or line_height
    widget:free()
    return math.max(0, total_lines - visible_lines) * line_height, line_height
end

function P.paragraph_line_count(text, width, role, opts)
    opts = opts or {}
    local widget = TextBoxWidget:new{
        text = tostring(text or ""),
        face = opts.face or Theme.face(role),
        bold = opts.bold,
        fgcolor = opts.color or Theme.ink,
        width = width,
        height = 1,
        height_adjust = true,
        line_height = opts.line_height,
    }
    local lines = #(widget.vertical_string_list or {})
    widget:free()
    return lines
end

function P.paragraph_metrics(text, width, role, opts)
    opts = opts or {}
    local widget = TextBoxWidget:new{
        text = tostring(text or ""),
        face = opts.face or Theme.face(role),
        bold = opts.bold,
        fgcolor = opts.color or Theme.ink,
        width = width,
        height = 1,
        height_adjust = true,
        line_height = opts.line_height,
    }
    local lines = #(widget.vertical_string_list or {})
    local line_height = widget.line_height_px or 1
    widget:free()
    return lines, line_height
end

function P.center_text(bb, text, x, y, w, role, opts)
    opts = opts or {}
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = opts.face or Theme.face(role),
        bold = opts.bold,
        fgcolor = opts.color or Theme.ink,
        max_width = w,
    }
    local size = widget:getSize()
    widget:paintTo(bb, x + math.max(0, math.floor((w - size.w) / 2)), y)
    widget:free()
    return size
end

function P.vcenter_text(bb, text, x, y, w, h, role, opts)
    opts = opts or {}
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = opts.face or Theme.face(role),
        bold = opts.bold,
        fgcolor = opts.color or Theme.ink,
        max_width = w,
    }
    local size = widget:getSize()
    widget:paintTo(bb, x, y + math.max(0, math.floor((h - size.h) / 2)))
    widget:free()
    return size
end

function P.center_text_box(bb, text, x, y, w, h, role, opts)
    opts = opts or {}
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = opts.face or Theme.face(role),
        bold = opts.bold,
        fgcolor = opts.color or Theme.ink,
        max_width = w,
    }
    local size = widget:getSize()
    widget:paintTo(
        bb,
        x + math.max(0, math.floor((w - size.w) / 2)),
        y + math.max(0, math.floor((h - size.h) / 2))
    )
    widget:free()
    return size
end

-- Right-aligned text, vertically centered inside the given box, bounded to w.
function P.right_text_box(bb, text, x, y, w, h, role, opts)
    opts = opts or {}
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = opts.face or Theme.face(role),
        bold = opts.bold,
        fgcolor = opts.color or Theme.ink,
        max_width = w,
    }
    local size = widget:getSize()
    widget:paintTo(
        bb,
        x + math.max(0, w - size.w),
        y + math.max(0, math.floor((h - size.h) / 2))
    )
    widget:free()
    return size
end

-- PNG dimensions from the IHDR chunk (pure io, no decoding). Used by
-- P.image's cover-fit mode to fill a container without stretching.
local function png_dims(file)
    local f = io.open(file, "rb")
    if not f then
        return nil
    end
    local sig = f:read(8)
    if sig ~= "\137PNG\r\n\26\n" then
        f:close()
        return nil
    end
    local ctype = f:read(8)
    local w = f:read(4)
    local h = f:read(4)
    f:close()
    if not ctype or ctype:sub(5) ~= "IHDR" or not w or not h then
        return nil
    end
    local function be32(s)
        local a, b, c, d = s:byte(1, 4)
        return (a * 16777216) + (b * 65536) + (c * 256) + d
    end
    local iw, ih = be32(w), be32(h)
    if iw and ih and iw > 0 and ih > 0 then
        return iw, ih
    end
    return nil
end

-- GIF dimensions from the logical screen descriptor (pure io, no
-- decoding): 6-byte signature, then little-endian u16 width/height.
local function gif_dims(file)
    local f = io.open(file, "rb")
    if not f then
        return nil
    end
    local head = f:read(10)
    f:close()
    if not head or #head < 10 or head:sub(1, 3) ~= "GIF" then
        return nil
    end
    local function le16(s)
        local a, b = s:byte(1, 2)
        return a + b * 256
    end
    local iw, ih = le16(head:sub(7, 8)), le16(head:sub(9, 10))
    if iw > 0 and ih > 0 then
        return iw, ih
    end
    return nil
end

-- SVG icons render at the exact requested size only when ImageWidget gets NO
-- scale_factor (nil lets renderSVGImageFile map the viewBox onto w×h); any
-- numeric scale_factor makes it aspect-keep instead.
local function exact_size_svg_icon(file, opts)
    return opts
        and opts.is_icon
        and tostring(file):lower():match("%.svg$") ~= nil
end

function P.image(bb, file, x, y, w, h, opts)
    if not file or file == "" then
        return false
    end
    opts = opts or {}
    -- cover: fill the container, cropping the overflow (scale to the larger
    -- ratio; ImageWidget centers the crop). Falls back to contain (scale to
    -- fit) when the dimensions can't be read.
    local scale_factor = 0
    if opts.cover then
        local iw, ih = P.image_dims(file)
        if iw and ih then
            scale_factor = math.max(w / iw, h / ih)
        end
    end
    local ok, widget = pcall(function()
        local image_opts = {
            file = file,
            width = w,
            height = h,
            alpha = opts.alpha ~= false,
            is_icon = opts.is_icon,
            file_do_cache = true,
        }
        if not exact_size_svg_icon(file, opts) then
            image_opts.scale_factor = opts.scale_factor or scale_factor
        end
        return ImageWidget:new(image_opts)
    end)
    if not ok or not widget then
        return false
    end
    -- Invert the rasterized ink (black <-> white) for icons on dark surfaces
    -- (filled pills, inverted theme). Alpha is preserved, so the silhouette
    -- stays clean; the double invert restores the cached bb afterwards.
    if opts.invert then
        pcall(function() widget:getSize() end)
    end
    if opts.invert and widget._bb then
        widget._bb:invert()
    end
    local painted = pcall(function()
        widget:paintTo(bb, x, y)
    end)
    if opts.invert and widget._bb then
        widget._bb:invert()
    end
    if widget.free then
        widget:free()
    end
    return painted
end

-- webp_dims parses the WebP container header (RIFF/VP8, VP8L or VP8X)
-- and returns width, height - used by image_dims for the cover crop
-- (remote thumbnails are typically WebP; png_dims cannot read them).
local function webp_dims(file)
    local f = io.open(file, "rb")
    if not f then
        return nil
    end
    local head = f:read(30)
    f:close()
    if not head or #head < 16 or head:sub(1, 4) ~= "RIFF" or head:sub(9, 12) ~= "WEBP" then
        return nil
    end
    local chunk = head:sub(13, 16)
    local function u16(s)
        local a, b = s:byte(1, 2)
        return a + b * 256
    end
    local function u24(s)
        local a, b, c = s:byte(1, 3)
        return a + b * 256 + c * 65536
    end
    if chunk == "VP8 " and #head >= 30 then
        -- lossy: frame tag (3) + sync 0x9D012A (3) then 14-bit dims
        if head:byte(24) == 0x9D and head:byte(25) == 0x01 and head:byte(26) == 0x2A then
            local w = head:byte(27) + head:byte(28) * 256
            local h = head:byte(29) + head:byte(30) * 256
            w = w % 16384
            h = h % 16384
            if w > 0 and h > 0 then return w, h end
        end
    elseif chunk == "VP8L" and #head >= 25 then
        -- lossless: signature 0x2F then 14-bit packed dims
        if head:byte(21) == 0x2F then
            local b1, b2, b3, b4 = head:byte(22, 25)
            local w = 1 + ((b1 % 64) + b2 * 64) % 16384
            local h = 1 + (b2 / 64 + (b3 % 16) * 4) % 16384
            w = math.floor(w)
            h = math.floor(h)
            if w > 0 and h > 0 then return w, h end
        end
    elseif chunk == "VP8X" and #head >= 30 then
        -- extended: 24-bit minus-one dims at offset 24 (canvas width/height)
        local w = u24(head:sub(25, 27)) + 1
        local h = u24(head:sub(28, 30)) + 1
        if w > 0 and h > 0 then return w, h end
    end
    return nil
end

-- image_dims returns the intrinsic pixel size of PNG or WebP files
-- (remote thumbnails are typically WebP; png_dims cannot read them).
function P.image_dims(file)
    if not file or file == "" then return nil end
    if file:lower():match("%.png$") then
        return png_dims(file)
    end
    if file:lower():match("%.webp$") then
        return webp_dims(file)
    end
    if file:lower():match("%.gif$") then
        return gif_dims(file)
    end
    local w, h = png_dims(file)
    if w then return w, h end
    return webp_dims(file)
end

function P.image_dimensions(file, max_width, max_height)
    if not file or file == "" or not max_width or max_width <= 0 then
        return nil
    end
    local ok, widget = pcall(function()
        return ImageWidget:new{
            file = file,
            width = max_width,
            height = max_height or max_width,
            scale_factor = 0,
            alpha = true,
            file_do_cache = true,
        }
    end)
    if not ok or not widget then
        return nil
    end
    local width, height
    local measured = pcall(function()
        local size = widget:getSize()
        local image = widget._bb
        if image then
            local image_width, image_height = image:getWidth(), image:getHeight()
            if image_width > 0 and image_height > 0 then
                width = math.min(max_width, image_width)
                height = math.max(1, math.floor(image_height * width / image_width + 0.5))
                if max_height and height > max_height then
                    height = max_height
                    width = math.max(1, math.floor(image_width * height / image_height + 0.5))
                end
            end
        end
        if not width and size and size.w and size.h and size.w > 0 and size.h > 0 then
            width = math.min(max_width, size.w)
            height = math.max(1, math.floor(size.h * width / size.w + 0.5))
            if max_height and height > max_height then
                height = max_height
                width = math.max(1, math.floor(size.w * height / size.h + 0.5))
            end
        end
    end)
    widget:free()
    if not measured then
        return nil
    end
    return width, height
end

-- Paint a horizontal window [source_y, source_y+h] of an image scaled to width
-- w (exact source-rect crop, no scratch buffer). Falls back to P.image.
function P.image_cropped(bb, file, x, y, w, h, source_h, source_y, opts)
    if not file or file == "" or w <= 0 or h <= 0 or not source_h or source_h <= 0 then
        return false
    end
    opts = opts or {}
    local base_ok, base = pcall(function()
        return ImageWidget:new{
            file = file,
            width = w,
            height = source_h,
            scale_factor = 0,
            alpha = opts.alpha ~= false,
            is_icon = opts.is_icon,
            file_do_cache = true,
        }
    end)
    if not base_ok or not base then
        return false
    end

    local painted = false
    local render_ok = pcall(function()
        base:getSize()
        local image = base._bb
        if image then
            local image_width = image:getWidth()
            if image_width > 0 then
                local center_y_ratio = math.max(0, math.min(1, (source_y + h / 2) / source_h))
                local widget = ImageWidget:new{
                    image = image,
                    image_disposable = false,
                    width = w,
                    height = h,
                    scale_factor = w / image_width,
                    alpha = opts.alpha ~= false,
                    is_icon = opts.is_icon,
                    center_x_ratio = 0.5,
                    center_y_ratio = center_y_ratio,
                }
                painted = pcall(function()
                    widget:paintTo(bb, x, y)
                end)
                if widget.free then
                    widget:free()
                end
            end
        end
    end)
    if base.free then
        base:free()
    end
    if render_ok and painted then
        return true
    end
    return P.image(bb, file, x, y, w, h, opts)
end

-- Cover-zoom an image inside (w, h) by `zoom` (centered crop).
function P.image_zoomed(bb, file, x, y, w, h, zoom, opts)
    opts = opts or {}
    zoom = zoom or 1
    if zoom <= 1 then
        return P.image(bb, file, x, y, w, h, opts)
    end
    if not file or file == "" then
        return false
    end

    local base_ok, base = pcall(function()
        return ImageWidget:new{
            file = file,
            width = w,
            height = h,
            scale_factor = 0,
            alpha = opts.alpha ~= false,
            is_icon = opts.is_icon,
            file_do_cache = true,
        }
    end)
    if not base_ok or not base then
        return false
    end

    local painted = false
    local render_ok = pcall(function()
        base:getSize()
        local image = base._bb
        if image then
            local iw, ih = image:getWidth(), image:getHeight()
            local widget = ImageWidget:new{
                image = image,
                image_disposable = false,
                width = w,
                height = h,
                scale_factor = math.max(w / iw, h / ih) * zoom,
                alpha = opts.alpha ~= false,
                is_icon = opts.is_icon,
                center_x_ratio = 0.5,
                center_y_ratio = 0.5,
            }
            painted = pcall(function()
                widget:paintTo(bb, x, y)
            end)
            if widget.free then
                widget:free()
            end
        end
    end)
    if base.free then
        base:free()
    end
    return render_ok and painted
end

function P.dim(bb, x, y, w, h, by)
    if w <= 0 or h <= 0 or not bb.lightenRect then
        return
    end
    pcall(function()
        bb:lightenRect(x, y, w, h, by or 0.5)
    end)
end

-- Theme-aware scrim behind modal surfaces: darkens the page on the light
-- theme, lightens it on the inverted one (P.dim only lightens, which is
-- invisible over a white background).
function P.scrim(bb, x, y, w, h, by)
    if w <= 0 or h <= 0 then
        return
    end
    by = by or 0.25
    if Theme.get_theme() == "inverted" then
        P.dim(bb, x, y, w, h, by)
    elseif bb.darkenRect then
        pcall(function()
            bb:darkenRect(x, y, w, h, by)
        end)
    else
        P.dim(bb, x, y, w, h, by)
    end
end

function P.hit(app, x, y, w, h, callback, label)
    table.insert(app.hitboxes, {
        x = x, y = y, w = w, h = h,
        callback = callback,
        label = label,
    })
end

-- Long-press hitbox: taps are consumed by an explicit no-op (same sweep
-- semantics as a tap callback); AppView:onHoldKotavern fires on_hold for
-- the topmost match. Never leave callback nil: onTapKotavern calls it.
function P.hit_hold(app, x, y, w, h, on_hold, label)
    table.insert(app.hitboxes, {
        x = x, y = y, w = w, h = h,
        callback = function() end,
        on_hold = on_hold,
        label = label,
    })
end

function P.contains(box, x, y)
    return x >= box.x and x <= box.x + box.w and y >= box.y and y <= box.y + box.h
end

function P.geom(x, y, w, h)
    return Geom:new{ x = x, y = y, w = w, h = h }
end

return P
