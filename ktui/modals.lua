-- Dialog/popup wrappers for KOTavern.
-- Adapted from ZenPM (zenpm.koplugin/ui/modals.lua)

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Icons = require("ktui/icons")

local Modals = {}
local status_modal = nil
local ok_android = pcall(require, "android")

local function show_input_dialog(dialog)
    UIManager:show(dialog)
    if not ok_android then
        dialog:onShowKeyboard()
    end
end

function Modals.info(text)
    UIManager:show(InfoMessage:new{ text = text })
    Modals.close_status()
end

function Modals.info_for(text, seconds)
    local modal = InfoMessage:new{ text = text }
    UIManager:show(modal)
    Modals.close_status()
    UIManager:scheduleIn(seconds, function()
        UIManager:close(modal)
    end)
end

function Modals.notice(text)
    UIManager:show(ConfirmBox:new{
        text = text,
        icon = "notice-info",
        no_ok_button = true,
        cancel_text = _("OK"),
    })
    Modals.close_status()
end

function Modals.status(text)
    Modals.close_status()
    status_modal = InfoMessage:new{
        text = text,
        dismissable = false,
        timeout = 60,
        flush_events_on_show = true,
    }
    UIManager:show(status_modal)
    return status_modal
end

function Modals.close_status()
    if status_modal then
        UIManager:close(status_modal)
        status_modal = nil
    end
end

-- ConfirmBox. When close_before_callback is true the dialog stays open while
-- the callback runs (ZenPM's keep_dialog_open pattern): the callback can
-- chain a follow-up dialog without a flash between the two.
function Modals.confirm(text, ok_text, ok_callback, close_before_callback)
    local dialog
    dialog = ConfirmBox:new{
        text = text,
        ok_text = ok_text or _("OK"),
        keep_dialog_open = close_before_callback,
        ok_callback = function()
            if close_before_callback then
                UIManager:close(dialog)
                UIManager:nextTick(ok_callback)
            else
                -- ConfirmBox closes itself before invoking ok_callback.
                if ok_callback then ok_callback() end
            end
        end,
    }
    UIManager:show(dialog)
    Modals.close_status()
end

-- Single-line input. clear_callback adds a leading Clear button (ZenPM
-- pattern: used by search prompts so the user can wipe the filter inline).
-- multiline adds allow_newline (Enter inserts a line break instead of firing
-- the OK button - KOReader's own tradeoff; scrolling stays swipe N/S).
function Modals.input(title, input, hint, ok_text, callback, clear_callback, multiline)
    local dialog
    local buttons = {
        {
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = ok_text or _("OK"),
                is_enter_default = true,
                callback = function()
                    local text = dialog:getInputText()
                    UIManager:close(dialog)
                    callback(text)
                end,
            },
        },
    }
    if clear_callback then
        table.insert(buttons, 1, {
            {
                text = _("Clear"),
                callback = function()
                    UIManager:close(dialog)
                    clear_callback()
                end,
            },
        })
    end
    dialog = InputDialog:new{
        title = title,
        input = input or "",
        input_hint = hint,
        input_type = "text",
        allow_newline = multiline and true or false,
        -- Without text_height the dialog sizes the box by its CONTENT, so an
        -- empty multiline input still paints one row (allow_newline alone is
        -- not enough). 160 scaled px ~= 5 lines: KOReader core precedent
        -- (filemanagerbookinfo.lua).
        text_height = multiline and require("device").screen:scaleBySize(160) or nil,
        keyboard_visible = not ok_android,
        buttons = buttons,
    }
    show_input_dialog(dialog)
end

function Modals.multi_input(title, fields, ok_text, callback)
    local dialog
    local buttons = {
        {
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = ok_text or _("OK"),
                is_enter_default = true,
                callback = function()
                    local values = dialog:getFields()
                    UIManager:close(dialog)
                    if callback then callback(values) end
                end,
            },
        },
    }
    dialog = MultiInputDialog:new{
        title = title,
        fields = fields,
        keyboard_visible = not ok_android,
        buttons = buttons,
    }
    show_input_dialog(dialog)
