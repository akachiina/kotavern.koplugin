-- KtBookActions: the interactive layer of the book mode.
--
-- The generated HTML is static (crengine cannot host our widgets), so every
-- action lives here, in native KOReader widgets drawn on top of the reader:
--
--   1. The reader's own menu gets a "KOTavern" entry -> the action sheet.
--   2. Reaching the end of the book (onEndOfBook) opens the colophon sheet:
--      "write next message", regenerate, persona, back.
--
-- All of it is plain KOReader (ButtonDialog / ConfirmBox) so it inherits the
-- reader's font, size and theme - nothing from the canvas app. Labels are
-- plain text: our SVG assets and nerd glyphs can't render inside native
-- widgets, and emoji are banned by design.
--
-- ReaderUI integration notes (both learned the hard way, see the repro
-- harness tools/book_repro.lua):
--
--   * WidgetContainer:paintTo forwards painting to the FIRST CHILD ONLY.
--     The event listener must therefore be inserted at position 2 (after
--     readerview, which is child 1) - at position 1 it hijacks the paint
--     chain and the book renders as a blank screen forever. Events still
--     reach us first among siblings because propagateEvent walks children
--     in order. (rakuyomi's MangaReader does the same insert-at-2.)
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
local logger = require("logger")

local BookActions = {}

-- Which widget instance is the active book reader (so we can close it and
-- return to the plugin exactly once).
local active = nil

local function is_shown(widget)
    for _, win in ipairs(UIManager._window_stack) do
        if win.widget == widget then return true end
    end
    return false
end

-- True while the colophon dialog is on screen (EndOfBook can fire again on
-- the next forward swipe; don't stack dialogs).
local colophon_dialog = nil

local function get(_w, name)
    return _w and _w[name]
end

-- ---------------------------------------------------------------------------
-- Sheet construction (plain text rows; sections as non-clickable bold rows)
-- ---------------------------------------------------------------------------

-- Build the action rows for a section. `actions` = { {label, cb}, ... }
-- Every row closes the dialog first: ButtonDialog does NOT close itself when
-- a button is tapped (only taps outside the panel do).
local function rows(dialog, actions)
    local out = {}
    for _, a in ipairs(actions) do
        out[#out + 1] = {
            text = a.label,
            callback = function()
                UIManager:close(dialog)
                if a.cb then a.cb() end
            end,
        }
    end
    return out
end

-- The full action sheet (reader menu entry).
function BookActions.show_sheet(app)
    if not app then return end
    local sections = BookActions.sections(app)

    local dialog
    local buttons = {}
    for _, sec in ipairs(sections) do
        if sec.title then
            buttons[#buttons + 1] = { { text = sec.title, bold = true, } }
        end
        for _, a in ipairs(sec.actions) do
            local row = rows(dialog, { a })[1]
            buttons[#buttons + 1] = { row }
        end
    end
    buttons[#buttons + 1] = { { text = _("Cancel") } }

    dialog = require("ui/widget/buttondialog"):new{
        title = _("KOTavern"),
        buttons = buttons,
        shrink_unneeded_width = true,
    }
    -- rows() closes `dialog` via the upvalue, so bind before showing.
    UIManager:show(dialog)
end

-- The action list. Kept in one place so the colophon and the sheet agree.
-- Mutating actions close the book first: the generated HTML is a snapshot,
-- so anything that changes the chat must hand control back to the canvas
-- (which regenerates the book on the next open).
function BookActions.sections(app)
    local _ = app and app._ or function(s) return s end
    local st = app and app.state or {}
    local out = {}

    out[#out + 1] = {
        title = _("Conversa"),
        actions = {
            { label = _("Escrever proxima mensagem"),
              cb = function() BookActions.leave_book(app) BookActions.write_next(app) end },
            { label = _("Regenerar ultima resposta"),
              cb = function() BookActions.leave_book(app) BookActions.regenerate(app) end },
            { label = _("Trocar persona"),
              cb = function() BookActions.leave_book(app) BookActions.choose_persona(app) end },
            { label = _("Apagar ultima mensagem"),
              cb = function() BookActions.leave_book(app) BookActions.delete_last(app) end },
        },
    }

    out[#out + 1] = {
        title = _("Contexto"),
        actions = {
            { label = _("Trocar conexao"),
              cb = function() BookActions.leave_book(app) BookActions.change_connection(app) end },
            { label = _("Preset"),
              cb = function()
                  BookActions.leave_book(app)
                  if get(app, "show_preset_picker") then app:show_preset_picker() end
              end },
            { label = _("Lorebook"),
              cb = function()
                  BookActions.leave_book(app)
                  if get(app, "show_lorebooks") then app:show_lorebooks() end
              end },
        },
    }

    out[#out + 1] = {
        title = _("Visual"),
        actions = {
            { label = _("Aparencia"),
              cb = function()
                  BookActions.leave_book(app)
                  if app.navigate then app:navigate("settings_appearance") end
              end },
        },
    }

    out[#out + 1] = {
        title = _("Navegacao"),
        actions = {
            { label = _("Voltar para a lista de chats"),
              cb = function() BookActions.leave_book(app) end },
        },
    }

    return out
end

-- ---------------------------------------------------------------------------
-- Colophon: shown when the reader reaches the end of the book.
-- ---------------------------------------------------------------------------

function BookActions.show_colophon(app)
    if not app or is_shown(colophon_dialog) then return end
    local _ = app._ or function(s) return s end
    local dialog
    local buttons = {
        { { text = _("Escrever proxima mensagem"), callback = function()
            UIManager:close(dialog)
            BookActions.leave_book(app)
            BookActions.write_next(app)
        end } },
        { { text = _("Regenerar ultima resposta"), callback = function()
            UIManager:close(dialog)
            BookActions.leave_book(app)
            BookActions.regenerate(app)
        end } },
        { { text = _("Trocar persona"), callback = function()
            UIManager:close(dialog)
            BookActions.leave_book(app)
            BookActions.choose_persona(app)
        end } },
        { { text = _("Voltar para a lista de chats"), callback = function()
            UIManager:close(dialog)
            BookActions.leave_book(app)
        end } },
    }
    dialog = require("ui/widget/buttondialog"):new{
        title = _("KOTavern"),
        text = _("Fim do chat. O que voce quer fazer agora?"),
        buttons = buttons,
        shrink_unneeded_width = true,
    }
    colophon_dialog = dialog
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- Actions -> app
-- ---------------------------------------------------------------------------

function BookActions.write_next(app)
    if not app then return end
    if app.ask_message then
        app:ask_message()
    elseif app.send_message then
        app:send_message()
    end
end

function BookActions.regenerate(app)
    if not app then return end
    if app.regenerate_last then app:regenerate_last() end
end

function BookActions.choose_persona(app)
    if not app then return end
    if app.choose_persona then app:choose_persona() end
end

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
            if app.delete_message_at then app:delete_message_at(#msgs) end
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
    local _ = app and app._ or function(s) return s end

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

function BookActions.on_close(app)
    active = nil
    if app and app.on_book_closed then
        app:on_book_closed()
    end
end

function BookActions.is_active()
    return active ~= nil
end

return BookActions
