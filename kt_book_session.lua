-- KtBookSession: the state machine behind "book mode".
--
-- A book mode session is ONE chat rendered as an HTML document and opened in
-- KOReader's native reader. The session owns everything that is temporary:
-- which chat is open, which ReaderUI is showing it, whether a reload is in
-- flight, and what to do when the reply lands.
--
-- The app (kt_app) only calls this module. The ReaderUI integration lives in
-- kt_book_reader; the native dialogs and the streaming HUD live in
-- kt_book_ui. This module never requires ReaderUI at load time so the app can
-- run without a reader.
--
-- Refresh policy (see PLAN / kt_book_reader):
--   kind = "user"     the user sent a message: reload, follow the tail
--   kind = "done"     a generation finished: reload, follow the tail when the
--                     user was already on the last page
--   kind = "mutation" edit/delete/swipe: clear reveals, restore message anchor
--   kind = "disclosure" a reveal toggle: preserve maps, restore message anchor
--   default           reload, restore the exact xpointer
-- Reloads are debounced (300 ms) so chained landings coalesce, and deferred
-- while a native dialog sits above the reader.

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local _ = require("gettext")

local Book = require("kt_book")
local BookTheme = require("kt_book_theme")
local Storage = require("kt_storage")

local Session = {}

-- All session state lives in one table so teardown can reset it in one go.
local state = {
    active = false,
    app = nil,
    chat_path = nil,
    book_path = nil,
    meta = nil,
    ui = nil,             -- ReaderUI currently bound to the book
    pending = nil,        -- first attach is still pending
    reloading = false,
    reload_token = 0,
    first_open = false,
    queued = nil,         -- opts of the refresh waiting to run
    refresh_token = 0,
    generation = false,
    stream_text = "",
    stream_status = nil,
    write_error = nil,
    return_to_list = false,
    revealed_spoilers = nil, -- qualified identity -> true; session-only
    revealed_details = nil,
}

local function clear_reveals()
    state.revealed_spoilers = {}
    state.revealed_details = {}
end

local function app_state()
    local app = state.app
    return app and app.state or nil
end

local function toast(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 3 })
end

-- === Data collection ===

-- The current look of the book (the theme owns every knob, including the
-- reasoning flag). The app settings are the only source.
function Session.theme()
    local st = app_state()
    return BookTheme.from_settings(st and st.settings or {})
end

-- Header metadata, mtime-cached by kt_storage (cheap enough for every build).
local function read_meta(chat_path)
    local header = Storage.chat_header(chat_path)
    local meta = header and header.chat_metadata or {}
    if type(meta) ~= "table" then meta = {} end
    return {
        chat_name = meta.chat_name,
        created_at = meta.created_at,
    }
end

-- Messages come from the LIVE app state when it holds this chat: it is the
-- only place a just-sent message or a mid-stream reply exists. Falling back
-- to disk keeps a book opened after an app restart readable.
local function collect()
    local app = state.app
    local st = app_state()
    local messages
    local character_name
    local persona_name
    if st and st.current_chat_path == state.chat_path then
        messages = st.messages
        character_name = st.current_character
        if app and app._active_persona_name then
            local ok, name = pcall(app._active_persona_name, app)
            if ok then persona_name = name end
        end
    end
    if type(messages) ~= "table" then
        local chat = Storage.load_chat(state.chat_path)
        messages = chat and chat.messages or {}
        local header = chat and chat.header and chat.header.chat_metadata or {}
        character_name = character_name or header.character_name
    end
    -- Rename Chat can change the header without reopening the session. Read it
    -- for every build so immediate and generation-deferred reloads both see it.
    local meta = read_meta(state.chat_path)
    state.meta = meta
    local theme = Session.theme()
    return {
        messages = messages,
        chat_name = meta.chat_name or character_name,
        character_name = character_name,
        persona_name = persona_name,
        created_at = meta.created_at,
        theme = theme,
        labels = theme.labels,
        show_reasoning = theme.show_reasoning,
        revealed_spoilers = state.revealed_spoilers,
        revealed_details = state.revealed_details,
    }
