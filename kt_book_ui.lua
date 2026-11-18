-- KtBookUI: the native UI that sits on top of the book reader.
--
-- Everything here is a stock KOReader widget (ButtonDialog via ktui/modals,
-- InfoMessage, TextBoxWidget). There is NO canvas painting on purpose: the
-- reader owns the page, and the actions must look and behave like the rest of
-- KOReader.
--
-- Two surfaces:
--   * menus/dialogs - message actions, compose, persona/preset/connection
--     pickers, end-of-book, reader menu entries
--   * the streaming HUD - a toast widget pinned above the footer. Because it
--     is a toast, events pass through it: page turns, taps and links keep
--     working while the reply streams.

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Device = require("device")
local logger = require("logger")
local _ = require("gettext")

local Modals = require("ktui/modals")
local Storage = require("kt_storage")

local BookUI = {}

local Screen = Device.screen

local function session()
    return require("kt_book_session")
end

local function toast(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 3 })
end

-- === Small text helpers (no canvas deps) ===

-- Last `max_bytes` of a string without cutting a UTF-8 sequence.
local function utf8_tail(text, max_bytes)
    text = tostring(text or "")
    if #text <= max_bytes then return text end
    local start = #text - max_bytes + 1
    while start <= #text do
        local byte = text:byte(start)
        if not byte then return "" end
        if byte < 0x80 or byte >= 0xC0 then break end
        start = start + 1
    end
    return text:sub(start)
end

local function preview_text(text)
    local s = tostring(text or "")
    s = s:gsub("<[^>]->", " ")
    s = s:gsub("```[%w]*", " ")
    s = s:gsub("!%[([^%]]*)%]%([^%)]*%)", "%1")
    s = s:gsub("%[([^%]]*)%]%([^%)]*%)", "%1")
    s = s:gsub("[*_`#>~|]+", "")
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return utf8_tail(s, 180)
end

local function status_label(status)
    if status == "thinking" then
        return _("Thinking…")
    end
    return _("Generating…")
end

-- === Streaming HUD ===

local hud = {
    frame = nil,
    status_widget = nil,
    preview_widget = nil,
    ui = nil,
    x = 0,
    y = 0,
    region = nil,
    status = nil,
    text = nil,
}

local function footer_height(ui)
    local ok, height = pcall(function()
        if ui and ui.footer and ui.footer.getHeight then
            return ui.footer:getHeight()
        end
    end)
    return (ok and tonumber(height)) or 0
end

