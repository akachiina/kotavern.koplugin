-- Chat message rendering for the canvas chat view.
-- Styles (Settings → Appearance → Chat style), mirroring ST chat_styles:
--   "bubbles" (ST BUBBLES, now the default): avatar COLUMN on the left and
--        every message inside a rounded panel (bot/user tints differ),
--        ST round avatars, ⋯ message-actions kebab in the name row.
--   "flat" (ST DEFAULT): same column layout, no panels; the user's message
--        sits on a subtle soft band. Densest option for e-ink.
--   "st" (legacy boxed): max-width bubbles, user right / char left.
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
    if style == "flat" or style == "none" then
        return (style == "none") and "flat" or style
    end
    if style == "bubbles" then
        return "bubbles"
    end
    return "st" -- st / rounded / square / unknown
end

-- ST avatar shape: the shared Widgets avatar (cover-fit image, corners
-- carved back to the surface color, ring). shape comes from the applied
-- chat theme first (round | rounded | square | rect - ST avatar_styles),
-- then the plain settings. "rect" paints the LANDSCAPE 4:3 box
-- (W.avatar_box_size); the geometry callers use avatar_w for it.
local function draw_avatar(view, bb, x, y, size, image_file, name, carve_color)
    local st = view.app and view.app.state or nil
    local shape = (st and st.chat_theme_applied and st.chat_theme_applied.avatar_shape)
        or (st and st.settings and st.settings.avatar_shape) or "round"
    if Widgets.avatar(bb, x, y, size, image_file, name, carve_color, shape) then
        view.dithered = true
    end
end

-- === Block layout (two-pass: measure, then paint) ===

-- HTML mode (experimental, Debug toggle): a message renders as ONE MuPDF
-- document (HtmlBoxWidget via KtHTML, real bold/italic/lists/tables), painted
-- as a single block entry. Measured once per content+width+theme (KtHTML's
-- tall-total scan), clipped per band like every other entry.