end

-- === Reader helpers ===

-- The reader module is required lazily: kt_book_reader hooks ReadHistory at
-- load time and must not be pulled in by a plain canvas boot.
local function reader()
    return require("kt_book_reader")
end

local function book_ui()
    return require("kt_book_ui")
end

local function current_page(ui)
    local page
    if ui.rolling and ui.rolling.current_page then
        page = ui.rolling.current_page
    elseif ui.document and ui.document.getCurrentPage then
        page = ui.document:getCurrentPage()
    end
    return tonumber(page) or 1
end

local function page_count(ui)
    local ok, pages = pcall(function()
        return ui.document and ui.document:getPageCount()
    end)
    pages = ok and tonumber(pages) or nil
    return pages or 1
end

-- True when no non-toast widget sits above the reader (a dialog is open).
local function reader_is_top(ui)
    local stack = UIManager._window_stack
    if not stack then return true end
    for i = #stack, 1, -1 do
        local widget = stack[i] and stack[i].widget
        if widget and not widget.toast then
            return widget == ui
        end
    end
    return true
end

-- === Refresh ===

local do_refresh

local function schedule_refresh(opts, delay, attempt)
    state.queued = opts
    local token = (state.refresh_token or 0) + 1
    state.refresh_token = token
    UIManager:scheduleIn(delay or 0.30, function()
        if state.refresh_token ~= token then return end
        if not state.active then return end
        -- A native dialog above the reader is usually a message action or the
        -- composer. Reloading under it is safe but jarring; wait it out.
        if state.ui and not reader_is_top(state.ui) and (attempt or 0) < 20 then
            schedule_refresh(state.queued or {}, 0.5, (attempt or 0) + 1)
            return
        end
        local queue = state.queued
        state.queued = nil
        do_refresh(queue or {})
    end)
end

