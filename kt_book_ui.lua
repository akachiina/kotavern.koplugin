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

-- The theme's labels: the user can rename every text of the book (the
-- in-book links, the speaker names and the native menus). An empty override
-- keeps the translated default.
local function label(app, key, default)
    local ok, BookTheme = pcall(require, "kt_book_theme")
    if not ok or not BookTheme then return default end
    local settings = app and app.state and app.state.settings or {}
    return BookTheme.label(BookTheme.from_settings(settings), key, default)
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

function BookUI.quick_replies(app)
    if not app then return end
    if app.state.is_generating then
        toast(_("Already generating. Stop the current response first."))
        return
    end
    local replies = (app.state.settings and app.state.settings.quick_replies) or {}
    if #replies == 0 then
        toast(_("No quick replies. Manage them in Settings → Data."), 3)
        return
    end

    local rows = {}
    for index = 1, #replies do
        local reply = replies[index]
        rows[#rows + 1] = {
            text = reply.label or "?",
            icon = "bolt",
            callback = function()
                if app.state.current_chat_path and not app.state.is_generating then
                    app:_do_send_message(reply.text or "")
                end
            end,
        }
    end
    Modals.actions(_("Quick Reply"), rows)
end

function BookUI.stop_generation(app)
    if not (app and app.state and app.state.is_generating) then
        toast(_("Nothing is being generated."), 2)
        return
    end
    app:stop_generation()
end

-- Native counterpart of the canvas Author's Note sheet. The storage writer is
-- shared with list mode; only the menus differ because Sheets cannot sit over
-- ReaderUI.
function BookUI.authors_note(app)
    local path = app and app.state and app.state.current_chat_path
    if not path then return end
    local chat_data = Storage.load_chat(path)
    local meta = (chat_data and chat_data.header and chat_data.header.chat_metadata) or {}
    local note = meta.note_prompt
    local depth = tonumber(meta.note_depth) or 4
    local interval = tonumber(meta.note_interval) or 1
    local position = tonumber(meta.note_position) or 1
    local role = tonumber(meta.note_role) or 0

    local rows = {
        {
            text = _("Edit Note"),
            icon = "edit",
            callback = function()
                Modals.input(_("Author's Note"), note or "",
                    _("Injected into the AI context"), _("Save"), function(text)
                        app:set_authors_note_field("note_prompt",
                            (text and text ~= "") and text or nil)
                    end, nil, true)
            end,
        },
        {
            text = _("Depth"),
            icon = "sliders",
            callback = function()
                local choices = {}
                for value = 0, 8 do
                    choices[#choices + 1] = {
                        text = tostring(value),
                        checked_func = function() return depth == value end,
                        callback = function() app:set_authors_note_field("note_depth", value) end,
                    }
                end
                Modals.actions(_("Insert at depth"), choices)
            end,
        },
        {
            text = _("Interval"),
            icon = "refresh",
            callback = function()
                local choices = {}
                for value = 1, 10 do
                    choices[#choices + 1] = {
                        text = tostring(value),
                        checked_func = function() return interval == value end,
                        callback = function() app:set_authors_note_field("note_interval", value) end,
                    }
                end
                Modals.actions(_("Every N user messages"), choices)
            end,
        },
        {
            text = _("Position"),
            icon = "list",
            callback = function()
                local choices = {
                    { text = _("In-chat @ depth"), value = 1 },
                    { text = _("In prompt"), value = 0 },
                    { text = _("Before scenario"), value = 2 },
                }
                for index = 1, #choices do
                    local choice = choices[index]
                    choice.checked_func = function() return position == choice.value end
                    choice.callback = function()
                        app:set_authors_note_field("note_position", choice.value)
                    end
                end
                Modals.actions(_("Note position"), choices)
            end,
        },
        {
            text = _("Role"),
            icon = "user",
            callback = function()
                local choices = {
                    { text = "system", value = 0 },
                    { text = "user", value = 1 },
                    { text = "assistant", value = 2 },
                }
                for index = 1, #choices do
                    local choice = choices[index]
                    choice.checked_func = function() return role == choice.value end
                    choice.callback = function()
                        app:set_authors_note_field("note_role", choice.value)
                    end
                end
                Modals.actions(_("Note role"), choices)
            end,
        },
        {
            text = _("Clear Note"),
            icon = "trash",
            callback = function() app:set_authors_note_field("note_prompt", nil) end,
        },
    }
    Modals.actions(_("Author's Note"), rows)
end

