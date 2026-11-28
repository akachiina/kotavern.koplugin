-- KtBook: "book mode" content layer.
--
-- A chat is rendered as ONE paginated HTML document and opened in KOReader's
-- native reader (crengine). This module owns ONLY the content: chat data ->
-- HTML. It never touches the ReaderUI, the canvas, or the KoReader settings.
--
-- Layout:
--   cover (title, character, persona, date)
--   <section class="msg" id="mN">...</section> one continuous message section
--   colophon (compose / continue / menu links)
--
-- Model markdown headings are demoted to styled paragraphs so they cannot
-- pollute the native TOC.
--
-- Action links use the private `kt:` scheme:
--   kt:msg/<index>  message actions
--   kt:new          write the next message
--   kt:continue     continue the last reply
--   kt:menu         book actions
--   kt:end          jump to the last page
-- kt_book_reader.lua intercepts taps on those links before ReaderLink.

local Storage = require("kt_storage")
local Md = require("ktui/md")
local BookTheme = require("kt_book_theme")
local _ = require("gettext")
local T = require("ffi/util").template

local Book = {}

Book.ACTION_SCHEME = "kt:"
Book.DIR_TAIL = "/books"

-- === Paths ===

local function book_dir()
    return Storage.data_dir() .. Book.DIR_TAIL
end

local function ensure_book_dir()
    local lfs = require("libs/libkoreader-lfs")
    local dir = book_dir()
    if lfs.attributes(dir, "mode") ~= "directory" then
        local ok, err = lfs.mkdir(dir)
        if not ok then
            require("logger").warn("kotavern/book: cannot create", dir, tostring(err))
            return nil, err
        end
    end
    return dir
end

-- Two independent djb2 accumulators, 16 hex chars. Pure Lua 5.1 (no bit
-- library), enough to keep per-chat paths unique; collisions would only mean
-- two chats sharing a generated cache file, which is regenerated on open.
local function path_hash(value)
    local h1, h2 = 5381, 52711
    for i = 1, #value do
        local b = value:byte(i)
        h1 = (h1 * 33 + b) % 4294967296
        h2 = (h2 * 65599 + b) % 4294967296
    end
    return string.format("%08x%08x", h1, h2)
end

local function safe_chat_id(chat_path)
    local id = tostring(chat_path or ""):match("([^/\\]+)%.jsonl$") or "chat"
    id = id:gsub("[^%w%-_%.]", "_")
    if id == "" then id = "chat" end
    return id
end

function Book.dir()
    return book_dir()
end

function Book.path_for(chat_path)
    chat_path = tostring(chat_path or "")
    return book_dir() .. "/" .. safe_chat_id(chat_path) .. "-" .. path_hash(chat_path) .. ".html"
end

