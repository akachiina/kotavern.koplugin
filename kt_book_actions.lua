-- KtBookActions: the interactive layer of the book mode.
--
-- The generated HTML is static (crengine cannot host our widgets), so every
-- action lives here, in widgets drawn on top of the reader:
--
--   1. The reader's own menu gets a "KOTavern" entry -> the action sheet.
--   2. Reaching the end of the book (onEndOfBook) opens the action sheet.
--   3. A swipe up (page mode) opens the sheet; swipe down on an open sheet
--      closes it.
--
-- The sheet is the PAINTED widget from kt_book_sheet (same look as the
-- canvas UI, SVG icons, no emoji). Mutating actions that change the chat
-- stay in the book: the composer is a rich InputDialog over the reader and
-- the live refresh (App:_book_generation_landed -> BookActions.reload_book)
-- rewrites the HTML and reloads the document in place. Only actions that
-- open canvas pickers (persona / connection / preset / lorebook /
-- appearance) leave the book - those paint into the canvas view, which is
-- invisible under the reader.
--
-- ReaderUI integration notes (all learned the hard way, see the repro
-- harness tools/book_repro.lua):
--
--   * WidgetContainer:paintTo forwards painting to the FIRST CHILD ONLY.
--     The event listener must therefore be inserted at position 2 (after
--     readerview, which is child 1) - at position 1 it hijacks the paint
--     chain and the book renders as a blank screen forever. Events still
--     reach us first among siblings because propagateEvent walks children
--     in order. (rakuyomi's MangaReader does the same insert-at-2.)
--   * Because propagation starts at child 1, the reader's own touch zones
--     consume vertical swipes before our child listener sees them - the
--     swipe-up-to-open hook therefore interposes on ReaderUI.handleEvent
--     itself (restored on close).
--   * Menu entries are registered through ReaderMenu:registerToMainMenu,
--     the official plugin hook - overriding reader_ui.addToMainMenu after
--     init does nothing.
--   * The hook is deferred via registerPostInitCallback when init is still
--     running (attach fires on a nextTick that can land mid-init, before
--     reader_ui.menu even exists).
--
-- The host (kt_app) passes itself in; every callback goes back through it so
-- the chat state, generation and storage stay owned by the app.

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local _ = require("gettext")

local BookActions = {}

-- Reused guard toast: the canvas UI has inline "generating" state, but the
-- book is static HTML - without a toast, blocked actions look broken ("I
-- tapped regenerate and nothing happened").
local function toast(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 2,
    })
end

-- Which widget instance is the active book reader (so we can close it and
-- return to the plugin exactly once).
local active = nil

local function is_shown(widget)
    for i, win in ipairs(UIManager._window_stack) do
        if win.widget == widget then return true end
    end
    return false
end

local function get(_w, name)
    return _w and _w[name]
end

-- Guard against stacking (EndOfBook can fire again on the next swipe): true
-- when a sheet widget is already on screen.
local function sheet_is_open()
    local ok, Sheet = pcall(require, "kt_book_sheet")
    return ok and Sheet.is_open()
end

-- ---------------------------------------------------------------------------
-- Sheet construction (painted widget; sections -> rows with SVG icons)
-- ---------------------------------------------------------------------------

-- The action list. Mutating actions (write / regenerate / delete) stay in
-- the book; only canvas pickers close it first.
function BookActions.sections(app)
    local out = {}

    out[#out + 1] = {
        title = _("Conversa"),
        actions = {
            { label = _("Escrever proxima mensagem"), icon = "edit",
              cb = function() BookActions.compose_in_book(app) end },
            { label = _("Regenerar ultima resposta"), icon = "refresh",
              cb = function() BookActions.regenerate(app) end },
            { label = _("Apagar ultima mensagem"), icon = "trash",
              cb = function() BookActions.delete_last(app) end },
            { label = _("Trocar persona"), icon = "user",
              cb = function()
                  BookActions.leave_book(app)
                  BookActions.choose_persona(app)
              end },
        },
    }

    out[#out + 1] = {
        title = _("Contexto"),
        actions = {
            { label = _("Trocar conexao"), icon = "plug",
              cb = function()
                  BookActions.leave_book(app)
                  BookActions.change_connection(app)
              end },
            { label = _("Preset"), icon = "sliders",
              cb = function()
                  BookActions.leave_book(app)
                  if get(app, "show_preset_picker") then app:show_preset_picker() end
              end },
            { label = _("Lorebook"), icon = "book",
              cb = function()
                  BookActions.leave_book(app)
                  if get(app, "show_lorebooks") then app:show_lorebooks() end
              end },
        },
    }

    out[#out + 1] = {
        title = _("Visual"),
        actions = {
            { label = _("Aparencia"), icon = "eye",
              cb = function()
                  BookActions.leave_book(app)
                  if app.navigate then app:navigate("settings_appearance") end
              end },
        },
    }

    out[#out + 1] = {
        title = _("Navegacao"),
        actions = {
            { label = _("Voltar para a lista de chats"), icon = "back",
              cb = function() BookActions.leave_book(app) end },
        },
    }

    return out
end

-- The full action sheet (reader menu entry / swipe up).
function BookActions.show_sheet(app)
    if not app then return end
    local Sheet = require("kt_book_sheet")
    Sheet.show{
        title = _("KOTavern"),
        cancel_label = _("Cancel"),
        sections = BookActions.sections(app),
    }
end

-- Shown when the reader reaches the end of the book: the same sheet, with
-- a lead-in message.
function BookActions.show_colophon(app)
    if not app or sheet_is_open() then return end
    local Sheet = require("kt_book_sheet")
    Sheet.show{
        title = _("KOTavern"),
        text = _("Fim do chat. O que voce quer fazer agora?"),
        cancel_label = _("Cancel"),
        sections = BookActions.sections(app),
    }
end

-- ---------------------------------------------------------------------------
-- In-book composer (rich InputDialog over the reader; does NOT close the book)
-- ---------------------------------------------------------------------------

-- Context line under the composer title: persona / connection / model.
local function compose_context(app)
    local st = app and app.state or {}
    local lines = {}
    local persona = get(app, "_active_persona_name") and app:_active_persona_name() or nil
    if type(persona) == "string" and persona ~= "" then
        lines[#lines + 1] = _("Persona") .. ": " .. persona
    end
    local conn = st.current_connection
    if type(conn) == "table" then
        local Models = require("kt_models")
        local preset = get(app, "active_preset") and app:active_preset() or {}
        local bits = {}
        if type(conn.name) == "string" and conn.name ~= "" then
            bits[#bits + 1] = conn.name
        end
        local model = preset.model_id or conn.model_id
        if type(model) == "string" and model ~= "" then
            bits[#bits + 1] = model
        end
        if #bits > 0 then
            lines[#lines + 1] = table.concat(bits, " / ")
        end
    end
    return table.concat(lines, "\n")
end

-- Send a composed message without leaving the book. Same send_if_empty
-- parity as the canvas composer: an empty submit with a configured
-- placeholder is still meaningful.
function BookActions.send_composed(app, text)
    if not app then return end
    local st = app.state or {}
    if st.is_generating then
        toast(_("Already generating. Stop the current response first."))
        return
    end
    text = tostring(text or "")
    if text:gsub("%s+", "") == "" then
        local placeholder = st.settings and st.settings.send_if_empty
        if type(placeholder) == "string" and placeholder ~= "" then
            app:_do_send_message(placeholder)
        end
        return
    end
    app:_do_send_message(text)
end

function BookActions.compose_in_book(app)
    if not app then return end
    local st = app.state or {}
    if st.is_generating then
        toast(_("Already generating. Stop the current response first."))
        return
    end
    logger.info("kotavern/book: composer opened")
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Escrever proxima mensagem"),
        description = compose_context(app),
        input = "",
        input_hint = _("Type your message..."),
        allow_newline = true,
        buttons = {
            {
                { text = _("Cancel"), id = "close", callback = function()
                    UIManager:close(dialog)
                end },
                { text = _("Send"), is_enter_default = true, callback = function()
                    local text = dialog:getInputText()
                    UIManager:close(dialog)
                    BookActions.send_composed(app, text)
                end },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ---------------------------------------------------------------------------
-- Actions -> app
-- ---------------------------------------------------------------------------

function BookActions.write_next(app)
    if not app then return end
    BookActions.compose_in_book(app)
end

function BookActions.regenerate(app)
    if not app then return end
    local st = app.state or {}
    if st.is_generating then
        toast(_("Already generating. Stop the current response first."))
        return
    end
    -- Visible refusal instead of a silent no-op: regenerate only works on a
    -- trailing assistant reply (canvas parity in App:regenerate_last).
    local msgs = st.messages or {}
    if #msgs == 0 or msgs[#msgs].role ~= "assistant" then
        toast(_("Nothing to regenerate."))
        return
    end
    logger.info("kotavern/book: regenerate requested")
    if app.regenerate_last then
        app:regenerate_last()
        if st.is_generating then
            -- The book only reloads when the reply lands (App:
            -- _book_generation_landed); until then tell the user it started.
            toast(_("Regenerating response..."))
        end
    end
end

function BookActions.choose_persona(app)
    if not app then return end
    if app.choose_persona then app:choose_persona() end
end

-- Deletes the last message (ConfirmBox over the reader, stays in book);
-- the live refresh rewrites the HTML afterwards. The old code called a
-- non-existent app:delete_message_at - the deletion never happened.
function BookActions.delete_last(app)
    if not app then return end
    local st = app.state or {}
    local msgs = st.messages or {}
    if #msgs == 0 then return end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Apagar a ultima mensagem?"),
        ok_text = _("Apagar"),
        ok_callback = function()
            local path = st.current_chat_path
            if app.state and app.state.is_generating then
                toast(_("Already generating. Stop the current response first."))
                return
            end
            logger.info("kotavern/book: delete last confirmed")
            table.remove(app.state.messages, #app.state.messages)
            if path then
                local Storage = require("kt_storage")
                local chat_data = Storage.load_chat(path)
                if chat_data then
                    Storage.save_chat(path, chat_data.header, app.state.messages)
                end
            end
            if path and app._book_generation_landed then
                app:_book_generation_landed(path)
            end
        end,
    })
end

function BookActions.change_connection(app)
    if not app then return end
    if app.show_connections then app:show_connections() end
end

function BookActions.leave_book(app)
    if not app then return end
    -- Close the reader (if ours); on_book_closed repaints the canvas.
    if app.close_book_reader then
        app:close_book_reader()
    elseif app.go_back then
        app:go_back()
    end
end

-- ---------------------------------------------------------------------------
-- Reader integration (called by kt_app when the book reader is up)
-- ---------------------------------------------------------------------------

-- Register the reader menu entry + end-of-book hook on the given ReaderUI.
function BookActions.attach(app, reader_ui)
    if reader_ui._kt_book_listener then return end -- already attached
    active = { app = app, ui = reader_ui }

    -- CRITICAL: HTML documents are paginated by crengine (readerrolling), and
    -- ReaderHighlight:onTap does `#self.view.highlight.visible_boxes` without
    -- a nil guard. `visible_boxes` starts nil and only becomes {} inside
    -- ReaderView:drawSavedHighlight; for rolling documents the first tap can
    -- land before that runs. Guarantee the field is always a table.
    local view = reader_ui.view
    if view and view.highlight and view.highlight.visible_boxes == nil then
        view.highlight.visible_boxes = {}
    end

    local function hook()
        if reader_ui._kt_book_listener then return end

        -- Reader menu entry through the official plugin registration.
        if reader_ui.menu then
            reader_ui.menu:registerToMainMenu({
                addToMainMenu = function(menu_items)
                    menu_items.kotavern_book = {
                        text = _("KOTavern"),
                        callback = function() BookActions.show_sheet(app) end,
                    }
                end,
            })
        end

        local eventListener = require("ui/widget/container/widgetcontainer"):new{}
        eventListener.onEndOfBook = function()
            BookActions.show_colophon(app)
            return true -- consume: ReaderStatus must not mark the book finished
        end
        eventListener.onCloseWidget = function()
            BookActions.on_close(app)
        end
        -- Position 2, NOT 1: WidgetContainer:paintTo forwards painting to the
        -- first child only; child 1 is readerview and must stay there.
        table.insert(reader_ui, 2, eventListener)
        reader_ui._kt_book_listener = eventListener

        -- Swipe up opens the sheet (page mode only). The reader's own paging
        -- zones are child 1 and would consume the gesture before our child
        -- listener, so interpose on ReaderUI.handleEvent itself; restored on
        -- close. Only the north swipe is taken - vertical swipes lose their
        -- page-turn role in page mode (taps still turn pages).
        local orig_handle = reader_ui.handleEvent
        reader_ui._kt_orig_handleEvent = orig_handle
        reader_ui.handleEvent = function(ui_self, event)
            if event and event.handler == "onGesture"
                and type(event.args) == "table" and event.args[1] then
                local ges = event.args[1]
                if ges.ges == "swipe" and ges.direction == "north"
                    and ui_self.view and ui_self.view.view_mode == "page" then
                    BookActions.show_sheet(app)
                    return true
                end
            end
            return orig_handle(ui_self, event)
        end
    end

    -- attach() runs on a nextTick that can land in the middle of ReaderUI
    -- init (before reader_ui.menu exists): defer until post-init if possible.
    if reader_ui.postInitCallback then
        reader_ui:registerPostInitCallback(hook)
    else
        hook()
    end

    logger.info("kotavern/book: reader attached")
end

-- Live refresh: the book file for the open chat was rewritten by the host;
-- reload the document in place and jump to the last page (the new reply).
-- Avoids a full close/reopen cycle.
function BookActions.reload_book()
    local ui = active and active.ui
    if not ui or not ui.document then return end
    local Event = require("ui/event")
    local doc = ui.document
    local ok, err = pcall(function()
        doc:invalidateCacheFile()
        doc:loadDocument()
        doc:render()
        doc:_readMetadata()
    end)
    if not ok then
        logger.info("kotavern/book: reload failed: ", tostring(err))
        return
    end
    pcall(function()
        if ui.rolling then
            ui.rolling:updatePos(true)
            local pages = doc:getPageCount()
            if pages and pages > 0 then
                ui:handleEvent(Event:new("GotoPage", pages))
            end
        end
    end)
    UIManager:setDirty(ui, "ui")
end

function BookActions.on_close(app)
    -- Restore the interposed handleEvent before dropping the reader.
    local ui = active and active.ui
    if ui and ui._kt_orig_handleEvent then
        ui.handleEvent = ui._kt_orig_handleEvent
        ui._kt_orig_handleEvent = nil
    end
    active = nil
    if app and app.on_book_closed then
        app:on_book_closed()
    end
end

function BookActions.is_active()
    return active ~= nil
end

return BookActions
