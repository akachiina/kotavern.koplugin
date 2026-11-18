-- KtBook: "book mode" for chats.
--
-- The experimental book mode renders a chat as a paginated HTML document and
-- opens it in KOReader's NATIVE reader (crengine, the same engine that reads
-- EPUB). That is the whole point: the user gets the real reader, with the
-- font, size, spacing, margins, night mode and page-turn gestures they already
-- configured for books - none of it comes from this plugin.
--
-- How it works:
--   Chat .jsonl  ->  Book.html_from_chat()  ->  <chat>.kotavern.html
--                    ->  ReaderUI:showReader(path)
--
-- The generated file is plain HTML 5 (a sequence of <section class="ktmsg">),
-- styled by a small embedded stylesheet that only carries what crengine cannot
-- express natively (the chat tints, the avatar initial, the name row). Type
-- metrics are left to the reader's own settings.
--
-- Actions (regenerate / persona / write next) are NOT links in the HTML: the
-- crengine does not know our kt: scheme and would drop them. They live in the
-- colophon page (the last section) and in the swipe-up sheet, both native
-- widgets that the reader draws on top. See kt_book_actions.lua.

local Storage = require("kt_storage")
local Theme = require("ktui/theme")

local Book = {}

-- Where generated books live. A chat keeps ONE book file, rewritten on every
-- open, so it never accumulates stale copies and the reader's own "recent"
-- list stays meaningful.
local BOOK_DIR_TAIL = "/books"

local function book_dir()
    return Storage.data_dir() .. BOOK_DIR_TAIL
end

local function ensure_book_dir()
    local lfs = require("libs/libkoreader-lfs")
    local dir = book_dir()
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    return dir
end