end

-- Search input with a close icon in the title bar and tap-outside-to-close.
function Modals.search(title, input, hint, callback)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = input or "",
        input_hint = hint,
        keyboard_visible = not ok_android,
        title_bar_left_icon = "close",
        title_bar_left_icon_tap_callback = function()
            UIManager:close(dialog)
        end,
        buttons = {
            {
                {
                    text = Icons.inline_label("search", _("Search")),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText()
                        UIManager:close(dialog)
                        callback(text)
                    end,
                },
            },
        },
    }
    function dialog:onTap(arg, ges)
        if ges.pos:notIntersectWith(self.dialog_frame.dimen) then
            UIManager:close(self)
            return true
        end
        return InputDialog.onTap(self, arg, ges)
    end
    show_input_dialog(dialog)
end

-- Native ButtonDialog menu (ZenPM's Modals.actions). opts:
--   rows = { { text, icon, align, checked_func, callback } }
--   anchor (Geom from the tapped hitbox), anchor_right (hang left off anchor)
--   compact + compact_min_width, align, title + title_icon (icon + title row),
--   show_cancel (default true), cancel_callback
function Modals.actions(title, rows, options)
    options = options or {}
    local dialog
    local anchor = options.anchor
    if anchor and options.anchor_right then
        local source = anchor
        anchor = function()
            local content = dialog and dialog.movable and dialog.movable[1]
            local content_w = content and content:getSize().w or 0
            -- MovableContainer expects a Geom (reads its fields/methods).
            return require("ui/geometry"):new{
                x = source.x + source.w - content_w - require("device").screen:scaleBySize(8),
                y = source.y,
                w = source.w,
                h = source.h,
            }
        end
    end
    local buttons = {}
    for _, row in ipairs(rows or {}) do
        table.insert(buttons, {
            {
                text = row.icon and Icons.inline_label(row.icon, row.text) or row.text,
                align = row.align or options.align,
                checked_func = row.checked_func,
                callback = function()
                    UIManager:nextTick(function()
                        UIManager:close(dialog)
                        if row.callback then row.callback() end
                    end)
                end,
            },
        })
    end
    if options.show_cancel ~= false then
        table.insert(buttons, {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                    if options.cancel_callback then options.cancel_callback() end
                end,
            },
        })
    end
    local dialog_title = title
    if options.title_icon then
        dialog_title = nil
    end
    local Screen = require("device").screen
    dialog = ButtonDialog:new{
        title = dialog_title,
        buttons = buttons,
        anchor = anchor,
        shrink_min_width = options.compact_min_width and Screen:scaleBySize(options.compact_min_width) or nil,
        shrink_unneeded_width = options.compact,
    }
    if options.title_icon then
        local icon_size = Screen:scaleBySize(28)
        local gap = Screen:scaleBySize(8)
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local HorizontalSpan = require("ui/widget/horizontalspan")
        local IconWidget = require("ui/widget/iconwidget")
        local LeftContainer = require("ui/widget/container/leftcontainer")
        local TextWidget = require("ui/widget/textwidget")
        local Font = require("ui/font")
        local Geom = require("ui/geometry")
        dialog:addWidget(LeftContainer:new{
            not_focusable = true,
            dimen = Geom:new{
                w = dialog:getAddedWidgetAvailableWidth(),
                h = icon_size,
            },
            HorizontalGroup:new{
                align = "center",
                IconWidget:new{
                    file = options.title_icon,
                    width = icon_size,
                    height = icon_size,
                },
                HorizontalSpan:new{ width = gap },
                TextWidget:new{
                    text = title,
                    face = Font:getFace("infofont"),
                },
            },
        })
    end
    UIManager:show(dialog)
end

return Modals
