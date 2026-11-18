-- KtBookReader: everything this plugin touches on KOReader's ReaderUI.
--
-- The reader is instantiated by KOReader from main.lua: when the plugin loads
-- inside a ReaderUI (self.ui.name == "ReaderUI") the plugin asks this module
-- to attach. Attach only does something when the document is a book generated
-- by kt_book AND the session has it pending/reloading - a real book opened by
-- the user is never touched.
--
-- Integration points (all official hooks, no monkey-patching of handleEvent):
--
--   * ReaderUI:registerPostInitCallback - menu + touch zone + event listener
--   * table.insert(ui, 2, listener)    - event listener. NEVER index 1:
--     WidgetContainer:paintTo paints the FIRST CHILD ONLY, and child 1 is the
--     readerview. Events still reach us because propagateEvent walks children
--     in order.
--   * ui:registerTouchZones            - our `kt:` tap zone, declared to
--     override `tap_link` so it runs first; it returns false for every other
--     tap, so links, page turns and menus keep working.
--   * ReaderUI:reloadDocument          - close/reopen the same path with the
--     new bytes (no private loadDocument/render poking).
--   * ReadHistory:addItem/updateLastBookTime - the generated book must never
--     appear in the history or the "open last document" slot.
--
-- Refresh policy/state lives in kt_book_session; this module is the plumbing.

local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local Book = require("kt_book")

local Reader = {}

local TAP_ZONE_ID = "kotavern_book_tap"

-- === ReadHistory suppression ===
--
-- Installed when this module is first required (the plugin runs its init
-- before ReaderUI's own ReadHistory:addItem in ReaderUI:init, so the first
-- open is already covered). The predicate is strict: a .html file inside
-- <data>/books. Real user books can never match.

local function is_our_book(path)
    if type(path) ~= "string" or path == "" then return false end
    if Book.is_book_path(path) then return true end
    local ok, real = pcall(function()
        return require("ffi/util").realpath(path)
    end)
    return ok and real and Book.is_book_path(real) or false
end

local function install_history_hooks()
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or not ReadHistory or ReadHistory._kotavern_book_hooked then
        return
    end
    ReadHistory._kotavern_book_hooked = true

    local orig_add = ReadHistory.addItem
    if type(orig_add) == "function" then
        ReadHistory.addItem = function(hist, file, ...)
            if is_our_book(file) then return end
            return orig_add(hist, file, ...)
        end
    end

    local orig_update = ReadHistory.updateLastBookTime
    if type(orig_update) == "function" then
        ReadHistory.updateLastBookTime = function(hist, ...)
            -- updateLastBookTime mutates hist[1] blindly; when the closed
            -- document is our book, hist[1] belongs to a real book.
            local ok_ui, ReaderUI = pcall(require, "apps/reader/readerui")
            local ui = ok_ui and ReaderUI and ReaderUI.instance
            local file = ui and ui.document and ui.document.file
            if file and is_our_book(file) then return end
            return orig_update(hist, ...)
        end
    end
end

install_history_hooks()

-- === Link interception ===

-- Current-page links (crengine keeps our kt: scheme as an external `uri`).
local function page_links(doc)
    local ok, links = pcall(function() return doc:getPageLinks() end)
    if ok and type(links) == "table" then return links end
    return {}
end

-- URI under a tap position, or nil. Primary path: crengine tells us the
-- anchor xpointer; match it against the page's link list. Fallback: hit-test
-- the link rectangles (crengine coordinates are occasionally imprecise).
function Reader.link_uri_at(ui, pos)
    local doc = ui and ui.document
    if not doc or not pos then return nil end
    local links = page_links(doc)

    local ok, a_xp = pcall(function()
        local _, a_xpointer = doc:getLinkFromPosition(pos)
        return a_xpointer
    end)
    if ok and a_xp then
        for _, link in ipairs(links) do
            if link.a_xpointer == a_xp and type(link.uri) == "string" and link.uri ~= "" then
                return link.uri
            end
        end
    end

    local Screen = require("device").screen
    local slack = Screen:scaleBySize(8)
    for _, link in ipairs(links) do
        if type(link.uri) == "string" and link.uri ~= "" then
            local x0, x1 = link.start_x, link.end_x
            local y0, y1 = link.start_y, link.end_y
            if link.segments and #link.segments > 0 then
                for _, seg in ipairs(link.segments) do
                    if pos.x >= seg.x0 - slack and pos.x <= seg.x1 + slack
                        and pos.y >= seg.y0 - slack and pos.y <= seg.y1 + slack then
                        return link.uri
                    end
                end
            elseif x0 and x1 and y0 and y1 then
                local left, right = math.min(x0, x1), math.max(x0, x1)
                local top, bottom = math.min(y0, y1), math.max(y0, y1)
                if pos.x >= left - slack and pos.x <= right + slack
                    and pos.y >= top - slack and pos.y <= bottom + slack then
                    return link.uri
                end
            end
        end
    end
    return nil
