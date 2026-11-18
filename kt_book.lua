-- KtBook: "book mode" content layer.
--
-- A chat is rendered as ONE paginated HTML document and opened in KOReader's
-- native reader (crengine). This module owns ONLY the content: chat data ->
-- HTML. It never touches the ReaderUI, the canvas, or the KoReader settings.
--
-- Layout:
--   cover (title, character, persona, date)
--   <h1 class="chapter" id="turn-N">...</h1>   one chapter per turn (TOC)
--   <section class="msg" id="mN">...</section> one message, with an action link
--   colophon (compose / continue / menu links)
--
-- Only our chapter <h1>s are headings; model markdown headings are demoted to
-- styled paragraphs so they cannot pollute the native TOC.
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

-- Truncate without splitting a UTF-8 sequence (byte-based :sub paints tofu).
local function utf8_truncate(text, max_bytes)
    text = tostring(text or "")
    if #text <= max_bytes then return text end
    local cut = max_bytes
    while cut > 0 do
        local b = text:byte(cut)
        if not b then
            cut = 0
            break
        end
        if b < 0x80 then
            break
        elseif b >= 0xC0 then
            -- Lead byte at the cut: its continuation bytes fall outside.
            cut = cut - 1
            break
        end
        cut = cut - 1
    end
    if cut < 1 then return "" end
    return text:sub(1, cut) .. "…"
end

