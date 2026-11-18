-- Book mode repro harness (dev tool, not part of the smoke gate).
-- Boots the REAL KOReader runtime (fonts, cre, SDL), shows the plugin canvas,
-- opens a chat in book mode through the real App:open_book path, and dumps
-- ASCII art of the framebuffer + the widget stack at several points, so the
-- reader-integration behavior can be inspected without eyes on a screen.
--
--   mkdir -p /tmp/opencode/kohome/settings/kotavern/{chats,characters,books}
--   cp -r ~/.config/koreader/settings/kotavern/{chats,characters,connections.json,settings.json} \
--       /tmp/opencode/kohome/settings/kotavern/
--   cd /usr/lib/koreader && KO_HOME=/tmp/opencode/kohome SDL_VIDEODRIVER=dummy \
--       ./luajit /path/to/kotavern.koplugin/tools/book_repro.lua 2>&1 | tee /tmp/opencode/book_repro.log
--
-- Dumps also land in /tmp/opencode/book_repro_dumps.txt

require("setupkoenv")

local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/")
local PLUGIN = here .. "/.."
package.path = PLUGIN .. "/?.lua;" .. PLUGIN .. "/?/init.lua;" .. package.path

local dumpfile = io.open("/tmp/opencode/book_repro_dumps.txt", "w")
local function dump_out(s)
    io.stderr:write(s .. "\n")
    if dumpfile then dumpfile:write(s .. "\n") dumpfile:flush() end
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
local Bidi = require("ui/bidi")
Bidi.setup(lang_locale)

local UIManager = require("ui/uimanager")
local Screen = Device.screen
if os.getenv("REPRO_DEBUG") then
    require("dbg"):turnOn()
end

-- gray 0..255 for any pixel color (4-bit gray or RGB32)
local function pixel_gray(c)
    local okv, va = pcall(function() return tonumber(c.a) end)
    if okv and va then
        if va <= 15 then return va * 17 end -- 4-bit gray scale
        return va
    end
    local okr, r = pcall(function() return tonumber(c.r) end)
    if okr and r then
        local _, g = pcall(function() return tonumber(c.g) end)
        local _, b = pcall(function() return tonumber(c.b) end)
        return ((r or 0) + (g or 0) + (b or 0)) / 3
    end
    return 255
end

