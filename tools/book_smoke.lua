-- Headless smoke harness for BOOK MODE (the native-reader rewrite).
--
-- Boots the REAL KOReader runtime (fonts, crengine, SDL), builds a book from
-- a synthetic chat, opens it through the real App:open_book path (ReaderUI +
-- crengine), and asserts the integration contract:
--
--   T1  content: one chapter <h1> per turn
--   T2  content: no <script> / no raw markdown leakage
--   T3  files: the book lives in <data>/books and is recognized as ours
--   T4  content: the kt: action links are present
--   T5  content: every message has an id="mN" anchor
--   T6  content: model headings are demoted (the native TOC stays clean)
--   T7  files: Book.remove drops the generated file
--   T8  reader: the native reader opened OUR document
--   T9  reader: the event listener sits at index 2 (the view keeps painting)
--   T10 reader: the kt: tap zone is registered and overrides tap_link
--   T11 history: the generated book never enters the reader history
--   T12 links: crengine kept our kt: scheme in the document links
--   T13 live: a message mutation reloads the reader with the new content
--   T14 close: closing the reader tears the session down
--   T15 hud: the streaming HUD appears and disappears
--   T16 links: the tap interception resolves the kt: link on screen
--
-- Run with KOReader's runtime (the reader needs the real crengine):
--   mkdir -p /tmp/kotavern_ko/settings/kotavern/{chats,characters,books}
--   cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy \
--       ./luajit /path/to/kotavern.koplugin/tools/book_smoke.lua
--
-- Exit 0 = all checks passed.

require("setupkoenv")

local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/")
local PLUGIN = here .. "/.."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local checks, fails = 0, 0
local function ok(cond, name)
    checks = checks + 1
    if not cond then
        fails = fails + 1
        io.stderr:write("FAIL: " .. tostring(name) .. "\n")
    else
        print("ok   " .. name)
    end
end
local function info(msg)
    print("--   " .. tostring(msg))
end

-- Mirror reader.lua's boot order ------------------------------------------------
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()

local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local lang_locale = G_reader_settings:readSetting("language")
require("ui/bidi").setup(lang_locale)

local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local ReaderUI = require("apps/reader/readerui")

-- The reader instantiates the plugins from <data>/plugins. Link ourselves in
-- so the REAL attach path runs (main.lua -> kt_book_reader -> ReaderUI),
-- exactly like on the device.
local plugins_dir = DataStorage:getDataDir() .. "/plugins"
os.execute("mkdir -p '" .. plugins_dir .. "'")
os.execute("ln -sfn '" .. PLUGIN .. "' '" .. plugins_dir .. "/kotavern.koplugin'")

-- === Fixtures =================================================================

local Storage = require("kt_storage")
local Book = require("kt_book")

local CHAR = "BookSmokeChar"
local chat_path = Storage.chat_path(CHAR, "book_smoke_chat")

local fixture_messages = {
    {
        role = "user",
        content = "Hello there, this is the **first** user message.",
        name = "User",
    },
    {
        role = "assistant",
        content = "Hi! I am the assistant.\n\n## A markdown heading\n\n- one\n- two",
        name = CHAR,
    },
    {
        role = "user",
        content = "Second turn, with a [link](https://example.org) inside.",
        name = "User",
    },
    {
        role = "assistant",
        content = "Second answer. ```\ncode block\n```",
        name = CHAR,
    },
}

Storage.save_chat(chat_path, {
    chat_metadata = {
        chat_name = "Book smoke",
        character_name = CHAR,
        created_at = os.time(),
    },
}, fixture_messages)

local function count(html, pattern)
    local n = 0
    for _ in html:gmatch(pattern) do n = n + 1 end
    return n
end

-- === T1..T7: content + files (no reader needed) ==============================

local html = Book.build({
    messages = fixture_messages,
    chat_name = "Book smoke",
    character_name = CHAR,
    persona_name = "Tester",
})

ok(count(html, '<h1 class="chapter"') == 2,
    "T1: one chapter heading per turn (2 turns)")
ok(html:lower():find("<script", 1, true) == nil
    and not html:find("**first**", 1, true)
    and not html:find("## A markdown", 1, true),
    "T2: no script tag and no raw markdown leakage")

local book_file = Book.path_for(chat_path)
local written, write_err = Book.write(chat_path, html)
ok(written == book_file and Book.exists(chat_path),
    "T3a: the book is written to <data>/books")
if not written then
    info("book write failed: " .. tostring(write_err))
end
ok(Book.is_book_path(book_file)
    and not Book.is_book_path("/tmp/some_other.html")
    and not Book.is_book_path(book_file .. ".tmp"),
    "T3b: is_book_path accepts ours and rejects everything else")

ok(html:find("kt:msg/1", 1, true) ~= nil
    and html:find("kt:new", 1, true) ~= nil
    and html:find("kt:continue", 1, true) ~= nil
    and html:find("kt:menu", 1, true) ~= nil,
    "T4: the kt: action links are rendered")