-- Plain text for chapter previews: drop HTML tags and markdown punctuation.
local function plain_text(value)
    local s = tostring(value or "")
    s = s:gsub("<[^>]->", " ")
    s = s:gsub("```.-```", " ")
    s = s:gsub("!%[([^%]]*)%]%([^%)]*%)", "%1")
    s = s:gsub("%[([^%]]*)%]%([^%)]*%)", "%1")
    s = s:gsub("[*_`#>~|]+", "")
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function chapter_preview(value)
    local s = plain_text(value)
    if s == "" then return "" end
    return utf8_truncate(s, 52)
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
    for _, block in ipairs(blocks) do
        local kind = block.kind
        if kind == "paragraph" then
            if block.text and block.text ~= "" then
                out[#out + 1] = "<p>" .. inline_html(block.text) .. "</p>"
            end
        elseif kind == "heading" then
            local level = math.max(1, math.min(6, tonumber(block.level) or 3))
            -- Demoted on purpose: only chapter <h1>s may reach the TOC.
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
            out[#out + 1] = '<p class="img-placeholder">['
                .. _("Image") .. ": " .. esc(alt) .. "]</p>"
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

local function stylesheet()
    return table.concat({
        "body { margin: 0; }",
        ".cover { text-align: center; padding: 2em 1em; }",
        ".book-title { font-size: 1.6em; font-weight: bold; }",
        ".book-sub { font-size: 1.1em; margin-top: .6em; }",
        ".book-meta { font-size: .9em; margin-top: .4em; }",
        ".chapter { page-break-before: always; margin-top: 1.2em; }",
        ".md-h { font-weight: bold; margin: 1em 0 .4em; }",
        ".md-h1 { font-size: 1.25em; }",
        ".md-h2 { font-size: 1.2em; }",
        ".md-h3 { font-size: 1.15em; }",
        ".md-h4, .md-h5, .md-h6 { font-size: 1.05em; }",
        ".speaker { font-size: .85em; font-weight: bold; letter-spacing: .03em;",
        "  margin: 1.2em 0 .2em; }",
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
    }, "\n")
end

local function speaker_for(msg, data)
    if msg.role == "user" then
        return data.persona_name or _("You")
    elseif msg.role == "system" then
        return _("System")
    end
    return msg.name or data.character_name or _("Assistant")
end

local function message_html(msg, index, data)
    local role = msg.role or "assistant"
    local classes = { "msg", "msg-" .. tostring(role) }
    if msg.hidden == true then
        classes[#classes + 1] = "msg-hidden"
    end

    local out = {}
    out[#out + 1] = '<section class="' .. table.concat(classes, " ")
        .. '" id="m' .. index .. '">'
    out[#out + 1] = '<div class="speaker">' .. esc(speaker_for(msg, data)) .. "</div>"

    local body = render_blocks(msg.content, data)
    if role == "user" then
        out[#out + 1] = "<blockquote>" .. body .. "</blockquote>"
    else
        out[#out + 1] = body
    end

    if data.show_reasoning and type(msg.reasoning) == "string"
        and msg.reasoning ~= "" then
        out[#out + 1] = '<blockquote class="reasoning">'
            .. render_blocks(msg.reasoning, data) .. "</blockquote>"
    end

    out[#out + 1] = '<p class="actions"><a href="kt:msg/' .. index .. '">... '
        .. _("Actions") .. "</a></p>"
    out[#out + 1] = "</section>"
    return table.concat(out, "\n")
end

-- Group messages into turns: a new chapter starts at every user message,
-- except when it is the first message (the greeting and the first user turn
-- belong to the opening chapter).
local function split_turns(messages)
    local turns = {}
    local current = nil
    for index, msg in ipairs(messages) do
        local starts = false
        if current == nil then
            starts = true
        elseif msg.role == "user" then
            -- The first user message joins an opening greeting chapter;
            -- every later user message opens a new turn.
            local has_user = false
            for _, entry in ipairs(current.messages) do
                if entry.msg.role == "user" then
                    has_user = true
                    break
                end
            end
            starts = has_user
        end
        if starts then
            current = { first_index = index, messages = {} }
            turns[#turns + 1] = current
        end
        table.insert(current.messages, { index = index, msg = msg })
    end
    return turns
end

local function turn_preview(turn)
    for _, entry in ipairs(turn.messages) do
        if entry.msg.role == "user" then
            local preview = chapter_preview(entry.msg.content)
            if preview ~= "" then return preview end
        end
    end
    local first = turn.messages[1] and turn.messages[1].msg
    local preview = first and chapter_preview(first.content) or ""
    return preview
end

-- === Public API ===

-- data = {
--   messages, chat_name, character_name, persona_name, created_at,
--   show_reasoning
-- }
function Book.build(data)
    data = data or {}
    local messages = type(data.messages) == "table" and data.messages or {}
    local chat_name = data.chat_name
        or (type(data.character_name) == "string" and data.character_name)
        or _("Chat")

    local out = {
        "<!DOCTYPE html>",
        "<html>",
        "<head>",
        '<meta charset="utf-8">',
        "<title>" .. esc(chat_name) .. "</title>",
    }
    if data.character_name then
        out[#out + 1] = '<meta name="author" content="'
            .. esc(data.character_name) .. '">'
    end
    out[#out + 1] = "<style>" .. stylesheet() .. "</style>"
    out[#out + 1] = "</head>"
    out[#out + 1] = "<body>"

    -- Cover
    out[#out + 1] = '<div class="cover">'
    out[#out + 1] = '<div class="book-title">' .. esc(chat_name) .. "</div>"
    local subtitle = {}
    if data.character_name then table.insert(subtitle, esc(data.character_name)) end
    if data.persona_name then table.insert(subtitle, esc(data.persona_name)) end
    if #subtitle > 0 then
        out[#out + 1] = '<div class="book-sub">' .. table.concat(subtitle, " · ") .. "</div>"
    end
    local meta = {}
    if data.created_at then
        table.insert(meta, esc(os.date("%Y-%m-%d", tonumber(data.created_at) or os.time())))
    end
    table.insert(meta, _("Messages") .. ": " .. tostring(#messages))
    out[#out + 1] = '<div class="book-meta">' .. table.concat(meta, " · ") .. "</div>"
    out[#out + 1] = '<p class="actions"><a href="kt:end">'
        .. _("Go to the end") .. "</a></p>"
    out[#out + 1] = "</div>"

    -- Chapters
    local turns = split_turns(messages)
    for turn_number, turn in ipairs(turns) do
        local preview = turn_preview(turn)
        local title = _("Turn") .. " " .. turn_number
        if preview ~= "" then
            title = title .. " — " .. preview
        end
        out[#out + 1] = '<h1 class="chapter" id="turn-' .. turn_number .. '">'
            .. esc(title) .. "</h1>"
        for _, entry in ipairs(turn.messages) do
            out[#out + 1] = message_html(entry.msg, entry.index, data)
        end
    end

    if #messages == 0 then
        out[#out + 1] = '<p class="empty">' .. _("No messages yet.") .. "</p>"
    end

    -- Colophon
    out[#out + 1] = '<div class="colophon">'
    out[#out + 1] = '<p class="compose"><a href="kt:new">&gt; '
        .. _("Write next message") .. "</a></p>"
    out[#out + 1] = '<p class="compose"><a href="kt:continue">&gt; '
        .. _("Continue last reply") .. "</a></p>"
    out[#out + 1] = '<p class="compose"><a href="kt:menu">&gt; '
        .. _("Book actions") .. "</a></p>"
    out[#out + 1] = "</div>"

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