end

local function on_tap(ui, ges)
    local uri = Reader.link_uri_at(ui, ges and ges.pos)
    if type(uri) ~= "string" or uri:sub(1, 3) ~= Book.ACTION_SCHEME then
        return false
    end
    local ok, err = pcall(function()
        require("kt_book_session").handle_uri(uri)
    end)
    if not ok then
        logger.warn("kotavern/book: kt: link failed:", tostring(err))
    end
    -- Consume every kt: link, even when the action is unknown: letting
    -- ReaderLink see it would open the "invalid/external link" dialog.
    return true
end

-- === Install / uninstall ===

local function install_listener(ui)
    if ui._kt_book_listener then return end
    local listener = WidgetContainer:new{}
    listener.onEndOfBook = function()
        -- Always consume: ReaderStatus would mark the book as finished and
        -- bounce the user into the file manager.
        pcall(function()
            require("kt_book_session").on_end_of_book()
        end)
        return true
    end
    listener.onCloseWidget = function()
        require("kt_book_session").on_close_widget(ui)
    end
    -- Position 2, never 1: child 1 is the readerview and must keep painting.
    table.insert(ui, 2, listener)
    ui._kt_book_listener = listener
end

local function install_tap_zone(ui)
    if not ui.registerTouchZones then return end
    ui:registerTouchZones({
        {
            id = TAP_ZONE_ID,
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1,
            },
            overrides = { "tap_link" },
            handler = function(ges) return on_tap(ui, ges) end,
        },
    })
end

local function install_menu(ui)
    if not ui.menu or not ui.menu.registerToMainMenu then return end
    ui.menu:registerToMainMenu({
        addToMainMenu = function(menu_items)
            pcall(function()
                require("kt_book_ui").add_to_main_menu(menu_items)
            end)
        end,
    })
end

-- Called from main.lua when the plugin is instantiated inside a ReaderUI.
function Reader.on_reader_init(ui)
    local file = ui and ui.document and ui.document.file
    if not file or not Book.is_book_path(file) then
        return false
    end

    local Session = require("kt_book_session")
    if not Session.attach(ui) then
        -- Generated book opened outside the app (file manager after a
        -- restart): stay read-only. History is still suppressed.
        return false
    end

    -- CRITICAL (HTML is a CreDocument): ReaderHighlight:onTap reads
    -- `self.view.highlight.visible_boxes` without a nil guard, and the field
    -- only becomes a table inside ReaderView:drawSavedHighlight. The first
    -- tap can land before that runs.
    local view = ui.view
    if view and view.highlight and view.highlight.visible_boxes == nil then
        view.highlight.visible_boxes = {}
    end

    ui:registerPostInitCallback(function()
        install_listener(ui)
        install_tap_zone(ui)
        install_menu(ui)
    end)
    ui:registerPostReaderReadyCallback(function()
        Session.apply_initial_position(ui)
    end)
    return true
end

function Reader.open(book_path)
    local Event = require("ui/event")
    local ReaderUI = require("apps/reader/readerui")
    -- SetupShowReader is required before showReader: without it the reader
    -- opens and tears itself down immediately.
    UIManager:broadcastEvent(Event:new("SetupShowReader"))
    ReaderUI:showReader(book_path)
end

-- Remove our chrome from a closing reader. The listener is detached on the
-- next tick: removing a child while KOReader is propagating the CloseWidget
-- event would shift the container and swallow the event for the widgets
-- after ours.
function Reader.uninstall(ui)
    if not ui then return end
    local listener = ui._kt_book_listener
    ui._kt_book_listener = nil
    pcall(function()
        ui:unRegisterTouchZones({
            { id = TAP_ZONE_ID, overrides = { "tap_link" } },
        })
    end)
    if listener then
        UIManager:nextTick(function()
            for i = #ui, 1, -1 do
                if ui[i] == listener then
                    table.remove(ui, i)
                end
            end
        end)
    end
end

-- Force a repaint of the reader after a position change (used by the UI).
function Reader.refresh(ui)
    if ui then
        UIManager:setDirty(ui, "ui")
    end
end

return Reader