-- Compact + re-express the message for MuPDF. Model text is NOT trusted as
-- HTML: block structure is detected on the RAW line, then the line is
-- escaped and only WE emit tags (<b>, <s>, <br>, <a>, span classes) out of
-- the same markdown the canvas path handles. Without the <br>s MuPDF
-- collapses newlines into spaces (the crooked-chat report); without the
-- tag spans the raw syntax stays visible (~~, `, [], || - the "ainda não
-- renderiza" report). Escape order matters: `&<>` first, then markup is
-- re-injected over the escaped text.
local function chat_html_escape(line)
    return (line:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- Underscore emphasis with word-boundary rules (port of md.lua's
-- underscore_emphasis): `snake_case` and `file_name.txt` must NOT turn into
-- italics, only ` _spaced or word_ bounded ` markers do. * runs through plain
-- gsubs first (*** then ** then *), underscores go through this.
local function chat_underscore_emphasis(line, marker, open, close)
    local output = {}
    local position = 1
    while position <= #line do
        local start = line:find(marker, position, true)
        if not start then
            output[#output + 1] = line:sub(position)
            break
        end
        local before = start == 1 and "" or line:sub(start - 1, start - 1)
        local ending = line:find(marker, start + #marker, true)
        if before:match("[%w]") or not ending then
            output[#output + 1] = line:sub(position, start + #marker - 1)
            position = start + #marker
        else
            local text = line:sub(start + #marker, ending - 1)
            local after = line:sub(ending + #marker, ending + #marker)
            if text == "" or text:match("^%s") or text:match("%s$") or after:match("[%w]") then
                output[#output + 1] = line:sub(position, start + #marker - 1)
                position = start + #marker
            else
                output[#output + 1] = line:sub(position, start - 1)
                output[#output + 1] = open .. text .. close
                position = ending + #marker
            end
        end
    end
    return table.concat(output)
end

-- Case-insensitive letter for Lua tag patterns (no /i flag): ci("ab").
local function ci_letters(s)
    return (s:gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end))
end

-- Quoted attribute value (double or single quotes) from a raw attr string.
local function attr_quoted(attrs, name)
    local v = attrs:match(ci_letters(name) .. '%s*=%s*"([^"]*)"')
    if v == nil then
        v = attrs:match(ci_letters(name) .. "%s*=%s*'([^']*)'")
    end
    return v
end

-- Validated link target: http(s) only (ST drops javascript:/etc. schemes at
-- the DOMPurify step; our tap layer would ignore them anyway, but a
-- dead-looking link is worse than literal text).
local function valid_href(url)
    url = tostring(url or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if url:match("^[hH][tT][tT][pP][sS]?://") and #url <= 2048 then
        return url
    end
    return nil
end

-- Validated CSS color: #rgb/#rrggbb (short form expanded) or a named color.
-- Anything else degrades to uncolored text (a broken declaration must never
-- break the row).
local function valid_color(value)
    local v = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub(";%s*$", "")
    local hex = v:match("^#(%x+)$")
    if hex and (#hex == 3 or #hex == 6) then
        if #hex == 3 then
            hex = hex:sub(1, 1):rep(2) .. hex:sub(2, 2):rep(2) .. hex:sub(3, 3):rep(2)
        end
        return "#" .. hex:lower()
    end
    if v:match("^[A-Za-z]+$") and #v <= 20 then
        return v:lower()
    end
    return nil
end

-- Model-HTML allowlist (SillyTavern parity: ST renders a DOMPurify-default
-- subset instead of escaping everything). Runs on RAW text BEFORE escaping;
-- every conversion goes behind \1N\1 sentinels so the escape + markdown
-- stages never see our angle brackets (and emphasis can't pair across them).
-- Only <letter...>-shaped tags are touched (<3, "a<b", unquoted attrs stay
-- literal, like ST showing them through). Probe-verified MuPDF notes:
-- <u> is ignored (-> bold, same single-protocol choice the canvas path
-- makes); style="color:#hex" is honored (-> font color remapped to it);
-- align=center is honored (-> center remapped); tables collapse cells
-- without spacing (-> pipe-text rows, same as markdown tables).
local function chat_html_allowlist(raw, stash_html)
    local line = tostring(raw or "")
    -- Lone structural tags (no closer needed).
    line = line:gsub("<" .. ci_letters("br") .. "%f[^%w]%s*/?%s*>",
        function() return stash_html("<br>") end)
    line = line:gsub("<" .. ci_letters("hr") .. "%f[^%w]%s*/?%s*>", "---")
    -- <img ...> -> image link ([image: alt] label keeps the tap-to-open-URL
    -- utility; plain text when the src is missing/invalid).
    line = line:gsub("<" .. ci_letters("img") .. "%f[^%w](.-)>", function(attrs)
        local src = valid_href(attr_quoted(attrs, "src"))
        local alt = attr_quoted(attrs, "alt") or "image"
        if alt == "" then alt = "image" end
        local label = "[image: " .. chat_html_escape(alt) .. "]"
        if src then
            return stash_html('<a href="' .. src .. '">' .. label .. '</a>')
        end
        return label
    end)
    -- Paired tags, innermost-first to a fixpoint (nested different tags
    -- resolve inside-out; mismatched names never convert, so this ends).
    local changed, guard = true, 0
    while changed and guard < 10 do
        changed, guard = false, guard + 1
        line = line:gsub("<(%a[%w]*)%s*([^<>]*)>([^<>]-)</(%a[%w]*)%s*>",
            function(o, attrs, inner, c)
                if o:lower() ~= c:lower() then return nil end
                local name = o:lower()
                local out = nil
                if name == "b" or name == "strong" then
                    out = "<b>" .. chat_html_escape(inner) .. "</b>"
                elseif name == "i" or name == "em" then
                    out = "<i>" .. chat_html_escape(inner) .. "</i>"
                elseif name == "u" or name == "cite" then
                    out = "<b>" .. chat_html_escape(inner) .. "</b>"
                elseif name == "s" or name == "strike" or name == "del" then
                    out = "<s>" .. chat_html_escape(inner) .. "</s>"
                elseif name == "code" then
                    out = '<span class="ktcode">' .. chat_html_escape(inner) .. "</span>"
                elseif name == "small" then
                    out = "<small>" .. chat_html_escape(inner) .. "</small>"
                elseif name == "center" then
                    out = '<div align="center">'
                        .. chat_html_escape(inner) .. "</div>"
                elseif name == "a" then
                    local href = valid_href(attr_quoted(attrs, "href"))
                    if href then
                        out = '<a href="' .. href .. '">'
                            .. chat_html_escape(inner) .. "</a>"
                    else
                        out = chat_html_escape(inner)
                    end
                elseif name == "font" then
                    local color = valid_color(attr_quoted(attrs, "color"))
                    if color then
                        out = '<span style="color:' .. color .. '">'
                            .. chat_html_escape(inner) .. "</span>"
                    else
                        out = chat_html_escape(inner)
                    end
                elseif name == "span" then
                    local style = attr_quoted(attrs, "style") or ""
                    local color = valid_color(style:match("[cC][oO][lL][oO][rR]%s*:%s*([^;]+)") or "")
                    if color then
                        out = '<span style="color:' .. color .. '">'
                            .. chat_html_escape(inner) .. "</span>"
                    else
                        out = chat_html_escape(inner)
                    end
                end
                -- Unknown pairs (div/p/li/table/details/summary/...) are NOT
                -- converted here: block-level tags belong to the row scan
                -- (which consumes them structurally); reaching this point as
                -- inline means stray markup -> fall through to the strip.
                if out then
                    changed = true
                    return stash_html(out)
                end
                return nil
            end)
    end
    -- Lone allowlisted openers convert (browser auto-close parity: <b>oops
    -- bolds to the block end); lone closers fall into the strip below (ST
    -- drops them too).
    line = line:gsub("<(%a[%w]*)%s*([^<>]*)>", function(o, attrs)
        local name = o:lower()
        local open = nil
        if name == "b" or name == "strong" or name == "u" or name == "cite" then
            open = "<b>"
        elseif name == "i" or name == "em" then
            open = "<i>"
        elseif name == "s" or name == "strike" or name == "del" then
            open = "<s>"
        elseif name == "code" then
            open = '<span class="ktcode">'
        elseif name == "small" then
            open = "<small>"
        elseif name == "a" then
            local href = valid_href(attr_quoted(attrs, "href"))
            if href then open = '<a href="' .. href .. '">' end
        elseif name == "font" then
            local color = valid_color(attr_quoted(attrs, "color"))
            if color then open = '<span style="color:' .. color .. '">' end
        end
        if open then return stash_html(open) end
        return nil
    end)
    -- Whatever <letter...> is left is unknown/stray markup: drop the brackets
    -- (DOMPurify parity: unknown tags go, inner text stays). Non-letters
    -- (<3, a<b, unclosed) and already-stashed spans survive untouched.
    line = line:gsub("</?%a[%w]*%s*[^>]*>", "")
    return line
end

-- Inline markdown over ALREADY-ESCAPED text. Order matters: links and code
-- spans are converted FIRST and stashed behind \1N\1 sentinels so emphasis
-- never pairs markers across their payloads (two code spans each holding one
-- `*` used to italicize the HTML between them); then spoiler, strike and the
-- emphasis chain (*** before ** before *, underscores with word-boundary
-- rules). Italic is REAL italic here (the canvas path's bold-fallback choice
-- does not apply: chat_css @font-faces sans-italic.ttf for MuPDF).
-- state = { revealed = { [n]=true }, spl_n = 0 }: spoiler numbering is
-- document order across the whole body; a revealed index re-renders as an
-- open span, otherwise as an <a href="kt:spl:N"> the tap layer flips.
local function chat_html_markdown(line, state, stash_html)
    -- Quoted runs -> <q> (ST parity: its quote_text_color paints "..." via
    -- the same wrapper; the "set Quote red and the quoted text stayed
    -- plain" report). Stashed: the <q> tags never feed the emphasis gsubs.
    -- Straight "..." first (the common chat case), then curly “...”.
    line = line:gsub('"([^"]+)"', function(quoted)
        return stash_html('<q>"' .. quoted .. '"</q>')
    end)
    line = line:gsub('\u{201C}([^\u{201D}]+)\u{201D}', function(quoted)
        return stash_html("<q>\u{201C}" .. quoted .. "\u{201D}</q>")
    end)
    -- ![alt](url) -> image link (keeps the tap-to-open-URL utility; the
    -- stray "!" prefix would otherwise survive as literal noise).
    line = line:gsub("!%[([^%]]*)%]%(([^)%s]+)%)", function(alt, url)
        if alt == "" then alt = "image" end
        local label = "[image: " .. alt .. "]"
        if valid_href(url) then
            return stash_html('<a href="' .. url .. '">' .. label .. '</a>')
        end
        return label
    end)
    -- [label](url) -> anchor, http(s) only (ST drops other schemes at the
    -- sanitizer; a dead-looking link is worse than literal text). Runs on
    -- ESCAPED text: a & in the url is already &amp; (valid href).
    line = line:gsub("%[([^%]]*)%]%(([^)%s]+)%)", function(label, url)
        if valid_href(url) then
            return stash_html('<a href="' .. url .. '">' .. label .. '</a>')
        end
        return "[" .. label .. "](" .. url .. ")"
    end)
    line = line:gsub("`([^`]*)`", function(code)
        return stash_html('<span class="ktcode">' .. code .. '</span>')
    end)
    line = line:gsub("||([^|]-)||", function(secret)
        state.spl_n = state.spl_n + 1
        if state.revealed and state.revealed[state.spl_n] then
            return stash_html('<span class="ktspl ktsplopen">' .. secret .. '</span>')
        end
        return stash_html('<a href="kt:spl:' .. state.spl_n .. '" class="ktspl">' .. secret .. '</a>')
    end)
    line = line:gsub("~~(.-)~~", "<s>%1</s>")
    line = line:gsub("%*%*%*(.-)%*%*%*", "<b><i>%1</i></b>")
    line = line:gsub("%*%*(.-)%*%*", "<b>%1</b>")
    line = chat_underscore_emphasis(line, "__", "<b>", "</b>")
    line = line:gsub("%*(.-)%*", "<i>%1</i>")
    line = chat_underscore_emphasis(line, "_", "<i>", "</i>")
    return line
end

-- One inline fragment (row payload, summary text, table cell): model-HTML
-- allowlist on the RAW text, then escape, then the markdown stage, then
-- stash restore. Stash tokens (\1N\1, no markup chars) survive the escape
-- untouched, so converted spans never participate in emphasis pairing.
local function chat_html_fragment(raw, state)
    local stash = {}
    local function stash_html(html)
        stash[#stash + 1] = html
        return "\1" .. #stash .. "\1"
    end
    local conv = chat_html_allowlist(raw, stash_html)
    local out = chat_html_markdown(chat_html_escape(conv), state, stash_html)
    if #stash > 0 then
        out = out:gsub("\1(%d+)\1", function(n) return stash[tonumber(n)] or "" end)
    end
    return out
end

-- One markdown line -> one HTML row. Block structure is detected on the RAW
-- line; the payload is THEN escaped and the inline encoder runs on it. The
-- tags we emit are never part of the escaped payload (the previous order -
-- inject <a> raw, escape after - displayed the anchor source verbatim).
-- state threads the spoiler counter/reveal set across the whole body.
local function chat_html_line(line, out, state)
    local hashes, heading = line:match("^%s*(#+)%s+(.+)$")
    local quoted = line:match("^%s*>%s?(.*)$")
    local unordered = line:match("^%s*[-+*]%s+(.+)$")
    local indent, number, ordered_text = line:match("^(%s*)(%d+)[%.)]%s+(.+)$")
    local open, payload, close = "", line, ""
    if hashes then
        open, payload, close = "<b>", heading, "</b>"
    elseif quoted then
        -- Corner + muted span, the canvas path's quote treatment.
        open, payload, close = "\u{250c} <span class=\"ktq\">", quoted, "</span>"
    elseif unordered then
        payload = "\194\183 " .. unordered
    elseif number then
        payload = indent .. number .. ". " .. ordered_text
    end
    out[#out + 1] = open .. chat_html_fragment(payload, state) .. close
end

-- Match an opening tag by exact name (case-insensitive, attrs allowed):
-- has_open_tag(line, "details") finds <details>, <details open>, <DETAILS
-- class="x"> but NOT <detailsxyz> (the %f frontier requires a name
-- boundary: space, / or > right after the name). NOTE: Lua patterns have no
-- (group)? optionals - quantifiers only apply to single items.
local function has_open_tag(line, name)
    return line:find("<" .. ci_letters(name) .. "%f[^%w]")
end

-- Own-line tag (<tag ...> or </tag> alone, optional whitespace around).
local function own_line_tag(line, name)
    return line:match("^%s*</?" .. ci_letters(name) .. "%f[^%w][^>]*>%s*$")
end

local function chat_html_body(content, revealed, det_revealed)
    -- Rows are tagged text|fence; consecutive fence rows flush as CONTIGUOUS
    -- <p class="ktfence"> blocks (probe: contiguous <p> bands touch, no gap;
    -- a <br> inside/between inline-block spans left an empty white band),
    -- text rows join with <br>. Groups always join with <br> - probe-verified
    -- safe on both block boundaries (text->fence, fence->text).
    --
    -- Model-HTML block scan (ST parity): script/style ranges are dropped
    -- (no JS/CSS executes in MuPDF and literal code would be garbage rows);
    -- <pre> becomes fence rows; table rows become pipe-text rows (MuPDF
    -- collapses table cells without spacing); <ul>/<ol>/<li> become bullet
    -- /numbered rows; <blockquote> becomes quote rows; <h1-h6> become bold
    -- rows; <details> becomes a tap-to-expand group (MuPDF has no native
    -- disclosure widget, so it's re-expressed with the spoiler machinery:
    -- a kt:det:N summary header, body rows only when revealed).
    local rows = {}
    local state = { revealed = revealed, spl_n = 0,
        det_revealed = det_revealed, det_n = 0 }
    -- Details stack: frames { sum_raw, sum_acc, sum_done, rows }. Body rows
    -- buffer per frame; numbering (det_n) counts every group even when
    -- collapsed, so rebuilds number identically.
    local det_stack = {}
    local in_code, in_pre, in_script, in_style = false, false, false, false
    local in_quote, in_ol, ol_n = false, false, 0

    local function target_rows()
        if #det_stack > 0 then return det_stack[#det_stack].rows end
        return rows
    end
    local function emit(row)
        local t = target_rows()
        t[#t + 1] = row
    end
    local function text_row(html) emit({ kind = "text", html = html or "" }) end
    local function fence_row(html) emit({ kind = "fence", html = html or "" }) end

    -- Pop one details group: number it, emit the tappable summary header,
    -- then the buffered body only when revealed.
    local function close_details()
        local frame = det_stack[#det_stack]
        if not frame then return end
        det_stack[#det_stack] = nil
        state.det_n = state.det_n + 1
        local n = state.det_n
        local sum_raw = frame.sum_raw
        if not sum_raw or sum_raw == "" then sum_raw = "…" end
        local sum_html = chat_html_fragment(sum_raw, state)
        local is_open = state.det_revealed and state.det_revealed[n] and true or false
        local marker = is_open and "▾" or "▸"
        local t = target_rows()
        t[#t + 1] = { kind = "text",
            html = '<a href="kt:det:' .. n .. '" class="ktdet">'
                .. marker .. " " .. sum_html .. "</a>" }
        if is_open then
            for ri = 1, #frame.rows do
                t[#t + 1] = frame.rows[ri]
            end
        end
    end

    local function sum_append(top, t)
        if t == "" then return end
        if top.sum_raw and top.sum_raw ~= "" then
            top.sum_raw = top.sum_raw .. "\n" .. t
        else
            top.sum_raw = t
        end
    end

    local DET_O = "<" .. ci_letters("details") .. "%f[^%w][^>]*>"
    local DET_C = "</" .. ci_letters("details") .. "%f[^%w]%s*>"
    local SUM_O = "<" .. ci_letters("summary") .. "%f[^%w][^>]*>"
    local SUM_C = "</" .. ci_letters("summary") .. "%f[^%w]%s*>"

    -- Full block pipeline for one marker-free text line.
    local function process_block_line(text)
        -- Table cells -> pipe-text row (structure-only lines vanish).
        if has_open_tag(text, "table") or has_open_tag(text, "thead")
            or has_open_tag(text, "tbody") or has_open_tag(text, "tfoot")
            or has_open_tag(text, "tr") or has_open_tag(text, "td")
            or has_open_tag(text, "th") or has_open_tag(text, "caption") then
            local cap_o, cap_e, cap_inner = text:find("^%s*<"
                .. ci_letters("caption") .. "%f[^%w][^>]*>(.-)</"
                .. ci_letters("caption") .. "%f[^%w]%s*>%s*$")
            if cap_inner then
                text_row("<b>" .. chat_html_fragment(cap_inner, state) .. "</b>")
                return
            end
            local cells = {}
            for cell in text:gmatch("<[tT][dDhH]%f[^%w][^>]*>([^<]*)") do
                cells[#cells + 1] = cell
            end
            if #cells > 0 then
                local parts = {}
                for ci = 1, #cells do
                    parts[#parts + 1] = chat_html_fragment(cells[ci], state)
                end
                text_row("| " .. table.concat(parts, " | ") .. " |")
            end
            return
        end
        -- Lists: <ol> opens a numbered range (</ol> or <ul> closes it);
        -- <li> items emit bullet/numbered rows (flat, ST nests - noted).
        if has_open_tag(text, "ol") then in_ol, ol_n = true, 0 end
        if text:find("</" .. ci_letters("ol") .. "%f[^%w]%s*>")
            or has_open_tag(text, "ul") or text:find("</" .. ci_letters("ul") .. "%f[^%w]%s*>") then
            in_ol = false
        end
        do
            local pos, found_li = 1, false
            while true do
                local s, e = text:find("<" .. ci_letters("li") .. "%f[^%w][^>]*>", pos)
                if not s then break end
                found_li = true
                local e1 = text:find("</" .. ci_letters("li") .. "%f[^%w]%s*>", e + 1)
                local e2 = text:find("<" .. ci_letters("li") .. "%f[^%w]", e + 1)
                local e3 = text:find("</" .. ci_letters("ol") .. "%f[^%w]%s*>", e + 1)
                    or text:find("</" .. ci_letters("ul") .. "%f[^%w]%s*>", e + 1)
                local cut = #text + 1
                local ends = { e1, e2, e3 }
                for ei = 1, #ends do
                    if ends[ei] and ends[ei] < cut then cut = ends[ei] end
                end
                local item = text:sub(e + 1, cut - 1)
                local prefix = nil
                if in_ol then
                    ol_n = ol_n + 1
                    prefix = tostring(ol_n) .. ". "
                else
                    prefix = "\194\183 "
                end
                text_row(prefix .. chat_html_fragment(item, state))
                pos = cut
                if cut > #text then break end
                -- cut landed on a nested <li: loop continues from there;
                -- on a closer/EOL the next find fails and we stop.
                if text:sub(cut, cut) ~= "<" then break end
            end
            if found_li then return end
            -- Structure-only lines (<ul>, </ol>, ...) vanish entirely: as
            -- normal rows they would become empty <br> bands.
            if has_open_tag(text, "ul") or has_open_tag(text, "ol")
                or text:find("</" .. ci_letters("ul") .. "%f[^%w]%s*>")
                or text:find("</" .. ci_letters("ol") .. "%f[^%w]%s*>") then
                return
            end
        end
        -- Blockquote: full-single line or alone-line range (flat, no nest).
        do
            local bq = text:match("^%s*<" .. ci_letters("blockquote")
                .. "%f[^%w][^>]*>(.-)</" .. ci_letters("blockquote") .. "%f[^%w]%s*>%s*$")
            if bq then
                text_row("\u{250c} " .. '<span class="ktq">'
                    .. chat_html_fragment(bq, state) .. "</span>")
                return
            end
            if own_line_tag(text, "blockquote") then
                in_quote = not text:find("</")
                return
            end
            if in_quote then
                text_row("\u{250c} " .. '<span class="ktq">'
                    .. chat_html_fragment(text, state) .. "</span>")
                return
            end
        end
        -- Headings h1-h6, full-single line only (lone markers strip away).
        do
            local h1, inner, h2 = text:match("^%s*<[hH]([1-6])%f[^%w][^>]*>(.-)</[hH]([1-6])%f[^%w]%s*>%s*$")
            if h1 and tonumber(h1) == tonumber(h2) then
                text_row("<b>" .. chat_html_fragment(inner, state) .. "</b>")
                return
            end
        end
        -- Centered block, full-single line: <center> or <div|p align>.
        -- align validates left/right/center/justify (MuPDF honors them);
        -- plain div/p unwrap to a normal row; alone structure lines vanish.
        do
            local cinner = text:match("^%s*<" .. ci_letters("center")
                .. "%f[^%w][^>]*>(.-)</" .. ci_letters("center") .. "%f[^%w]%s*>%s*$")
            if cinner then
                text_row('<div align="center">' .. chat_html_fragment(cinner, state) .. "</div>")
                return
            end
            -- NOTE: Lua patterns have no %1 backreference; open/close names
            -- are matched in separate alternatives below.
            do
                local dinner = text:match("^%s*<"
                    .. ci_letters("div") .. "%f[^%w]%s*[^>]*>(.-)</"
                    .. ci_letters("div") .. "%f[^%w]%s*>%s*$")
                local pinner = text:match("^%s*<"
                    .. ci_letters("p") .. "%f[^%w]%s*[^>]*>(.-)</"
                    .. ci_letters("p") .. "%f[^%w]%s*>%s*$")
                if dinner ~= nil or pinner ~= nil then
                    local open = text:match("^%s*(<[^>]*>)") or ""
                    local av = (attr_quoted(open, "align") or ""):lower()
                    local alg = nil
                    if av == "left" or av == "right" or av == "center"
                        or av == "justify" then
                        alg = av
                    end
                    local payload = dinner or pinner or ""
                    -- div without useful align unwraps; p likewise.
                    if alg then
                        text_row('<div align="' .. alg .. '">'
                            .. chat_html_fragment(payload, state) .. "</div>")
                    else
                        text_row(chat_html_fragment(payload, state))
                    end
                    return
                end
            end
            if text:match("^%s*</?" .. ci_letters("div") .. "%f[^%w][^>]*>%s*$")
                or text:match("^%s*</?" .. ci_letters("p") .. "%f[^%w][^>]*>%s*$")
                or own_line_tag(text, "center") then
                return
            end
        end
        -- Markdown detection (lists/quotes/headings) on the raw line.
        local one = {}
        chat_html_line(text, one, state)
        text_row(one[1] or "")
    end

    -- Text segment: summary capture when the innermost group still needs one,
    -- otherwise the normal block pipeline (appends to the group buffer).
    local function text_segment(seg)
        if seg == "" then return end
        local top = det_stack[#det_stack]
        if top and not top.sum_done then
            local s, e = seg:find(SUM_O)
            if s then
                local pre = seg:sub(1, s - 1)
                if pre ~= "" then
                    if top.sum_acc then sum_append(top, pre)
                    else process_block_line(pre) end
                end
                local rest = seg:sub(e + 1)
                local cs, ce = rest:find(SUM_C)
                if cs then
                    sum_append(top, rest:sub(1, cs - 1))
                    top.sum_done, top.sum_acc = true, false
                    local post = rest:sub(ce + 1)
                    if post ~= "" then text_segment(post) end
                else
                    sum_append(top, rest)
                    top.sum_acc = true
                end
                return
            end
            local cs, ce = seg:find(SUM_C)
            if cs and top.sum_acc then
                sum_append(top, seg:sub(1, cs - 1))
                top.sum_done, top.sum_acc = true, false
                local post = seg:sub(ce + 1)
                if post ~= "" then text_segment(post) end
                return
            end
            if top.sum_acc then sum_append(top, seg); return end
            -- Pre-summary text without markers: buffered as body rows.
        end
        process_block_line(seg)
    end

    -- <script>/<style>: drop marker-to-close spans (single-line or range);
    -- surrounding text stays (ST parity: the tags never render, but the
    -- prose around them does).
    local function drop_script_style(ln)
        local rest = ln
        while rest ~= "" do
            local ss = rest:find("<" .. ci_letters("script") .. "%f[^%w]")
            local ys = rest:find("<" .. ci_letters("style") .. "%f[^%w]")
            local ms, is_script = nil, false
            if ss and (not ys or ss < ys) then
                ms, is_script = ss, true
            elseif ys then
                ms, is_script = ys, false
            else
                break
            end
            local head = rest:sub(1, ms - 1)
            if head:match("%S") then text_segment(head) end
            local cpat = is_script
                and ("</" .. ci_letters("script") .. "%f[^%w]%s*>")
                or ("</" .. ci_letters("style") .. "%f[^%w]%s*>")
            local cs, ce = rest:find(cpat, ms)
            if cs then
                rest = rest:sub(ce + 1)
            else
                if is_script then in_script = true else in_style = true end
                return
            end
        end
        if rest:match("%S") then text_segment(rest) end
    end

    for line in (tostring(content or "") .. "\n"):gmatch("(.-)\n") do
        if in_script or in_style then
            -- Close whichever ranges end on this line (possibly both); a
            -- tail that reopens a range routes through the same drop logic.
            -- Anything still in range (or empty) is dropped: literal JS/CSS
            -- would be garbage rows.
            local rest = line
            local again = true
            while again and (in_script or in_style) do
                again = false
                if in_script then
                    local cs, ce = rest:find("</" .. ci_letters("script") .. "%f[^%w]%s*>")
                    if cs then
                        in_script = false
                        rest = rest:sub(ce + 1)
                        again = true
                    end
                end
                if in_style then
                    local cs, ce = rest:find("</" .. ci_letters("style") .. "%f[^%w]%s*>")
                    if cs then
                        in_style = false
                        rest = rest:sub(ce + 1)
                        again = true
                    end
                end
            end
            if rest ~= "" and not in_script and not in_style then
                drop_script_style(rest)
            end
        elseif line:match("^%s*```") then
            in_code = not in_code
        elseif in_code then
            fence_row(chat_html_escape(line))
        elseif has_open_tag(line, "script") or has_open_tag(line, "style") then
            drop_script_style(line)
        elseif in_pre then
            local s, e = line:find("</" .. ci_letters("pre") .. "%f[^%w]%s*>")
            if s then
                in_pre = false
                local tail = line:sub(e + 1)
                if tail:match("%S") then text_segment(tail) end
            else
                fence_row(chat_html_escape(line))
            end
        elseif own_line_tag(line, "pre") then
            in_pre = true
        else
            -- Single-line <pre>inner</pre> anywhere on the line.
            local ps, pe, pinner = line:find("<" .. ci_letters("pre")
                .. "%f[^%w][^>]*>(.-)</" .. ci_letters("pre") .. "%f[^%w]%s*>")
            if ps then
                local head, tail = line:sub(1, ps - 1), line:sub(pe + 1)
                if head:match("%S") then text_segment(head) end
                fence_row(chat_html_escape(pinner))
                if tail:match("%S") then text_segment(tail) end
            else
                -- Details markers split the line; text pieces route through
                -- the summary/block pipeline above.
                local rest, handled = line, false
                while true do
                    local s, e = rest:find(DET_O)
                    local cs, ce = rest:find(DET_C)
                    local kind, ms, me = nil, nil, nil
                    if s and (not cs or s < cs) then
                        kind, ms, me = "open", s, e
                    elseif cs then
                        kind, ms, me = "close", cs, ce
                    else
                        break
                    end
                    handled = true
                    local pre = rest:sub(1, ms - 1)
                    local top = det_stack[#det_stack]
                    if kind == "open" then
                        if top and top.sum_acc and not top.sum_done then
                            -- Pathological: nested open inside summary
                            -- accumulation -> kept literally in the summary.
                            sum_append(top, rest:sub(ms, me))
                        elseif #det_stack >= 4 then
                            -- Absurd nesting: markers degrade through the
                            -- strip (vanish), content stays.
                            text_segment(rest:sub(ms, me))
                        else
                            if pre ~= "" then text_segment(pre) end
                            det_stack[#det_stack + 1] = {
                                sum_raw = nil, sum_acc = false,
                                sum_done = false, rows = {},
                            }
                        end
                    else
                        if top and top.sum_acc and not top.sum_done then
                            top.sum_done, top.sum_acc = true, false
                        end
                        if #det_stack == 0 then
                            -- Stray close: strip path vanishes it.
                            if pre ~= "" then text_segment(pre) end
                            text_segment(rest:sub(ms, me))
                        else
                            if pre ~= "" then text_segment(pre) end
                            close_details()
                        end
                    end
                    rest = rest:sub(me + 1)
                    if rest == "" then break end
                end
                if not handled then
                    text_segment(line)
                elseif rest ~= "" then
                    text_segment(rest)
                end
            end
        end
    end
    -- Unclosed groups flush as collapsed (markers dropped, body kept only
    -- in the buffer for a later toggle... no: collapsed shows summary only).
    while #det_stack > 0 do
        close_details()
    end
    local parts, pending_text = {}, nil
    for _, r in ipairs(rows) do
        if r.kind == "fence" then
            if pending_text then
                parts[#parts + 1] = table.concat(pending_text, "<br>")
                pending_text = nil
            end
            local f = parts[#parts]
            if f and f:match("</p>$") then
                parts[#parts] = f .. '<p class="ktfence">' .. r.html .. "</p>"
            else
                parts[#parts + 1] = '<p class="ktfence">' .. r.html .. "</p>"
            end
        else
            pending_text = pending_text or {}
            pending_text[#pending_text + 1] = r.html
        end
    end
    if pending_text then parts[#parts + 1] = table.concat(pending_text, "<br>") end
    -- Join parts with <br>, EXCEPT right after a fence <p>: its line break
    -- is the block boundary - an extra <br> paints an empty white row there
    -- (probe-verified; text->fence keeps the <br>, no double break there).
    local body = {}
    for i, part in ipairs(parts) do
        if i > 1 and not parts[i - 1]:match("</p>$") then
            body[#body + 1] = "<br>"
        end
        body[#body + 1] = part
    end
    -- MuPDF collapses \n: a literal <br> in the body is rewritten by
    -- setContent one-for-one into "&nbsp;<div></div>" - one visual row per
    -- source line, no extra empty band (probe-verified).
    return table.concat(body)
end

-- djb2 over the message body: doc keys embed the digest + length +
-- head/tail slices (collision would need same len, same hash AND matching
-- ends - acceptable for a 32-slot doc cache). Pure arithmetic (no bit
-- lib / no 5.3 bitops): every intermediate stays under 2^36, exact in
-- doubles on LuaJIT.
local function content_digest(str)
    local h = 5381
    for i = 1, #str do
        h = (h * 33 + str:byte(i)) % 2147483647
    end
    return string.format("%x", h)
end

local function html_doc_for(app, view, content, width, revealed, det_revealed, css_extra, role)
    if not app or not app.state then return nil end
    local docs = app.state.chat_html_docs
    if not docs then
        docs = {}
        app.state.chat_html_docs = docs
        docs.cap = 32 -- tall-bitmap cache cap; pruned below (see paint epoch)
        docs.n = 0    -- entry counter (amortized prune, audit D4: the
                      -- per-build pairs() count over the whole store was
                      -- O(n) per miss = O(N^2) opening a long chat)
    end
    local Constants = require("kt_constants")
    local Theme = require("ktui/theme")
    local Geom = require("ui/geometry")
    local HtmlBoxWidget = require("ui/widget/htmlboxwidget")
    local ChatTheme = require("ktui/chat_theme")
    -- One resolved theme (colors/text knobs merged with the settings) feeds
    -- the stylesheet AND the cache key: any knob change rebuilds the doc.
    local resolved = ChatTheme.resolved(app)
    -- The doc is blitted ONTO whatever the canvas painted behind it, so
    -- its background must MATCH that surface - by style and role:
    -- bubbles/boxed paint panels per role; flat paints a themed band on
    -- user messages and bare surface on assistant ones. One flat rule
    -- ("always the panel") painted the opaque blue "text stripe" inside
    -- gray bubbles the print reports caught.
    local eff_style = effective_style(Theme.get_bubble_style())
    local panel_bg
    if eff_style == "bubbles" or eff_style == "st" then
        panel_bg = (role == "user")
            and resolved.colors.user_panel
            or resolved.colors.ai_panel
    elseif (role == "user") and eff_style == "flat" then
        panel_bg = resolved.colors.user_panel
    else
        panel_bg = resolved.colors.surface
    end
    local doc_colors = {}
    for ck, cv in pairs(resolved.colors) do doc_colors[ck] = cv end
    doc_colors.surface = panel_bg
    local doc_resolved = {
        font_file = resolved.font_file,
        font_size = resolved.font_size,
        font_scale = resolved.font_scale,
        line_spacing = resolved.line_spacing,
        custom_css = resolved.custom_css,
        colors = doc_colors,
        sig = resolved.sig,
    }
    resolved = doc_resolved
    -- Revealed-spoiler / details indices participate in the key: a toggle
    -- re-runs the measure with a new set, which lands on a fresh doc without
    -- touching the masked render still cached for other messages.
    local function set_sig_local(set)
        if type(set) ~= "table" then return "" end
        local ks = {}
        for rk in pairs(set) do ks[#ks + 1] = tostring(rk) end
        table.sort(ks)
        return table.concat(ks, ",")
    end
    local key = table.concat({ content_digest(content), "\0",
        tostring(#content), "\0",
        content:sub(1, 16), "\0", content:sub(-16), "\0",
        tostring(width), "\0",
        resolved.sig, "\0", panel_bg,
        "\0", set_sig_local(revealed),
        "\0", set_sig_local(det_revealed), "\0", tostring(css_extra or "") }, "")
    local cached = docs[key]
    if cached and cached.width == width then
        return cached
    end
    if cached then
        pcall(function() if cached.widget then cached.widget:free() end end)
        docs[key] = nil
    end
    -- Prune: DOCs keyed by content grow with long chats; keep the last N.
    -- Never evict a doc whose layout was measured in the CURRENT paint
    -- (same-paint builds, or fast-pathed entries pass 2 below still needs):
    -- evicting those painted blank bands on first open of long chats.
    -- Evicted docs become eligible again on the next paint that builds;
    -- their layouts re-measure through the fast-path guard (visible ones
    -- rebuild in the same paint that needs them). Non-table slots (the cap
    -- field itself) are never victims.
    local paint_id = view and view._chat_paint_id or 0
    local live = {}
    local lc = view and view._chat_layout_cache or nil
    if type(lc) == "table" then
        for lk, l in pairs(lc) do
            if type(l) == "table" and l._paint_id == paint_id then
                for ei = 1, #(l.entries or {}) do
                    local e = l.entries[ei]
                    if type(e) == "table" and e.kind == "html" and e.widget then
                        live[e.widget] = true
                    end
                end
                -- Reasoning entries in HTML mode hold their own docs.
                for ri = 1, #(l.reasoning_entries or {}) do
                    local re = l.reasoning_entries[ri]
                    if type(re) == "table" and re.kind == "html" and re.widget then
                        live[re.widget] = true
                    end
                end
            end
        end
    end
    local n = docs.n or 0
    if n > (docs.cap or 32) + 1 then
        local victims = {}
        for k, v in pairs(docs) do
            if type(k) == "string" and k ~= key and type(v) == "table"
                and v.paint_id ~= paint_id
                and not live[v.widget] then
                victims[#victims + 1] = k
            end
        end
        local removed = 0
        for vi = 1, #victims do
            if removed >= n - (docs.cap or 32) then break end
            local k = victims[vi]
            local v = docs[k]
            pcall(function() if v.widget then v.widget:free() end end)
            docs[k] = nil
            removed = removed + 1
        end
        docs.n = math.max(0, n - removed)
    end
    local okp, perr = pcall(function()
        -- Live settings thread through so the custom chat font (KTUser
        -- @font-face), chat_font_size and custom_css all ride inside the
        -- same stylesheet; by-sig callers cache on the settings hash anyway.
        local css = require("ktui/kthtml").chat_css(resolved)
        -- Reasoning docs ride the same stylesheet plus a mute + indent layer
        -- (the canvas reasoning look): colors come from Theme live.
        if css_extra and css_extra ~= "" then
            css = css .. "\n" .. css_extra
        end
        -- font_scale layers on the base size (ST font_scale parity).
        local base_px = Theme.scale(Theme.get_base_font_size())
            * (tonumber(resolved.font_scale) or 1)
        base_px = math.max(8, math.floor(base_px + 0.5))
        local widget = HtmlBoxWidget:new{ dimen = Geom:new{ w = width, h = 96 } }
        widget:setContent(chat_html_body(content, revealed, det_revealed), css,
            base_px, false, nil, Constants.PLUGIN_DIR .. "/assets")
        local pages = widget.page_count or 1
        -- Tall bitmap: relayout at pages*96 then scan the exact bottom.
        local tall = math.max(96, pages * 96)
        widget.dimen = Geom:new{ w = width, h = tall }
        widget:setContent(chat_html_body(content, revealed, det_revealed), css,
            base_px, false, nil, Constants.PLUGIN_DIR .. "/assets")
        widget:_render()
        -- scan_bottom must compare against the DOC's own background (the
        -- theme surface), not the app palette - dark themes made every row
        -- read as ink.
        local last = require("ktui/kthtml").scan_bottom(widget.bb, width,
            resolved.colors.surface)
        local h = last and math.max(16, last) or 96
        docs[key] = { widget = widget, height = h, width = width, key = key,
            paint_id = view and view._chat_paint_id or 0 }
        docs.n = (docs.n or 0) + 1
    end)
    if not okp then
        require("logger").warn("chat html render failed: ", perr)
        docs[key] = nil
        return nil
    end
    return docs[key]
end

-- === Spoiler reveal + HTML-block taps ===

-- Reveal set for one message (session-scoped: dies with app.state, like the
-- reasoning open map). Lazy-created; the measure pass reads it to decide
-- which spoilers/details re-render open.
local function reveal_store(app, field, msg_key)
    if not app or not app.state or not msg_key then return {} end
    local all = app.state[field]
    if not all then
        all = {}
        app.state[field] = all
    end
    local set = all[msg_key]
    if not set then
        set = {}
        all[msg_key] = set
    end
    return set
end

function ChatBubbles.spoiler_state(app, msg_key)
    return reveal_store(app, "chat_spoilers_revealed", msg_key)
end

function ChatBubbles.details_state(app, msg_key)
    return reveal_store(app, "chat_details_revealed", msg_key)
end

-- The fast path may only reuse a cached layout while every html entry still
-- points at a live widget: the doc-cache prune frees evicted widgets, and
-- repainting a layout that references a freed one paints a blank band (the
-- "bugada" report on long chats). A dead widget forces the full re-measure,
-- which rebuilds the doc from the same content.
local function layout_html_alive(layout)
    if not layout then return true end
    for ei = 1, #(layout.entries or {}) do
        local entry = layout.entries[ei]
        if entry.kind == "html" then
            if not entry.widget or entry.widget.document == nil then
                return false
            end
        end
    end
    for ri = 1, #(layout.reasoning_entries or {}) do
        local entry = layout.reasoning_entries[ri]
        if entry.kind == "html" then
            if not entry.widget or entry.widget.document == nil then
                return false
            end
        end
    end
    return true
end

-- Layout-cache signature of a reveal set ("" when nothing is revealed):
-- a toggle must force the full re-measure, or the fast path would keep the
-- masked layout even after the doc cache entry was dropped.
local function set_sig(app, field, msg_key)
    if not app or not app.state or not msg_key then return "" end
    local all = app.state[field]
    local set = all and all[msg_key]
    if not set then return "" end
    local ks = {}
    for sk in pairs(set) do ks[#ks + 1] = tostring(sk) end
    table.sort(ks)
    return table.concat(ks, ",")
end

local function spoiler_sig(app, msg_key)
    return set_sig(app, "chat_spoilers_revealed", msg_key)
end

local function details_sig(app, msg_key)
    return set_sig(app, "chat_details_revealed", msg_key)
end

-- Drop one cached HTML doc (toggle path): the widget is freed now because
-- the next paint re-measures (reveal sig changed) and rebuilds before
-- painting anything, so nothing can still reference it.
local function invalidate_doc(app, entry)
    local docs = app.state and app.state.chat_html_docs
    if docs and entry.doc_key then
        local old = docs[entry.doc_key]
        if old and old.widget then
            pcall(function() old.widget:free() end)
        end
        if old then docs.n = math.max(0, (docs.n or 1) - 1) end
        docs[entry.doc_key] = nil
    end
end

-- Tap inside a chat HTML band, already translated to widget-local
-- tall-bitmap coords by the hitbox (band offset included). Looks the link up
-- (getLinkByPosition, same probe the kt: pages use - the global
-- tap_to_follow_links switch is bypassed on purpose). kt:spl:N flips that
-- spoiler's reveal and rebuilds the doc; http(s) opens the KOReader
-- external-link dialog; every other scheme is ignored.
function ChatBubbles.chat_html_tap(view, entry, msg_key, lx, ly)
    local widget = entry.widget
    if not widget or not widget.getLinkByPosition then return end
    local ok_t, link = pcall(widget.getLinkByPosition, widget, { x = lx, y = ly })
    if not ok_t or not link then return end
    local uri = tostring(link.uri or link.url or "")
    if uri:find("^kt:spl:", 1) then
        local n = tonumber(uri:match("^kt:spl:(%d+)$"))
        if not n or not view.app then return end
        local set = ChatBubbles.spoiler_state(view.app, msg_key)
        if set[n] then set[n] = nil else set[n] = true end
        invalidate_doc(view.app, entry)
        if view.refresh then view:refresh() end
    elseif uri:find("^kt:det:", 1) then
        local n = tonumber(uri:match("^kt:det:(%d+)$"))
        if not n or not view.app then return end
        local set = ChatBubbles.details_state(view.app, msg_key)
        if set[n] then set[n] = nil else set[n] = true end
        invalidate_doc(view.app, entry)
        if view.refresh then view:refresh() end
    elseif uri:find("^https?://", 1) then
        ChatBubbles.show_external_link(view.app, uri)
    end
end

-- KOReader-style external link dialog (readerlink.lua parity): Copy / Show
-- QR code / Open in browser. Everything is lazy-required so the chat paint
-- path never loads dialog widgets, and the smoke can stub them.
function ChatBubbles.show_external_link(app, url)
    local UIManager = require("ui/uimanager")
    local Device = require("device")
    local _ = require("gettext")
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = url,
        buttons = {
            { { text = _("Copy"),
                callback = function()
                    if Device.input and Device.input.setClipboardText then
                        Device.input.setClipboardText(url)
                    end
                    UIManager:close(dialog)
                end } },
            { { text = _("Show QR code"),
                callback = function()
                    UIManager:close(dialog)
                    local QRMessage = require("ui/widget/qrmessage")
                    UIManager:show(QRMessage:new{
                        text = url,
                        width = Device.screen:getWidth(),
                        height = Device.screen:getHeight(),
                    })
                end } },
            { { text = _("Open in browser"),
                callback = function()
                    UIManager:close(dialog)
                    if Device:canOpenLink() then
                        Device:openLink(url)
                    end
                end,
                show_in_dialog_func = function()
                    return Device:canOpenLink()
                end } },
        },
    }
    UIManager:show(dialog)
end

local function block_entries(blocks, width, app, show_inline, view, body_face)
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
        elseif block.kind == "html" then
            -- Experimental HTML render: the WHOLE message body goes through
            -- MuPDF (real bold/italic/lists/tables), measured once and cached
            -- per content+width+font+reveal (chat_html_docs on app.state). A
            -- failed render falls back to the plain-text parse, never a blank
            -- bubble. doc.key rides along so the spoiler tap can invalidate
            -- exactly this doc.
            local doc = html_doc_for(app, view, block.text, width,
                block.revealed, block.det_revealed, nil, block.role)
            if doc and doc.height then
                table.insert(entries, {
                    kind = "html", widget = doc.widget,
                    h = doc.height, doc_key = doc.key, pad = 0, offset = 0,
                })
            else
                local fallback = block.text:gsub("<[^>]->", "")
                local lines, line_h = P.paragraph_metrics(fallback, width, "default")
                table.insert(entries, {
                    kind = "text", text = fallback, role = "default", opts = {},
                    h = math.max(line_h, lines * line_h), line_h = line_h, pad = 0, offset = 0,
                })
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
            -- Custom chat font (Appearance > Chat): body paragraphs render
            -- on the user's face; headings keep the system hierarchy face.
            if body_face and role == "default" then
                opts.face = body_face
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
-- hit_ctx (optional) enables interactive HTML blocks: when it carries
-- msg_key, every visible html band registers a tap hitbox AFTER the caller's
-- msghold box (reverse-order checking), so links/spoilers win taps while
-- long-press still reaches the hold zone underneath.
local function draw_blocks(view, bb, entries, cx, content_y, width, color, bg, vis_top, vis_bottom, hit_ctx)
    for index, entry in ipairs(entries) do
        local entry_y = content_y + entry.offset
        local top = math.max(entry_y, vis_top)
        local bottom = math.min(entry_y + entry.h, vis_bottom)
        local band_h = bottom - top
        if band_h > 0 then
            if entry.kind == "rule" then
                P.rect(bb, cx, top, width, band_h, Theme.chat_border)
            elseif entry.kind == "table" then
                -- Whole-row culling: a row cut by the band edge is skipped
                -- (partial mono cells read as garbage on e-ink). Shading
                -- derives from the THEME border color: palette soft painted
                -- a light band under the themed light header text (an
                -- invisible header on dark themes).
                for r, row in ipairs(entry.rows) do
                    local row_y = entry_y + row.offset
                    if row_y >= vis_top and row_y + row.h <= vis_bottom then
                        if r == 1 then
                            P.rect(bb, cx, row_y, width, row.h, Theme.chat_border)
                        end
                        for ci, cell_text in ipairs(row.cells) do
                            local cell_x = cx + (ci - 1) * (entry.column_width + entry.column_gap)
                            P.paragraph(bb, cell_text, cell_x, row_y, entry.column_width, row.h, "small",
                                { bold = row.bold, line_height = 0.1, color = color, bgcolor = bg })
                        end
                        if r < #entry.rows then
                            P.rect(bb, cx, row_y + row.h, width, entry.rule_h, Theme.chat_border)
                        end
                    end
                end
            elseif entry.kind == "image" then
                -- Whole-image culling: a slice of an image reads as garbage
                -- on e-ink, so images clipped by the band edge are skipped.
                if entry_y >= vis_top and entry_y + entry.h <= vis_bottom then
                    P.image(bb, entry.path, cx, entry_y, entry.w, entry.h, {})
                    view.dithered = true -- photo bitmap: dithered refresh
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
                        box_w - Theme.scale(16), "tiny", { color = Theme.chat_muted })
                end
            elseif entry.kind == "html" then
                -- Experimental HTML render: blit the VISIBLE slice of the
                -- tall bitmap. The source offset MUST track the band
                -- (top - entry_y, like the text branch's scroll offset): a
                -- constant src_y re-stamped the doc's head rows on every
                -- scrolled band, so tall bubbles could never show their tail
                -- (the "mensagem cortada" report).
                if entry.widget and band_h > 0 then
                    local okp = pcall(function()
                        entry.widget:_render()
                        local src_y = math.max(0, top - entry_y)
                        local src_h = entry.widget.bb and entry.widget.bb:getHeight() or 0
                        local copy_h = math.min(band_h, math.max(0, src_h - src_y))
                        if copy_h > 0 then
                            bb:blitFrom(entry.widget.bb, cx, top, 0, src_y, width, copy_h)
                        end
                    end)
                    if okp then
                        view.dithered = true
                    end
                    -- Tap zone for links + spoiler reveals (message bodies
                    -- only - hit_ctx is nil for system/reasoning draws).
                    -- Widget-local coords account for the band offset (same
                    -- src_y as the blit above): a tap lands on the link rect
                    -- only when translated by the visible slice.
                    if hit_ctx and hit_ctx.msg_key and entry.doc_key then
                        local hb_src_y = math.max(0, top - entry_y)
                        P.hit(view, cx, top, width, band_h, function(tapx, tapy)
                            ChatBubbles.chat_html_tap(view, entry, hit_ctx.msg_key,
                                tapx - cx, hb_src_y + (tapy - top))
                        end, "chathtml_" .. hit_ctx.msg_key)
                    end
                end
            elseif entry.kind == "code" then
                P.box(bb, cx, top, width, band_h, { border = false, background = Theme.soft, radius = false })
                P.rect(bb, cx, top, Theme.scale(3), band_h, Theme.chat_muted)
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
                        { color = color, bgcolor = bg, bold = entry.opts.bold, line_height = entry.opts.line_height, face = entry.opts.face })
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
    -- Paint epoch: html docs built during THIS paint must survive its own
    -- prune pass (their layouts were just measured above and pass 2 below
    -- still needs their widgets). html_doc_for stamps it per doc and the
    -- prune skips same-epoch docs.
    view._chat_paint_id = (view._chat_paint_id or 0) + 1
    local settings = (view.app and view.app.state and view.app.state.settings) or {}
    -- An applied bubble theme (chat override or global default) overrides the
    -- detail toggles; plain settings otherwise.
    local theme_live = view.app and view.app.state and view.app.state.chat_theme_applied or nil
    local show_avatars = (theme_live and theme_live.show_avatars ~= nil)
        and (theme_live.show_avatars == true) or (settings.show_avatars ~= false)
    local show_inline = settings.show_inline_images ~= false
    local outline_user = (theme_live and theme_live.outline_user_bubbles ~= nil)
        and (theme_live.outline_user_bubbles == true)
        or (settings.outline_user_bubbles == true)
    local show_timestamps = (theme_live and theme_live.show_timestamps ~= nil)
        and (theme_live.show_timestamps == true) or (settings.show_timestamps == true)
    local show_tokens = (theme_live and theme_live.show_tokens ~= nil)
        and (theme_live.show_tokens == true) or (settings.show_tokens == true)
    -- ST mesIDDisplay / timer_enabled ports (theme keys; plain settings
    -- never carry them, so no fallback chain needed).
    local show_msg_ids = (theme_live and theme_live.show_msg_ids == true) or false
    local show_gen_timer = (theme_live and theme_live.show_gen_timer == true) or false
    -- Experimental: whole-message HTML render (Debug toggle, false default).
    local html_render = settings.chat_html_render == true
    local style = effective_style(Theme.get_bubble_style())
    local boxed = (style == "st")
    local panel_mode = (style == "bubbles")
    local radius = boxed and Theme.scale(STYLE_RADIUS[Theme.get_bubble_style()] or 12) or 0
    local dens = Theme.get_density()

    local pad = Theme.scale(10 * dens)
    local gap = Theme.scale(10 * dens)
    -- Chat theme wins for the keys it carries (themes are FULL snapshots,
    -- ST semantics); plain settings otherwise.
    local av_size_setting = (theme_live and theme_live.avatar_size)
        or settings.avatar_size
    local av_mult = av_size_setting == "large" and 1.25
        or (av_size_setting == "small" and 0.75 or 1.0)
    local avatar_size = math.floor(Theme.scale(48) * av_mult)
    -- Avatar WIDTH per shape: "rect" is landscape 4:3 (ST avatar_style 1).
    -- Height (and every vertical metric) stays `avatar_size`; only the
    -- width-sensitive geometry below uses avatar_w.
    local av_shape = (theme_live and theme_live.avatar_shape)
        or settings.avatar_shape or "round"
    local avatar_w = select(1, Widgets.avatar_box_size(avatar_size, av_shape))
    local name_h = line_height(Theme.face("small")) + 2
    -- ST fa-ellipsis kebab (message actions) in the name row: 3 round dots.
    local kebab_r = math.max(2, math.floor(Theme.scale(6) / 2))
    local kebab_gap = Theme.scale(4)
    local kebab_w = kebab_r * 6 + kebab_gap * 2
    local user = user_name or "You"
    local user_image = (view.app and view.app._active_persona_avatar and view.app:_active_persona_avatar()) or nil
    local face = Theme.face("default")
    -- Custom chat font (Appearance > Chat): message bodies + inline
    -- reasoning render on the user's face; chrome stays on the system face.
    local body_face = Theme.chat_face()

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
    -- ST chat_width (25..100%): narrows the whole message column - panels
    -- included (ST narrows #chat itself via --sheldWidth), centered. 100 and
    -- anything above keep the old full-width geometry. Flat has no panels,
    -- so the same bounds ARE the text column. The chat theme wins when one
    -- is applied (full-snapshot semantics).
    local cw_pct = tonumber((theme_live and theme_live.chat_width)
        or settings.chat_width) or 100
    if cw_pct < 100 then
        cw_pct = math.max(25, math.min(100, cw_pct))
        -- Gutter-aware centering: the scrollbar track lives OUTSIDE the
        -- centered column, so shrink against the pre-gutter right edge
        -- (panel_right already excludes the gutter; also exclude the LEFT
        -- pad mirror so the column is optically centered between the
        -- screen edges, not the scroll area - the "150 vs 172 margins").
        local full_w = panel_right - panel_x
        local col_w = math.floor(full_w * (cw_pct / 100))
        local inset = math.floor((full_w - col_w) / 2)
        panel_x = panel_x + inset
        panel_right = panel_right - inset
    end
    local inner_left = panel_mode and (panel_x + pn_pad) or panel_x
    local inner_right = panel_mode and (panel_right - pn_pad) or panel_right
    local area = math.max(8, inner_right - inner_left)
    -- ST bubbles cap at 78% of the area; flat uses the full area.
    local max_bubble_w = math.floor(area * 0.78)

    -- Flat ST-DEFAULT geometry: the avatar is a COLUMN; all text (name row +
    -- content) starts right of it and uses the full remaining width.
    local flat = panel_mode or (style == "flat")
    local av_col_w = 0
    local col_text_x = inner_left
    local col_text_w = area
    if flat and show_avatars then
        av_col_w = avatar_w + Theme.scale(10)
        col_text_x = inner_left + av_col_w
        col_text_w = math.max(8, inner_right - col_text_x)
    end
    local text_w = boxed and math.max(1, math.min(area, max_bubble_w) - pad * 2)
        or (panel_mode and math.max(1, col_text_w) or math.max(1, col_text_w - pad * 2))
    local bubble_w = text_w + pad * 2

    -- === Incremental measure cache (perf P1) ===
    -- Pass 1 used to re-measure EVERY message on EVERY repaint (~0.29ms per
    -- message on the bench, including off-screen ones). Layouts are cached
    -- per message key and re-measured only when their validity signature
    -- changes; y positions are recomputed every paint from cached heights.
    local layout_cache = rawget(view, "_chat_layout_cache")
    -- Chat-level inputs shared by every entry: style, metrics, settings and
    -- the chat itself. Any change rebuilds the cache from scratch.
    local chat_sig = table.concat({
        style, tostring(dens), tostring(pad), tostring(gap),
        tostring(avatar_size), tostring(avatar_w), tostring(show_avatars), tostring(show_inline),
        tostring(outline_user), tostring(show_timestamps), tostring(show_tokens),
        tostring(boxed), tostring(panel_mode), tostring(radius),
        tostring(dens), -- global density: pad/gap/metrics scale with it
        tostring(w), tostring(text_w), tostring(bubble_w),
        tostring(settings.avatar_size), tostring(settings.chat_width),
        tostring(settings.reasoning_prefix), tostring(settings.reasoning_suffix),
        tostring(settings.chat_font_file), tostring(settings.chat_font_size),
        tostring(settings.custom_css),
        -- The applied chat theme participates whole: a theme change (or a
        -- per-chat override) must rebuild every cached layout.
        tostring(view.app and view.app.state
            and view.app.state.chat_theme_applied
            and require("ktui/chat_theme").sig(view.app.state.chat_theme_applied) or ""),
        tostring(view.app and view.app.state and view.app.state.current_chat_path),
    }, "|")
    if not layout_cache or chat_sig ~= rawget(view, "_chat_layout_sig") then
        layout_cache = {}
        view._chat_layout_cache = layout_cache
        view._chat_layout_sig = chat_sig
        view._chat_reasoning_cache = nil
    end
    -- Display-side regex scripts signature (busts per-msg parse caches when
    -- scripts are added/edited/disabled).
    local regex_sig = ""
    do
        local scripts = settings.regex_scripts
        if type(scripts) == "table" and #scripts > 0 then
            local parts = {}
            for _rs, sc in ipairs(scripts) do
                if type(sc) == "table" and not sc.disabled then
                    table.insert(parts, tostring(sc.scriptName) .. "\1" .. tostring(sc.find)
                        .. "\1" .. tostring(sc.replace) .. "\1" .. tostring(sc.placement))
                end
            end
            regex_sig = table.concat(parts, "\2")
        end
    end

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

    -- Expanded reasoning blocks are measured at their own width; cached per
    -- (text, width, inline) so open/collapse repaints skip the re-parse.
    local reasoning_cache = rawget(view, "_chat_reasoning_cache")
    if not reasoning_cache then
        reasoning_cache = {}
        view._chat_reasoning_cache = reasoning_cache
    end
    -- Reasoning reveal state lives under the message key suffixed "|r": its
    -- spoilers/details number independently of the message body (each doc
    -- numbers its own kt:spl/kt:det from 1, so body and reasoning would
    -- collide on the plain msg_key).
    local function reasoning_ns(msg_key)
        return tostring(msg_key or "?") .. "|r"
    end
    local function measure_reasoning(reasoning, rtw, inline, msg_key)
        -- HTML mode: the reasoning body renders through the SAME MuPDF path
        -- as message bodies (real markdown), but muted: css_extra layers a
        -- muted color + ambient font-family over chat_css(). The cache key
        -- carries a content sample (same-length reasonings of different
        -- messages used to share a doc - the wrong one showed) plus the
        -- reveal sigs, so a spoiler/details toggle rebuilds this doc.
        if html_render then
            local ns = reasoning_ns(msg_key)
            local rkey = "html:" .. #reasoning .. ":" .. rtw .. ":"
                .. reasoning:sub(1, 24) .. ":" .. reasoning:sub(-16)
                .. ":" .. spoiler_sig(view.app, ns)
                .. ":" .. details_sig(view.app, ns)
            local hit = reasoning_cache[rkey]
            -- A cached hit may hold a widget FREED by a later reveal toggle
            -- (invalidate_doc) - reusing it would paint a blank band on the
            -- ON->OFF->ON cycle. Dead hits rebuild like misses.
            if hit and type(hit) == "table" then
                local hw = hit.entries and hit.entries[1] and hit.entries[1].widget
                if not hw or hw.document == nil then
                    hit = nil
                    reasoning_cache[rkey] = nil
                end
            end
            if not hit then
                local doc = html_doc_for(view.app, view, reasoning, rtw,
                    ChatBubbles.spoiler_state(view.app, ns),
                    ChatBubbles.details_state(view.app, ns),
                    "body { color: " .. require("ktui/kthtml").css_hex(Theme.chat_muted, "#666666")
                        .. " !important; } p { color: "
                        .. require("ktui/kthtml").css_hex(Theme.chat_muted, "#666666")
                        .. " !important; }")
                if doc and doc.height then
                    hit = { entries = { { kind = "html", widget = doc.widget,
                        h = doc.height, doc_key = doc.key, pad = 0, offset = 0 } }, h = doc.height }
                else
                    -- Render failed: fall back to the canvas parse below.
                    hit = false
                end
                reasoning_cache[rkey] = hit
            end
            if hit then
                return hit.entries, hit.h
            end
        end
        local rkey = #reasoning .. ":" .. rtw .. ":" .. tostring(inline)
        local hit = reasoning_cache[rkey]
        if not hit then
            local rentries, rh = block_entries(Md.parse(reasoning), rtw, view.app, inline, view, body_face)
            hit = { entries = rentries, h = rh }
            reasoning_cache[rkey] = hit
        end
        return hit.entries, hit.h
    end

    -- Per-message validity signature: cache identity + content length +
    -- everything the measure pass consumed (reasoning text, parse toggles,
    -- stream state, swipe row status, reasoning open/full flags keyed by the
    -- original msg_key identity).
    local function sig_msg(msg, key, msg_key, content_text, reasoning, is_last)
        return key .. "#" .. #content_text .. ":" ..
            (reasoning and (#reasoning .. ":y") or "n") .. ":" ..
            tostring(settings.reasoning_auto_parse ~= false) .. ":" ..
            tostring(msg.is_streaming == true) .. ":" ..
            tostring(is_last == true) .. ":" ..
            -- The swipe row only exists on the last message while idle, so
            -- generation start/end must invalidate exactly that one.
            (is_last and (tostring(is_generating == true) .. ":") or "") ..
            -- Active swipe + count: cycle_swipe can swap two swipes that
            -- share head+tail samples (regenerations often do) and even
            -- the same LENGTH - without these the fast path reused the
            -- stale layout and the tap looked like a no-op / a "jump"
            -- (the 1/3 -> 3/3 report).
            tostring(tonumber(msg.swipe_id) or 1) .. "/" ..
            tostring(#(msg.swipes or {})) .. ":" ..
            tostring(reasoning_open[msg_key] == true) .. ":" ..
            tostring(reasoning_full[msg_key] == true) .. ":" ..
            tostring(settings.chat_html_render == true)
    end
    -- Regex scripts participate in every message's signature: an edited
    -- script changes rendered text (and often heights) without touching the
    -- raw content identity.
    local function full_sig(msg, key, msg_key, content_text, reasoning, is_last)
        return sig_msg(msg, key, msg_key, content_text, reasoning, is_last) .. ":" .. regex_sig
            .. ":" .. spoiler_sig(view.app, msg_key)
            .. ":" .. details_sig(view.app, msg_key)
    end

    -- Re-measure one message into a fresh layout (the slow path; unchanged
    -- messages take the cache fast path in the loop below).
    local function measure_msg(msg, i)
        local is_user = (msg.role == "user")
        local is_system = (msg.role == "system") or (msg.hidden == true)
        local is_streaming = msg.is_streaming
        local display_name = is_user and user or (msg.name or char_name or "?")
        local content_text = msg.content or ""
        -- UI-state identity (reasoning_open/full maps, hitbox labels): the
        -- original msg_key format. The layout CACHE key extends it with
        -- samples of BOTH ends of the content: same-second messages with
        -- same-length bodies must never share a layout slot (a shared slot
        -- would repaint one message's row at another's position).
        local msg_key = tostring(msg.send_date) .. ":" .. tostring(msg.name) .. ":" .. #content_text
        local key = msg_key .. ":" .. content_text:sub(1, 48) .. ":" .. content_text:sub(-48)
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

        -- FAST PATH: an unchanged message reuses its measured layout; only
        -- positions (y/bubble_y/idx) are refreshed. Content, reasoning,
        -- stream state, last-message status, reasoning toggles or parse
        -- settings changes fall through to the full measure.
        local cached = layout_cache[key]
        if cached and cached._sig == full_sig(msg, key, msg_key, content_text, reasoning,
                i == #(messages or {})) then
            local rh = cached.row_h or cached.h or 0
            -- A dead html widget forces the full re-measure (rebuild) - but
            -- only when the message is actually painted: rebuilding
            -- off-screen messages on every eviction would churn an over-cap
            -- chat on every paint. Invisible entries keep their (still valid)
            -- heights; the rebuild happens in the same paint that scrolls
            -- them into view. Margin: heal one line early, never late.
            local visible = (cy + rh > scroll + y - 100)
                and (cy < scroll + y + h + 100)
            if layout_html_alive(cached) or not visible then
                local dy = cy - (cached.y or cy)
                cached.y = cy
                if dy ~= 0 and cached.bubble_y then
                    cached.bubble_y = cached.bubble_y + dy
                end
                cached.idx = i
                cached._paint_id = view._chat_paint_id
                cy = cy + rh
                total_h = total_h + rh
                layouts[i] = cached
                return cached
            end
            -- else fall through to the full measure below
        end

        local layout = {
            idx = i,
            -- Stable per-message identity for UI state (reasoning open flag):
            -- keying by array index reattaches state to the wrong message
            -- after delete/move. The layout cache keys on `key` (content-
            -- sampled) while UI state keeps this original identity.
            msg_key = msg_key,
            is_user = is_user,
            is_system = is_system,
            is_streaming = is_streaming,
            send_date = msg.send_date,
            display_name = display_name,
            -- Prefer the provider's real completion_tokens (v0.6 usage capture)
            -- over the chars/4 estimate (ST token counters parity).
            tokens = tonumber(msg.completion_tokens) or math.ceil(#content_text / 4),
            tokens_real = tonumber(msg.completion_tokens) ~= nil,
            gen_ms = tonumber(msg.gen_ms) or nil,
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
                -- (content identity, not repaint count). regex_sig busts the
                -- per-msg caches when scripts change.
                local scripts = settings.regex_scripts
                if type(scripts) == "table" and #scripts > 0
                    and msg._md_regex_sig ~= regex_sig then
                    content_text = require("kt_regex_engine").apply(content_text, scripts, "display")
                end
                if msg._md_sig ~= content_text or msg._md_regex_sig ~= regex_sig then
                    msg._md_sig = content_text
                    msg._md_blocks = Md.parse(content_text)
                    msg._md_regex_sig = regex_sig
                end
                blocks = msg._md_blocks
                -- Experimental HTML render (Debug toggle): the plain parse
                -- stays underneath as fallback; the bubble carries the RAW
                -- content as one html block (see block_entries' html branch).
                -- Streaming keeps the plain path (partial HTML re-layouts per
                -- chunk are jumpy and 10x the cost). USER messages render
                -- through it too (their markdown/links/spoilers deserve the
                -- same treatment); system/narrator lines keep the canvas
                -- centered-muted style. The message identity and the
                -- revealed-spoiler set ride along: the doc body re-renders
                -- per reveal state, and the tap layer keys reveals by msg_key.
                if html_render then
                    blocks = { { kind = "html", text = content_text,
                        role = is_user and "user" or "ai",
                        msg_key = msg_key,
                        revealed = ChatBubbles.spoiler_state(view.app, msg_key),
                        det_revealed = ChatBubbles.details_state(view.app, msg_key) } }
                end
            end
            local entries, content_h, block_gap = block_entries(blocks, text_w, view.app, show_inline, view, body_face)
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
                    local rentries, rh = measure_reasoning(reasoning, rtw, show_inline, msg_key)
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
                    -- Flat: content column starts right of the avatar column.
                    layout.bx = col_text_x - (is_user and Theme.scale(6) or 0)
                    layout.cx = col_text_x
                end
                layout.row_h = row_h
                cy = cy + row_h
                total_h = total_h + row_h
            end
            layouts[i] = layout
        end

        layout._sig = full_sig(msg, key, msg_key, content_text, reasoning, i == #(messages or {}))
        -- Store under the SAME key the fast path looks up (content-sampled);
        -- msg_key (plain identity) remains the UI-state identity only.
        layout._paint_id = view._chat_paint_id
        layout_cache[key] = layout
        return layout
    end

    for i, msg in ipairs(messages or {}) do
        measure_msg(msg, i)
    end

    -- Thinking bubble (non-streaming generation indicator): a synthetic
    -- streaming message through the same measure path (cached on its own
    -- frame-varying content, so it re-measures per pulse frame).
    if thinking_text then
        local tl = measure_msg({
            role = "assistant", name = nil, send_date = nil,
            content = thinking_text, is_streaming = true,
        }, #layouts + 1)
        if tl then
            tl.is_thinking = true
            tl.display_name = nil
        end
    end

    -- Bottom breathing room: the fully-scrolled view must always show a
    -- strip of paper under the last panel (the "balão cortado" report).
    total_h = total_h + Theme.scale(6)
    -- Footer on: extra breathing under the last message so the bottom line
    -- never reads as "cut behind the status band" (the print reports).
    if (settings.chat_footer == true) and view.app and view.app.state
        and view.app.state.page == "chat" then
        total_h = total_h + Theme.line_h("default")
    end

    -- Clamp scroll before drawing (auto-scroll 999999 on first paint)
    local max_scroll = math.max(0, total_h - h)
    local clamped = math.max(0, math.min(scroll or 0, max_scroll))
    if clamped ~= (scroll or 0) and view.app and view.app.state then
        view.app.state.scroll[view.app:scroll_key()] = clamped
    end
    scroll = clamped

    -- Pass 2: draw
    -- Bubble panels paint through a viewport clamped to the messages band:
    -- the FULL rounded box can be drawn for every bubble (also the ones
    -- grown past the viewport, e.g. an expanded reasoning block) and the
    -- clipping keeps the on-screen part exact - rounded corners stay rounded
    -- wherever they are visible, and nothing leaks below the band (where
    -- the composer bar lives).
    local clip_bb = bb:viewport(0, 0, bb:getWidth(),
        math.min(y + h, bb:getHeight()))
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
                    Theme.chat_muted, Theme.chat_bg, math.max(top, y), math.min(bottom, y + h))
            else
                local srow_y = top
                local name_off = panel_mode and pn_pad or 0
                local panel_color = l.is_user and Theme.chat_panel_user or Theme.chat_panel
                local reasoning_y = srow_y + name_off + name_row_h
                local bubble_y = l.bubble_y - scroll

                -- ST bubbles: rounded panel behind the WHOLE message (avatar
                -- + name + text). Square edges when clipped by the viewport.
                if panel_mode and not l.is_thinking then
                    local pb_color = (l.is_streaming and Theme.chat_ink) or Theme.chat_border
                    local pb_size = l.is_streaming and 2 or 1
                    -- The FULL rounded box paints through a viewport clamped
                    -- to the messages band: a bubble grown past the viewport
                    -- (expanding a reasoning block used to flip every corner
                    -- square AND drop the top border - the "balao fica
                    -- quadrado/torto" report) keeps its rounded visible
                    -- corners and the whole border ring; the off-band part is
                    -- clipped away safely (probe-verified: viewport painting
                    -- clamps - no overflow writes, no crash, negative y ok).
                    P.box(clip_bb, panel_x, bubble_y, l.bubble_w, l.bubble_h, {
                        border_color = pb_color, border_size = pb_size,
                        background = panel_color, radius = Theme.bubble_radius_px(),
                    })
                end

                -- Sender row.
                -- Flat/bubbles: avatar is a top-aligned COLUMN at the far
                -- left; the name (bold, ST ch_name) sits beside it with a
                -- muted timestamp after. Boxed: legacy inline row.
                local name_drawn = false
                -- Avatar tap target (filled below when a real photo paints;
                -- the initial fallback stays untappable). Emitted after the
                -- hold zone + kebab so the disc wins taps.
                local av_hit = nil
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
                        draw_avatar(view, bb, inner_left, srow_y + name_off, avatar_size,
                            av_img,
                            l.is_user and user or char_name, carve)
                        if av_img and av_img ~= "" then
                            av_hit = { x = inner_left, y = srow_y + name_off, img = av_img }
                        end
                        local ny = srow_y + name_off + math.floor((name_row_h - name_h) / 2)
                        local nx = col_text_x
                        -- Message ID (ST mesIDDisplay): tiny muted "#N" before
                        -- the name, from its own draw (never bold like the
                        -- name itself).
                        if show_msg_ids then
                            local id_str = "#" .. tostring(l.idx or "?")
                            local idw = P.text_size(id_str, nil, "tiny").w
                            -- +2px nudge: the tiny face centers on the
                            -- small-face box but reads a touch high next to
                            -- the bold name (the "#3 sobe" print note).
                            P.text(bb, id_str, nx, ny + math.floor((name_h - Theme.line_h("tiny")) / 2) + 2,
                                idw + 2, "tiny", { color = Theme.chat_muted })
                            nx = nx + idw + Theme.scale(6)
                        end
                        -- Generation timer (ST timer_enabled): duration of
                        -- the reply, recorded at finalize time.
                        if show_gen_timer and l.gen_ms then
                            local secs = math.floor((l.gen_ms or 0) / 100 + 0.5) / 10
                            l.gen_timer_str = tostring(secs) .. "s"
                        end
                        -- End the sender budget where the ⋯ kebab hit starts
                        -- (kebab_x - 8): a long name used to run under the dots
                        -- and the timestamp overprinted them.
                        local nw = math.max(1, inner_right - kebab_w - Theme.scale(8) - nx)
                        if sender_str ~= "" then
                            P.text(bb, sender_str, nx, ny, nw,
                                "small", { bold = true, color = Theme.chat_ink })
                            local after_w = P.text_size(sender_str, nw, "small", { bold = true })
                            local tx = nx + math.min(after_w.w, nw) + Theme.scale(6)
                            if timestamp then
                                local tsize = P.text_size(timestamp, math.max(1, inner_right - kebab_w - Theme.scale(8) - tx), "tiny")
                                local ty = ny + math.max(0, after_w.h - tsize.h)
                                P.text(bb, timestamp, tx, ty,
                                    math.max(1, inner_right - kebab_w - Theme.scale(8) - tx), "tiny", { color = Theme.chat_muted })
                                tx = tx + math.min(tsize.w, inner_right - kebab_w - Theme.scale(8) - tx) + Theme.scale(6)
                            end
                            -- Gen timer trails the timestamp (ST shows the
                            -- duration in the timestamp row).
                            if l.gen_timer_str then
                                P.text(bb, l.gen_timer_str, tx, ny + math.max(0, after_w.h - Theme.line_h("tiny")),
                                    math.max(1, inner_right - kebab_w - Theme.scale(8) - tx), "tiny", { color = Theme.chat_muted })
                            end
                        end
                        name_drawn = true
                    elseif l.is_user then
                        local boxed_str = sender_str .. (timestamp and ((sender_str ~= "" and "  " or "") .. timestamp) or "")
                        local av_x = content_right - pad - avatar_w
                        if show_avatars then
                            draw_avatar(view, bb, av_x, srow_y + av_dy, avatar_size, user_image, user, Theme.chat_panel)
                            if user_image and user_image ~= "" then
                                av_hit = { x = av_x, y = srow_y + av_dy, img = user_image }
                            end
                        end
                        local name_right = av_x - Theme.scale(4)
                        local name_w = math.max(1, name_right - (x + pad))
                        local size = P.text_size(boxed_str, name_w, "tiny")
                        P.text(bb, boxed_str, name_right - math.min(size.w, name_w),
                            srow_y + math.floor((name_row_h - name_h) / 2), math.min(size.w, name_w),
                            "tiny", { color = Theme.chat_muted })
                        name_drawn = true
                    else
                        local boxed_str = sender_str .. (timestamp and ((sender_str ~= "" and "  " or "") .. timestamp) or "")
                        local av_x = x + pad
                        if show_avatars and not l.is_thinking then
                            draw_avatar(view, bb, av_x, srow_y + av_dy, avatar_size, char_image, char_name, Theme.chat_panel)
                            if char_image and char_image ~= "" then
                                av_hit = { x = av_x, y = srow_y + av_dy, img = char_image }
                            end
                        end
                        local name_x = show_avatars and (av_x + avatar_w + Theme.scale(4)) or av_x
                        local name_w = math.max(1, content_right - pad - name_x)
                        if boxed_str ~= "" then
                            P.text(bb, boxed_str, name_x,
                                srow_y + math.floor((name_row_h - name_h) / 2), name_w,
                                "tiny", { bold = true, color = Theme.chat_ink })
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
                            math.min(tw, col_text_w), "tiny", { color = Theme.chat_muted })
                    end
                end

                -- Message hold zone (clamped to the visible area): actions open
                -- on long-press or via the ⋯ kebab - never on tap. Registered
                -- BEFORE the reasoning/swipe hits below so the narrower bands
                -- win their taps (hitboxes are checked in reverse order);
                -- onHoldKotavern only fires boxes that declare on_hold.
                -- The zone spans the NARROWED panel bounds (chat_width): a
                -- full-width origin left it inset px off the bubble column.
                if not l.is_thinking then
                    local hy = math.max(top, y)
                    local hh = math.min(bottom, y + h) - hy
                    if hh > 0 then
                        P.hit_hold(view, panel_x, hy, panel_right - panel_x, hh, function()
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
                            tw + 2, "tiny", { color = Theme.chat_muted })
                    end
                    local dot_cy = row_y0 + math.floor(name_row_h / 2)
                    for k = 0, 2 do
                        P.circle(bb, kebab_x + kebab_r + k * (kebab_r * 2 + kebab_gap), dot_cy, kebab_r, Theme.chat_muted)
                    end
                    P.hit(view, kebab_x - Theme.scale(8), row_y0, kebab_w + Theme.scale(16), name_row_h, function()
                        if view.app.show_message_actions then
                            view.app:show_message_actions(l.idx)
                        end
                    end, "kebab_" .. l.idx)
                end

                -- Avatar tap: fullscreen photo (lists parity). Registered
                -- after hold + kebab (reverse order wins the disc); hold and
                -- kebab keep working everywhere else.
                if av_hit and view.app.show_character_image_fullscreen then
                    local ah = av_hit
                    P.hit(view, ah.x, ah.y, avatar_w, avatar_size, function()
                        view.app:show_character_image_fullscreen(ah.img)
                    end, "chat_avatar_" .. l.idx)
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
                    -- Rule at cx-8: the reasoning TEXT (cx+8) aligns with
                    -- the reply text (cx) - the old cx/cx+8 stagger read as
                    -- a misaligned block in the print reports.
                    local rul_x = l.cx - Theme.scale(8)
                    local rul_y0 = head_y
                    local rul_y1 = reasoning_y + l.reasoning_h - Theme.scale(2)
                    if reasoning_open[l.msg_key] then
                        -- Left rule spanning the section (muted, 2px).
                        if rul_y1 > rul_y0 then
                            P.rect(bb, rul_x, rul_y0, Theme.scale(2), rul_y1 - rul_y0, Theme.chat_muted)
                        end
                        -- Header row: chevron rotated down + label, then the
                        -- reasoning text indented past the rule.
                        Icons.draw(bb, "chev-down", rul_x + Theme.scale(8), head_y + math.floor((head_h - isz.h) / 2), icon_size, { color = Theme.chat_muted })
                        P.text(bb, label, rul_x + Theme.scale(8) + isz.w + Theme.scale(6), head_y,
                            l.text_w - Theme.scale(8) - isz.w - Theme.scale(6), "tiny", { bold = true, color = Theme.chat_muted })
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
                                    l.text_w - Theme.scale(8), "tiny", { bold = true, color = Theme.chat_muted })
                            end
                        end
                        draw_blocks(view, bb, l.reasoning_entries, rul_x + Theme.scale(8), ry,
                            rtw, Theme.chat_muted, panel_mode and panel_color or Theme.chat_bg,
                            math.max(ry, y), body_bottom,
                            -- hit_ctx: reasoning taps resolve under the "|r"
                            -- namespace (own spoiler/details numbering).
                            { msg_key = reasoning_ns(l.msg_key) })
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
                        Icons.draw(bb, "chev-right", rul_x + Theme.scale(8), line_y + math.floor((head_h - isz.h) / 2), icon_size, { color = Theme.chat_muted })
                        P.text(bb, label, rul_x + Theme.scale(8) + isz.w + Theme.scale(6), line_y,
                            l.text_w - Theme.scale(8) - isz.w - Theme.scale(6), "tiny", { color = Theme.chat_muted })
                        P.hit(view, rul_x, reasoning_y, l.bubble_w - Theme.scale(8), l.reasoning_h, function()
                            reasoning_open[l.msg_key] = true
                            view:refresh()
                        end, "reasoning_" .. l.msg_key)
                    end
                end

                -- Bubble box (boxed style) / subtle user band (flat ST-DEFAULT)
                local bg = l.is_user and (outline_user and Theme.panel or Theme.soft) or Theme.panel
                local text_color = Theme.chat_ink
                local border_color = (l.is_streaming and Theme.chat_ink) or Theme.chat_muted
                local border_size = (l.is_streaming or (l.is_user and outline_user)) and 2 or 1

                local vis_top = math.max(bubble_y, y)
                local vis_bottom = math.min(bubble_y + l.bubble_h, y + h)

                if boxed then
                    -- Full rounded box through the band viewport (same fix as
                    -- the bubbles panel): clipped bottoms used to square-cut
                    -- every corner and drop the top border.
                    P.box(clip_bb, l.bx, bubble_y, l.bubble_w, l.bubble_h, {
                        border_color = border_color,
                        border_size = border_size,
                        background = bg,
                        radius = radius,
                    })
                    if l.is_streaming then
                        local ind_h = vis_bottom - vis_top
                        if ind_h > 0 then
                            P.rect(bb, l.bx, vis_top, Theme.scale(3), ind_h, Theme.chat_ink)
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
                                    { border = false, background = Theme.chat_panel_user, radius = Theme.scale(6) })
                            else
                                P.rect(bb, l.bx, vis_top, l.bubble_w, vis_h, Theme.chat_panel_user)
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
                    or (l.is_user and Theme.chat_panel_user or Theme.chat_bg)
                if boxed then
                    draw_blocks(view, bb, l.entries, l.cx, content_y,
                        l.text_w, text_color, bg, vis_top, vis_bottom,
                        { msg_key = l.msg_key })
                else
                    draw_blocks(view, bb, l.entries, l.cx, content_y,
                        l.text_w, Theme.chat_ink, content_bg,
                        math.max(content_y, y), math.min(content_y + l.content_h + pad, y + h),
                        { msg_key = l.msg_key })
                end

                -- Inline swipe indicator (ST): ‹ n/N › + under the bubble.
                if l.swipes_h and l.swipes_h > 0 and l.swipes_n then
                    -- Bubbles keep the swipe row INSIDE the panel (above the
                    -- bottom pad); flat puts it right under the text band.
                    local sy = panel_mode
                        and (bubble_y + l.bubble_h - pn_pad - l.swipes_h)
                        or (bubble_y + l.bubble_h)
                    if sy + l.swipes_h <= y + h and sy >= y - Theme.scale(20) then
                        local icon_size = Theme.scale(14)
                        local isz = Icons.text_size("chev-left", icon_size)
                        local row_cy = sy + math.floor((l.swipes_h - isz.h) / 2)
                        local sx = l.cx
                        local counter = ""
                        if l.swipes_n > 1 then
                            counter = tostring(l.swipes_id) .. "/" .. tostring(l.swipes_n)
                            -- ‹ previous
                            Icons.draw(bb, "chev-left", sx, row_cy, icon_size, { color = Theme.chat_muted })
                            P.hit(view, sx - Theme.scale(10), sy, isz.w + Theme.scale(20), l.swipes_h, function()
                                view.app:cycle_swipe(l.idx, -1)
                            end, "swipe_prev_" .. l.idx)
                            sx = sx + isz.w + Theme.scale(10)
                            local csize = P.text_size(counter, nil, "tiny")
                            P.text(bb, counter, sx, sy + math.floor((l.swipes_h - csize.h) / 2),
                                csize.w + 2, "tiny", { color = Theme.chat_muted })
                            sx = sx + csize.w + Theme.scale(10)
                            -- › next
                            Icons.draw(bb, "chev-right", sx, row_cy, icon_size, { color = Theme.chat_muted })
                            P.hit(view, sx - Theme.scale(10), sy, isz.w + Theme.scale(20), l.swipes_h, function()
                                view.app:cycle_swipe(l.idx, 1)
                            end, "swipe_next_" .. l.idx)
                            sx = sx + isz.w + Theme.scale(14)
                        end
                        -- + new swipe. Hit cushions stay INSIDE the row's
                        -- own span: the widened boxes used to overlap the
                        -- › chevron by 6px and taps there fired regenerate.
                        Icons.draw(bb, "plus", sx, row_cy, icon_size, { color = Theme.chat_muted })
                        P.hit(view, sx - Theme.scale(2), sy, isz.w + Theme.scale(8), l.swipes_h, function()
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

-- TEST-ONLY hook (ui_smoke): expose the HTML-mode body encoder without a
-- paint. Not used by the app path. revealed = optional { [n]=true } set.
function ChatBubbles._test_chat_html_body(content, revealed, det_revealed)
    return chat_html_body(content, revealed, det_revealed)
end

return ChatBubbles
