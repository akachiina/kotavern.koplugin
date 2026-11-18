-- KtBookActions: the interactive layer of the book mode.
--
-- The generated HTML is static (crengine cannot host our widgets), so every
-- action lives here, in native KOReader widgets drawn on top of the reader:
--
--   1. The reader's own menu (registered via registerToMainMenu) gets a
--      "KOTavern" entry -> the action sheet.
--   2. A swipe-up gesture on the reader opens the same sheet.
--   3. Reaching the end of the book (onEndOfBook) opens the colophon sheet:
--      "write next message", regenerate, persona, back.
--
-- All of it is plain KOReader (ButtonDialog / ConfirmBox / InputDialog) so it
-- inherits the reader's font, size and theme - nothing from the canvas app.
--
-- The host (kt_app) passes itself in; every callback goes back through it so
-- the chat state, generation and storage stay owned by the app.

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("logger")

local BookActions = {}

-- Which widget instance is the active book reader (so we can close it and
-- return to the plugin exactly once).
local active = nil

-- ---------------------------------------------------------------------------
-- Sheet construction (sections of icon+label rows, our SVG assets via the
-- app's Icons module - never emoji, crengine has no emoji font on device).
-- ---------------------------------------------------------------------------

local function icon_label(Icons, name, text)
    if Icons and Icons.inline_label then
        return Icons.inline_label(name, text)
    end
    return text
end

-- Build the action rows for a section. `actions` = { {icon, label, cb}, ... }
local function build_rows(app, actions)
    local Icons = app and app.Icons
    local rows = {}
    for _, a in ipairs(actions) do
        rows[#rows + 1] = {
            text = icon_label(Icons, a.icon, a.label),
            callback = function()
                UIManager:close()
                if a.cb then a.cb() end
            end,
        }
    end
    return rows
end

-- The full action sheet (swipe up / reader menu).
function BookActions.show_sheet(app)
    if not app then return end
    local sections = BookActions.sections(app)

    -- KOReader's ButtonDialog: one button per row, grouped by section labels.
    -- A section is a non-clickable bold row (text only).
    local buttons = {}
    for _, sec in ipairs(sections) do
        if sec.title then
            buttons[#buttons + 1] = { { text = sec.title, bold = true, } }
        end
        for _, a in ipairs(sec.actions) do
            buttons[#buttons + 1] = build_rows(app, { a })
        end
    end
    buttons[#buttons + 1] = { { text = _("Cancel") } }

    UIManager:show(require("ui/widget/buttondialog"):new{
        title = _("KOTavern"),
        buttons = buttons,
        shrink_unneeded_width = true,
    })
end

-- The action list. Kept in one place so the colophon and the sheet agree.
function BookActions.sections(app)
    local _ = app and app._ or function(s) return s end
    local st = app and app.state or {}
    local out = {}

    out[#out + 1] = {
        title = _("Conversa"),
        actions = {
            { icon = "edit", label = _("Escrever proxima mensagem"),
              cb = function() BookActions.write_next(app) end },
            { icon = "refresh", label = _("Regenerar ultima resposta"),
              cb = function() BookActions.regenerate(app) end },
            { icon = "user", label = _("Trocar persona"),
              cb = function() BookActions.choose_persona(app) end },
            { icon = "trash", label = _("Apagar ultima mensagem"),
              cb = function() BookActions.delete_last(app) end },
        },
    }

    out[#out + 1] = {
        title = _("Contexto"),
        actions = {
            { icon = "plug", label = _("Trocar conexao"),
              cb = function() BookActions.change_connection(app) end },
            { icon = "sliders", label = _("Preset"),
              cb = function() if app.show_preset_picker then app:show_preset_picker() end end },
            { icon = "book", label = _("Lorebook"),
              cb = function() if app.show_lorebooks then app:show_lorebooks() end end },
        },
    }

    out[#out + 1] = {
        title = _("Visual"),
        actions = {
            { icon = "magic", label = _("Aparencia"),
              cb = function() app:navigate("settings_appearance") end },
            { icon = "list", label = _("Voltar ao modo lista"),
              cb = function() BookActions.leave_book(app) end },
        },
    }

    out[#out + 1] = {
        title = _("Navegacao"),
        actions = {
            { icon = "back", label = _("Voltar para a lista de chats"),
              cb = function() BookActions.leave_book(app) end },
        },
    }

    return out
end

-- ---------------------------------------------------------------------------
-- Colophon: shown when the reader reaches the end of the book.
-- ---------------------------------------------------------------------------

function BookActions.show_colophon(app)
    if not app then return end
    local _ = app._ or function(s) return s end
    local buttons = {
        { { text = _("Escrever proxima mensagem"), callback = function()
            UIManager:close()
            BookActions.write_next(app)
        end } },
        { { text = _("Regenerar ultima resposta"), callback = function()
            UIManager:close()
            BookActions.regenerate(app)
        end } },
        { { text = _("Trocar persona"), callback = function()
            UIManager:close()
            BookActions.choose_persona(app)
        end } },
        { { text = _("Voltar para a lista de chats"), callback = function()
            UIManager:close()
            BookActions.leave_book(app)
        end } },
    }
    UIManager:show(require("ui/widget/buttondialog"):new{
        title = _("KOTavern"),
        text = _("Fim do chat. O que voce quer fazer agora?"),
        buttons = buttons,
        shrink_unneeded_width = true,
    })
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
    -- Close the reader (if ours) and go back to the chat list.
    if app.close_book_reader then
        app:close_book_reader()
    elseif app.go_back then
        app:go_back()
    end
end

-- ---------------------------------------------------------------------------
-- Reader integration (called by kt_app when the book reader is up)
-- ---------------------------------------------------------------------------

-- Register the reader menu entry + swipe-up gesture on the given ReaderUI.
function BookActions.attach(app, reader_ui)
    active = { app = app, ui = reader_ui }
    local _ = app and app._ or function(s) return s end

    -- Reader menu entry: "KOTavern" -> the action sheet.
    if reader_ui.registerToMainMenu then
        reader_ui.addToMainMenu = function(menu_items)
            menu_items.kotavern_book = {
                text = _("KOTavern"),
                callback = function() BookActions.show_sheet(app) end,
            }
        end
    end

    -- CRITICAL: HTML documents are paginated by crengine (readerrolling), and
    -- ReaderHighlight:onTap does `#self.view.highlight.visible_boxes` without
    -- a nil guard. `visible_boxes` starts nil and only becomes {} inside
    -- ReaderView:drawSavedHighlight (readerpaging); for rolling documents the
    -- first tap can land before that runs, crashing the reader with
    -- "attempt to get length of field 'visible_boxes' (a nil value)".
    -- Guarantee the field is always a table for our book.
    local view = reader_ui.view
    if view and view.highlight and view.highlight.visible_boxes == nil then
        view.highlight.visible_boxes = {}
    end

    -- End of book -> the colophon sheet (one shot per open).
    local ReaderUI = reader_ui
    local eventListener = require("ui/widget/container/widgetcontainer"):new{}
    eventListener.onEndOfBook = function()
        BookActions.show_colophon(app)
        return true
    end
    eventListener.onCloseWidget = function()
        BookActions.on_close(app)
    end
    -- Insert as the FIRST child so we see the event before other widgets.
    table.insert(ReaderUI, 1, eventListener)

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