-- Minimal HTML escape (the chat body is plain text, never markup: the model's
-- markdown is intentionally NOT rendered here - the book is a reading surface,
-- and the reader's own typography is the point).
local function esc(s)
    s = tostring(s or "")
    s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    s = s:gsub('"', "&quot;")
    return s
end

-- First glyph of a name, as the avatar fallback (canvas chat parity).
local function initial(name)
    local n = tostring(name or ""):gsub("^%s+", "")
    if n == "" then return "?" end
    return n:sub(1, 1):upper()
end

-- Split body into paragraphs on blank lines; a single newline stays inside the
-- paragraph (the model's line breaks are meaningful in chat).
local function paragraphs(text)
    local out = {}
    for block in (tostring(text or "") .. "\n\n"):gmatch("(.-)\n\n") do
        local b = block:gsub("\n", " ")
        if b:gsub("%s", "") ~= "" then
            out[#out + 1] = b
        end
    end
    if #out == 0 and tostring(text or "") ~= "" then
        out[1] = tostring(text):gsub("\n", " ")
    end
    return out
end

-- Build the embedded stylesheet. Only what the reader cannot do natively:
-- the message bubble tint, the name row, the colophon button grid.
local function stylesheet(look)
    local colors = look.colors or {}
    local function c(key, fallback)
        local v = colors[key]
        if type(v) == "string" and v ~= "" then return v end
        return fallback
    end
    local ink = c("text", "#000000")
    local surface = c("surface", "#ffffff")
    local ai = c("ai_panel", surface)
    local user = c("user_panel", "#eeeeee")
    local border = c("border", "#cccccc")

    return table.concat({
        "body { margin: 0; padding: 0; }",
        -- The reader owns typography; we only ask for a little breathing room.
        "section.ktmsg { margin: 0 0 1.2em 0; }",
        "div.ktname { font-size: 85%; font-weight: bold; color: " .. ink .. ";",
        "  margin: 0 0 0.2em 0; }",
        "div.ktbubble { padding: 0.6em 0.8em; border: 1px solid " .. border .. ";",
        "  border-radius: 0.5em; }",
        "section.ktmsg.ktuser div.ktbubble { background: " .. user .. "; }",
        "section.ktmsg.ktassistant div.ktbubble { background: " .. ai .. "; }",
        -- Reasoning block: collapsed by default is impossible in static HTML,
        -- so it is shown muted under the body (the book is a reading view).
        "div.ktreason { font-size: 85%; color: " .. ink .. "; opacity: 0.65;",
        "  margin: 0.4em 0 0 0; }",
        -- Colophon: the action page at the end.
        "section.ktcolophon { margin: 2em 0 0 0; border-top: 1px solid " .. border .. ";",
        "  padding-top: 1em; }",
        "h1.ktcolophon-title { font-size: 110%; margin: 0 0 0.6em 0; }",
        "p.kthint { font-size: 85%; opacity: 0.7; margin: 0.6em 0 0 0; }",
    }, "\n")
end

-- One message as a <section>. `is_last` marks the final assistant message
-- (the colophon follows it).
local function message_html(msg, opts)
    local role = msg.role or "assistant"
    local name
    if role == "user" then
        name = opts.persona_name or "You"
    else
        name = msg.name or opts.character_name or "AI"
    end

    local cls = (role == "user") and "ktmsg ktuser" or "ktmsg ktassistant"
    local out = {}
    out[#out + 1] = '<section class="' .. cls .. '">'
    out[#out + 1] = '<div class="ktname">' .. esc(name) .. "</div>"
    out[#out + 1] = '<div class="ktbubble">'
    for _, p in ipairs(paragraphs(msg.content)) do
        out[#out + 1] = "<p>" .. esc(p) .. "</p>"
    end
    out[#out + 1] = "</div>"
    if msg.reasoning and msg.reasoning ~= "" then
        out[#out + 1] = '<div class="ktreason">' .. esc(msg.reasoning) .. "</div>"
    end
    out[#out + 1] = "</section>"
    return table.concat(out, "\n")
end

-- The colophon: what the user sees after the last page. It is a regular HTML
-- section so it flows in the same document (no overlay, no widget); its
-- "buttons" are links to the native sheet the plugin installs, which is the
-- only interactive surface crengine can host.
local function colophon_html(opts)
    return table.concat({
        '<section class="ktcolophon">',
        "<h1>Continua a conversa</h1>",
        '<p>Escreva a proxima mensagem, ou escolha uma acao abaixo.</p>',
        "<p>Escolha uma acao no menu do leitor (Gestos &gt; Action sheet),",
        " ou volte para a lista de chats.</p>",
        '<p class="kthint">Dica: arraste para cima para abrir as acoes.</p>',
        "</section>",
    }, "\n")
end

-- Full document.
function Book.html_from_chat(chat, opts)
    opts = opts or {}
    local parts = {}
    parts[#parts + 1] = "<!DOCTYPE html>"
    parts[#parts + 1] = '<html><head><meta charset="utf-8">'
    parts[#parts + 1] = "<title>" .. esc(opts.character_name or "KOTavern") .. "</title>"
    parts[#parts + 1] = "<style>" .. stylesheet(opts.look or {}) .. "</style>"
    parts[#parts + 1] = "</head><body>"

    for _, msg in ipairs(chat.messages or {}) do
        parts[#parts + 1] = message_html(msg, opts)
    end
    if opts.colophon ~= false then
        parts[#parts + 1] = colophon_html(opts)
    end

    parts[#parts + 1] = "</body></html>"
    return table.concat(parts, "\n")
end

-- Write the book file for a chat and return its path (nil on failure).
-- `opts`: { look, character_name, persona_name, colophon }
function Book.write(chat_path, opts)
    local chat = Storage.load_chat(chat_path)
    if not chat or not chat.messages or #chat.messages == 0 then
        return nil, "empty chat"
    end
    local dir = ensure_book_dir()
    -- One file per chat, named after the chat file (unique, no collisions).
    local base = tostring(chat_path):match("([^/\\]+)$") or "chat"
    local path = dir .. "/" .. base .. ".html"

    local f = io.open(path, "w")
    if not f then
        return nil, "cannot write book"
    end
    f:write(Book.html_from_chat(chat, opts))
    f:close()
    return path
end

-- Generated-book bookkeeping (so the reader UI can clean up / re-open).
function Book.path_for(chat_path)
    local base = tostring(chat_path):match("([^/\\]+)$") or "chat"
    return book_dir() .. "/" .. base .. ".html"
end

function Book.remove(chat_path)
    os.remove(Book.path_for(chat_path))
end

return Book