local anchors = 0
for i = 1, #fixture_messages do
    if html:find('id="m' .. i .. '"', 1, true) then anchors = anchors + 1 end
end
ok(anchors == #fixture_messages,
    "T5: every message has an id=\"mN\" anchor")

ok(count(html, "<h1") == 2 and count(html, "<h2") == 0
    and html:find('class="md-h', 1, true) ~= nil,
    "T6: model headings are demoted (the native TOC stays clean)")

Book.remove(chat_path)
ok(not Book.exists(chat_path), "T7: Book.remove drops the generated file")

-- === T8..T15: the native reader ==============================================

local App = require("kt_app")
local Session = require("kt_book_session")
local BookUI = require("kt_book_ui")

local app = App:new(nil)
app.state.settings.chat_mode = "book"
app:show()

-- The chat fixture must be the app's live chat (the book reads the live
-- message list first).
app:_load_chat_state(CHAR, chat_path, nil)

local reader_before = nil
local reload_seen = false

app:open_book(chat_path)

UIManager:scheduleIn(1.8, function()
    reader_before = ReaderUI.instance
    ok(reader_before ~= nil and reader_before.document ~= nil
        and reader_before.document.file == Book.path_for(chat_path),
        "T8: the native reader opened OUR document")

    local view_is_first = reader_before[1] ~= nil
        and reader_before[1].name == "readerview"
    local listener = reader_before[2]
    ok(view_is_first and listener ~= nil and listener.onEndOfBook ~= nil
        and listener.onCloseWidget ~= nil,
        "T9: the event listener sits at index 2 (the view keeps painting)")

    local zones = reader_before._zones or {}
    local zone = zones["kotavern_book_tap"]
    ok(zone ~= nil and zone.def ~= nil and zone.def.overrides ~= nil
        and zone.def.overrides[1] == "tap_link",
        "T10: the kt: tap zone is registered and overrides tap_link")

    local ReadHistory = require("readhistory")
    local in_history = false
    for _, item in ipairs(ReadHistory.hist or {}) do
        if item.file == Book.path_for(chat_path) then in_history = true end
    end
    ok(not in_history, "T11: the generated book never enters the reader history")

    local links = reader_before.document:getPageLinks() or {}
    local kt_link = false
    local kt_uri, kt_xp = nil, nil
    for _, link in ipairs(links) do
        if type(link.uri) == "string" and link.uri:sub(1, 3) == "kt:" then
            kt_link = true
            kt_uri = link.uri
            kt_xp = link.a_xpointer
        end
    end
    ok(kt_link, "T12: crengine kept the kt: scheme in the document links")

    -- T16: the tap interception resolves the kt: link at its screen
    -- position (the same path the touch zone uses).
    local Reader = require("kt_book_reader")
    if kt_xp then
        local ok_pos, sy, sx = pcall(function()
            return reader_before.document:getScreenPositionFromXPointer(kt_xp)
        end)
        local got = nil
        if ok_pos and sx then
            got = Reader.link_uri_at(reader_before, { x = sx, y = sy })
        end
        ok(got == kt_uri,
            "T16: the kt: link is resolved at its screen position")
    else
        ok(false, "T16: the kt: link is resolved at its screen position")
    end

    -- T15: the streaming HUD.
    BookUI.hud_show(reader_before, "thinking", "streaming preview")
    local hud_shown = BookUI.hud_is_shown()
    BookUI.hud_hide()
    ok(hud_shown and not BookUI.hud_is_shown(),
        "T15: the streaming HUD appears and disappears")
end)

UIManager:scheduleIn(2.6, function()
    -- T13: a live mutation reloads the reader with the new content.
    table.insert(app.state.messages, {
        role = "user",
        content = "A message added while the book is open.",
        name = "User",
    })
    Storage.append_message(chat_path, "user",
        "A message added while the book is open.", nil, "User")
    app:_book_mutated({ kind = "mutation", tail = true })
end)

UIManager:scheduleIn(5.2, function()
    local ui = ReaderUI.instance
    local fresh = ui ~= reader_before
    local content_ok = false
    if ui and ui.document and ui.document.file == Book.path_for(chat_path) then
        local f = io.open(Book.path_for(chat_path), "r")
        local body = f and f:read("*a") or ""
        if f then f:close() end
        content_ok = body:find("A message added while the book is open.", 1, true) ~= nil
    end
    reload_seen = fresh and content_ok
    ok(reload_seen,
        "T13: a message mutation reloads the reader with the new content")
end)

UIManager:scheduleIn(6.2, function()
    -- T14: closing the reader tears the session down.
    app:close_book_reader()
    UIManager:scheduleIn(0.4, function()
        ok(not Session.is_active() and app.state.book_active == nil,
            "T14: closing the reader tears the session down")
        print(string.format("\n%d checks, %d failures", checks, fails))
        UIManager:quit()
        os.exit(fails == 0 and 0 or 1)
    end)
end)

UIManager:run()
