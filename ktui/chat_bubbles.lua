-- Chat message rendering for the canvas chat view.
-- Styles (Settings → Appearance → Chat style), mirroring ST chat_styles:
--   "bubbles" (ST BUBBLES, now the default): avatar COLUMN on the left and
--        every message inside a rounded panel (bot/user tints differ),
--        ST round avatars, ⋯ message-actions kebab in the name row.
--   "flat" (ST DEFAULT): same column layout, no panels; the user's message
--        sits on a subtle soft band. Densest option for e-ink.
--   "st" (legacy boxed): max-width bubbles, user right / char left.
--   "book" (ST DOCUMENT): document flow, no boxes, no dividers.
--   "rounded"/"square": legacy aliases of st with their corner radius.
--   "none": alias of flat.
-- Extras: optional ~N tok estimate in the name row (ST tokenCounter), an
-- inline swipe indicator (‹ n/N › +) under the last assistant message and
-- inline images (ST media) via ui/images.lua + the fullscreen viewer.
-- Content is Markdown + HTML (the ST subset) parsed by ui/md.lua and painted
-- with whole-line scrolling (no torn glyphs, no scratch buffer).

local P = require("ktui/primitives")
local Theme = require("ktui/theme")
local Icons = require("ktui/icons")
local Md = require("ktui/md")
local Widgets = require("ktui/widgets")
local Images = require("ktui/images")
local Models = require("kt_models")
local _ = require("gettext")

local ChatBubbles = {}

-- HH:MM timestamp from a unix epoch (matches the Send / send_date field).
local function format_time(ts)
    if type(ts) ~= "number" or ts <= 0 then return nil end
    return os.date("%H:%M", ts)
end

local function line_height(face)
    return math.floor((1 + 0.3) * (face and face.size or Theme.get_base_font_size()) + 0.5)
end

local STYLE_RADIUS = { st = 12, rounded = 6, square = 0 }

local function effective_style(style)
    if style == "flat" or style == "book" or style == "none" then
        return (style == "none") and "flat" or style
    end
    if style == "bubbles" then
        return "bubbles"
    end
    return "st" -- st / rounded / square / unknown
end

-- ST round avatar: square cover-fit image, corners carved back to the
-- surface color, 1px ring on top (see primitives P.circle_carve/ring).
local function draw_avatar(bb, x, y, size, image_file, name, carve_color)
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
        local initial = Widgets.first_glyph(name or "?"):upper()
        P.center_text_box(bb, initial, x, y, size, size, "small", { bold = true })
    end
end

-- === Block layout (two-pass: measure, then paint) ===