function BookUI.rename_chat(app)
    local path = app and app.state and app.state.current_chat_path
    if not path then return end
    app:rename_chat(path, function()
        session().on_chat_changed(path, { kind = "mutation" })
    end)
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
    -- The theme owns the flag (one writer, one setting). The app API also
    -- refreshes the open book, so no extra refresh is needed here.
    local value = not app:book_theme().show_reasoning
    app:set_book_theme_key("show_reasoning", value)
    toast(value and _("Reasoning shown in the book.") or _("Reasoning hidden in the book."), 2)
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

-- The quick appearance dialog: the knobs that matter most, reachable while
-- the reader is on top (the canvas pages are not).
function BookUI.book_appearance(app)
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local theme = app:book_theme()
    local function pick(title, current, options, on_pick)
        local rows = {}
        for _oi, option in ipairs(options) do
            rows[#rows + 1] = {
                text = option.label,
                checked = option.value == current,
                callback = function() on_pick(option.value) end,
            }
        end
        Modals.actions(title, rows)
    end
    Modals.actions(_("Book appearance"), {
        {
            text = _("Font size"),
            callback = function()
                pick(_("Font size"), theme.font_size, {
                    { label = _("Follow the reader"), value = 0 },
                    { label = "20", value = 20 },
                    { label = "22", value = 22 },
                    { label = "24", value = 24 },
                    { label = "28", value = 28 },
                }, function(value) app:set_book_theme_key("font_size", value) end)
            end,
        },
        {
            text = _("Line spacing"),
            callback = function()
                pick(_("Line spacing"), theme.line_spacing, {
                    { label = _("Follow the reader"), value = 0 },
                    { label = "90", value = 90 },
                    { label = "100", value = 100 },
                    { label = "115", value = 115 },
                    { label = "130", value = 130 },
                }, function(value) app:set_book_theme_key("line_spacing", value) end)
            end,
        },
        {
            text = _("Margins"),
            callback = function()
                pick(_("Margins"), theme.margin, {
                    { label = _("Narrow"), value = "narrow" },
                    { label = _("Normal"), value = "normal" },
                    { label = _("Wide"), value = "wide" },
                }, function(value) app:set_book_theme_key("margin", value) end)
            end,
        },
        {
            text = _("Message titles"),
            callback = function()
                pick(_("Message titles"), theme.message_title, {
                    { label = _("Speaker"), value = "speaker" },
                    { label = _("Speaker and time"), value = "speaker_time" },
                    { label = _("Time"), value = "time" },
                    { label = _("Number"), value = "number" },
                    { label = _("None"), value = "none" },
                }, function(value) app:set_book_theme_key("message_title", value) end)
            end,
        },
        {
            text = theme.show_reasoning and label(app, "hide_reasoning", _("Hide reasoning"))
                or label(app, "show_reasoning", _("Show reasoning")),
            callback = function()
                app:set_book_theme_key("show_reasoning", not theme.show_reasoning)
            end,
        },
        {
            text = theme.cover and _("Hide cover") or _("Show cover"),
            callback = function()
                app:set_book_theme_key("cover", not theme.cover)
            end,
        },
        {
            text = theme.colophon and _("Hide colophon") or _("Show colophon"),
            callback = function()
                app:set_book_theme_key("colophon", not theme.colophon)
            end,
        },
        {
            text = _("Full settings"),
            callback = function()
                -- The canvas pages live under the reader: close the book first.
                app:close_book_reader()
                app:navigate("settings_book")
            end,
        },
    })
end

-- === Global actions dialog (the "Menu do livro" link / colophon) ===