-- ASCII framebuffer dump: max-pool (darkest pixel wins per cell) so 2px text
-- strokes survive the downsampling.
local function ascii_screen(tag)
    local bb = Screen.bb
    if not bb then dump_out("[ascii " .. tag .. "] no bb") return end
    local W, H = bb:getWidth(), bb:getHeight()
    local cols, rows = 78, 44
    local out = {}
    for ry = 0, rows - 1 do
        local line = {}
        local y0 = math.floor(ry * H / rows)
        local y1 = math.max(y0 + 1, math.floor((ry + 1) * H / rows))
        for rx = 0, cols - 1 do
            local x0 = math.floor(rx * W / cols)
            local x1 = math.max(x0 + 1, math.floor((rx + 1) * W / cols))
            local dark = 255
            for y = y0, math.min(y1 - 1, H - 1) do
                for x = x0, math.min(x1 - 1, W - 1) do
                    local g = pixel_gray(bb:getPixel(x, y))
                    if g < dark then dark = g end
                end
            end
            local ch = (dark < 64 and "#") or (dark < 140 and "+") or (dark < 215 and ".") or " "
            line[#line + 1] = ch
        end
        out[#out + 1] = table.concat(line)
    end
    dump_out("=== SCREEN[" .. tag .. "] " .. W .. "x" .. H .. " ===\n"
        .. table.concat(out, "\n"))
end

local function describe_widget(widget)
    local bits = {}
    if widget.dimen then
        bits[#bits + 1] = string.format("dimen=%dx%d@%d,%d", widget.dimen.w,
            widget.dimen.h, widget.dimen.x or 0, widget.dimen.y or 0)
    end
    if widget.text then bits[#bits + 1] = "text=" .. tostring(widget.text):sub(1, 60) end
    if widget.title then bits[#bits + 1] = "title=" .. tostring(widget.title) end
    if widget.buttons then bits[#bits + 1] = "buttons=#" .. tostring(#widget.buttons) end
    if widget.modal ~= nil then bits[#bits + 1] = "modal=" .. tostring(widget.modal) end
    if widget.invisible ~= nil then bits[#bits + 1] = "invisible=" .. tostring(widget.invisible) end
    if widget.timeout ~= nil then bits[#bits + 1] = "timeout=" .. tostring(widget.timeout) end
    return table.concat(bits, " ")
end

local function stack_dump(tag)
    local lines = { "=== STACK[" .. tag .. "] ===" }
    local ReaderUI = require("apps/reader/readerui")
    lines[#lines + 1] = "ReaderUI.instance: " .. tostring(ReaderUI.instance ~= nil)
    for i, w in ipairs(UIManager._window_stack) do
        local widget = w.widget
        local name = widget.name or widget.id or tostring(widget):match("0x%x+")
        lines[#lines + 1] = string.format("  [%d] %s fs=%s %s",
            i, tostring(name), tostring(widget.covers_fullscreen), describe_widget(widget))
        if widget == ReaderUI.instance and widget.document then
            lines[#lines + 1] = "      doc=" .. tostring(widget.document.file)
            if widget.rolling then
                local pages = "?"
                if widget.document.getPageCount then
                    pages = tostring(widget.document:getPageCount())
                end
                lines[#lines + 1] = string.format("      rolling page=%s/%s pos=%s",
                    tostring(widget.rolling.current_page), pages,
                    tostring(widget.rolling.current_pos))
            end
        end
        if type(widget[1]) == "table" then
            local names = {}
            for j, c in ipairs(widget) do
                local n = tostring(c.name or c.id or type(c))
                if c.onEndOfBook then n = n .. "(EOB)" end
                if c.onCloseWidget then n = n .. "(CW)" end
                names[#names + 1] = j .. ":" .. n
            end
            lines[#lines + 1] = "      children: " .. table.concat(names, " ")
        end
    end
    dump_out(table.concat(lines, "\n"))
end

-- fast screen fingerprint (samples a sparse grid, sums gray)
local function screen_hash()
    local bb = Screen.bb
    if not bb then return -1 end
    local W, H = bb:getWidth(), bb:getHeight()
    local sum = 0
    for y = 0, H - 1, 11 do
        for x = 0, W - 1, 7 do
            sum = sum + math.floor(pixel_gray(bb:getPixel(x, y)))
        end
    end
    return sum
end

local function dump(tag)
    stack_dump(tag)
    dump_out("hash[" .. tag .. "]=" .. tostring(screen_hash()))
end

-- Data setup --------------------------------------------------------------------
local Storage = require("kt_storage")
local lfs = require("libs/libkoreader-lfs")
local chat_path = nil
local function scan_chats(dir)
    if chat_path then return end
    for f in lfs.dir(dir) do
        if f:sub(1, 1) ~= "." then
            local p = dir .. "/" .. f
            local mode = lfs.attributes(p, "mode")
            if mode == "file" and f:match("%.jsonl$") then
                chat_path = p
                return
            elseif mode == "directory" then
                scan_chats(p)
            end
        end
    end
end
local chats_dir = Storage.data_dir() .. "/chats"
scan_chats(chats_dir)
dump_out("chat_path=" .. tostring(chat_path))
if not chat_path then
    dump_out("NO CHAT FOUND - aborting")
    os.exit(1)
end

-- Control mode: no plugin app at all - just showReader on the book file.
-- If THIS paints the book, our open_book path is what breaks the screen.
local CONTROL = os.getenv("REPRO_CONTROL") == "1"

local App = require("kt_app")
local app = nil
if not CONTROL then
    app = App:new(nil)
    app.state.settings.chat_mode = "book"
    app:show()
    dump_out("--- calling open_book ---")
    app:open_book(chat_path)
else
    dump_out("--- CONTROL: generate book + direct ReaderUI:showReader ---")
    local Book = require("kt_book")
    local ok, path = pcall(Book.write, chat_path, {
        look = nil,
        character_name = "Marinara Rigate",
        persona_name = nil,
    })
    dump_out("book write ok=" .. tostring(ok) .. " path=" .. tostring(path))
    local Event0 = require("ui/event")
    local UIManager0 = require("ui/uimanager")
    UIManager0:broadcastEvent(Event0:new("SetupShowReader"))
    require("apps/reader/readerui"):showReader(path)
end

local Event = require("ui/event")
local ReaderUI = require("apps/reader/readerui")

-- Probe timeline
UIManager:scheduleIn(1.0, function() dump("t1.0-after-open") end)
UIManager:scheduleIn(1.5, function()
    dump_out("--- DIRECT paintTo on ReaderUI (bypassing UIManager) ---")
    local ui = ReaderUI.instance
    if ui then
        ui:paintTo(Screen.bb, 0, 0)
        dump_out("hash after direct paintTo=" .. tostring(screen_hash()))
        ascii_screen("direct-paint")
    else
        dump_out("no ReaderUI.instance at t1.5")
    end
end)
UIManager:scheduleIn(2.2, function()
    dump_out("--- setDirty(full)+forceRePaint via UIManager ---")
    local ui = ReaderUI.instance
    if ui then
        UIManager:setDirty(ui, "full")
        UIManager:forceRePaint()
    end
    dump_out("hash after forceRePaint=" .. tostring(screen_hash()))
    ascii_screen("force-repaint")
end)
UIManager:scheduleIn(1.7, function()
    dump_out("--- direct sheet show + forceRePaint ---")
    local BookActions = require("kt_book_actions")
    BookActions.show_sheet(app)
    UIManager:forceRePaint()
    ascii_screen("sheet-direct")
    -- If the repaint path skipped it, paint the sheet straight into the bb.
    local top = UIManager._window_stack[#UIManager._window_stack]
    if top and top.widget and top.widget.name == "kotavern_booksheet" then
        top.widget:paintTo(Screen.bb, 0, 0)
        ascii_screen("sheet-directpaint")
    else
        dump_out("no booksheet on top at t1.7")
    end
end)
UIManager:scheduleIn(2.6, function()
    -- Leave the sheet open briefly, then dismiss it through its Cancel hit
    -- rect (bottom of the panel) to also exercise the tap dispatch.
    local top = UIManager._window_stack[#UIManager._window_stack]
    if top and top.widget and top.widget.name == "kotavern_booksheet" then
        local hits = top.widget._hits
        dump_out("sheet hits registered: " .. tostring(hits and #hits or 0))
        if hits and #hits > 0 then
            hits[#hits].cb() -- last registered = Cancel
        end
    end
    dump("t2.6-sheet-dismissed")
end)
UIManager:scheduleIn(3.0, function()
    dump_out("--- forward page turn #1 ---")
    local ui = ReaderUI.instance
    if ui then ui:handleEvent(Event:new("GotoViewRel", 1))
    else dump_out("no ReaderUI.instance at t3") end
end)
UIManager:scheduleIn(3.6, function()
    dump_out("--- forward page turn #2 (should hit end -> EndOfBook) ---")
    local ui = ReaderUI.instance
    if ui then ui:handleEvent(Event:new("GotoViewRel", 1))
    else dump_out("no ReaderUI.instance at t3.6") end
end)
UIManager:scheduleIn(4.8, function() dump("t4.8-after-turns") end)
UIManager:scheduleIn(4.9, function() ascii_screen("colophon-sheet") end)
UIManager:scheduleIn(5.1, function()
    dump_out("--- dismiss sheet; simulated swipe north (interposed) ---")
    local top = UIManager._window_stack[#UIManager._window_stack]
    if top and top.widget and top.widget.name == "kotavern_booksheet" then
        UIManager:close(top.widget)
    else
        dump_out("no painted sheet on top (expected in the new flow)")
    end
    local Geom = require("ui/geometry")
    local ui = ReaderUI.instance
    if ui then
        ui:handleEvent(Event:new("Gesture", {
            ges = "swipe", direction = "north", distance = 200,
            pos = Geom:new{ x = 300, y = 400, w = 0, h = 0 },
        }))
        dump_out("swipe north dispatched")
    end
end)
UIManager:scheduleIn(5.4, function() dump("t5.4-after-swipe") end)
UIManager:scheduleIn(5.5, function()
    dump_out("--- double_tap while sheet open (modal leak regression) ---")
    local top = UIManager._window_stack[#UIManager._window_stack]
    local sheet_open = top and top.widget and top.widget.name == "kotavern_booksheet"
    local Geom = require("ui/geometry")
    local Event = require("ui/event")
    local ui = ReaderUI.instance
    local page_before = ui and ui.view and ui.view.state
        and tostring(ui.view.state.page)
    if sheet_open then
        -- sendEvent is what the device really does: if the sheet does not
        -- consume the gesture, it walks DOWN the window stack into the
        -- reader (pre-stop_events_propagation bug).
        UIManager:sendEvent(Event:new("Gesture", {
            ges = "double_tap",
            pos = Geom:new{ x = 300, y = 300, w = 0, h = 0 },
        }))
        local top2 = UIManager._window_stack[#UIManager._window_stack]
        local still_sheet = top2 and top2.widget
            and top2.widget.name == "kotavern_booksheet"
        local page_after = ui and ui.view and ui.view.state
            and tostring(ui.view.state.page)
        if still_sheet then
            dump_out("OK: sheet still on top after double_tap (page "
                .. tostring(page_before) .. " -> " .. tostring(page_after) .. ")")
        else
            dump_out("FAIL: sheet lost after double_tap (top="
                .. tostring(top2 and top2.widget and top2.widget.name) .. ")")
        end
    else
        dump_out("SKIP: sheet not on top at t5.5")
    end
end)
UIManager:scheduleIn(5.6, function()
    dump_out("--- close sheet; open in-book composer ---")
    local top = UIManager._window_stack[#UIManager._window_stack]
    if top and top.widget and top.widget.name == "kotavern_booksheet" then
        UIManager:close(top.widget)
    end
    local BookActions = require("kt_book_actions")
    BookActions.compose_in_book(app)
end)
UIManager:scheduleIn(6.0, function() dump("t6.0-composer") end)
UIManager:scheduleIn(6.2, function()
    dump_out("--- close composer; user message + landing hook ---")
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
        if w.name ~= "kotavern_booksheet" and w ~= ReaderUI.instance then
            UIManager:close(w)
            break
        end
    end
    Storage.append_message(chat_path, "user", "mensagem de teste do repro", nil, "User")
    app:_book_generation_landed(chat_path)
end)
UIManager:scheduleIn(7.4, function()
    dump_out("--- after live reload (debounce 0.5s -> refresh_open_book) ---")
    dump("t7.4-after-reload")
end)
UIManager:scheduleIn(8.2, function()
    dump_out("--- closing reader via app:close_book_reader ---")
    app:close_book_reader()
end)
UIManager:scheduleIn(9.4, function() dump("t9.4-after-close") end)
UIManager:scheduleIn(10.4, function()
    dump_out("--- quitting ---")
    UIManager:quit()
end)

UIManager:run()
dump_out("=== REPRO DONE ===")
if dumpfile then dumpfile:close() end