local function block_entries(blocks, width, app, show_inline)
    local entries = {}
    local gap = Theme.scale(8)
    for _, block in ipairs(blocks) do
        if block.kind == "rule" then
            table.insert(entries, { kind = "rule", h = Theme.scale(1) })
        elseif block.kind == "table" then
            -- ZenPM-style aligned table: equal columns measured from the
            -- content width, shaded header row, hairline rules between rows.
            local column_count = math.max(1, #(block.header or {}))
            local column_gap = Theme.scale(7)
            local column_width = math.max(1, math.floor((width - column_gap * (column_count - 1)) / column_count))
            local rule_h = Theme.scale(1)
            local function measure_row(cells, bold)
                local row_h = 1
                local out = {}
                for _, cell in ipairs(cells or {}) do
                    local cell_text = Md.inline(cell)
                    local lines, line_h = P.paragraph_metrics(cell_text, column_width, "small",
                        { bold = bold, line_height = 0.1 })
                    row_h = math.max(row_h, math.max(line_h, lines * line_h))
                    table.insert(out, cell_text)
                end
                return out, row_h
            end
            local rows = {}
            local total = Theme.scale(2)
            local header_cells, header_h = measure_row(block.header, true)
            table.insert(rows, { cells = header_cells, h = header_h, bold = true, offset = total })
            total = total + header_h + rule_h
            for _, cells in ipairs(block.rows or {}) do
                local out, rh = measure_row(cells, false)
                table.insert(rows, { cells = out, h = rh, bold = false, offset = total })
                total = total + rh + rule_h
            end
            table.insert(entries, {
                kind = "table",
                rows = rows,
                column_width = column_width,
                column_gap = column_gap,
                rule_h = rule_h,
                h = total + Theme.scale(2),
            })
        elseif block.kind == "image" then
            -- ST media: message images render inline. Repaint-safe: the
            -- measure pass only consults the disk cache; a miss schedules
            -- ONE background fetch (ui/images.lua) and shows a placeholder
            -- until the bits land and the chat repaints.
            local path = nil
            if show_inline then
                path = Images.cached_path(block.url)
                if not path then
                    Images.ensure(block.url, app)
                end
            end
            if path then
                local img_w, img_h = P.image_dimensions(path, math.max(8, width), Theme.scale(340))
                if img_w and img_h then
                    table.insert(entries, { kind = "image", path = path, w = img_w, h = img_h, alt = block.alt })
                else
                    table.insert(entries, { kind = "image_pending", alt = block.alt, h = Theme.scale(44) })
                end
            else
                table.insert(entries, { kind = "image_pending", alt = block.alt, h = Theme.scale(44) })
            end
        else
            local role, opts, pad = "default", {}, 0
            local text
            if block.kind == "code" then
                role = "small"
                pad = Theme.scale(8)
                opts.line_height = 0.1
                text = block.text
            elseif block.kind == "heading" then
                role = block.level == 1 and "heading" or "small"
                opts.bold = true
                text = Md.inline(block.text)
            elseif block.kind == "quote" then
                text = Md.inline(block.text)
                text = "│ " .. text:gsub("\n", "\n│ ")
            else
                text = Md.inline(block.text)
            end
            local text_width = math.max(1, width - pad * 2)
            local lines, line_h = P.paragraph_metrics(text, text_width, role, opts)
            table.insert(entries, {
                kind = block.kind == "code" and "code" or "text",
                text = text,
                role = role,
                opts = opts,
                h = math.max(line_h, lines * line_h) + pad * 2,
                line_h = line_h,
                pad = pad,
            })
        end
    end
    local total = 0
    for index, entry in ipairs(entries) do
        entry.offset = total
        total = total + entry.h
        if index < #entries then total = total + gap end
    end
    return entries, total, gap
end

-- Paint block entries inside the visible band [vis_top, vis_bottom]
-- (absolute y). content_y is the absolute y of the first entry. Whole-line
-- scrolling: a block cut at the top continues from its next full line; a
-- block cut at the bottom loses the torn line (ZenPM trick).
local function draw_blocks(view, bb, entries, cx, content_y, width, color, bg, vis_top, vis_bottom)
    for index, entry in ipairs(entries) do
        local entry_y = content_y + entry.offset
        local top = math.max(entry_y, vis_top)
        local bottom = math.min(entry_y + entry.h, vis_bottom)
        local band_h = bottom - top
        if band_h > 0 then
            if entry.kind == "rule" then
                P.rect(bb, cx, top, width, band_h, Theme.soft)
            elseif entry.kind == "table" then
                -- Whole-row culling: a row cut by the band edge is skipped
                -- (partial mono cells read as garbage on e-ink).
                for r, row in ipairs(entry.rows) do
                    local row_y = entry_y + row.offset
                    if row_y >= vis_top and row_y + row.h <= vis_bottom then
                        if r == 1 then
                            P.rect(bb, cx, row_y, width, row.h, Theme.soft)
                        end
                        for ci, cell_text in ipairs(row.cells) do
                            local cell_x = cx + (ci - 1) * (entry.column_width + entry.column_gap)
                            P.paragraph(bb, cell_text, cell_x, row_y, entry.column_width, row.h, "small",
                                { bold = row.bold, line_height = 0.1, color = color, bgcolor = bg })
                        end
                        if r < #entry.rows then
                            P.rect(bb, cx, row_y + row.h, width, entry.rule_h, Theme.soft)
                        end
                    end
                end
            elseif entry.kind == "image" then
                -- Whole-image culling: a slice of an image reads as garbage
                -- on e-ink, so images clipped by the band edge are skipped.
                if entry_y >= vis_top and entry_y + entry.h <= vis_bottom then
                    P.image(bb, entry.path, cx, entry_y, entry.w, entry.h, {})
                    P.hit(view, cx - Theme.scale(6), entry_y, entry.w + Theme.scale(12), entry.h, function()
                        if view.app.show_character_image_fullscreen then
                            view.app:show_character_image_fullscreen(entry.path)
                        end
                    end, "img_" .. tostring(entry_y))
                end
            elseif entry.kind == "image_pending" then
                local ph = entry.h
                if entry_y + ph > vis_top and entry_y < vis_bottom then
                    local box_w = math.min(width, Theme.scale(240))
                    P.box(bb, cx, entry_y, box_w, ph,
                        { border_color = Theme.soft, border_size = 1, background = bg, radius = Theme.scale(6) })
                    local label = _("Image") .. ((entry.alt and entry.alt ~= "") and (": " .. entry.alt) or "")
                    P.text(bb, Widgets.truncate(label, 30), cx + Theme.scale(8),
                        entry_y + math.floor((ph - Theme.line_h("tiny")) / 2),
                        box_w - Theme.scale(16), "tiny", { color = Theme.muted })
                end
            elseif entry.kind == "code" then
                P.box(bb, cx, top, width, band_h, { border = false, background = Theme.soft, radius = false })
                P.rect(bb, cx, top, Theme.scale(3), band_h, Theme.muted)
                local text_top = entry_y + entry.pad
                local text_bottom = entry_y + entry.h - entry.pad
                local text_y = math.max(top, text_top)
                local text_h = math.min(bottom, text_bottom) - text_y
                if entry_y + entry.h > vis_bottom then
                    text_h = text_h - entry.line_h
                end
                if text_h >= entry.line_h then
                    P.scrollable_paragraph(bb, entry.text, cx + entry.pad, text_y,
                        width - entry.pad * 2, text_h, entry.role,
                        math.max(0, text_y - text_top), entry.opts)
                end
            else
                local text_h = band_h
                if entry_y + entry.h > vis_bottom then
                    text_h = text_h - entry.line_h
                end
                if text_h >= entry.line_h then
                    P.scrollable_paragraph(bb, entry.text, cx, top, width, text_h, entry.role,
                        math.max(0, top - entry_y),
                        { color = color, bgcolor = bg, bold = entry.opts.bold, line_height = entry.opts.line_height })
                end
            end
        end
    end
end

-- Reasoning text of a message (internal field or ST extra.reasoning)
local function message_reasoning(msg)
    if type(msg.reasoning) == "string" and msg.reasoning ~= "" then
        return msg.reasoning
    end
    local extra = msg._st and msg._st.extra
    if type(extra) == "table" and type(extra.reasoning) == "string" and extra.reasoning ~= "" then
        return extra.reasoning
    end
    return nil
end

function ChatBubbles.draw(view, bb, x, y, w, h, scroll, messages, char_name, is_generating, user_name, char_image, thinking_frame)
    local settings = (view.app and view.app.state and view.app.state.settings) or {}
    local show_avatars = settings.show_avatars ~= false
    local show_inline = settings.show_inline_images ~= false
    local outline_user = not not settings.outline_user_bubbles
    local show_timestamps = not not settings.show_timestamps
    local show_tokens = not not settings.show_tokens
    local style = effective_style(Theme.get_bubble_style())
    local boxed = (style == "st")
    local panel_mode = (style == "bubbles")
    local radius = boxed and Theme.scale(STYLE_RADIUS[Theme.get_bubble_style()] or 12) or 0
    local dens = Theme.get_density()

    local pad = Theme.scale(10 * dens)
    local gap = Theme.scale(10 * dens)
    local av_mult = settings.avatar_size == "large" and 1.25 or (settings.avatar_size == "small" and 0.75 or 1.0)
    local avatar_size = math.floor(Theme.scale(48) * av_mult)
    local name_h = line_height(Theme.face("small")) + 2
    -- ST fa-ellipsis kebab (message actions) in the name row: 3 round dots.
    local kebab_r = math.max(2, math.floor(Theme.scale(6) / 2))
    local kebab_gap = Theme.scale(4)
    local kebab_w = kebab_r * 6 + kebab_gap * 2
    local user = user_name or "You"
    local user_image = (view.app and view.app._active_persona_avatar and view.app:_active_persona_avatar()) or nil
    local face = Theme.face("default")

    local thinking_text = nil
    if is_generating and thinking_frame then
        local n = (thinking_frame % 3) + 1
        thinking_text = string.rep("▌", n)
    end

    -- Right gutter keeps everything clear of the scrollbar thumb.
    local gutter = Theme.scale(18)
    local content_right = x + w - gutter
    -- ST bubbles: the panel wraps the whole message (avatar + name + text);
    -- the panel is inset by pad from the page, its content by pn_pad.
    local pn_pad = panel_mode and Theme.scale(10) or 0
    local panel_x = x + pad
    local panel_right = content_right - pad
    local inner_left = panel_mode and (panel_x + pn_pad) or (x + pad)
    local inner_right = panel_mode and (panel_right - pn_pad) or (content_right - pad)
    local area = math.max(8, inner_right - inner_left)
    -- ST bubbles cap at 78% of the area; flat/book use the full area.
    local max_bubble_w = math.floor(area * 0.78)

    -- Flat ST-DEFAULT geometry: the avatar is a COLUMN; all text (name row +
    -- content) starts right of it and uses the full remaining width.
    local flat = panel_mode or (style == "flat" or style == "book")
    local av_col_w = 0
    local col_text_x = inner_left
    local col_text_w = area
    if flat and show_avatars then
        av_col_w = avatar_size + Theme.scale(10)
        col_text_x = inner_left + av_col_w
        col_text_w = math.max(8, inner_right - col_text_x)
    end
    local text_w = boxed and math.max(1, math.min(area, max_bubble_w) - pad * 2)
        or (panel_mode and math.max(1, col_text_w) or math.max(1, col_text_w - pad * 2))
    local bubble_w = text_w + pad * 2

    local name_row_h = (flat and show_avatars) and math.max(name_h, avatar_size)
        or (show_avatars and math.max(name_h, avatar_size) or name_h)
    local av_dy = math.max(0, math.floor((name_row_h - avatar_size) / 2))
    local reasoning_open = (view.app and view.app.state and view.app.state.reasoning_open) or {}
    -- "Show more" state for clamped reasoning blocks (see the measure pass).
    local reasoning_full = (view.app and view.app.state and view.app.state.reasoning_full) or {}

    -- Pass 1: measure every message. The chat content starts one gap below
    -- the top edge: the first panel must NOT sit glued to the header hairline
    -- (the "balão colado no topo" the user called out).
    local layouts = {}
    local total_h = 0
    local cy = y + gap

    for i, msg in ipairs(messages or {}) do
        local is_user = (msg.role == "user")
        local is_system = (msg.role == "system") or (msg.hidden == true)
        local is_streaming = msg.is_streaming
        local display_name = is_user and user or (msg.name or char_name or "?")
        local content_text = msg.content or ""
        local reasoning = message_reasoning(msg)

        -- Auto-parse inline reasoning tags (configurable prefix/suffix).
        -- Covers streaming chunks and messages that were never finalized
        -- through the extraction step; already-extracted messages skip this.
        if not reasoning and settings.reasoning_auto_parse ~= false
            and not (is_user or is_system) then
            local clean, parsed = Models.extract_reasoning(
                content_text, settings.reasoning_prefix, settings.reasoning_suffix)
            if parsed then
                reasoning = parsed
                content_text = clean
            end
        end

        local layout = {
            idx = i,
            -- Stable per-message identity for UI state (reasoning open flag):
            -- keying by array index reattaches state to the wrong message
            -- after delete/move.
            msg_key = tostring(msg.send_date) .. ":" .. tostring(msg.name) .. ":" .. #content_text,
            is_user = is_user,
            is_system = is_system,
            is_streaming = is_streaming,
            send_date = msg.send_date,
            display_name = display_name,
            -- Prefer the provider's real completion_tokens (v0.6 usage capture)
            -- over the chars/4 estimate (ST token counters parity).
            tokens = tonumber(msg.completion_tokens) or math.ceil(#content_text / 4),
            tokens_real = tonumber(msg.completion_tokens) ~= nil,
            y = cy,
        }

        if is_system then
            -- Hidden / narrator messages: centered muted line, no bubble.
            local text = Widgets.truncate(content_text:gsub("%s+", " "), 300)
            local lines, line_h = P.paragraph_metrics(text, area, "small")
            layout.kind = "system"
            layout.h = lines * line_h + gap
            layout.entries = { { kind = "text", text = text, role = "small", opts = {}, h = lines * line_h, line_h = line_h, pad = 0, offset = 0 } }
            layout.content_h = lines * line_h
            total_h = total_h + layout.h
            cy = cy + layout.h
            layouts[i] = layout
        else
            local blocks
            if is_streaming then
                -- Partial markdown during streaming looks jumpy: plain text.
                blocks = { { kind = "paragraph", text = content_text .. " ▌" } }
            else
                -- Display-side regex scripts, then cache parse per message
                -- (content identity, not repaint count)
                local scripts = settings.regex_scripts
                if type(scripts) == "table" and #scripts > 0 then
                    content_text = require("kt_regex_engine").apply(content_text, scripts, "display")
                end
                if msg._md_sig ~= content_text then
                    msg._md_sig = content_text
                    msg._md_blocks = Md.parse(content_text)
                end
                blocks = msg._md_blocks
            end
            local entries, content_h, block_gap = block_entries(blocks, text_w, view.app, show_inline)
            layout.kind = boxed and "boxed" or style
            layout.entries = entries
            layout.content_h = content_h
            layout.block_gap = block_gap

            -- Reasoning (collapsible)
            layout.reasoning = reasoning
            layout.reasoning_h = 0
            if reasoning then
                -- Expanded: a muted, rule-indented section (NO nested box -
                -- the old full-width bordered box read as a panel inside the
                -- panel and glued to its edges). Text is measured at the SAME
                -- width it is drawn at (text column minus the rule gutter).
                if reasoning_open[layout.msg_key] then
                    local rtw = math.max(8, text_w - Theme.scale(8))
                    local rentries, rh = block_entries(Md.parse(reasoning), rtw, view.app, show_inline)
                    layout.reasoning_entries = rentries
                    layout.reasoning_tw = rtw
                    local head_pad = Theme.line_h("tiny") + Theme.scale(4) + Theme.scale(8)
                    local full_h = head_pad + rh
                    -- Height clamp: an expanded block never takes more than
                    -- half the viewport (a long reasoning used to push the
                    -- actual reply off-screen); a pinned "Show more" hint at
                    -- the section bottom expands it in place.
                    local cap = math.floor(h * 0.5)
                    local hint_h = Theme.line_h("tiny") + Theme.scale(4)
                    if reasoning_full[layout.msg_key] or full_h <= cap then
                        layout.reasoning_h = full_h
                    else
                        layout.reasoning_clamped = true
                        layout.reasoning_h = math.max(head_pad + hint_h, cap)
                    end
                else
                    layout.reasoning_h = Theme.line_h("tiny") + Theme.scale(6)
                end
            end

            -- Inline swipe indicator (ST): last assistant message, idle only.
            layout.swipes_h = 0
            if msg.role == "assistant" and i == #(messages or {}) and not is_generating and not is_streaming then
                layout.swipes_n = math.max(1, #(msg.swipes or { content_text }))
                layout.swipes_id = tonumber(msg.swipe_id) or 1
                layout.swipes_h = Theme.line_h("tiny") + Theme.scale(6)
            end

            if panel_mode then
                -- Bubbles: the panel wraps name row + reasoning + content +
                -- swipes (ST bubblechat wraps the whole .mes). Panel width =
                -- panel_x..panel_right; content is inset by pn_pad (the
                -- earlier area-based width let the text bg leak past the
                -- panel's right border).
                local panel_h = pn_pad + name_row_h + layout.reasoning_h + content_h + pn_pad + layout.swipes_h
                layout.bubble_y = cy
                layout.bubble_h = panel_h
                layout.bubble_w = panel_right - panel_x
                layout.bx = panel_x
                layout.cx = col_text_x
                layout.text_w = text_w
                layout.row_h = panel_h + gap
                cy = cy + layout.row_h
                total_h = total_h + layout.row_h
            else
                local bubble_h = content_h + pad * 2
                local row_h = name_row_h + layout.reasoning_h + bubble_h + layout.swipes_h + gap
                layout.bubble_y = cy + name_row_h + layout.reasoning_h
                layout.bubble_h = bubble_h
                layout.bubble_w = bubble_w
                layout.text_w = text_w
                if boxed then
                    layout.bx = is_user and (content_right - pad - bubble_w) or (x + pad)
                    layout.cx = layout.bx + pad
                else
                    -- Flat/book: content column starts right of the avatar column.
                    layout.bx = col_text_x - (is_user and Theme.scale(6) or 0)
                    layout.cx = col_text_x
                end
                layout.row_h = row_h
                cy = cy + row_h
                total_h = total_h + row_h
            end
            layouts[i] = layout
        end
    end

    -- Thinking bubble (non-streaming generation indicator)
    if thinking_text then
        local entries, content_h = block_entries(Md.parse(thinking_text), text_w, view.app, show_inline)
        local bubble_h = content_h + pad * 2
        local row_h = bubble_h + gap
        local layout = {
            kind = boxed and "boxed" or "flat", is_user = false, is_thinking = true,
            is_streaming = true, display_name = nil,
            -- y is REQUIRED: the paint pass computes top = l.y - scroll for
            -- every layout (its absence crashed the first thinking repaint).
            y = cy,
            entries = entries, content_h = content_h, text_w = text_w,
            bubble_y = cy + pad, bubble_w = bubble_w, bubble_h = bubble_h,
            bx = boxed and (x + pad) or col_text_x, cx = (boxed and (x + pad) or col_text_x) + pad, row_h = row_h,
        }
        layouts[#layouts + 1] = layout
        total_h = total_h + row_h
    end

    -- Bottom breathing room: the fully-scrolled view must always show a
    -- strip of paper under the last panel (the "balão cortado" report).
    total_h = total_h + Theme.scale(6)

    -- Clamp scroll before drawing (auto-scroll 999999 on first paint)
    local max_scroll = math.max(0, total_h - h)
    local clamped = math.max(0, math.min(scroll or 0, max_scroll))
    if clamped ~= (scroll or 0) and view.app and view.app.state then
        view.app.state.scroll[view.app:scroll_key()] = clamped
    end
    scroll = clamped

    -- Pass 2: draw
    -- NOTE: the loop variable must NOT be `_` - it would shadow the gettext
    -- alias inside the body (the reasoning rows call _("Reasoning") here and
    -- crashed with "attempt to call local '_' (a number value)").
    for _i, l in ipairs(layouts) do
        local top = l.y - scroll
        local bottom = top + (l.row_h or l.h)
        if bottom >= y and top <= y + h then
            if l.kind == "system" then
                -- Centered muted line
                draw_blocks(view, bb, l.entries, x + pad, top, area,
                    Theme.muted, Theme.chat_bg, math.max(top, y), math.min(bottom, y + h))
            else
                local srow_y = top
                local name_off = panel_mode and pn_pad or 0
                local panel_color = l.is_user and Theme.chat_panel_user or Theme.chat_panel
                local reasoning_y = srow_y + name_off + name_row_h
                local bubble_y = l.bubble_y - scroll

                -- ST bubbles: rounded panel behind the WHOLE message (avatar
                -- + name + text). Square edges when clipped by the viewport.
                if panel_mode and not l.is_thinking then
                    local pb_color = (l.is_streaming and Theme.ink) or Theme.soft
                    local pb_size = l.is_streaming and 2 or 1
                    local p_top = math.max(bubble_y, y)
                    local p_bottom = math.min(bubble_y + l.bubble_h, y + h)
                    local fully = bubble_y >= y and (bubble_y + l.bubble_h) <= y + h
                    if fully then
                        P.box(bb, panel_x, bubble_y, l.bubble_w, l.bubble_h, {
                            border_color = pb_color, border_size = pb_size,
                            background = panel_color, radius = Theme.scale(10),
                        })
                    else
                        local vis_h = p_bottom - p_top
                        if vis_h > 0 then
                            P.rect(bb, panel_x, p_top, l.bubble_w, vis_h, panel_color)
                            P.rect(bb, panel_x, p_top, pb_size, vis_h, pb_color)
                            P.rect(bb, panel_x + l.bubble_w - pb_size, p_top, pb_size, vis_h, pb_color)
                            if p_bottom >= bubble_y + l.bubble_h then
                                P.rect(bb, panel_x, p_bottom - pb_size, l.bubble_w, pb_size, pb_color)
                            end
                        end
                    end
                end

                -- Sender row.
                -- Flat/bubbles: avatar is a top-aligned COLUMN at the far
                -- left; the name (bold, ST ch_name) sits beside it with a
                -- muted timestamp after. Boxed: legacy inline row.
                local name_drawn = false
                if srow_y >= y - name_row_h - name_off and srow_y < y + h then
                    local sender_str = l.display_name or ""
                    local timestamp = show_timestamps and format_time(l.send_date) or nil
                    if flat and show_avatars and not l.is_thinking then
                        local carve = panel_mode and panel_color or Theme.chat_bg
                        -- NOTE: `a and b or c` falls through to c when b is nil:
                        -- with no persona avatar the user must get the initial
                        -- fallback (draw_avatar handles nil), never char_image.
                        local av_img = l.is_user and user_image or nil
                        if not l.is_user then av_img = char_image end
                        draw_avatar(bb, inner_left, srow_y + name_off, avatar_size,
                            av_img,
                            l.is_user and user or char_name, carve)
                        local ny = srow_y + name_off + math.floor((name_row_h - name_h) / 2)
                        local nx = col_text_x
                        local nw = math.max(1, inner_right - nx)
                        if sender_str ~= "" then
                            P.text(bb, sender_str, nx, ny, nw,
                                "small", { bold = true, color = Theme.ink })
                            if timestamp then
                                local nsize = P.text_size(sender_str, nw, "small", { bold = true })
                                local tx = nx + math.min(nsize.w, nw) + Theme.scale(6)
                                P.text(bb, timestamp, tx, ny + math.max(0, name_h - Theme.line_h("tiny") - 2),
                                    math.max(1, inner_right - tx), "tiny", { color = Theme.muted })
                            end
                        end
                        name_drawn = true
                    elseif l.is_user then
                        local boxed_str = sender_str .. (timestamp and ((sender_str ~= "" and "  " or "") .. timestamp) or "")
                        local av_x = content_right - pad - avatar_size
                        if show_avatars then
                            draw_avatar(bb, av_x, srow_y + av_dy, avatar_size, user_image, user, Theme.bg)
                        end
                        local name_right = av_x - Theme.scale(4)
                        local name_w = math.max(1, name_right - (x + pad))
                        local size = P.text_size(boxed_str, name_w, "tiny")
                        P.text(bb, boxed_str, name_right - math.min(size.w, name_w),
                            srow_y + math.floor((name_row_h - name_h) / 2), math.min(size.w, name_w),
                            "tiny", { color = Theme.muted })
                        name_drawn = true
                    else
                        local boxed_str = sender_str .. (timestamp and ((sender_str ~= "" and "  " or "") .. timestamp) or "")
                        local av_x = x + pad
                        if show_avatars and not l.is_thinking then
                            draw_avatar(bb, av_x, srow_y + av_dy, avatar_size, char_image, char_name, Theme.bg)
                        end
                        local name_x = show_avatars and (av_x + avatar_size + Theme.scale(4)) or av_x
                        local name_w = math.max(1, content_right - pad - name_x)
                        if boxed_str ~= "" then
                            P.text(bb, boxed_str, name_x,
                                srow_y + math.floor((name_row_h - name_h) / 2), name_w,
                                "tiny", { bold = true, color = Theme.ink })
                        end
                        name_drawn = true
                    end
                    -- Token estimate right of the name (legacy boxed only;
                    -- flat/bubbles draw it next to the kebab below).
                    if not flat and show_tokens and name_drawn and l.tokens and l.tokens > 0 then
                        local tok = "~" .. tostring(l.tokens) .. " " .. _("tok")
                        local tw = P.text_size(tok, nil, "tiny").w
                        P.text(bb, tok, inner_right - tw,
                            srow_y + math.floor((name_row_h - name_h) / 2),
                            math.min(tw, col_text_w), "tiny", { color = Theme.muted })
                    end
                end

                -- Message hold zone (clamped to the visible area): actions open
                -- on long-press or via the ⋯ kebab - never on tap. Registered
                -- BEFORE the reasoning/swipe hits below so the narrower bands
                -- win their taps (hitboxes are checked in reverse order);
                -- onHoldKotavern only fires boxes that declare on_hold.
                if not l.is_thinking then
                    local hy = math.max(top, y)
                    local hh = math.min(bottom, y + h) - hy
                    if hh > 0 then
                        P.hit_hold(view, x + pad, hy, area, hh, function()
                            if view.app.show_message_actions then
                                view.app:show_message_actions(l.idx)
                            end
                        end, "msghold_" .. l.idx)
                    end
                end

                -- Name-row right side: token estimate + ⋯ kebab (ST message
                -- actions). Registered AFTER the message hitbox so the kebab
                -- wins its taps (reverse-order hitbox checking).
                if flat and name_drawn and not l.is_thinking then
                    local row_y0 = srow_y + name_off
                    local kebab_x = inner_right - kebab_w
                    if show_tokens and l.tokens and l.tokens > 0 then
                        local tok = (l.tokens_real and tostring(l.tokens) or ("~" .. tostring(l.tokens))) .. " " .. _("tok")
                        local tw = P.text_size(tok, nil, "tiny").w
                        P.text(bb, tok, kebab_x - Theme.scale(8) - tw,
                            row_y0 + math.floor((name_row_h - Theme.line_h("tiny")) / 2),
                            tw + 2, "tiny", { color = Theme.muted })
                    end
                    local dot_cy = row_y0 + math.floor(name_row_h / 2)
                    for k = 0, 2 do
                        P.circle(bb, kebab_x + kebab_r + k * (kebab_r * 2 + kebab_gap), dot_cy, kebab_r, Theme.muted)
                    end
                    P.hit(view, kebab_x - Theme.scale(8), row_y0, kebab_w + Theme.scale(16), name_row_h, function()
                        if view.app.show_message_actions then
                            view.app:show_message_actions(l.idx)
                        end
                    end, "kebab_" .. l.idx)
                end

                -- Reasoning (collapsible): muted section with a left rule
                -- (quote-style indent), chevron fold marker, no nested box.
                if l.reasoning and reasoning_y + l.reasoning_h >= y and reasoning_y <= y + h then
                    local icon_size = Theme.scale(10)
                    local isz = Icons.text_size("chev-right", icon_size)
                    local label = _("Reasoning")
                    local head_y = reasoning_y + Theme.scale(2)
                    local head_h = Theme.line_h("tiny")
                    -- Shared header geometry (drawn in both states).
                    local rul_x = l.cx
                    local rul_y0 = head_y
                    local rul_y1 = reasoning_y + l.reasoning_h - Theme.scale(2)
                    if reasoning_open[l.msg_key] then
                        -- Left rule spanning the section (muted, 2px).
                        if rul_y1 > rul_y0 then
                            P.rect(bb, rul_x, rul_y0, Theme.scale(2), rul_y1 - rul_y0, Theme.muted)
                        end
                        -- Header row: chevron rotated down + label, then the
                        -- reasoning text indented past the rule.
                        Icons.draw(bb, "chev-down", rul_x + Theme.scale(8), head_y + math.floor((head_h - isz.h) / 2), icon_size, { color = Theme.muted })
                        P.text(bb, label, rul_x + Theme.scale(8) + isz.w + Theme.scale(6), head_y,
                            l.text_w - Theme.scale(8) - isz.w - Theme.scale(6), "tiny", { bold = true, color = Theme.muted })
                        local ry = head_y + head_h + Theme.scale(4)
                        local rtw = l.reasoning_tw or math.max(8, l.text_w - Theme.scale(8))
                        -- Clamped section: the body is clipped ABOVE a pinned
                        -- "Show more" hint so no text runs behind it.
                        local body_bottom = math.min(reasoning_y + l.reasoning_h, y + h)
                        local hint_h, hint_y
                        if l.reasoning_clamped then
                            hint_h = Theme.line_h("tiny")
                            hint_y = reasoning_y + l.reasoning_h - Theme.scale(6) - hint_h
                            body_bottom = math.min(body_bottom, hint_y - Theme.scale(2))
                            if hint_y + hint_h > y and hint_y < y + h then
                                P.text(bb, _("Show more") .. " ▾", rul_x + Theme.scale(8), hint_y,
                                    l.text_w - Theme.scale(8), "tiny", { bold = true, color = Theme.muted })
                            end
                        end
                        draw_blocks(view, bb, l.reasoning_entries, rul_x + Theme.scale(8), ry,
                            rtw, Theme.muted, panel_mode and panel_color or Theme.chat_bg,
                            math.max(ry, y), body_bottom)
                        P.hit(view, rul_x, reasoning_y, l.bubble_w - Theme.scale(8), math.min(l.reasoning_h, y + h - reasoning_y), function()
                            reasoning_open[l.msg_key] = nil
                            reasoning_full[l.msg_key] = nil
                            view:refresh()
                        end, "reasoning_" .. l.msg_key)
                        if l.reasoning_clamped then
                            -- Narrower than the collapse band and registered
                            -- AFTER it, so the hint wins its taps (reverse-order
                            -- hitbox checking).
                            P.hit(view, rul_x, hint_y - Theme.scale(4), l.bubble_w - Theme.scale(8), hint_h + Theme.scale(8), function()
                                reasoning_full[l.msg_key] = true
                                view:refresh()
                            end, "reasoning_more_" .. l.msg_key)
                        end
                    else
                        -- Collapsed: single muted line (chevron right + label).
                        local line_y = reasoning_y + math.floor((l.reasoning_h - head_h) / 2)
                        Icons.draw(bb, "chev-right", rul_x + Theme.scale(8), line_y + math.floor((head_h - isz.h) / 2), icon_size, { color = Theme.muted })
                        P.text(bb, label, rul_x + Theme.scale(8) + isz.w + Theme.scale(6), line_y,
                            l.text_w - Theme.scale(8) - isz.w - Theme.scale(6), "tiny", { color = Theme.muted })
                        P.hit(view, rul_x, reasoning_y, l.bubble_w - Theme.scale(8), l.reasoning_h, function()
                            reasoning_open[l.msg_key] = true
                            view:refresh()
                        end, "reasoning_" .. l.msg_key)
                    end
                end

                -- Bubble box (boxed style) / subtle user band (flat ST-DEFAULT)
                local bg = l.is_user and (outline_user and Theme.panel or Theme.soft) or Theme.panel
                local text_color = Theme.ink
                local border_color = (l.is_streaming and Theme.ink) or Theme.soft
                local border_size = (l.is_streaming or (l.is_user and outline_user)) and 2 or 1

                local vis_top = math.max(bubble_y, y)
                local vis_bottom = math.min(bubble_y + l.bubble_h, y + h)

                if boxed then
                    if bubble_y >= y then
                        P.box(bb, l.bx, bubble_y, l.bubble_w, l.bubble_h, {
                            border_color = border_color,
                            border_size = border_size,
                            background = bg,
                            radius = radius,
                        })
                    else
                        local vis_h = vis_bottom - vis_top
                        if vis_h > 0 then
                            P.rect(bb, l.bx, vis_top, l.bubble_w, vis_h, bg)
                            if border_size > 0 then
                                P.rect(bb, l.bx, vis_top, border_size, vis_h, border_color)
                                P.rect(bb, l.bx + l.bubble_w - border_size, vis_top, border_size, vis_h, border_color)
                                if vis_bottom >= bubble_y + l.bubble_h then
                                    P.rect(bb, l.bx, vis_bottom - border_size, l.bubble_w, border_size, border_color)
                                end
                            end
                        end
                    end
                    if l.is_streaming then
                        local ind_h = vis_bottom - vis_top
                        if ind_h > 0 then
                            P.rect(bb, l.bx, vis_top, Theme.scale(3), ind_h, Theme.ink)
                        end
                    end
                elseif style == "flat" and not l.is_thinking then
                    if l.is_user then
                        -- ST-DEFAULT user band: subtle full-width strip behind
                        -- the text (rounded when fully visible, square when
                        -- clipped at a viewport edge).
                        local vis_h = vis_bottom - vis_top
                        if vis_h > 0 then
                            if bubble_y >= y and vis_bottom >= bubble_y + l.bubble_h then
                                P.box(bb, l.bx, bubble_y, l.bubble_w, l.bubble_h,
                                    { border = false, background = Theme.soft, radius = Theme.scale(6) })
                            else
                                P.rect(bb, l.bx, vis_top, l.bubble_w, vis_h, Theme.soft)
                            end
                        end
                    elseif l.is_streaming then
                        -- Flat streaming: no side rule (too heavy next to
                        -- full-width text) - the ▌ text caret is the indicator.
                    end
                end

                -- Content
                local content_y
                if panel_mode and not l.is_thinking then
                    content_y = bubble_y + pn_pad + name_row_h + (l.reasoning_h or 0)
                else
                    content_y = bubble_y + pad
                end
                -- Thinking has no panel behind it - its text bg must be the
                -- chat surface, not the panel color (white box on paper).
                local content_bg = (panel_mode and not l.is_thinking) and panel_color
                    or (l.is_user and Theme.soft or Theme.chat_bg)
                if boxed then
                    draw_blocks(view, bb, l.entries, l.cx, content_y,
                        l.text_w, text_color, bg, vis_top, vis_bottom)
                else
                    draw_blocks(view, bb, l.entries, l.cx, content_y,
                        l.text_w, Theme.ink, content_bg,
                        math.max(content_y, y), math.min(content_y + l.content_h + pad, y + h))
                end

                -- Inline swipe indicator (ST): ‹ n/N › + under the bubble.
                if l.swipes_h and l.swipes_h > 0 and l.swipes_n then
                    -- Bubbles keep the swipe row INSIDE the panel (above the
                    -- bottom pad); flat puts it right under the text band.
                    local sy = panel_mode
                        and (bubble_y + l.bubble_h - pn_pad - l.swipes_h)
                        or (bubble_y + l.bubble_h)
                    if sy + l.swipes_h <= y + h and sy >= y - Theme.scale(20) then
                        local icon_size = Theme.scale(11)
                        local isz = Icons.text_size("chev-left", icon_size)
                        local row_cy = sy + math.floor((l.swipes_h - isz.h) / 2)
                        local sx = l.cx
                        local counter = ""
                        if l.swipes_n > 1 then
                            counter = tostring(l.swipes_id) .. "/" .. tostring(l.swipes_n)
                            -- ‹ previous
                            Icons.draw(bb, "chev-left", sx, row_cy, icon_size, { color = Theme.muted })
                            P.hit(view, sx - Theme.scale(6), sy, isz.w + Theme.scale(12), l.swipes_h, function()
                                view.app:cycle_swipe(l.idx, -1)
                            end, "swipe_prev_" .. l.idx)
                            sx = sx + isz.w + Theme.scale(10)
                            local csize = P.text_size(counter, nil, "tiny")
                            P.text(bb, counter, sx, sy + math.floor((l.swipes_h - csize.h) / 2),
                                csize.w + 2, "tiny", { color = Theme.muted })
                            sx = sx + csize.w + Theme.scale(10)
                            -- › next
                            Icons.draw(bb, "chev-right", sx, row_cy, icon_size, { color = Theme.muted })
                            P.hit(view, sx - Theme.scale(6), sy, isz.w + Theme.scale(12), l.swipes_h, function()
                                view.app:cycle_swipe(l.idx, 1)
                            end, "swipe_next_" .. l.idx)
                            sx = sx + isz.w + Theme.scale(14)
                        end
                        -- + new swipe
                        Icons.draw(bb, "plus", sx, row_cy, icon_size, { color = Theme.muted })
                        P.hit(view, sx - Theme.scale(6), sy, isz.w + Theme.scale(12), l.swipes_h, function()
                            view.app:regenerate_last()
                        end, "swipe_new_" .. l.idx)
                    end
                end
            end
        end
    end

    return total_h
end

-- Scroll snap step for the chat list: one full text line.
function ChatBubbles.line_step()
    return line_height(Theme.face("default"))
end

return ChatBubbles