function BookUI.global_actions(app)
    if not app then return end
    local busy = app.state and app.state.is_generating
    local rows = {
        {
            text = label(app, "write_next", _("Write next message")),
            icon = "edit",
            callback = function() BookUI.write_next(app) end,
        },
        {
            text = label(app, "quick_reply", _("Quick Reply")),
            icon = "bolt",
            callback = function() BookUI.quick_replies(app) end,
        },
        {
            text = label(app, "continue_last", _("Continue last reply")),
            icon = "forward",
            callback = function() BookUI.continue_last(app) end,
        },
        {
            text = label(app, "regenerate", _("Regenerate last reply")),
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
        text = label(app, "go_last", _("Go to last message")),
        icon = "arrow-down",
        callback = function() BookUI.go_to_last(app) end,
    }
    local show_reasoning = app:book_theme().show_reasoning
    rows[#rows + 1] = {
        text = show_reasoning and label(app, "hide_reasoning", _("Hide reasoning"))
            or label(app, "show_reasoning", _("Show reasoning")),
        icon = "eye",
        callback = function() BookUI.toggle_reasoning(app) end,
    }
    rows[#rows + 1] = {
        text = label(app, "book_appearance", _("Book appearance")),
        icon = "sliders",
        callback = function() BookUI.book_appearance(app) end,
    }
    rows[#rows + 1] = {
        text = label(app, "authors_note", _("Author's Note")),
        icon = "edit",
        callback = function() BookUI.authors_note(app) end,
    }
    rows[#rows + 1] = {
        text = label(app, "system_note", _("Add System Note")),
        icon = "info-circle",
        callback = function() app:add_system_note() end,
    }
    rows[#rows + 1] = {
        text = label(app, "impersonate", _("Impersonate")),
        icon = "user",
        callback = function() app:impersonate() end,
    }
    rows[#rows + 1] = {
        text = label(app, "persona", _("Persona")),
        icon = "user",
        callback = function() BookUI.choose_persona(app) end,
    }
    rows[#rows + 1] = {
        text = label(app, "preset", _("Preset")),
        icon = "sliders",
        callback = function() BookUI.choose_preset(app) end,
    }
    rows[#rows + 1] = {
        text = label(app, "api", _("API connection")),
        icon = "plug",
        callback = function() BookUI.choose_connection(app) end,
    }
    rows[#rows + 1] = {
        text = label(app, "rename", _("Rename Chat")),
        icon = "edit",
        callback = function() BookUI.rename_chat(app) end,
    }
    rows[#rows + 1] = {
        text = label(app, "export_chat", _("Export Chat")),
        icon = "upload",
        callback = function() app:export_chat() end,
    }
    rows[#rows + 1] = {
        text = label(app, "export_txt", _("Export TXT")),
        icon = "file",
        callback = function() app:export_chat_txt() end,
    }
    rows[#rows + 1] = {
        text = label(app, "open_list", _("Open in list view")),
        icon = "list",
        callback = function() BookUI.open_in_list(app) end,
    }
    rows[#rows + 1] = {
        text = label(app, "close_book", _("Close book")),
        icon = "back",
        callback = function() session().close() end,
    }
    Modals.actions(label(app, "book_actions_title", _("Book actions")), rows)
end

-- === End of book ===

function BookUI.end_of_book(app)
    local rows = {
        {
            text = label(app, "write_next", _("Write next message")),
            icon = "edit",
            callback = function() BookUI.write_next(app) end,
        },
        {
            text = label(app, "quick_reply", _("Quick Reply")),
            icon = "bolt",
            callback = function() BookUI.quick_replies(app) end,
        },
        {
            text = label(app, "continue_last", _("Continue last reply")),
            icon = "forward",
            callback = function() BookUI.continue_last(app) end,
        },
        {
            text = label(app, "close_book", _("Close book")),
            icon = "back",
            callback = function() session().close() end,
        },
    }
    Modals.actions(label(app, "end_of_chat", _("End of chat")), rows)
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
                menu_item(_("Quick Reply"), function() BookUI.quick_replies(app) end),
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
                text = label(app, "show_reasoning", _("Show reasoning")),
                checked_func = function()
                    return app:book_theme().show_reasoning
                end,
                keep_menu_open = false,
                callback = function()
                    UIManager:nextTick(function()
                        BookUI.toggle_reasoning(app)
                    end)
                end,
            }
            items[#items + 1] = menu_item(_("Book appearance"), function()
                BookUI.book_appearance(app)
            end)
            items[#items + 1] = menu_item(_("Author's Note"),
                function() BookUI.authors_note(app) end)
            items[#items + 1] = menu_item(_("Add System Note"),
                function() app:add_system_note() end)
            items[#items + 1] = menu_item(_("Impersonate"),
                function() app:impersonate() end)
            items[#items + 1] = menu_item(_("Persona"),
                function() BookUI.choose_persona(app) end)
            items[#items + 1] = menu_item(_("Preset"),
                function() BookUI.choose_preset(app) end)
            items[#items + 1] = menu_item(_("API connection"),
                function() BookUI.choose_connection(app) end)
            items[#items + 1] = menu_item(_("Rename Chat"),
                function() BookUI.rename_chat(app) end)
            items[#items + 1] = menu_item(_("Export Chat"),
                function() app:export_chat() end)
            items[#items + 1] = menu_item(_("Export TXT"),
                function() app:export_chat_txt() end)
            items[#items + 1] = menu_item(_("Open in list view"),
                function() BookUI.open_in_list(app) end)
            items[#items + 1] = menu_item(_("Close book"),
                function() session().close() end)
            return items
        end,
    }
end

return BookUI