-- Where should the freshly reloaded reader land?
--   cover   the book has no messages (the only page-1 jump)
--   anchor  the refresh named a message section (#mN)
--   tail    follow the end of the book
--   old_xp  the exact xpointer the reader had before the reload
--   keep    nothing valid: leave the reader where it is (never the cover)
local function choose_position(pos, has_messages)
    pos = pos or {}
    if not has_messages then return "cover" end
    if pos.anchor and pos.anchor ~= "" then return "anchor" end
    if pos.tail then return "tail" end
    if pos.old_xp and pos.old_xp ~= "" then return "old_xp" end
    return "keep"
end

local function finish_reload(pos)
    local ui = state.ui
    state.reloading = false
    state.reload_kind = nil
    state.reload_token = (state.reload_token or 0) + 1

    -- The reader that came back must be OUR book: if the plugin failed to
    -- attach (or the user navigated elsewhere), do not drive it.
    if not ui or not ui.document
        or (ui.document.file and state.book_path and ui.document.file ~= state.book_path) then
        -- The reader never came back. Do not leave the app stuck thinking a
        -- book is open: tear down and tell the user.
        logger.warn("kotavern/book: reload produced no reader")
        Session.teardown()
        toast(_("Could not update the book."))
        return
    end

    if state.write_error then
        toast(_("Could not update the book."), 4)
        state.write_error = nil
    end

    local Event = require("ui/event")
    local doc = ui.document
    local data = collect()
    local follow_tail = pos.tail

    local done = false
    -- NOTE: 'goto' is a reserved word in LuaJIT 2.1 (the Lua 5.2 syntax), and
    -- the CI runner's luajit build rejects it as an identifier even though the
    -- device runtime accepts it. Name it navigate to keep every LuaJIT
    -- version's parser happy.
    local function navigate(handler, arg)
        if done then return end
        done = true
        pcall(function()
            ui:handleEvent(Event:new(handler, arg))
        end)
    end

    local choice = choose_position(pos, #(data.messages or {}) > 0)
    if choice == "cover" then
        navigate("GotoPage", 1)
    elseif choice == "anchor" then
        local ok, in_doc = pcall(function() return doc:isXPointerInDocument(pos.anchor) end)
        if ok and in_doc then
            navigate("GotoXPointer", pos.anchor)
        else
            -- The anchor is gone (the message was deleted): fall back to the
            -- tail, then to the previous position - never to the cover.
            if follow_tail then
                navigate("GotoPage", page_count(ui))
            elseif pos.old_xp and pos.old_xp ~= "" then
                local ok2, in_doc2 = pcall(function()
                    return doc:isXPointerInDocument(pos.old_xp)
                end)
                if ok2 and in_doc2 then
                    navigate("GotoXPointer", pos.old_xp)
                end
            end
        end
    elseif choice == "tail" then
        navigate("GotoPage", page_count(ui))
    elseif choice == "old_xp" then
        local ok, in_doc = pcall(function() return doc:isXPointerInDocument(pos.old_xp) end)
        if ok and in_doc then
            navigate("GotoXPointer", pos.old_xp)
        end
    end
    -- choice == "keep": the reader keeps the position it restored.

    -- The old reader widget (and with it the HUD) was closed by the reload.
    if state.generation then
        book_ui().hud_show(ui, state.stream_status, state.stream_text)
    end

    UIManager:setDirty(ui, "ui")

    if state.queued then
        schedule_refresh(state.queued, 0.25)
    end
end

do_refresh = function(opts)
    opts = opts or {}
    local ui = state.ui
    if not state.active or not ui or not ui.document or state.reloading then
        if state.active and (state.reloading or not ui) then
            state.queued = opts
        end
        return
    end

    local data = collect()
    local html = Book.build(data)
    if type(html) ~= "string" or html == "" then
        toast(_("Could not update the book."))
        return
    end

    -- A change that does not touch the book (provider, preset, a settings
    -- toggle) must not tear the reader down: compare the freshly built HTML
    -- with the bytes on disk and keep the reader where it is.
    local current = Book.read(state.book_path)
    local current_sig = ""
    if current then
        current_sig = current:match('name="kotavern%-book%-theme" content="([^"]*)"') or ""
    end
    local new_sig = BookTheme.sig(data.theme)
    if current and current == html and current_sig == new_sig then
        return
    end

    local old_xp = ""
    pcall(function() old_xp = ui.document:getXPointer() or "" end)
    local cache_file
    pcall(function() cache_file = ui.document:getCacheFilePath() end)

    -- Follow the tail when the user was already at the bottom - unless the
    -- caller says otherwise (mutation anchors preserve the spot).
    local tail = opts.tail
    if tail == nil then
        tail = current_page(ui) >= page_count(ui)
    end

    state.reloading = true
    state.reload_kind = opts.kind or ""
    local token = (state.reload_token or 0) + 1
    state.reload_token = token
    pcall(function() book_ui().hud_hide() end)

    local ok, err = pcall(function()
        reader().ensure_emoji_font()
        ui:reloadDocument(function(file)
            if cache_file and cache_file ~= "" then
                os.remove(cache_file)
            end
            local saved, save_err = Book.save(state.book_path, html)
            if not saved then
                state.write_error = save_err or "write failed"
            end
            -- The reader's per-document settings are rewritten in the reload
            -- window: the old reader has closed (and flushed its position),
            -- so the sidecar keeps the reading position and gains the new
            -- typography before the reader opens again.
            pcall(function()
                BookTheme.apply_reader_settings(state.book_path, data.theme)
            end)
            -- Keep the reader's own copy in sync in case anything reads it
            -- before the reopen (the path is stable, the bytes are new).
            if file and file ~= state.book_path then
                pcall(Book.save, file, html)
            end
        end, true, function()
            finish_reload({
                old_xp = old_xp,
                anchor = opts.anchor,
                tail = tail,
            })
        end)
    end)

    if not ok then
        state.reloading = false
        logger.warn("kotavern/book: reload failed:", tostring(err))
        toast(_("Could not update the book."))
        return
    end

    -- Watchdog: a failed reopen would otherwise pin reloading forever.
    UIManager:scheduleIn(15, function()
        if state.reload_token == token and state.reloading and state.active then
            state.reloading = false
            state.reload_kind = nil
            local ReaderUI = require("apps/reader/readerui")
            if not ReaderUI.instance or not state.ui or not state.ui.document then
                Session.teardown()
            elseif state.queued then
                -- Match finish_reload: a usable reader must not retain a
                -- non-disclosure refresh forever after a missing callback.
                schedule_refresh(state.queued, 0.25)
            end
        end
    end)
end

-- === Public API ===

function Session.is_active()
    return state.active == true
end

function Session.ui()
    return state.ui
end

function Session.app()
    return state.app
end

function Session.chat_path()
    return state.chat_path
end

-- Options of the refresh waiting to run (diagnostics and tests).
function Session.queued_opts()
    return state.queued
end

-- TEST-ONLY hook (book_smoke): the position decision, without a reader.
function Session._test_choose_position(pos, has_messages)
    return choose_position(pos, has_messages)
end

function Session.open(app, chat_path)
    if type(chat_path) ~= "string" or chat_path == "" then
        return nil, "no chat path"
    end
    -- A session cannot own two readers: close the current one first (it
    -- stays on the widget stack otherwise and the new book would open on
    -- top of a stale one).
    if state.active then
        Session.close()
        if state.active then
            Session.teardown()
        end
    end

    local meta = read_meta(chat_path)
    local st = app and app.state or nil
    local messages
    if st and st.current_chat_path == chat_path then
        messages = st.messages
    end
    if type(messages) ~= "table" then
        local chat = Storage.load_chat(chat_path)
        messages = chat and chat.messages or {}
    end

    local persona_name
    if app and app._active_persona_name then
        local ok_name, name = pcall(app._active_persona_name, app)
        if ok_name then persona_name = name end
    end

    clear_reveals()
    local theme = Session.theme()
    local data = {
        messages = messages,
        chat_name = meta.chat_name,
        character_name = st and st.current_character,
        persona_name = persona_name,
        created_at = meta.created_at,
        theme = theme,
        labels = theme.labels,
        show_reasoning = theme.show_reasoning,
        revealed_spoilers = state.revealed_spoilers,
        revealed_details = state.revealed_details,
    }

    local html = Book.build(data)
    local book_path, err = Book.write(chat_path, html)
    if not book_path then
        return nil, err or "write failed"
    end

    -- The reader's per-document settings (font, size, margins) travel with
    -- the generated book: they are written BEFORE the reader opens, so the
    -- first paint already uses them. A failure is not fatal: the book opens
    -- with the reader's own defaults.
    pcall(function()
        BookTheme.apply_reader_settings(book_path, theme)
    end)

    -- First open: jump to the last page once the reader is ready. Later
    -- opens keep whatever position the sidecar restored.
    local first_open = false
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_ds and DocSettings then
        local ok_open, ds = pcall(function() return DocSettings:open(book_path) end)
        if ok_open and ds then
            first_open = ds:readSetting("last_xpointer") == nil
        end
    end

    state.active = true
    state.app = app
    state.chat_path = chat_path
    state.book_path = book_path
    state.meta = meta
    state.ui = nil
    state.pending = { app = app, chat_path = chat_path, book_path = book_path }
    state.reloading = false
    state.first_open = first_open
    state.queued = nil
    state.write_error = nil
    state.return_to_list = false
    state.stream_text = ""
    state.stream_status = nil
    -- Invalidate any refresh/reload left pending by the PREVIOUS session:
    -- it would otherwise rebuild this new book with the old chat's data.
    state.refresh_token = (state.refresh_token or 0) + 1
    state.reload_token = (state.reload_token or 0) + 1

    reader().ensure_emoji_font()
    local ok_open, open_err = pcall(reader().open, book_path)
    if not ok_open then
        state.active = false
        state.pending = nil
        state.revealed_spoilers = nil
        state.revealed_details = nil
        return nil, open_err or "reader open failed"
    end
    return book_path
end

function Session.attach(ui)
    if not state.active or not ui or not ui.document then
        return false
    end
    local file = ui.document.file
    if not file then
        return false
    end

    if state.reloading then
        -- Reload: the new ReaderUI is being created for our book. Bind it so
        -- finish_reload can restore the position on it.
        if file == state.book_path then
            state.ui = ui
            return true
        end
        return false
    end

    local pending = state.pending
    if not pending then
        -- Book opened by the file manager (app not involved, or after a
        -- restart): keep it readable, but no chrome/actions.
        return false
    end
    if pending.book_path ~= file then
        return false
    end

    state.app = pending.app
    state.ui = ui
    state.pending = nil
    return true
end

-- Position the freshly opened reader: first open jumps to the last page,
-- an empty chat stays on the cover, later opens keep the sidecar position.
function Session.apply_initial_position(ui)
    if not state.active or state.reloading or not ui or not ui.document then
        return
    end
    local Event = require("ui/event")
    local data = collect()
    if #(data.messages or {}) == 0 then
        pcall(function()
            ui:handleEvent(Event:new("GotoPage", 1))
        end)
    elseif state.first_open then
        pcall(function()
            ui:handleEvent(Event:new("GotoPage", page_count(ui)))
        end)
    end
    state.first_open = false
end

function Session.on_chat_changed(chat_path, opts)
    if not state.active then return end
    if chat_path and chat_path ~= state.chat_path then return end
    opts = opts or {}

    -- A generation in flight owns the tail; except a user message, which must
    -- show up immediately (the HUD covers the reply).
    if opts.kind ~= "user" then
        local st = app_state()
        if st and st.is_generating then return end
    end

    -- Reveal URIs are positional. Content/structure mutations invalidate them
    -- so a different message can never inherit a disclosure after a shift.
    if opts.kind == "mutation" then clear_reveals() end
    schedule_refresh(opts)
end

function Session.on_generation_start(app)
    if not state.active then return end
    if app then state.app = app end
    state.generation = true
    state.stream_text = ""
    state.stream_status = "thinking"
    local ui = state.ui
    if ui then
        book_ui().hud_show(ui, "thinking", "")
    end
end

function Session.on_stream_tick(text, status)
    if not state.active or not state.generation then return end
    state.stream_text = text or ""
    state.stream_status = status or (state.stream_text ~= "" and "generating" or "thinking")
    local ui = state.ui
    if ui then
        book_ui().hud_update(ui, state.stream_status, state.stream_text)
    end
end

function Session.on_generation_end()
    if not state.active then return end
    local was = state.generation
    state.generation = false
    state.stream_text = ""
    state.stream_status = nil
    pcall(function() book_ui().hud_hide() end)
    if was then
        -- Generation/continue/regenerate may replace the active swipe's markup.
        clear_reveals()
        -- The reply is the last message: the anchor points at it, so the
        -- reader lands on the new answer instead of the cover.
        local data = collect()
        local count = #(data.messages or {})
        local anchor = count > 0 and ("#m" .. tostring(count)) or nil
        schedule_refresh({ kind = "done", anchor = anchor }, 0.35)
    end
end

function Session.on_close_widget(ui)
    -- The reload closes the old ReaderUI internally: that is not the user
    -- leaving the book.
    if state.reloading then return end
    if ui and state.ui and ui ~= state.ui then return end
    Session.teardown(ui)
end

function Session.on_end_of_book()
    if not state.active then return false end
    local app = state.app
    if not app then return false end
    book_ui().end_of_book(app)
    return true
end

local function disclosure_exists(data, index, reasoning, disclosure, item)
    local msg = data.messages[index]
    if not msg then return false end
    if reasoning == "r" and not data.show_reasoning then return false end
    local content = reasoning == "r" and msg.reasoning or msg.content
    if type(content) ~= "string" then return false end
    local prefix = tostring(index) .. reasoning .. ":"
    -- Open every details group only for this validation pass so nested
    -- spoilers/disclosures are enumerable; reveal state itself is untouched.
    local open_details = setmetatable({}, { __index = function() return true end })
    local html = require("ktui/chat_bubbles").encode_html(
        content, nil, open_details, { link_prefix = prefix })
    local class_name = disclosure == "det" and "ktdet" or "ktspl"
    local link = '<a href="kt:' .. disclosure .. ":" .. prefix .. tostring(item)
        .. '" class="' .. class_name .. '">'
    return html:find(link, 1, true) ~= nil
end

local function content_refresh_inflight()
    if state.queued and state.queued.kind ~= "disclosure" then return true end
    return state.reloading and state.reload_kind ~= "disclosure"
end

function Session.handle_uri(uri)
    if not state.active then return end
    local text = tostring(uri or "")
    local disclosure, message_number, reasoning, item_number =
        text:match("^kt:(%a+):(%d+)(r?):(%d+)$")
    if disclosure == "det" or disclosure == "spl" then
        -- The old document remains tappable during debounce/reload. Never let
        -- its positional URI reveal different content queued for that slot.
        if content_refresh_inflight() then return end
        local index = tonumber(message_number)
        local item = tonumber(item_number)
        local data = collect()
        if not index or index < 1 or not item or item < 1
            or not disclosure_exists(data, index, reasoning, disclosure, item) then
            return
        end
        local key = tostring(index) .. reasoning .. ":" .. tostring(item)
        local field = disclosure == "det" and "revealed_details" or "revealed_spoilers"
        local revealed = state[field]
        if not revealed then
            revealed = {}
            state[field] = revealed
        end
        if revealed[key] then revealed[key] = nil else revealed[key] = true end
        schedule_refresh({
            kind = "disclosure", anchor = "#m" .. tostring(index), tail = false,
        })
        return
    end

    local kind, arg = text:match("^kt:([%w_]+)/?(%d*)$")
    local app = state.app
    if not kind or not app then return end

    if kind == "msg" and arg ~= "" then
        local index = tonumber(arg)
        local msg = index and app.state and app.state.messages and app.state.messages[index]
        if not msg then
            toast(_("Message no longer exists."))
            schedule_refresh({ kind = "mutation" }, 0.1)
            return
        end
        book_ui().message_actions(app, index)
    elseif kind == "new" then
        app:send_message()
    elseif kind == "continue" then
        book_ui().continue_last(app)
    elseif kind == "menu" then
        book_ui().global_actions(app)
    elseif kind == "end" then
        local ui = state.ui
        if ui and ui.document then
            local Event = require("ui/event")
            pcall(function()
                ui:handleEvent(Event:new("GotoPage", page_count(ui)))
            end)
        end
    end
end

-- Close the book and then open the same chat on the canvas list view.
function Session.open_in_list()
    state.return_to_list = true
    Session.close()
end

function Session.close()
    local ui = state.ui
    local ReaderUI = require("apps/reader/readerui")
    if ui and ReaderUI.instance == ui then
        ui:onClose()
        -- onCloseWidget -> teardown normally; guard against a reader that
        -- refuses to close (or an already-closed instance).
        if state.active then
            Session.teardown(ui)
        end
    else
        Session.teardown()
    end
end

function Session.teardown(ui)
    if ui and state.ui and ui ~= state.ui then return end
    if not state.active and not state.ui then return end

    local app = state.app
    local chat_path = state.chat_path
    local return_to_list = state.return_to_list

    pcall(function() book_ui().hud_hide() end)

    local reader_ui = state.ui
    if reader_ui then
        pcall(function() reader().uninstall(reader_ui) end)
    end

    state.active = false
    state.app = nil
    state.chat_path = nil
    state.book_path = nil
    state.meta = nil
    state.ui = nil
    state.pending = nil
    state.reloading = false
    state.queued = nil
    state.generation = false
    state.stream_text = ""
    state.stream_status = nil
    state.return_to_list = false
    state.revealed_spoilers = nil
    state.revealed_details = nil
    state.refresh_token = (state.refresh_token or 0) + 1
    state.reload_token = (state.reload_token or 0) + 1

    if app and app.on_book_closed then
        pcall(app.on_book_closed, app)
    end

    if return_to_list and app and chat_path and app.open_chat_in_list then
        UIManager:scheduleIn(0.2, function()
            pcall(function() app:open_chat_in_list(chat_path) end)
        end)
    end
end

return Session