local function build_hud(ui, status, text)
    local Blitbuffer = require("ffi/blitbuffer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local Font = require("ui/font")
    local Size = require("ui/size")
    local Geom = require("ui/geometry")

    local face = Font:getFace("smallinfofont")
    local margin = Screen:scaleBySize(8)
    -- The frame adds its borders and padding on both sides: keep the text
    -- width inside the screen or the HUD would overflow.
    local chrome = 2 * (Size.border.window + Size.padding.small)
    local width = math.max(40, Screen:getWidth() - 2 * margin - chrome)

    local status_widget = TextBoxWidget:new{
        text = status_label(status),
        face = face,
        width = width,
        alignment = "left",
        bold = true,
        bgcolor = Blitbuffer.COLOR_WHITE,
    }
    local preview_widget = TextBoxWidget:new{
        text = preview_text(text),
        face = face,
        width = width,
        height = math.max(1, math.floor(face.size * 2.2)),
        alignment = "left",
        bgcolor = Blitbuffer.COLOR_WHITE,
        height_overflow_show_ellipsis = true,
    }
    local frame = FrameContainer:new{
        name = "kotavern_book_hud",
        toast = true,
        covers_fullscreen = false,
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.window,
        padding = Size.padding.small,
        margin = 0,
        VerticalGroup:new{ status_widget, preview_widget },
    }
    local frame_size = frame:getSize()
    local x = margin
    local y = Screen:getHeight() - footer_height(ui) - frame_size.h - margin
    if y < 0 then y = 0 end
    return {
        frame = frame,
        status_widget = status_widget,
        preview_widget = preview_widget,
        x = x,
        y = y,
        region = Geom:new{ x = x, y = y, w = frame_size.w, h = frame_size.h },
    }
end

function BookUI.hud_show(ui, status, text)
    BookUI.hud_hide()
    local built = build_hud(ui, status, text)
    hud.ui = ui
    hud.status = status
    hud.text = text or ""
    hud.frame = built.frame
    hud.status_widget = built.status_widget
    hud.preview_widget = built.preview_widget
    hud.x, hud.y = built.x, built.y
    hud.region = built.region
    UIManager:show(hud.frame, "ui", hud.region, hud.x, hud.y)
end

function BookUI.hud_update(ui, status, text)
    if not hud.frame or (ui and hud.ui and ui ~= hud.ui) then
        BookUI.hud_show(ui, status, text)
        return
    end
    text = text or ""
    if hud.status == status and hud.text == text then return end
    hud.status = status
    hud.text = text

    local ok, err = pcall(function()
        hud.status_widget:setText(status_label(status))
        hud.preview_widget:setText(preview_text(text))
        UIManager:setDirty(hud.frame, "ui", hud.region)
    end)
    if not ok then
        logger.warn("kotavern/book: hud update failed:", tostring(err))
    end
end

function BookUI.hud_hide()
    if hud.frame then
        local frame = hud.frame
        hud.frame = nil
        hud.status_widget = nil
        hud.preview_widget = nil
        hud.region = nil
        pcall(function() UIManager:close(frame, "ui") end)
    end
    hud.ui = nil
    hud.status = nil
    hud.text = nil
end

function BookUI.hud_is_shown()
    return hud.frame ~= nil
end

-- === Message actions ===

function BookUI.message_actions(app, index)
    local st = app and app.state or {}
    local msgs = st.messages or {}
    local msg = msgs[index]
    if not msg then return end
    local is_last = (index == #msgs)
    local busy = st.is_generating

    local rows = {}

    if msg.role == "assistant" and type(msg.swipes) == "table" and #msg.swipes > 1 then
        rows[#rows + 1] = {
            text = _("Previous swipe") .. " (" .. tostring(msg.swipe_id) .. "/"
                .. tostring(#msg.swipes) .. ")",
            icon = "chev-left",
            callback = function() app:cycle_swipe(index, -1) end,
        }
        rows[#rows + 1] = {
            text = _("Next swipe") .. " (" .. tostring(msg.swipe_id) .. "/"
                .. tostring(#msg.swipes) .. ")",
            icon = "chev-right",
            callback = function() app:cycle_swipe(index, 1) end,
        }
    end

    if msg.role == "assistant" and is_last and not busy then
        rows[#rows + 1] = {
            text = _("Regenerate"),
            icon = "refresh",
            callback = function() app:regenerate_last() end,
        }
        rows[#rows + 1] = {
            text = _("New swipe"),
            icon = "random",
            callback = function() app:regenerate_last() end,
        }
        rows[#rows + 1] = {
            text = _("Continue"),
            icon = "forward",
            callback = function() app:continue_message(index) end,
        }
    end

    rows[#rows + 1] = {
        text = _("View Full"),
        icon = "eye",
        callback = function() Modals.info(msg.content or "") end,
    }
    rows[#rows + 1] = {
        text = _("Message info"),
        icon = "info-circle",
        callback = function()
            local chars = #(msg.content or "")
            local info = string.format("%s · %s\n%d chars · ~%d tokens",
                msg.name or (msg.role == "user" and _("You") or _("Assistant")),
                msg.role or "?", chars, math.ceil(chars / 4))
            UIManager:show(InfoMessage:new{ text = info, timeout = 6 })
        end,
    }

    if index > 1 and not busy then
        rows[#rows + 1] = {
            text = _("Move Up"),
            icon = "chev-up",
            callback = function() app:move_message(index, -1) end,
        }
    end
    if index < #msgs and not busy then
        rows[#rows + 1] = {
            text = _("Move Down"),
            icon = "chev-down",
            callback = function() app:move_message(index, 1) end,
        }
    end

    rows[#rows + 1] = {
        text = _("Copy"),
        icon = "copy",
        callback = function()
            if Device.input and Device.input.setClipboardText then
                Device.input.setClipboardText(msg.content or "")
                toast(_("Copied!"), 2)
            end
        end,
    }
    rows[#rows + 1] = {
        text = _("Edit"),
        icon = "edit",
        callback = function() app:edit_message(index) end,
    }

    if msg.role == "system" or msg.hidden == true then
        rows[#rows + 1] = {
            text = _("Unhide"),
            icon = "eye",
            callback = function() app:unhide_message(index) end,
        }
    else
        rows[#rows + 1] = {
            text = _("Hide"),
            icon = "ban",
            callback = function() app:hide_message(index) end,
        }
    end

    rows[#rows + 1] = {
        text = _("Branch from here"),
        icon = "random",
        callback = function() app:branch_from(index) end,
    }

    if msg.role == "user" and is_last and not busy then
        rows[#rows + 1] = {
            text = _("Edit & send"),
            icon = "forward",
            callback = function() app:edit_and_resend(index) end,
        }
    end

    rows[#rows + 1] = {
        text = _("Delete"),
        icon = "trash",
        callback = function() app:delete_message(index, false) end,
    }
    rows[#rows + 1] = {
        text = _("Delete from here"),
        icon = "trash",
        callback = function() app:delete_message(index, true) end,
    }

    Modals.actions(_("Message Actions"), rows)
end

-- === Compose ===

function BookUI.continue_last(app)
    local msgs = app and app.state and app.state.messages or {}
    if #msgs == 0 then
        app:send_message()
        return
    end
    local last = msgs[#msgs]
    if last.role == "assistant" then
        app:continue_message(#msgs)
    else
        app:generate_reply()
    end
end

function BookUI.write_next(app)
    if app and app.state and app.state.is_generating then
        toast(_("Already generating. Stop the current response first."))
        return
    end
    app:send_message()
end

function BookUI.regenerate_last(app)
    if app and app.state and app.state.is_generating then
        toast(_("Already generating. Stop the current response first."))
        return
    end
    app:regenerate_last()
end

function BookUI.stop_generation(app)
    if not (app and app.state and app.state.is_generating) then
        toast(_("Nothing is being generated."), 2)
        return
    end
    app:stop_generation()
end

-- === Pickers (native; the canvas sheets cannot be used over the reader) ===

function BookUI.choose_persona(app)
    local current = app.state.current_chat_persona_id
    local rows = {
        {
            text = _("None"),
            checked_func = function() return current == nil end,
            -- set_chat_persona already refreshes the book.
            callback = function() app:set_chat_persona(nil) end,
        },
    }
    local data = Storage.list_personas() or {}
    for _, p in ipairs(data.list or {}) do
        rows[#rows + 1] = {
            text = p.name or "?",
            checked_func = function() return current == p.id end,
            callback = function() app:set_chat_persona(p.id) end,
        }
    end
    Modals.actions(_("Select Persona"), rows)
end

function BookUI.choose_preset(app)
    local current = app.state.current_chat_preset_id
    local rows = {
        {
            text = _("None (connection defaults)"),
            checked_func = function() return current == nil end,
            -- set_chat_preset already refreshes the book.
            callback = function() app:set_chat_preset(nil) end,
        },
    }
    for _, p in ipairs(Storage.list_presets() or {}) do
        rows[#rows + 1] = {
            text = p.name or "?",
            checked_func = function() return current == p.id end,
            callback = function() app:set_chat_preset(p.id) end,
        }
    end
    Modals.actions(_("Select Preset"), rows)
end

function BookUI.choose_connection(app)
    local current = app.state.current_connection
    local rows = {}
    for _, conn in ipairs(Storage.list_connections() or {}) do
        rows[#rows + 1] = {
            text = conn.name .. " (" .. (conn.model_id or "?") .. ")",
            checked_func = function()
                return current and current.id == conn.id
            end,
            callback = function()
                if app.set_chat_connection then
                    app:set_chat_connection(conn)
                end
                session().on_chat_changed(app.state.current_chat_path, { kind = "mutation" })
            end,
        }
    end
    if #rows == 0 then
        toast(_("No API connections available."), 2)
        return
    end
    Modals.actions(_("Select API"), rows)
end

function BookUI.toggle_reasoning(app)
    local s = app.state.settings
    local value = not s.book_show_reasoning
    app:save_setting("book_show_reasoning", value)
    toast(value and _("Reasoning shown in the book.") or _("Reasoning hidden in the book."), 2)
    session().on_chat_changed(app.state.current_chat_path, { kind = "mutation" })
end

function BookUI.go_to_last(app)
    local ui = session().ui()
    if not ui or not ui.document then return end
    local Event = require("ui/event")
    pcall(function()
        ui:handleEvent(Event:new("GotoPage", ui.document:getPageCount()))
    end)
end

function BookUI.open_in_list(app)
    session().open_in_list()
end

-- === Global actions dialog (the "Menu do livro" link / colophon) ===

function BookUI.global_actions(app)
    if not app then return end
    local busy = app.state and app.state.is_generating
    local rows = {
        {
            text = _("Write next message"),
            icon = "edit",
            callback = function() BookUI.write_next(app) end,
        },
        {
            text = _("Continue last reply"),
            icon = "forward",
            callback = function() BookUI.continue_last(app) end,
        },
        {
            text = _("Regenerate last reply"),
            icon = "refresh",
            callback = function() BookUI.regenerate_last(app) end,
        },
    }
    if busy then
        rows[#rows + 1] = {
            text = _("Stop generating"),
            icon = "times",
            callback = function() BookUI.stop_generation(app) end,
        }
    end
    rows[#rows + 1] = {
        text = _("Go to last message"),
        icon = "arrow-down",
        callback = function() BookUI.go_to_last(app) end,
    }
    local show_reasoning = app.state.settings and app.state.settings.book_show_reasoning
    rows[#rows + 1] = {
        text = show_reasoning and _("Hide reasoning") or _("Show reasoning"),
        icon = "eye",
        callback = function() BookUI.toggle_reasoning(app) end,
    }
    rows[#rows + 1] = {
        text = _("Persona"),
        icon = "user",
        callback = function() BookUI.choose_persona(app) end,
    }
    rows[#rows + 1] = {
        text = _("Preset"),
        icon = "sliders",
        callback = function() BookUI.choose_preset(app) end,
    }
    rows[#rows + 1] = {
        text = _("API connection"),
        icon = "plug",
        callback = function() BookUI.choose_connection(app) end,
    }
    rows[#rows + 1] = {
        text = _("Open in list view"),
        icon = "list",
        callback = function() BookUI.open_in_list(app) end,
    }
    rows[#rows + 1] = {
        text = _("Close book"),
        icon = "back",
        callback = function() session().close() end,
    }
    Modals.actions(_("Book actions"), rows)
end

-- === End of book ===

function BookUI.end_of_book(app)
    local rows = {
        {
            text = _("Write next message"),
            icon = "edit",
            callback = function() BookUI.write_next(app) end,
        },
        {
            text = _("Continue last reply"),
            icon = "forward",
            callback = function() BookUI.continue_last(app) end,
        },
        {
            text = _("Close book"),
            icon = "back",
            callback = function() session().close() end,
        },
    }
    Modals.actions(_("End of chat"), rows)
end

-- === Reader main menu ===

local function menu_item(text, callback, icon)
    return {
        text = text,
        keep_menu_open = false,
        callback = function()
            UIManager:nextTick(callback)
        end,
    }
end

function BookUI.add_to_main_menu(menu_items)
    local app = session().app()
    if not app then return end

    menu_items.kotavern_book = {
        text = _("KOTavern"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            local busy = app.state and app.state.is_generating
            local items = {
                menu_item(_("Write next message"), function() BookUI.write_next(app) end),
                menu_item(_("Continue last reply"), function() BookUI.continue_last(app) end),
                menu_item(_("Regenerate last reply"), function() BookUI.regenerate_last(app) end),
            }
            if busy then
                items[#items + 1] = menu_item(_("Stop generating"),
                    function() BookUI.stop_generation(app) end)
            end
            items[#items + 1] = menu_item(_("Go to last message"),
                function() BookUI.go_to_last(app) end)
            items[#items + 1] = {
                text = _("Show reasoning"),
                checked_func = function()
                    return app.state.settings and app.state.settings.book_show_reasoning
                end,
                keep_menu_open = false,
                callback = function()
                    UIManager:nextTick(function()
                        BookUI.toggle_reasoning(app)
                    end)
                end,
            }
            items[#items + 1] = menu_item(_("Persona"),
                function() BookUI.choose_persona(app) end)
            items[#items + 1] = menu_item(_("Preset"),
                function() BookUI.choose_preset(app) end)
            items[#items + 1] = menu_item(_("API connection"),
                function() BookUI.choose_connection(app) end)
            items[#items + 1] = menu_item(_("Open in list view"),
                function() BookUI.open_in_list(app) end)
            items[#items + 1] = menu_item(_("Close book"),
                function() session().close() end)
            return items
        end,
    }
end

return BookUI
