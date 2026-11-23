-- Headless smoke harness for BOOK MODE (the native-reader rewrite).
--
-- Boots the REAL KOReader runtime (fonts, crengine, SDL), builds a book from
-- a synthetic chat, opens it through the real App:open_book path (ReaderUI +
-- crengine), and asserts the integration contract:
--
--   T1  content: continuous message sections, no generated chapters
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
--   T17 mode: Book -> List closes the reader and stores the mode
--   T18 mode: List -> Book opens the book for the chat on screen
--   T19 mode: disabling Debug Mode forces the mode back to List
--   T20 content: titles carry speaker, valid local time and message number
--   T21 actions: native chat actions and quick replies work over the reader
--   T22 input: the hidden canvas ignores taps, holds, swipes, pans and keys
--   T23 files: all PathChooser callers work without a host UI instance
--   T24 review: multiline editors, metadata sorting, rename and busy HUD
--   T25 disclosures: qualified markup, isolated state and real native taps
--   T26 emoji: scoped Noto Emoji spans and one-time crengine registration
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
        content = "Hello there, this is the **first** user message. "
            .. "<details><summary>Native more</summary>native hidden body "
            .. "<a href='https://example.org/\" href=\"kt:continue'>injected action</a>"
            .. "</details> ||native secret||",
        name = "User",
        send_date = 1700000000,
    },
    {
        role = "assistant",
        content = "Hi! I am the assistant.\n\n- one\n- two\n\n"
            .. "<details><summary>Second native</summary>second hidden body</details> "
            .. "||second secret||",
        name = CHAR,
    },
    {
        role = "user",
        content = "Second turn, with a [link](https://example.org) inside.\n\n## A markdown heading"
            .. "\n\n<code>href=\"kt:det:3:999\"</code>",
        reasoning = "<pre>href=\"kt:spl:3r:999\"</pre>",
        name = "User",
        send_date = -7,
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
-- Infinity cannot be represented in the persisted JSON fixture; exercise it
-- only in the in-memory build, where an invalid timestamp must stay harmless.
fixture_messages[4].send_date = math.huge

local function count(html, pattern)
    local n = 0
    for _ in html:gmatch(pattern) do n = n + 1 end
    return n
end

local function find_row(rows, text)
    for index = 1, #(rows or {}) do
        local row = rows[index]
        if row.text == text then return row end
    end
    return nil
end

local function read_generated_book()
    local f = io.open(Book.path_for(chat_path), "r")
    if not f then return "" end
    local body = f:read("*a") or ""
    f:close()
    return body
end

local function current_page(ui)
    if not ui then return nil end
    if ui.rolling and ui.rolling.current_page then
        return tonumber(ui.rolling.current_page)
    end
    if ui.document and ui.document.getCurrentPage then
        return tonumber(ui.document:getCurrentPage())
    end
    return nil
end

-- Exercise the actual crengine link and registered touch-zone handler. The
-- boolean only proves dispatch; generated-content assertions prove the action.
local function tap_native_link(ui, uri)
    if not ui or not ui.document then return false, nil end
    local links = ui.document:getPageLinks() or {}
    for index = 1, #links do
        local link = links[index]
        if link.uri == uri and link.a_xpointer then
            local ok_pos, sy, sx = pcall(function()
                return ui.document:getScreenPositionFromXPointer(link.a_xpointer)
            end)
            local zone = ui._zones and ui._zones.kotavern_book_tap
            if ok_pos and sx and zone and zone.def and zone.def.handler then
                local before = current_page(ui)
                local handled = zone.def.handler({ pos = { x = sx, y = sy } })
                return handled == true, before
            end
        end
    end
    return false, nil
end

-- === T1..T7: content + files (no reader needed) ==============================

local html = Book.build({
    messages = fixture_messages,
    chat_name = "Book smoke",
    character_name = CHAR,
    persona_name = "Tester",
})

ok(count(html, '<section class="msg ') == #fixture_messages
    and html:find('<h1 class="chapter"', 1, true) == nil
    and html:find('id="turn-', 1, true) == nil,
    "T1: messages are continuous sections without generated chapters")
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

ok(count(html, "<h1") == 0 and count(html, "<h2") == 0
    and html:find('class="md-h', 1, true) ~= nil,
    "T6: model headings are demoted (the native TOC stays clean)")

local titles_ok = html:find('<span class="speaker">Tester</span>', 1, true) ~= nil
    and html:find('<span class="message-meta">'
        .. os.date("%H:%M", 1700000000) .. ' · #1</span>', 1, true) ~= nil
for index = 2, #fixture_messages do
    titles_ok = titles_ok and html:find(
        '<span class="message-meta">#' .. index .. '</span>', 1, true) ~= nil
end
ok(titles_ok,
    "T20: titles carry speaker, valid local time and one-based message numbers")

local invalid_ok, invalid_html = pcall(Book.build, {
    messages = {
        { role = "assistant", content = "string time", send_date = "not-a-time" },
        { role = "assistant", content = "nan time", send_date = 0 / 0 },
    },
})
ok(invalid_ok
    and invalid_html:find('<span class="message-meta">#1</span>', 1, true) ~= nil
    and invalid_html:find('<span class="message-meta">#2</span>', 1, true) ~= nil
    and invalid_html:find('<span class="message-meta">%d%d:%d%d') == nil,
    "T20b: string and NaN timestamps omit time without aborting the build")

local interactive_data = {
    character_name = CHAR,
    persona_name = "Tester",
    show_reasoning = true,
    messages = {
        {
            role = "assistant",
            content = "<details><summary>Body one</summary>body one hidden</details> ||body secret||",
            reasoning = "<details><summary>Reason one</summary>reason one hidden</details> ||reason secret||",
        },
        {
            role = "user",
            content = "<details><summary>Body two</summary>body two hidden</details> ||two secret||",
        },
    },
}
local interactive = Book.build(interactive_data)
local qualified_links = {
    "kt:det:1:1", "kt:spl:1:1", "kt:det:1r:1", "kt:spl:1r:1",
    "kt:det:2:1", "kt:spl:2:1",
}
local all_qualified = true
for index = 1, #qualified_links do
    all_qualified = all_qualified and interactive:find(
        'href="' .. qualified_links[index] .. '"', 1, true) ~= nil
end
ok(all_qualified
    and interactive:find("body one hidden", 1, true) == nil
    and interactive:find("reason one hidden", 1, true) == nil
    and interactive:find("body two hidden", 1, true) == nil
    and interactive:find('href="kt:det:1"', 1, true) == nil,
    "T25a: Book details and spoilers are qualified and start collapsed")

interactive_data.revealed_details = { ["1:1"] = true }
interactive_data.revealed_spoilers = { ["1r:1"] = true }
local selectively_open = Book.build(interactive_data)
ok(selectively_open:find("body one hidden", 1, true) ~= nil
    and selectively_open:find("reason one hidden", 1, true) == nil
    and selectively_open:find("body two hidden", 1, true) == nil
    and selectively_open:find('<span class="ktspl ktsplopen">reason secret</span>', 1, true) ~= nil
    and selectively_open:find('href="kt:spl:1:1" class="ktspl">body secret</a>', 1, true) ~= nil
    and selectively_open:find('href="kt:spl:2:1" class="ktspl">two secret</a>', 1, true) ~= nil,
    "T25b: disclosure state is isolated by message and reasoning channel")

local family_emoji = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
local emoji_html = Book.build({
    show_reasoning = true,
    revealed_details = { ["2:1"] = true },
    revealed_spoilers = { ["2:1"] = true, ["2r:1"] = true },
    messages = {
        {
            role = "assistant",
            content = "Ordinary **bold** Café 漢字 ✅ 😀 " .. family_emoji,
        },
        {
            role = "assistant",
            content = "<details><summary>Emoji ✅</summary>hidden 😀</details> "
                .. "||secret " .. family_emoji .. "||",
            reasoning = "Reason ✅ ||reason 😀||",
        },
    },
})
ok(emoji_html:find('.ktemoji { font-family: "Noto Emoji"; }', 1, true) ~= nil
    and emoji_html:find('Café 漢字 <span class="ktemoji">✅</span> '
        .. '<span class="ktemoji">😀</span> <span class="ktemoji">'
        .. family_emoji .. '</span>', 1, true) ~= nil
    and emoji_html:find('class="ktdet">▾ Emoji <span class="ktemoji">✅</span></a>', 1, true) ~= nil
    and emoji_html:find('hidden <span class="ktemoji">😀</span>', 1, true) ~= nil
    and emoji_html:find('<span class="ktspl ktsplopen">secret <span class="ktemoji">'
        .. family_emoji .. '</span></span>', 1, true) ~= nil
    and emoji_html:find('Reason <span class="ktemoji">✅</span>', 1, true) ~= nil
    and emoji_html:find('<span class="ktspl ktsplopen">reason <span class="ktemoji">😀</span></span>', 1, true) ~= nil,
    "T26a: scoped emoji spans cover both Book renderers and preserve UTF-8/ZWJ text")

local keycaps = "1\u{FE0F}\u{20E3} #\u{FE0F}\u{20E3} *\u{FE0F}\u{20E3}"
local keycap_html = Book.build({ messages = {{ role = "assistant", content = keycaps }} })
ok(keycap_html:find('<span class="ktemoji">1\u{FE0F}\u{20E3}</span> '
        .. '<span class="ktemoji">#\u{FE0F}\u{20E3}</span> '
        .. '<span class="ktemoji">*\u{FE0F}\u{20E3}</span>', 1, true) ~= nil,
    "T26e: digit, hash and asterisk keycaps stay in one Noto Emoji span")

local overlong_emoji = "\240\130\156\133" -- overlong U+2705, invalid UTF-8
local invalid_html = Book.build({ messages = {{
    role = "assistant", content = "invalid " .. overlong_emoji,
}} })
ok(invalid_html:find(overlong_emoji, 1, true) ~= nil
    and invalid_html:find('<span class="ktemoji">' .. overlong_emoji .. '</span>', 1, true) == nil,
    "T26f: invalid overlong UTF-8 is preserved without emoji classification")

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
app.state.settings.book_show_reasoning = true

local reader_before = nil
local reload_seen = false

-- Count successful registrations of only the bundled emoji face. All other
-- crengine fonts continue through the real function unchanged.
local cre = require("libs/libkoreader-cre")
local Constants = require("kt_constants")
local Font = require("ui/font")
local emoji_font_path = Constants.ASSET_DIR .. "/emoji-noto.ttf"
local original_register_font = cre.registerFont
local emoji_registrations = 0
cre.registerFont = function(path, ...)
    local result = original_register_font(path, ...)
    if path == emoji_font_path then
        emoji_registrations = emoji_registrations + 1
    end
    return result
end

app:open_book(chat_path)

UIManager:scheduleIn(1.8, function()
    reader_before = ReaderUI.instance
    ok(reader_before ~= nil and reader_before.document ~= nil
        and reader_before.document.file == Book.path_for(chat_path),
        "T8: the native reader opened OUR document")
    ok(emoji_registrations == 1
        and not table.concat(Font.fallbacks, "|"):find("emoji-noto.ttf", 1, true),
        "T26b: initial Book open registers Noto Emoji once without global fallback mutation")

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

    -- T22: the canvas remains mounted under ReaderUI. Its stale hitboxes and
    -- scroll state must not react to input while the book owns the screen.
    local view = app.view
    local gesture = {
        pos = { x = 5, y = 5 },
        start_pos = { x = 5, y = 5 },
        direction = "north",
        relative = { x = 0, y = 0 },
    }
    local old_hitboxes = view.hitboxes
    local old_bounds, old_step = view.list_bounds, view.scroll_step
    local old_max_scroll = view.max_scroll
    local scroll_key = app:scroll_key()
    local old_scroll = app.state.scroll[scroll_key]
    local taps, holds = 0, 0
    view.hitboxes = {
        {
            x = 0, y = 0, w = 50, h = 50,
            callback = function() taps = taps + 1 end,
            on_hold = function() holds = holds + 1 end,
        },
    }
    view.list_bounds = { x = 0, y = 0, w = 50, h = 50 }
    view.scroll_step, view.max_scroll = 20, 500
    app.state.scroll[scroll_key] = 0

    local tap_result = view:onTapKotavern(nil, gesture)
    ok(tap_result == false and taps == 0,
        "T22a: book mode blocks stale canvas tap hitboxes")
    local hold_result = view:onHoldKotavern(nil, gesture)
    ok(hold_result == false and holds == 0,
        "T22b: book mode blocks stale canvas hold hitboxes")

    app.state.scroll[scroll_key] = 0
    local swipe_result = view:onSwipeKotavern(nil, gesture)
    ok(swipe_result == false and app.state.scroll[scroll_key] == 0,
        "T22c: book mode blocks canvas swipe scrolling")

    app.state.scroll[scroll_key] = 0
    gesture.mousewheel_direction = "north"
    local pan_result = view:onPanKotavern(nil, gesture)
    gesture.mousewheel_direction = nil
    view._mousewheel_handled = nil
    app.state.scroll[scroll_key] = 0
    gesture.from_mousewheel = true
    local release_result = view:onPanReleaseKotavern(nil, gesture)
    gesture.from_mousewheel = nil
    ok(pan_result == false and release_result == false
        and app.state.scroll[scroll_key] == 0,
        "T22d: book mode blocks canvas wheel and pan-release scrolling")

    app.state.scroll[scroll_key] = 0
    local key_result = view:onKotavernScroll(1)
    ok(key_result == false and app.state.scroll[scroll_key] == 0,
        "T22e: book mode blocks canvas hardware-key scrolling")

    view.hitboxes = old_hitboxes
    view.list_bounds, view.scroll_step = old_bounds, old_step
    view.max_scroll = old_max_scroll
    app.state.scroll[scroll_key] = old_scroll

    -- T21: frequent chat actions use native dialogs over the reader, with
    -- Quick Reply available on every compose-oriented action surface.
    local _ = require("gettext")
    local Modals = require("ktui/modals")
    local captured_actions = {}
    local real_actions = Modals.actions
    Modals.actions = function(title, rows)
        captured_actions[#captured_actions + 1] = { title = title, rows = rows }
    end
    BookUI.global_actions(app)
    BookUI.end_of_book(app)
    local expected_rows = {
        _("Quick Reply"),
        _("Author's Note"),
        _("Add System Note"),
        _("Impersonate"),
        _("Rename Chat"),
        _("Export Chat"),
        _("Export TXT"),
    }
    local global_rows = captured_actions[1] and captured_actions[1].rows or {}
    local all_present = true
    for index = 1, #expected_rows do
        if not find_row(global_rows, expected_rows[index]) then
            all_present = false
        end
    end
    ok(all_present,
        "T21a: Book actions include the native-safe chat actions")

    local menu_items = {}
    BookUI.add_to_main_menu(menu_items)
    local reader_rows = menu_items.kotavern_book
        and menu_items.kotavern_book.sub_item_table_func() or {}
    ok(find_row(captured_actions[2] and captured_actions[2].rows, _("Quick Reply")) ~= nil
        and find_row(reader_rows, _("Quick Reply")) ~= nil,
        "T21b: end-of-book and reader menus include Quick Reply")

    -- The Author's Note editor must not fall back to a canvas Sheet. Exercise
    -- its native row dialog and save through the real chat metadata writer.
    local author_row = find_row(global_rows, _("Author's Note"))
    if author_row then author_row.callback() end
    local author_rows = captured_actions[3] and captured_actions[3].rows or {}
    ok(find_row(author_rows, _("Edit Note")) ~= nil
        and find_row(author_rows, _("Depth")) ~= nil
        and find_row(author_rows, _("Interval")) ~= nil
        and find_row(author_rows, _("Position")) ~= nil
        and find_row(author_rows, _("Role")) ~= nil
        and find_row(author_rows, _("Clear Note")) ~= nil,
        "T21c: Author's Note uses a native book dialog")

    local old_chat = Storage.load_chat(chat_path)
    local old_note = old_chat and old_chat.header.chat_metadata.note_prompt or nil
    local captured_input = nil
    local real_input = Modals.input
    Modals.input = function(title, input, hint, ok_text, callback)
        captured_input = { title = title, callback = callback }
    end
    local edit_note_row = find_row(author_rows, _("Edit Note"))
    if edit_note_row then edit_note_row.callback() end
    Modals.input = real_input
    Modals.actions = real_actions
    if captured_input and captured_input.callback then
        captured_input.callback("Book smoke note")
    end
    local saved_chat = Storage.load_chat(chat_path)
    ok(captured_input ~= nil and saved_chat ~= nil
        and saved_chat.header.chat_metadata.note_prompt == "Book smoke note",
        "T21d: Author's Note saves from the native book editor")
    app:set_authors_note_field("note_prompt", old_note)

    -- T24c: drive the real rename action and its scheduled reader reload.
    -- T13's later mutation gives the reload ample time to settle before the
    -- generated cover and HTML title are inspected.
    local rename_callback = nil
    local real_rename_input = Modals.input
    Modals.input = function(title, input, hint, ok_text, callback)
        rename_callback = callback
    end
    BookUI.rename_chat(app)
    Modals.input = real_rename_input
    if rename_callback then rename_callback("Book smoke renamed") end

    -- T24d: impersonation is a generation too. Its native HUD must appear
    -- while the request is active and disappear before the draft editor opens.
    local Client = require("kt_client")
    local old_connection = app.state.current_connection
    local old_client_new = Client.new
    local old_impersonate_input = Modals.input
    local impersonate_editor = nil
    app.state.current_connection = { id = "impersonate-smoke", model_id = "smoke" }
    Client.new = function()
        return {
            chat_completion = function(self, api_messages, conn, preset, callback)
                callback("Impersonated draft", nil)
            end,
        }
    end
    Modals.input = function(title, input)
        impersonate_editor = input
    end
    app:impersonate()
    local impersonate_hud_started = BookUI.hud_is_shown()
    UIManager:scheduleIn(0.5, function()
        local impersonate_hud_cleared = not BookUI.hud_is_shown()
        local impersonate_finished = not app.state.is_generating
            and impersonate_editor == "Impersonated draft"
        app.state.current_connection = old_connection
        Client.new = old_client_new
        Modals.input = old_impersonate_input
        if app.state.is_generating then app:stop_generation() end
        ok(impersonate_hud_started and impersonate_hud_cleared and impersonate_finished,
            "T24d: Impersonate shows and clears the native generation HUD")
    end)

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

local router_ui, router_body
local details_tapped, details_page_before = false, nil
local details_ui = nil
local spoiler_tapped = false
local swipe_message_index = nil

UIManager:scheduleIn(5.2, function()
    local ui = ReaderUI.instance
    local fresh = ui ~= reader_before
    local content_ok = false
    local body = ""
    if ui and ui.document and ui.document.file == Book.path_for(chat_path) then
        local f = io.open(Book.path_for(chat_path), "r")
        body = f and f:read("*a") or ""
        if f then f:close() end
        content_ok = body:find("A message added while the book is open.", 1, true) ~= nil
    end
    reload_seen = fresh and content_ok
    ok(reload_seen,
        "T13: a message mutation reloads the reader with the new content")
    ok(body:find("<title>Book smoke renamed</title>", 1, true) ~= nil
        and body:find('<div class="book-title">Book smoke renamed</div>', 1, true) ~= nil,
        "T24c: Rename Chat refreshes the generated book title and cover")

    -- Malformed/stale disclosure URIs are consumed without changing state or
    -- scheduling a rebuild. The next block compares observable reader/file state.
    router_ui = ui
    router_body = body
    Session.handle_uri("kt:det:1")
    Session.handle_uri("kt:det:x:1")
    Session.handle_uri("kt:det:999:1")
    Session.handle_uri("kt:det:1:999")
    Session.handle_uri("kt:spl:1r:999")
    Session.handle_uri("kt:det:3:999") -- literal inside <code>, not a link
    Session.handle_uri("kt:spl:3r:999") -- literal inside <pre>, not a link
end)

-- T27: a refresh whose HTML is byte-identical to the file on disk must NOT
-- tear the reader down (the provider/preset switch case): the reader keeps
-- its position and its history. A real content change still reloads.
UIManager:scheduleIn(5.4, function()
    local ui = ReaderUI.instance
    if not ui then
        ok(false, "T27a: a no-op refresh does not reload the reader")
        ok(false, "T27b: a no-op refresh keeps the reading position")
        ok(false, "T27c: a real change still reloads the reader")
        return
    end
    local original_bytes = read_generated_book()
    local last_index = #app.state.messages
    local original_content = app.state.messages[last_index].content
    local reloads = 0
    local real_reload = ui.reloadDocument
    local real_schedule = UIManager.scheduleIn
    local pending = {}
    -- Run the refresh debounce (and its reschedules); the 15 s watchdog is
    -- left alone - it belongs to the reload path this block fakes.
    local function drain(limit)
        local ran = 0
        while ran < limit do
            local picked = nil
            for index = #pending, 1, -1 do
                if pending[index].delay <= 1.0 then
                    picked = pending[index]
                    table.remove(pending, index)
                    break
                end
            end
            if not picked then break end
            picked.callback()
            ran = ran + 1
        end
    end
    ui.reloadDocument = function(_, after_close, _, after_open)
        reloads = reloads + 1
        if after_close then after_close(ui.document.file) end
        if after_open then after_open() end
    end
    UIManager.scheduleIn = function(_, delay, callback)
        pending[#pending + 1] = { delay = delay, callback = callback }
    end
    -- (1) no-op refresh: the generated HTML is identical to the file.
    local page_before = current_page(ui)
    Session.on_chat_changed(chat_path, { kind = "mutation" })
    drain(5)
    local page_after = current_page(ui)
    ok(reloads == 0,
        "T27a: a no-op refresh does not reload the reader (reloads=" .. reloads .. ")")
    ok(page_after == page_before,
        "T27b: a no-op refresh keeps the reading position (page "
        .. tostring(page_before) .. " -> " .. tostring(page_after) .. ")")
    -- (2) a real change still reloads.
    app.state.messages[last_index].content = original_content .. " (edited)"
    Storage.update_message(chat_path, last_index, app.state.messages[last_index])
    Session.on_chat_changed(chat_path, { kind = "mutation" })
    drain(5)
    ok(reloads == 1,
        "T27c: a real change still reloads the reader (reloads=" .. reloads .. ")")
    -- Restore the fixture: the chat and the generated file go back to the
    -- bytes the later blocks expect.
    app.state.messages[last_index].content = original_content
    Storage.update_message(chat_path, last_index, app.state.messages[last_index])
    Book.save(Book.path_for(chat_path), original_bytes)
    UIManager.scheduleIn = real_schedule
    ui.reloadDocument = real_reload
end)

UIManager:scheduleIn(6.2, function()
    ok(ReaderUI.instance == router_ui and read_generated_book() == router_body
        and router_body:find("native hidden body", 1, true) == nil,
        "T25c: malformed and stale disclosure URIs leave the Book untouched")

    local ui = router_ui
    if ui then
        pcall(function()
            ui:handleEvent(Event:new("GotoXPointer", "#m1"))
        end)
    end
    UIManager:scheduleIn(0.3, function()
        details_tapped, details_page_before = tap_native_link(ui, "kt:det:1:1")
        ok(details_tapped, "T25d: a real native details link reaches the Book tap zone")
    end)
end)

UIManager:scheduleIn(7.4, function()
    details_ui = ReaderUI.instance
    local body = read_generated_book()
    ok(details_ui ~= nil and details_ui ~= router_ui
        and body:find("native hidden body", 1, true) ~= nil
        and body:find('href="kt:spl:1:1" class="ktspl">native secret</a>', 1, true) ~= nil
        and current_page(details_ui) == details_page_before,
        "T25e: details tap reloads revealed content at the same reading position")
    local injected_private_link = false
    for index, link in ipairs(details_ui and details_ui.document
        and details_ui.document:getPageLinks() or {}) do
        if link.uri == "kt:continue" then injected_private_link = true end
    end
    ok(not injected_private_link,
        "T25i: model HTML cannot inject a private action through a duplicate href")

    spoiler_tapped = tap_native_link(details_ui, "kt:spl:1:1")
    ok(spoiler_tapped, "T25f: a real native spoiler link reaches the Book tap zone")
end)

UIManager:scheduleIn(8.6, function()
    local body = read_generated_book()
    ok(ReaderUI.instance ~= nil and ReaderUI.instance ~= details_ui
        and body:find("native hidden body", 1, true) ~= nil
        and body:find('<span class="ktspl ktsplopen">native secret</span>', 1, true) ~= nil,
        "T25g: spoiler tap preserves the independently revealed details body")
    ok(emoji_registrations == 1,
        "T26c: disclosure reloads do not register the emoji font again")
    -- Positional URIs must not transfer this open state to the next message.
    app:move_message(1, 1)
end)

UIManager:scheduleIn(9.6, function()
    local body = read_generated_book()
    ok(body:find("native hidden body", 1, true) == nil
        and body:find("second hidden body", 1, true) == nil
        and body:find('<span class="ktspl ktsplopen">', 1, true) == nil,
        "T25j: moving messages invalidates reveals instead of transferring them")
    -- Reveal the new first message, then remove it through the same persisted
    -- mutation used by App:delete_message's confirmation callback.
    Session.handle_uri("kt:det:1:1")
end)

UIManager:scheduleIn(10.4, function()
    ok(read_generated_book():find("second hidden body", 1, true) ~= nil,
        "T25k-pre: the details target is revealed before deletion")
    table.remove(app.state.messages, 1)
    local chat_data = Storage.load_chat(chat_path)
    if chat_data then
        Storage.save_chat(chat_path, chat_data.header, app.state.messages)
    end
    app:_book_mutated({ kind = "mutation", anchor = "#m1" })
end)

UIManager:scheduleIn(11.2, function()
    local body = read_generated_book()
    ok(body:find("native hidden body", 1, true) == nil
        and body:find("second hidden body", 1, true) == nil
        and body:find('<span class="ktspl ktsplopen">', 1, true) == nil,
        "T25k: deleting a message cannot reveal the message shifted into its place")
    for index, msg in ipairs(app.state.messages) do
        if msg.role == "assistant" and not swipe_message_index then
            swipe_message_index = index
            msg.swipes = {
                "<details><summary>Swipe old</summary>old swipe hidden</details> ||old secret||",
                "<details><summary>Swipe native</summary>swipe hidden body</details> ||swipe secret||",
            }
            msg.swipe_id = 1
            msg.content = msg.swipes[1]
            Storage.update_message(chat_path, index, msg)
            Session.handle_uri("kt:det:" .. index .. ":1")
        end
    end
end)

UIManager:scheduleIn(12.0, function()
    ok(read_generated_book():find("old swipe hidden", 1, true) ~= nil,
        "T25l-pre: the old swipe details target is revealed before cycling")
    if swipe_message_index then app:cycle_swipe(swipe_message_index, 1) end
end)

UIManager:scheduleIn(12.8, function()
    local body = read_generated_book()
    ok(swipe_message_index ~= nil
        and body:find("Swipe native", 1, true) ~= nil
        and body:find("swipe hidden body", 1, true) == nil
        and body:find('href="kt:spl:' .. tostring(swipe_message_index)
            .. ':1" class="ktspl">swipe secret</a>', 1, true) ~= nil,
        "T25l: changing swipes does not carry reveals into different content")

    -- Control the scheduler: an old-document tap arrives after new content was
    -- queued but before its mutation reload can run. It must not replace the
    -- mutation with a disclosure or reveal the new item at the same position.
    local msg = swipe_message_index and app.state.messages[swipe_message_index]
    if msg then
        msg.content = "<details><summary>Race new</summary>race new hidden</details> ||race new secret||"
        msg.swipes[msg.swipe_id] = msg.content
        Storage.update_message(chat_path, swipe_message_index, msg)
        local pending = {}
        local real_schedule = UIManager.scheduleIn
        UIManager.scheduleIn = function(_, _, callback)
            pending[#pending + 1] = callback
        end
        Session.on_chat_changed(chat_path, { kind = "mutation", anchor = "#m" .. swipe_message_index })
        Session.handle_uri("kt:det:" .. swipe_message_index .. ":1")
        UIManager.scheduleIn = real_schedule
        ok(#pending == 1,
            "T25m: a stale tap during mutation debounce cannot replace the queued refresh")
        for index = 1, #pending do pending[index]() end
    else
        ok(false, "T25m: a stale tap during mutation debounce cannot replace the queued refresh")
    end
end)

UIManager:scheduleIn(13.6, function()
    local body = read_generated_book()
    ok(body:find("Race new", 1, true) ~= nil
        and body:find("race new hidden", 1, true) == nil
        and body:find('<span class="ktspl ktsplopen">race new secret</span>', 1, true) == nil,
        "T25n: a stale tap cannot reveal replacement content before the mutation reload")
end)

UIManager:scheduleIn(14.4, function()
    local ui = ReaderUI.instance
    local function check_watchdog_recovery(opts, uri, revealed_text, label)
        local pending = {}
        local real_schedule = UIManager.scheduleIn
        local real_reload = ui.reloadDocument
        local function take(delay)
            for index = #pending, 1, -1 do
                if pending[index].delay == delay then
                    local callback = pending[index].callback
                    table.remove(pending, index)
                    return callback
                end
            end
            return nil
        end

        -- The reload guard skips a refresh whose HTML is byte-identical to
        -- the file on disk, so this scenario (a reload that never calls
        -- back) needs a REAL content change to reach the reload path.
        local last_index = #app.state.messages
        app.state.messages[last_index].content =
            (app.state.messages[last_index].content or "") .. " (watchdog " .. label .. ")"
        Storage.update_message(chat_path, last_index, app.state.messages[last_index])

        UIManager.scheduleIn = function(_, delay, callback)
            pending[#pending + 1] = { delay = delay, callback = callback }
        end
        -- Simulate a reader reopen that never calls back. The reader remains
        -- usable, so the watchdog must recover the queued refresh itself.
        ui.reloadDocument = function() end
        Session.on_chat_changed(chat_path, opts)
        local initial = take(0.30)
        if initial then initial() end
        Session.on_chat_changed(chat_path, opts) -- queued behind the hung reload
        local watchdog = take(15)
        if watchdog then watchdog() end

        -- A later reopen succeeds at the real ReaderUI callback boundary.
        ui.reloadDocument = function(_, after_close, _, after_open)
            if after_close then after_close(ui.document.file) end
            if after_open then after_open() end
        end
        local recovery = take(0.25)
        ok(recovery ~= nil, label .. ": watchdog reschedules the queued refresh")
        if recovery then recovery() end

        Session.handle_uri(uri)
        local disclosure_refresh = take(0.30)
        if disclosure_refresh then disclosure_refresh() end
        UIManager.scheduleIn = real_schedule
        ui.reloadDocument = real_reload
        ok(read_generated_book():find(revealed_text, 1, true) ~= nil,
            label .. ": disclosures still work after watchdog recovery")
    end

    if ui and swipe_message_index then
        check_watchdog_recovery({ kind = "user" },
            "kt:det:" .. swipe_message_index .. ":1", "race new hidden", "T25o")
        check_watchdog_recovery({},
            "kt:spl:" .. swipe_message_index .. ":1",
            '<span class="ktspl ktsplopen">race new secret</span>', "T25p")
    else
        ok(false, "T25o: watchdog reschedules the queued refresh")
        ok(false, "T25o: disclosures still work after watchdog recovery")
        ok(false, "T25p: watchdog reschedules the queued refresh")
        ok(false, "T25p: disclosures still work after watchdog recovery")
    end
end)

UIManager:scheduleIn(15.4, function()
    -- T14 + T17: the Book -> List transition closes the reader and tears
    -- the session down (the display mode switch does it for us).
    app:set_chat_mode("list")
    UIManager:scheduleIn(0.4, function()
        ok(not Session.is_active() and app.state.book_active == nil,
            "T14: closing the reader tears the session down")
        ok(app.state.settings.chat_mode == "list",
            "T17: Book -> List closes the reader and stores the mode")
        -- T18: List -> Book opens the book again for the chat on screen.
        app:navigate("chat")
        app:set_chat_mode("book")
        UIManager:scheduleIn(1.8, function()
            local ui2 = ReaderUI.instance
            ok(ui2 ~= nil and ui2.document ~= nil
                and ui2.document.file == Book.path_for(chat_path),
                "T18: List -> Book opens the book for the chat on screen")
            local reopened_body = read_generated_book()
            ok(reopened_body:find("native hidden body", 1, true) == nil
                and reopened_body:find('href="kt:spl:1:1" class="ktspl">native secret</a>', 1, true) ~= nil,
                "T25h: a new Book session starts details and spoilers collapsed")
            ok(emoji_registrations == 1,
                "T26d: reopening a Book session does not register the emoji font again")
            cre.registerFont = original_register_font
            -- T19: leaving Debug Mode takes the experimental book mode with
            -- it (otherwise the switch would be stranded without a UI).
            app.state.settings.debug_mode = true
            app:set_chat_mode("book")
            app:disable_debug_mode()
            ok(app.state.settings.chat_mode == "list"
                and app.state.settings.debug_mode == false,
                "T19: disabling Debug Mode forces the display mode back to List")
            app:close_book_reader()
            UIManager:scheduleIn(0.4, function()
                -- T21e: choosing a quick reply sends its configured text via
                -- the real message pipeline; only the network generation is
                -- stubbed at its boundary.
                local _ = require("gettext")
                local Modals = require("ktui/modals")
                local quick_dialogs = {}
                local real_actions = Modals.actions
                Modals.actions = function(title, rows)
                    quick_dialogs[#quick_dialogs + 1] = { title = title, rows = rows }
                end
                local old_replies = app.state.settings.quick_replies
                local old_connection = app.state.current_connection
                local old_generate = app._do_generate
                local generated_messages = nil
                app.state.settings.quick_replies = {
                    { label = "Smoke reply", text = "Quick reply body" },
                }
                app.state.current_connection = {
                    id = "book-smoke", name = "Book smoke", model_id = "smoke",
                }
                app._do_generate = function(_, api_messages)
                    generated_messages = api_messages
                end
                BookUI.global_actions(app)
                local quick_row = find_row(quick_dialogs[1] and quick_dialogs[1].rows,
                    _("Quick Reply"))
                if quick_row then quick_row.callback() end
                local reply_row = find_row(quick_dialogs[2] and quick_dialogs[2].rows,
                    "Smoke reply")
                if reply_row then reply_row.callback() end
                Modals.actions = real_actions
                local last_message = app.state.messages[#app.state.messages]
                ok(last_message ~= nil and last_message.content == "Quick reply body"
                    and generated_messages ~= nil,
                    "T21e: Quick Reply sends its configured text")
                app.state.settings.quick_replies = old_replies
                app.state.current_connection = old_connection
                app._do_generate = old_generate

                -- T24a: all three multiline note editors must request newline
                -- support without accidentally passing true as clear_callback.
                local input_calls = {}
                local real_input = Modals.input
                Modals.input = function(title, input, hint, ok_text, callback,
                    clear_callback, multiline)
                    input_calls[#input_calls + 1] = {
                        title = title,
                        clear_callback = clear_callback,
                        multiline = multiline,
                    }
                end
                app:add_system_note()

                local Sheets = require("ktui/sheets")
                local real_sheet_show = Sheets.show
                local note_sheet = nil
                Sheets.show = function(_, spec) note_sheet = spec end
                app:show_authors_note()
                Sheets.show = real_sheet_show
                for index = 1, #((note_sheet and note_sheet.actions) or {}) do
                    local action = note_sheet.actions[index]
                    if action.label == _("Edit Note") then action.on_tap() end
                end

                local note_dialogs = {}
                local real_note_actions = Modals.actions
                Modals.actions = function(title, rows)
                    note_dialogs[#note_dialogs + 1] = rows
                end
                BookUI.authors_note(app)
                Modals.actions = real_note_actions
                local book_edit_row = find_row(note_dialogs[1], _("Edit Note"))
                if book_edit_row then book_edit_row.callback() end
                Modals.input = real_input

                local editors_multiline = #input_calls == 3
                for index = 1, #input_calls do
                    local call = input_calls[index]
                    if call.clear_callback ~= nil or call.multiline ~= true then
                        editors_multiline = false
                    end
                end
                ok(editors_multiline,
                    "T24a: note editors are multiline and have no boolean Clear callback")

                -- T23: after the book closes there may be neither a ReaderUI
                -- nor a FileManager instance. Every PathChooser entry point
                -- must still construct its real native widget.
                local FileManager = require("apps/filemanager/filemanager")
                local old_reader, old_file_manager = ReaderUI.instance, FileManager.instance
                ReaderUI.instance, FileManager.instance = nil, nil
                local shown = {}
                local real_show = UIManager.show
                UIManager.show = function(_, widget)
                    shown[#shown + 1] = widget
                end
                local import_ok, import_err = pcall(function()
                    app:choose_file_path(function() end, "/tmp")
                end)
                local export_ok, export_err = pcall(function()
                    app:choose_export_dir(function() end)
                end)
                local backup_ok, backup_err = pcall(function()
                    app:choose_import_file(function() end)
                end)
                UIManager.show = real_show
                ReaderUI.instance, FileManager.instance = old_reader, old_file_manager
                ok(import_ok and shown[1] ~= nil and shown[1].ui ~= nil
                    and shown[1].ui.folder_shortcuts ~= nil,
                    "T23a: file import chooser works without a host ReaderUI/FileManager")
                ok(export_ok and shown[2] ~= nil and shown[2].ui ~= nil
                    and shown[2].ui.folder_shortcuts ~= nil,
                    "T23b: export directory chooser works without a host ReaderUI/FileManager")
                ok(backup_ok and shown[3] ~= nil and shown[3].ui ~= nil
                    and shown[3].ui.folder_shortcuts ~= nil,
                    "T23c: backup import chooser works without a host ReaderUI/FileManager")
                if not import_ok then info("import chooser error: " .. tostring(import_err)) end
                if not export_ok then info("export chooser error: " .. tostring(export_err)) end
                if not backup_ok then info("backup chooser error: " .. tostring(backup_err)) end

                -- T24b: metadata sorting calls ui.bookinfo for every file after
                -- construction, not just during the original refreshPath().
                local fixture_dir = "/tmp/opencode/kotavern_book_smoke"
                os.execute("mkdir -p '" .. fixture_dir .. "'")
                local fixture_file = io.open(fixture_dir .. "/chooser.json", "w")
                if fixture_file then
                    fixture_file:write("{}")
                    fixture_file:close()
                end
                local old_collate = G_reader_settings:readSetting("collate", "strcoll")
                G_reader_settings:saveSetting("collate", "title")
                local metadata_ok, metadata_err = pcall(function()
                    shown[1]:changeToPath(fixture_dir)
                end)
                G_reader_settings:saveSetting("collate", old_collate)
                local fixture_found = false
                for index = 1, #((shown[1] and shown[1].item_table) or {}) do
                    if shown[1].item_table[index].path == fixture_dir .. "/chooser.json" then
                        fixture_found = true
                    end
                end
                ok(metadata_ok and shown[1].ui.bookinfo ~= nil and fixture_found,
                    "T24b: hostless chooser lists files with metadata sorting")
                if not metadata_ok then
                    info("metadata chooser error: " .. tostring(metadata_err))
                end
                os.remove(fixture_dir .. "/chooser.json")
                os.remove(fixture_dir)

                print(string.format("\n%d checks, %d failures", checks, fails))
                UIManager:quit()
                os.exit(fails == 0 and 0 or 1)
            end)
        end)
    end)
end)

UIManager:run()