function Book.is_book_path(path)
    if type(path) ~= "string" or path == "" then return false end
    local function matches(value, base)
        return value:sub(1, #base) == base and value:sub(-5) == ".html"
    end
    local dir = book_dir() .. "/"
    if matches(path, dir) then return true end
    -- ReadHistory realpaths its arguments; the data dir itself may be a
    -- symlink on device, so compare the resolved forms too.
    local ok, util = pcall(require, "ffi/util")
    if not ok or not util or not util.realpath then return false end
    local variants = { path }
    local real_path = util.realpath(path)
    if real_path then variants[#variants + 1] = real_path end
    local real_book_dir = util.realpath(book_dir())
    local bases = { dir }
    if real_book_dir then bases[#bases + 1] = real_book_dir .. "/" end
    for _, value in ipairs(variants) do
        for _, base in ipairs(bases) do
            if matches(value, base) then return true end
        end
    end
    return false
end

-- === Escaping / text helpers ===

local function esc(value)
    local s = tostring(value or "")
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    s = s:gsub('"', "&quot;")
    s = s:gsub("'", "&#39;")
    return s
end

-- === Inline markdown -> HTML ===

-- Liquid links/code are stashed as control-char tokens so the emphasis
-- patterns cannot touch their contents.
local function stash_new(stash, value)
    local token = "\1KT" .. tostring(#stash + 1) .. "\2"
    stash[#stash + 1] = value
    return token
end

local function restore_stash(text, stash)
    return (text:gsub("\1KT(%d+)\2", function(index)
        return stash[tonumber(index)] or ""
    end))
end

local function safe_url(url)
    url = tostring(url or "")
    local scheme = url:match("^(%a[%w+.-]*):")
    if not scheme then
        return nil
    end
    scheme = scheme:lower()
    if scheme ~= "http" and scheme ~= "https" and scheme ~= "mailto" then
        return nil
    end
    return url
end

local function inline_html(value)
    local s = tostring(value or "")
    local stash = {}

    -- Images inline in a paragraph: keep a readable placeholder.
    s = s:gsub("!%[([^%]]*)%]%([^%)]*%)", function(alt)
        return stash_new(stash, "[" .. _("Image") .. ": " .. esc(alt or "") .. "]")
    end)

    -- Code spans first: their content must stay literal.
    s = s:gsub("`([^`\n]+)`", function(code)
        return stash_new(stash, "<code>" .. esc(code) .. "</code>")
    end)

    -- Markdown links: only safe schemes become anchors; the rest stays text.
    s = s:gsub("%[([^%]]*)%]%(([^%s%)]+)%)", function(label, url)
        local safe = safe_url(url)
        if not safe then
            return stash_new(stash, "[" .. esc(label) .. "](" .. esc(url) .. ")")
        end
        return stash_new(stash,
            '<a href="' .. esc(safe) .. '">' .. esc(label) .. "</a>")
    end)

    -- Escape everything that is left, then apply emphasis to the plain text
    -- only. The stashed HTML is restored afterwards so a `*`/`_` inside a URL
    -- can never corrupt an attribute.
    s = esc(s)
    s = s:gsub("%*%*%*([^*\n]+)%*%*%*", "<b><i>%1</i></b>")
    s = s:gsub("%*%*([^*\n]+)%*%*", "<b>%1</b>")
    s = s:gsub("__([^_\n]+)__", "<b>%1</b>")
    s = s:gsub("%*([^*\n]+)%*", "<i>%1</i>")
    s = s:gsub("^_([^_\n]+)_", "<i>%1</i>")
    s = s:gsub("([%s%p])_([^_\n]+)_([%s%p])", "%1<i>%2</i>%3")
    s = s:gsub("([%s%p])_([^_\n]+)_$", "%1<i>%2</i>")
    s = s:gsub("~~([^~\n]+)~~", "<s>%1</s>")

    -- Single newlines inside a block are real line breaks in chat prose.
    s = s:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "<br/>")
    return restore_stash(s, stash)
end

-- === Block renderer ===

local function render_list(text)
    local out = { "<ul>" }
    for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        local item = line:match("^%s*•%s+(.+)$")
        if item then
            out[#out + 1] = "<li>" .. inline_html(item) .. "</li>"
        else
            local number, numbered = line:match("^%s*(%d+)%.%s+(.+)$")
            if numbered then
                -- Mixed lists are flattened to <ul>: the parser already
                -- flattens nesting, and this keeps the output predictable.
                out[#out + 1] = "<li>" .. number .. ". " .. inline_html(numbered) .. "</li>"
            end
        end
    end
    out[#out + 1] = "</ul>"
    return table.concat(out, "\n")
end

local function render_table(block)
    local out = { "<table>" }
    local header = block.header or {}
    if #header > 0 then
        out[#out + 1] = "<tr>"
        for _, cell in ipairs(header) do
            out[#out + 1] = "<th>" .. inline_html(cell) .. "</th>"
        end
        out[#out + 1] = "</tr>"
    end
    for _, row in ipairs(block.rows or {}) do
        out[#out + 1] = "<tr>"
        for _, cell in ipairs(row) do
            out[#out + 1] = "<td>" .. inline_html(cell) .. "</td>"
        end
        out[#out + 1] = "</tr>"
    end
    out[#out + 1] = "</table>"
    return table.concat(out, "\n")
end

local function render_blocks(text, opts)
    local blocks = Md.parse(text or "")
    local out = {}
    -- NOT "_": the body calls gettext.
    for _bi, block in ipairs(blocks) do
        local kind = block.kind
        if kind == "paragraph" then
            if block.text and block.text ~= "" then
                out[#out + 1] = "<p>" .. inline_html(block.text) .. "</p>"
            end
        elseif kind == "heading" then
            local level = math.max(1, math.min(6, tonumber(block.level) or 3))
            -- Demoted on purpose: model headings must not reach the native TOC.
            out[#out + 1] = '<p class="md-h md-h' .. level .. '">'
                .. inline_html(block.text) .. "</p>"
        elseif kind == "quote" then
            out[#out + 1] = "<blockquote>" .. inline_html(block.text) .. "</blockquote>"
        elseif kind == "list" then
            out[#out + 1] = render_list(block.text)
        elseif kind == "code" then
            out[#out + 1] = "<pre>" .. esc(block.text or "") .. "</pre>"
        elseif kind == "rule" then
            out[#out + 1] = "<hr/>"
        elseif kind == "table" then
            out[#out + 1] = render_table(block)
        elseif kind == "image" then
            local alt = tostring(block.alt or "")
            -- The theme can hide the placeholder entirely.
            local theme = opts.theme or {}
            if theme.inline_images ~= "hidden" then
                out[#out + 1] = '<p class="img-placeholder">['
                    .. _("Image") .. ": " .. esc(alt) .. "]</p>"
            end
        else
            if block.text and block.text ~= "" then
                out[#out + 1] = "<p>" .. inline_html(block.text) .. "</p>"
            end
        end
    end
    if #out == 0 then
        out[1] = '<p class="empty"></p>'
    end
    return table.concat(out, "\n")
end

-- === Document parts ===

-- The book stylesheet. The base rules are the book's own look; the theme
-- adds the rules it owns (spacing, separators, code blocks, spoilers...).
local function stylesheet(theme)
    theme = theme or BookTheme.normalize(nil)
    local css = {
        "body { margin: 0; }",
        ".cover { text-align: center; padding: 2em 1em; }",
        ".book-title { font-size: 1.6em; font-weight: bold; }",
        ".book-sub { font-size: 1.1em; margin-top: .6em; }",
        ".book-meta { font-size: .9em; margin-top: .4em; }",
        ".md-h { font-weight: bold; margin: 1em 0 .4em; }",
        ".md-h1 { font-size: 1.25em; }",
        ".md-h2 { font-size: 1.2em; }",
        ".md-h3 { font-size: 1.15em; }",
        ".md-h4, .md-h5, .md-h6 { font-size: 1.05em; }",
        ".message-title { margin: 1.2em 0 .2em; }",
        ".speaker { font-size: .85em; font-weight: bold; letter-spacing: .03em; }",
        ".message-meta { font-size: .8em; opacity: .7; margin-left: .6em; }",
        '.ktemoji { font-family: "Noto Emoji"; }',
        ".ktdet { font-weight: bold; text-decoration: none !important; }",
        ".ktspl { display: inline-block; background: #555; color: #555 !important;",
        "  text-decoration: none !important; }",
        ".ktsplopen { background: transparent; color: inherit !important; }",
        "blockquote { margin: .2em 0 .8em 0; padding-left: .8em;",
        "  border-left: 2px solid #888; }",
        ".actions { margin: .2em 0 1em; font-size: .85em; }",
        ".actions a { display: block; padding: .4em 0; text-decoration: none; }",
        "pre { white-space: pre-wrap; }",
        "table { border-collapse: collapse; }",
        "td, th { border: 1px solid #888; padding: .2em .4em; }",
        ".msg-system, .msg-hidden { opacity: .7; font-style: italic; }",
        ".img-placeholder { font-style: italic; }",
        ".colophon { margin-top: 2em; page-break-before: always; }",
        ".compose { margin: .8em 0; }",
    }
    if theme.paragraph_spacing == "compact" then
        css[#css + 1] = "p { margin: .2em 0 .4em 0; }"
    elseif theme.paragraph_spacing == "airy" then
        css[#css + 1] = "p { margin: .6em 0 1em 0; }"
    end
    if theme.justify then
        css[#css + 1] = "p, li, blockquote { text-align: justify; }"
    end
    if theme.hyphenate then
        css[#css + 1] = "p, li { hyphens: auto; -webkit-hyphens: auto; }"
    end
    if theme.separator == "line" then
        css[#css + 1] = ".msg + .msg { border-top: 1px solid #888; padding-top: .6em; }"
    elseif theme.separator == "ornament" then
        css[#css + 1] = ".msg + .msg { border-top: 1px solid #888; padding-top: .6em; }"
        css[#css + 1] = ".kt-ornament { text-align: center; margin: .8em 0; }"
    elseif theme.separator == "none" then
        css[#css + 1] = ".message-title { margin: .3em 0 .2em 0; }"
    end
    if theme.code_style == "box" then
        css[#css + 1] = "pre { border: 1px solid #888; padding: .3em .4em; }"
    elseif theme.code_style == "indent" then
        css[#css + 1] = "pre { margin-left: 1.5em; }"
    end
    if not theme.table_border then
        css[#css + 1] = "td, th { border: none; }"
    end
    if theme.spoiler == "reveal" then
        css[#css + 1] = ".ktspl { background: transparent !important; color: inherit !important; }"
    end
    if theme.emoji_size == "small" then
        css[#css + 1] = ".ktemoji { font-size: .85em; }"
    elseif theme.emoji_size == "large" then
        css[#css + 1] = ".ktemoji { font-size: 1.15em; }"
    end
    if theme.drop_cap then
        css[#css + 1] = ".ktdropcap { float: left; font-size: 2.2em; line-height: .9; padding-right: .08em; }"
    end
    if theme.user_style == "panel" then
        css[#css + 1] = ".msg-user > blockquote { border: 1px solid #888; padding: .3em .5em; }"
    elseif theme.user_style == "plain" then
        css[#css + 1] = "blockquote { border: none; padding: 0; margin: .2em 0; }"
    end
    if theme.system_style == "plain" then
        css[#css + 1] = ".msg-system, .msg-hidden { opacity: 1; font-style: normal; }"
    elseif theme.system_style == "hidden" then
        css[#css + 1] = ".msg-system { display: none; }"
    end
    if theme.toc then
        css[#css + 1] = "h2.toc-entry { font-size: .95em; margin: 1.2em 0 .2em 0; }"
    end
    if theme.custom_css ~= "" then
        css[#css + 1] = theme.custom_css
    end
    return table.concat(css, "\n")
end

-- The speaker of a message. The names are the theme's labels: the user can
-- rename them (an empty override keeps the translated default).
local function speaker_for(msg, data, labels)
    labels = labels or {}
    local function L(key, default)
        local value = labels[key]
        if type(value) == "string" and value ~= "" then return value end
        return default
    end
    if msg.role == "user" then
        return data.persona_name or L("you", _("You"))
    elseif msg.role == "system" then
        return L("system", _("System"))
    end
    return msg.name or data.character_name or L("assistant", _("Assistant"))
end

local function format_time(ts)
    if type(ts) ~= "number" or ts <= 0 or ts ~= ts or ts == math.huge then
        return nil
    end
    local ok, value = pcall(os.date, "%H:%M", ts)
    if ok and type(value) == "string" then return value end
    return nil
end

local function has_interactive_markup(text)
    text = tostring(text or "")
    return text:find("||", 1, true) ~= nil
        or text:find("<[dD][eE][tT][aA][iI][lL][sS]%f[^%w]") ~= nil
end

-- Pure-byte UTF-8 decode (LuaJIT has no utf8 library). Invalid sequences are
-- copied byte-for-byte by the wrapper instead of being replaced or truncated.
local function decode_utf8(text, index)
    local b = text:byte(index)
    if not b then return nil, index end
    if b < 0x80 then return b, index end
    local length, cp
    if b >= 0xF0 and b <= 0xF4 then
        length, cp = 4, b % 8
    elseif b >= 0xE0 then
        length, cp = 3, b % 16
    elseif b >= 0xC2 then
        length, cp = 2, b % 32
    else
        return nil, index
    end
    for offset = 1, length - 1 do
        local continuation = text:byte(index + offset)
        if not continuation or continuation < 0x80 or continuation >= 0xC0 then
            return nil, index
        end
        cp = cp * 64 + continuation % 64
    end
    if (length == 2 and cp < 0x80)
        or (length == 3 and cp < 0x800)
        or (length == 4 and cp < 0x10000)
        or (cp >= 0xD800 and cp <= 0xDFFF) or cp > 0x10FFFF then
        return nil, index
    end
    return cp, index + length - 1
end

local function is_emoji(cp)
    return (cp >= 0x1F000 and cp <= 0x1FAFF)
        or (cp >= 0x2600 and cp <= 0x27BF)
        or (cp >= 0x2B00 and cp <= 0x2BFF)
        or (cp >= 0x2194 and cp <= 0x2199)
        or (cp >= 0x21A9 and cp <= 0x21AA)
        or (cp >= 0x231A and cp <= 0x231B)
        or (cp >= 0x23E9 and cp <= 0x23F3)
        or (cp >= 0x23F8 and cp <= 0x23FA)
        or (cp >= 0x25AA and cp <= 0x25AB)
        or (cp >= 0x25FB and cp <= 0x25FE)
        or (cp >= 0x2934 and cp <= 0x2935)
        or cp == 0x00A9 or cp == 0x00AE or cp == 0x203C or cp == 0x2049
        or cp == 0x2122 or cp == 0x2139 or cp == 0x25B6 or cp == 0x25C0
        or cp == 0x3030 or cp == 0x303D or cp == 0x3297 or cp == 0x3299
end

local function is_emoji_suffix(cp)
    return (cp >= 0xFE00 and cp <= 0xFE0F)
        or (cp >= 0x1F3FB and cp <= 0x1F3FF) or cp == 0x20E3
end

-- Wrap one text node. Joined emoji must share a span: splitting at ZWJ or a
-- variation selector would break the sequence before crengine shapes it.
local function emoji_text(text)
    local out = {}
    local index = 1
    while index <= #text do
        local cp, last = decode_utf8(text, index)
        local keycap_last = nil
        if cp and ((cp >= 0x30 and cp <= 0x39) or cp == 0x23 or cp == 0x2A) then
            local next_cp, next_last = decode_utf8(text, last + 1)
            if next_cp == 0xFE0F then
                next_cp, next_last = decode_utf8(text, next_last + 1)
            end
            if next_cp == 0x20E3 then keycap_last = next_last end
        end
        if cp and (is_emoji(cp) or keycap_last) then
            local run_end = keycap_last or last
            -- A regional-indicator flag is one emoji, not two independent runs.
            if not keycap_last and cp >= 0x1F1E6 and cp <= 0x1F1FF then
                local next_cp, next_last = decode_utf8(text, last + 1)
                if next_cp and next_cp >= 0x1F1E6 and next_cp <= 0x1F1FF then
                    run_end = next_last
                end
            end
            while run_end < #text do
                local next_cp, next_last = decode_utf8(text, run_end + 1)
                if next_cp and is_emoji_suffix(next_cp) then
                    run_end = next_last
                elseif next_cp == 0x200D then
                    local joined_cp, joined_last = decode_utf8(text, next_last + 1)
                    if not joined_cp or not is_emoji(joined_cp) then break end
                    run_end = joined_last
                else
                    break
                end
            end
            out[#out + 1] = '<span class="ktemoji">'
                .. text:sub(index, run_end) .. "</span>"
            index = run_end + 1
        else
            out[#out + 1] = text:sub(index, cp and last or index)
            index = cp and (last + 1) or (index + 1)
        end
    end
    return table.concat(out)
end

-- The encoders have already sanitized/escaped their input. Wrapping only text
-- outside tags covers normal Book blocks and the shared interactive encoder
-- without touching URLs, attributes, or element names.
local function emoji_html(html)
    local out = {}
    local position = 1
    html = tostring(html or "")
    while position <= #html do
        local first, last = html:find("<[^>]->", position)
        if not first then
            out[#out + 1] = emoji_text(html:sub(position))
            break
        end
        out[#out + 1] = emoji_text(html:sub(position, first - 1))
        out[#out + 1] = html:sub(first, last)
        position = last + 1
    end
    return table.concat(out)
end

local function render_body(text, data, link_prefix)
    local html
    if has_interactive_markup(text) then
        html = require("ktui/chat_bubbles").encode_html(
            text, data.revealed_spoilers, data.revealed_details,
            { link_prefix = link_prefix })
    else
        html = render_blocks(text, data)
    end
    return emoji_html(html)
end

-- Wrap the first letter of a body in a drop-cap span. The letter may live
-- INSIDE a tag (<b>Bold</b>), so the tags are skipped; an entity (&) is
-- skipped as a whole (it must not be broken) and a body that starts with
-- something else than a letter gets NO cap.
local function drop_cap_html(html)
    local open = html:find("<p[^>]*>")
    if not open then return html end
    local pos = html:find(">", open, true)
    if not pos then return html end
    pos = pos + 1
    -- Skip the markup that starts AT the cursor: a tag (<b>Bold</b>) or an
    -- entity (&). The text after it may be the first letter.
    while true do
        local char = html:sub(pos, pos)
        if char == "<" then
            local tag_close = html:find(">", pos, true)
            if not tag_close then return html end
            pos = tag_close + 1
        elseif char == "&" then
            local semi = html:find(";", pos, true)
            if not semi then return html end
            pos = semi + 1
        else
            break
        end
    end
    local first = html:sub(pos, pos)
    if not first:match("^[%a]") then return html end
    return html:sub(1, pos - 1)
        .. '<span class="ktdropcap">' .. first .. "</span>"
        .. html:sub(pos + 1)
end

-- One message section. The theme owns the title block, the user/system
-- styles, the reasoning and the action link.
local function message_html(msg, index, data, theme, labels, prev)
    local role = msg.role or "assistant"
    local classes = { "msg", "msg-" .. tostring(role) }
    if msg.hidden == true then
        classes[#classes + 1] = "msg-hidden"
    end
    -- The system style "hidden" drops the whole section (the anchors of the
    -- other messages keep their numbers).
    if role == "system" and theme.system_style == "hidden" then
        return ""
    end

    local function L(key, default)
        local value = labels and labels[key]
        if type(value) == "string" and value ~= "" then return value end
        return default
    end

    local out = {}
    local style = theme.page_break and ' style="page-break-before: always;"' or ""
    out[#out + 1] = '<section class="' .. table.concat(classes, " ")
        .. '" id="m' .. index .. '"' .. style .. ">"

    -- The title block: the theme decides what it carries.
    local kind = theme.message_title
    local speaker = speaker_for(msg, data, labels)
    local timestamp = format_time(msg.send_date)
    local number = "#" .. index
    local speaker_text, meta_text
    if kind == "speaker" then
        speaker_text = speaker
        meta_text = timestamp and (timestamp .. " · " .. number) or number
    elseif kind == "speaker_time" then
        speaker_text = speaker
        meta_text = timestamp or number
    elseif kind == "time" then
        meta_text = timestamp or number
    elseif kind == "number" then
        meta_text = number
    end
    if theme.toc then
        -- A real heading: the native reader's TOC lists the messages.
        local toc_text = (speaker_text or "") .. " · " .. number
        out[#out + 1] = '<h2 class="toc-entry">' .. esc(toc_text) .. "</h2>"
    end
    if kind ~= "none" then
        local merged = false
        if theme.merge_speakers and prev and prev.role == role
            and speaker_for(prev, data, labels) == speaker then
            merged = true
        end
        if not merged then
            out[#out + 1] = '<div class="message-title">'
            if speaker_text then
                out[#out + 1] = '<span class="speaker">' .. esc(speaker_text) .. "</span>"
            end
            if meta_text then
                out[#out + 1] = '<span class="message-meta">' .. esc(meta_text) .. "</span>"
            end
            out[#out + 1] = "</div>"
        end
    end

    local body = render_body(msg.content, data, tostring(index) .. ":")
    if role == "user" then
        if theme.user_style ~= "hidden" then
            out[#out + 1] = "<blockquote>" .. body .. "</blockquote>"
        end
    else
        if theme.drop_cap then
            body = drop_cap_html(body)
        end
        out[#out + 1] = body
    end

    if theme.show_reasoning and type(msg.reasoning) == "string"
        and msg.reasoning ~= "" then
        out[#out + 1] = '<blockquote class="reasoning">'
            .. render_body(msg.reasoning, data, tostring(index) .. "r:") .. "</blockquote>"
    end

    if theme.message_actions then
        out[#out + 1] = '<p class="actions"><a href="kt:msg/' .. index .. '">... '
            .. L("actions", _("Actions")) .. "</a></p>"
    end
    out[#out + 1] = "</section>"
    return table.concat(out, "\n")
end

-- === Public API ===

-- data = {
--   messages, chat_name, character_name, persona_name, created_at,
--   theme (a normalized BookTheme), labels (the theme's label overrides),
--   show_reasoning, revealed_spoilers, revealed_details
-- }
function Book.build(data)
    data = data or {}
    local messages = type(data.messages) == "table" and data.messages or {}
    local chat_name = data.chat_name
        or (type(data.character_name) == "string" and data.character_name)
        or _("Chat")
    local theme
    if data.theme == nil then
        -- A caller without a theme (the old API) keeps its own reasoning flag.
        theme = BookTheme.normalize({ show_reasoning = data.show_reasoning == true })
    else
        theme = BookTheme.normalize(data.theme)
    end
    local labels = type(data.labels) == "table" and data.labels or {}
    local function L(key, default)
        local value = labels[key]
        if type(value) == "string" and value ~= "" then return value end
        return default
    end

    local out = {
        "<!DOCTYPE html>",
        "<html>",
        "<head>",
        '<meta charset="utf-8">',
        "<title>" .. esc(chat_name) .. "</title>",
    }
    -- The theme signature: any look change changes the bytes, so the
    -- session's no-op guard reloads the book when the look changed.
    out[#out + 1] = '<meta name="kotavern-book-theme" content="'
        .. esc(BookTheme.sig(theme)) .. '">'
    if data.character_name then
        out[#out + 1] = '<meta name="author" content="'
            .. esc(data.character_name) .. '">'
    end
    out[#out + 1] = "<style>" .. stylesheet(theme) .. "</style>"
    out[#out + 1] = "</head>"
    out[#out + 1] = "<body>"

    -- Cover
    if theme.cover then
        local cover_title = chat_name
        if theme.cover_title == "character" then
            cover_title = data.character_name or chat_name
        elseif theme.cover_title == "both" and data.character_name then
            cover_title = chat_name .. " · " .. data.character_name
        end
        out[#out + 1] = '<div class="cover">'
        out[#out + 1] = '<div class="book-title">' .. esc(cover_title) .. "</div>"
        local subtitle = {}
        if data.character_name and theme.cover_title ~= "character" then
            table.insert(subtitle, esc(data.character_name))
        end
        if data.persona_name then table.insert(subtitle, esc(data.persona_name)) end
        if #subtitle > 0 then
            out[#out + 1] = '<div class="book-sub">' .. table.concat(subtitle, " · ") .. "</div>"
        end
        local meta = {}
        if theme.cover_date and data.created_at then
            table.insert(meta, esc(os.date("%Y-%m-%d", tonumber(data.created_at) or os.time())))
        end
        table.insert(meta, _("Messages") .. ": " .. tostring(#messages))
        out[#out + 1] = '<div class="book-meta">' .. table.concat(meta, " · ") .. "</div>"
        if theme.cover_actions then
            out[#out + 1] = '<p class="actions"><a href="kt:end">'
                .. L("go_end", _("Go to the end")) .. "</a></p>"
        end
        out[#out + 1] = "</div>"
    end

    -- Messages stay in chat order, without generated turn/chapter boundaries.
    local prev = nil
    for index, msg in ipairs(messages) do
        local html = message_html(msg, index, data, theme, labels, prev)
        prev = msg
        if html ~= "" then
            if theme.separator == "ornament" and index > 1 then
                out[#out + 1] = '<p class="kt-ornament">&#10087;</p>'
            end
            out[#out + 1] = html
        end
    end

    if #messages == 0 then
        out[#out + 1] = '<p class="empty">' .. _("No messages yet.") .. "</p>"
    end

    -- Colophon
    if theme.colophon then
        out[#out + 1] = '<div class="colophon">'
        out[#out + 1] = '<p class="compose"><a href="kt:new">&gt; '
            .. L("write_next", _("Write next message")) .. "</a></p>"
        out[#out + 1] = '<p class="compose"><a href="kt:continue">&gt; '
            .. L("continue_last", _("Continue last reply")) .. "</a></p>"
        out[#out + 1] = '<p class="compose"><a href="kt:menu">&gt; '
            .. L("book_actions", _("Book actions")) .. "</a></p>"
        out[#out + 1] = "</div>"
    end

    out[#out + 1] = "</body>"
    out[#out + 1] = "</html>"
    return table.concat(out, "\n")
end

-- Atomic write: temp file + rename (same convention as kt_storage).
function Book.save(book_path, html)
    if type(book_path) ~= "string" or book_path == "" then
        return nil, "invalid path"
    end
    local dir, dir_err = ensure_book_dir()
    if not dir then
        return nil, dir_err or "cannot create book dir"
    end
    local tmp = book_path .. ".tmp"
    local f, err = io.open(tmp, "w")
    if not f then
        return nil, err or "cannot write"
    end
    local ok = f:write(html or "")
    f:close()
    if not ok then
        os.remove(tmp)
        return nil, "write failed"
    end
    local renamed, rename_err = os.rename(tmp, book_path)
    if not renamed then
        os.remove(tmp)
        return nil, rename_err or "rename failed"
    end
    return book_path
end

-- Read the generated book back (the no-op reload guard compares the freshly
-- built HTML with the bytes the reader is showing).
function Book.read(book_path)
    if type(book_path) ~= "string" or book_path == "" then
        return nil
    end
    local f = io.open(book_path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

function Book.write(chat_path, html)
    local path = Book.path_for(chat_path)
    local ok, err = Book.save(path, html)
    if not ok then return nil, err end
    return ok
end

-- Remove the generated book and its reader sidecar(s). Best effort: a failure
-- to remove one of them must not stop the chat deletion.
function Book.remove(chat_path)
    local path = Book.path_for(chat_path)
    os.remove(path)
    os.remove(path .. ".tmp")

    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_ds and DocSettings and DocSettings.getSidecarDir then
        local util = require("ffi/util")
        local seen = {}
        for _, location in ipairs({ "doc", "dir", "hash" }) do
            local ok_dir, dir = pcall(function()
                return DocSettings:getSidecarDir(path, location)
            end)
            if ok_dir and dir and dir ~= "" and not seen[dir] then
                seen[dir] = true
                pcall(util.purgeDir, dir)
            end
        end
    end
end

function Book.clear()
    local util = require("ffi/util")
    pcall(util.purgeDir, book_dir())
end

function Book.exists(chat_path)
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(Book.path_for(chat_path), "mode") == "file"
end

return Book
