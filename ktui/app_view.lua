-- AppView is the root InputContainer for KOTavern.
-- Handles: gestures, paint pipeline, hitbox detection.
-- Pattern: ZenPM canvas-based rendering.

local Device = require("device")
local Input = require("device/input")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")

local Header = require("ktui/header")
local Nav = require("ktui/nav")
local P = require("ktui/primitives")
local Pages = require("ktui/pages")
local Scroll = require("ktui/scroll")
local Sheets = require("ktui/sheets")
local Theme = require("ktui/theme")

local Screen = Device.screen

local AppView = InputContainer:extend{
    modal = false,
    stop_events_propagation = true,
}

function AppView:init()
    self.hitboxes = {}
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapKotavern = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            },
        },
        SwipeKotavern = {
            GestureRange:new{
                ges = "swipe",
                range = self.dimen,
            },
        },
        PanKotavern = {
            GestureRange:new{
                ges = "pan",
                range = self.dimen,
            },
        },
        PanReleaseKotavern = {
            GestureRange:new{
                ges = "pan_release",
                range = self.dimen,
            },
        },
        HoldKotavern = {
            GestureRange:new{
                ges = "hold",
                range = self.dimen,
            },
        },
    }
    if Device:hasKeys() then
        self.key_events = {
            KotavernPageForward = { { Input.group.PgFwd }, event = "KotavernScroll", args = 1 },
            KotavernPageBack = { { Input.group.PgBack }, event = "KotavernScroll", args = -1 },
        }
    end
end

function AppView:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    return self.dimen
end

-- === Gesture handlers ===

function AppView:onTapKotavern(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    for i = #self.hitboxes, 1, -1 do
        local box = self.hitboxes[i]
        if P.contains(box, x, y) then
            box.callback(x, y)
            return true
        end
    end
    -- Sheets sit on top of everything: a tap on their dimmed backdrop that
    -- misses the panel must close the sheet, NOT pass through to KOReader's
    -- menu (the backdrop hit above only covers the panel's own area).
    if Sheets.active(self.app) then
        Sheets.close(self.app)
        return true
    end
    -- Book style page turn (KOReader reader parity: DTAP_ZONE_BACKWARD is
    -- the left quarter, DTAP_ZONE_FORWARD the right three quarters): a tap
    -- that hit no hitbox turns one page instead of doing nothing. Message
    -- taps, hold, kebab and the sheet above keep priority.
    if self.app.state.page == "chat" and Theme.get_bubble_style() == "book"
        and self.dimen and self.dimen.w and self.dimen.w > 0 then
        local rx = x - (self.dimen.x or 0)
        if rx < self.dimen.w * 0.25 then
            self:_scroll_list(-1)
            return true
        elseif rx > self.dimen.w * 0.25 then
            self:_scroll_list(1)
            return true
        end
    end
    if self:tap_should_pass_to_koreader_menu(ges) then
        return self:show_koreader_menu_from_gesture(ges, "tap")
    end
    return true
end

-- Long-press: only hitboxes that declare on_hold react (message bubbles);
-- everything else keeps today's fallthrough behavior (return false).
function AppView:onHoldKotavern(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    for i = #self.hitboxes, 1, -1 do
        local box = self.hitboxes[i]
        if box.on_hold and P.contains(box, x, y) then
            box.on_hold(x, y)
            return true
        end
    end
    return false
end

-- KOReader menu passthrough (ported from ZenPM): taps/swipes in the title-bar
-- zone that miss every hitbox open KOReader's own menu, when the user's
-- activate_menu setting allows that gesture kind. The header registers its
-- rectangle as view.koreader_menu_zone.
function AppView:tap_menu_enabled()
    local activation = G_reader_settings
        and G_reader_settings.readSetting
        and G_reader_settings:readSetting("activate_menu")
        or "swipe_tap"
    return activation == "tap" or activation == "swipe_tap"
        or activation == "tap_swipe" or activation == "both"
end

function AppView:tap_in_koreader_menu_zone(ges)
    local pos = ges and ges.pos
    return pos and self.koreader_menu_zone and P.contains(self.koreader_menu_zone, pos.x, pos.y)
end

function AppView:tap_should_pass_to_koreader_menu(ges)
    return self:tap_menu_enabled() and self:tap_in_koreader_menu_zone(ges)
end

function AppView:gesture_in_menu_zone(ges)
    local pos = ges and ges.pos
    return pos and self.koreader_menu_zone and P.contains(self.koreader_menu_zone, pos.x, pos.y)
end

function AppView:show_koreader_menu_from_gesture(ges, kind)
    if kind == "tap" then
        if not self:tap_menu_enabled() or not self:tap_in_koreader_menu_zone(ges) then
            return false
        end
    elseif not self:gesture_in_menu_zone(ges) then
        return false
    else
        local activation = G_reader_settings
            and G_reader_settings.readSetting
            and G_reader_settings:readSetting("activate_menu")
            or "swipe_tap"
        if activation ~= "swipe_tap" and activation ~= "tap_swipe"
            and activation ~= "both" and activation ~= kind then
            return false
        end
    end
    local plugin = self.app and self.app.plugin
    local ui = plugin and plugin.ui
    local menu = ui and ui.menu
    if not menu then
        return false
    end
    if kind == "swipe" and menu.onSwipeShowMenu then
        local ok = pcall(function() menu:onSwipeShowMenu(ges) end)
        return ok
    elseif kind == "tap" and menu.onTapShowMenu then
        local ok = pcall(function() menu:onTapShowMenu(ges) end)
        return ok
    elseif menu.onShowMenu then
        local ok = pcall(function() menu:onShowMenu() end)
        return ok
    end
    return false
end

function AppView:onSwipeKotavern(_, ges)
    -- A fast scrollbar drag can terminate as a swipe rather than pan_release.
    -- Finalize the in-progress drag with a clean repaint and consume the
    -- event, so it neither leaks a stuck drag flag nor double-scrolls via the
    -- paging logic below.
    if self._scroll_dragging then
        self:_end_scroll_drag(nil)
        return true
    end
    local direction = ges.direction
    if Sheets.active(self.app) then
        -- Modal sheet: vertical swipes scroll the sheet, a swipe DOWN that
        -- started above the panel closes it (bottom-sheet affordance), and
        -- anything else is consumed so the page underneath never reacts.
        if direction == "north" then
            Sheets.scroll_by(self.app, self.swipe_step or math.floor(Screen:getHeight() * 0.3))
        elseif direction == "south" then
            local panel_top = Sheets.panel_top(self.app)
            if panel_top and ges.start_pos and ges.start_pos.y < panel_top then
                Sheets.close(self.app)
            else
                Sheets.scroll_by(self.app, -(self.swipe_step or math.floor(Screen:getHeight() * 0.3)))
            end
        end
        return true
    end
    if direction == "west" or direction == "east" then
        -- Horizontal swipe on the chat page cycles swipes of the last
        -- assistant message (SillyTavern-style).
        if self.app.state.page == "chat" and not self.app.state.is_generating then
            local msgs = self.app.state.messages
            for i = #msgs, 1, -1 do
                local msg = msgs[i]
                if msg.role == "assistant" and msg.swipes and #msg.swipes > 1 then
                    self.app:cycle_swipe(i, direction == "west" and 1 or -1)
                    break
                end
            end
        end
        return true
    end
    if direction ~= "north" and direction ~= "south" then
        return true
    end
    -- Swipe down over the title bar may open KOReader's menu (gated by the
    -- activate_menu setting); otherwise it scrolls the page up.
    if direction == "south" and self:show_koreader_menu_from_gesture(ges, "swipe") then
        return true
    end
    if self.list_bounds and not P.contains(self.list_bounds, ges.pos.x, ges.pos.y) then
        return true
    end
    -- Fixed single step per flick (zenpm parity): every list owns a small
    -- row-sized step (chat: a few text lines). Distance-scaled jumps were
    -- tried and reverted - on e-ink they read as uncontrolled leaps.
    self:_scroll_list(direction == "north" and 1 or -1)
    return true
end

function AppView:onPanKotavern(_, ges)
    -- Mouse wheel (SDL / some e-readers): scroll by line steps. Without this
    -- the wheel events fall through to the scrollbar-zone check below and die,
    -- so wheel scrolling would do nothing on every page.
    if ges.mousewheel_direction then
        self._mousewheel_handled = true
        if Sheets.active(self.app) then
            if ges.direction == "north" then
                Sheets.scroll_by(self.app, Theme.scale(60))
            elseif ges.direction == "south" then
                Sheets.scroll_by(self.app, -Theme.scale(60))
            end
            return true
        end
        if ges.direction == "north" then
            self:_scroll_list(1)
        elseif ges.direction == "south" then
            self:_scroll_list(-1)
        end
        return true
    end

    if Sheets.active(self.app) then
        return true
    end

    if not self._scroll_dragging then
        local sb = self.scrollbar
        -- Grab decision uses the gesture START position: testing the current
        -- finger position made any pan crossing the ~28px gutter jump into
        -- absolute thumb-mapping mid-gesture (violent scroll jump).
        if not sb or sb.travel <= 0 or not ges.start_pos
            or not P.contains(sb.zone, ges.start_pos.x, ges.start_pos.y) then
            return false
        end
        self._scroll_dragging = true
    end

    local rects = Scroll.paint_drag_thumb(self, ges.pos.y)
    if rects then
        for _i = 1, #rects do
            UIManager:setDirty(nil, "fast", Geom:new(rects[_i]))
        end
    end

    if Scroll.apply_y(self, ges.pos.y) then
        self:_note_manual_scroll()
        self._scroll_list_render = self._scroll_list_render or function()
            self:_render_scroll_list()
        end
        UIManager:unschedule(self._scroll_list_render)
        UIManager:scheduleIn(0.18, self._scroll_list_render)
    end
    return true
end

function AppView:onPanReleaseKotavern(_, ges)
    if ges and ges.from_mousewheel then
        if self._mousewheel_handled then
            self._mousewheel_handled = false
            return true
        end
        local relative_y = ges.relative and ges.relative.y
        if relative_y and relative_y < 0 then
            self:_scroll_list(1)
        elseif relative_y and relative_y > 0 then
            self:_scroll_list(-1)
        end
        return true
    end
    if not self._scroll_dragging then
        return false
    end
    self:_end_scroll_drag(ges and ges.pos and ges.pos.y)
    return true
end

-- Finalize a scrollbar drag: drop the pending debounced render, commit the
-- final offset and do one immediate clean repaint of the list.
function AppView:_end_scroll_drag(pos_y)
    self._scroll_dragging = false
    if self._scroll_list_render then
        UIManager:unschedule(self._scroll_list_render)
    end
    if pos_y then
        Scroll.apply_y(self, pos_y)
    end
    self:_snap_book_scroll()
    self:refresh()
end

-- Book style (KOReader readerpaging parity): scroll positions are discrete
-- page starts, never half positions. Snaps the current offset to the
-- nearest page boundary; no-op everywhere else.
function AppView:_snap_book_scroll()
    if self.app.state.page ~= "chat" then
        return false
    end
    if Theme.get_bubble_style() ~= "book" then
        return false
    end
    local page_h = self.swipe_step
    if not page_h or page_h <= 0 then
        return false
    end
    local key = self.app:scroll_key()
    local cur = self.app.state.scroll[key] or 0
    local max_scroll = self.max_scroll or 0
    local pages = math.max(1, math.ceil(((max_scroll or 0)
        + ((self.list_bounds and self.list_bounds.h) or page_h)) / page_h))
    local want = math.max(0, math.min(math.floor(cur / page_h + 0.5), pages - 1))
    local snapped = want * page_h
    if snapped == cur then
        return false
    end
    self.app.state.scroll[key] = snapped
    return true
end

function AppView:onKotavernScroll(steps)
    self:_scroll_list(steps, true)
    return true
end

function AppView:_scroll_list(steps, page_sized)
    local key = self.app:scroll_key()
    local old = self.app.state.scroll[key] or 0
    local delta = self.scroll_step or math.floor(Screen:getHeight() * 0.45)
    if page_sized and self.list_bounds then
        delta = math.floor(self.list_bounds.h * 0.9)
    elseif self.swipe_step then
        -- Chat swipe unit (a few text lines); other pages use scroll_step.
        delta = self.swipe_step
    end
    local new
    if self.app.state.page == "chat" and Theme.get_bubble_style() == "book"
        and self.swipe_step and self.swipe_step > 0 then
        -- Book paging (KOReader readerpaging parity): every gesture lands
        -- on a page start, never a half position. swipe_step IS the snapped
        -- page height here. Forward goes to the next page after the one
        -- containing the offset; back goes to the previous page start.
        local page_h = self.swipe_step
        local viewport = (self.list_bounds and self.list_bounds.h) or page_h
        local pages = math.max(1, math.ceil(((self.max_scroll or 0) + viewport) / page_h))
        local want = math.max(0, math.min(math.floor(old / page_h) + steps, pages - 1))
        new = want * page_h
    else
        new = math.max(0, math.min(old + steps * delta, self.max_scroll or 0))
    end
    if new == old then
        return false
    end
    self.app.state.scroll[key] = new
    self:_note_manual_scroll()
    self:refresh()
    return true
end

function AppView:_render_scroll_list()
    local region = self.scrollbar and self.scrollbar.region or self.dimen
    UIManager:setDirty(self, "ui", Geom:new(region))
end

-- === Paint pipeline ===

function AppView:refresh(full, region)
    UIManager:setDirty(self, full and "full" or "ui",
        region and Geom:new(region) or self.dimen)
end

-- Track manual scrolling while a generation is running: once the user scrolls
-- up to read, chunk-driven auto-follow must stop yanking the view down until
-- they return to the bottom.
function AppView:_note_manual_scroll()
    local app = self.app
    if app.state.is_generating and app.state.page == "chat" then
        local key = app:scroll_key()
        local cur = app.state.scroll[key] or 0
        if cur < (self.max_scroll or 0) then
            app.state.user_scrolled_up = true
        else
            app.state.user_scrolled_up = nil
        end
    end
end

function AppView:onCloseWidget()
    UIManager:setDirty("all", "flashui", self.dimen)
end

function AppView:onClose()
    self.app:close()
    return true
end

function AppView:paintTo(bb, x, y)
    self.hitboxes = {}
    self.list_bounds = nil
    self.scroll_step = nil
    self.swipe_step = nil
    self.scrollbar = nil

    local m = Theme.metrics()
    self.dimen = Geom:new{ x = x, y = y, w = m.screen_w, h = m.screen_h }

    -- Background
    P.rect(bb, x, y, m.screen_w, m.screen_h, Theme.bg)

    -- Content area metrics. The header is drawn LAST (see below): it is an
    -- opaque full-width bar, so it covers any content bleed and its hitboxes
    -- (back/close) win over the pages' (hitboxes are checked in reverse
    -- registration order). This mirrors the chat's bottom action bar.
    -- Header.height accounts for the dashboard's contextual pill toolbar.
    local content_top = y + Header.height(self)

    local is_chat = self.app.state.page == "chat"

    if is_chat then
        -- Chat is fullscreen (no nav bar). Chat page handles its own bottom bar
        local content_h = m.screen_h - (content_top - y)
        -- Region for streaming/pulse partial repaints: everything below the
        -- header. Repainting only this avoids per-chunk shimmer over the
        -- status/header chrome on e-ink.
        self.chat_region = Geom:new{ x = x, y = content_top, w = m.screen_w, h = content_h }
        self:draw_content(bb, x, content_top, m.screen_w, content_h)
    else
        -- Normal pages: nav bar at bottom
        local nav_h = m.nav_h
        local nav_top = y + m.screen_h - nav_h
        local content_h = nav_top - content_top
        self:draw_content(bb, x, content_top, m.screen_w, content_h)
        Nav.draw(self, bb, x, nav_top, m.screen_w, nav_h)
    end

    -- Header on top
    Header.draw(self, bb, x, y, m.screen_w)

    -- Modal action sheet on top of everything (hits registered last win).
    if self.app.state.sheet then
        Sheets.draw(self, bb)
    end
end

function AppView:draw_content(bb, x, y, w, h)
    local state = self.app.state
    local page = state.page
    local scroll_key = self.app:scroll_key()
    local scroll = state.scroll[scroll_key] or 0
    local max_scroll = 0

    if state.loading then
        P.rect(bb, x, y, w, h, Theme.bg)
        P.text(bb, state.loading, x + Theme.scale(16), y + Theme.scale(10), w - Theme.scale(32), "default")
        Scroll.set_list_bounds(self, x, y, w, h, h)
        self.max_scroll = 0
        return
    end

    if state.error then
        Pages.error(self, bb, x, y, w, h, state.error)
        self.max_scroll = 0
        return
    end

    if page == "dashboard" then
        max_scroll = Pages.dashboard(self, bb, x, y, w, h, scroll)
    elseif page == "chats" then
        max_scroll = Pages.chats(self, bb, x, y, w, h, scroll)
    elseif page == "settings" then
        max_scroll = Pages.settings(self, bb, x, y, w, h, scroll)
    elseif page == "settings_appearance" then
        max_scroll = Pages.settings_appearance(self, bb, x, y, w, h, scroll)
    elseif page == "settings_dashboard" then
        max_scroll = Pages.settings_dashboard(self, bb, x, y, w, h, scroll)
    elseif page == "settings_behavior" then
        max_scroll = Pages.settings_behavior(self, bb, x, y, w, h, scroll)
    elseif page == "settings_network" then
        max_scroll = Pages.settings_network(self, bb, x, y, w, h, scroll)
    elseif page == "settings_language" then
        max_scroll = Pages.settings_language(self, bb, x, y, w, h, scroll)
    elseif page == "settings_data" then
        max_scroll = Pages.settings_data(self, bb, x, y, w, h, scroll)
    elseif page == "data_storage" then
        max_scroll = Pages.data_storage(self, bb, x, y, w, h, scroll)
    elseif page == "settings_updates" then
        max_scroll = Pages.settings_updates(self, bb, x, y, w, h, scroll)
    elseif page == "presets" then
        max_scroll = Pages.presets(self, bb, x, y, w, h, scroll)
    elseif page == "connections" then
        max_scroll = Pages.connections(self, bb, x, y, w, h, scroll)
    elseif page == "personas" then
        max_scroll = Pages.personas(self, bb, x, y, w, h, scroll)
    elseif page == "character_editor" then
        max_scroll = Pages.character_editor(self, bb, x, y, w, h, scroll)
    elseif page == "preset_editor" then
        max_scroll = Pages.preset_editor(self, bb, x, y, w, h, scroll)
    elseif page == "connection_editor" then
        max_scroll = Pages.connection_editor(self, bb, x, y, w, h, scroll)
    elseif page == "model_picker" then
        max_scroll = Pages.model_picker(self, bb, x, y, w, h, scroll)
    elseif page == "prompt_manager" then
        max_scroll = Pages.prompt_manager(self, bb, x, y, w, h, scroll)
    elseif page == "regex_scripts" then
        max_scroll = Pages.regex_scripts(self, bb, x, y, w, h, scroll)
    elseif page == "character_view" then
        max_scroll = Pages.character_view(self, bb, x, y, w, h, scroll)
    elseif page == "character_greetings" then
        max_scroll = Pages.character_greetings(self, bb, x, y, w, h, scroll)
    elseif page == "lorebooks" then
        max_scroll = Pages.lorebooks(self, bb, x, y, w, h, scroll)
    elseif page == "lorebook_editor" then
        max_scroll = Pages.lorebook_editor(self, bb, x, y, w, h, scroll)
    elseif page == "lorebook_entry" then
        max_scroll = Pages.lorebook_entry(self, bb, x, y, w, h, scroll)
    elseif page == "chat" then
        max_scroll = Pages.chat(self, bb, x, y, w, h, scroll)
    elseif page == "chat_history" then
        max_scroll = Pages.chat_history(self, bb, x, y, w, h, scroll)
    end

    Scroll.draw_scrollbar(self, bb, max_scroll, scroll)
    -- Book last pages may start past max_scroll (partial tail page): settle
    -- on the last page start instead of max. Every other case clamps back;
    -- switching styles heals itself through the same lines.
    local book_hold = page == "chat" and Theme.get_bubble_style() == "book"
    if scroll > max_scroll then
        if book_hold then
            local page_h = self.swipe_step
            local viewport = self.list_bounds and self.list_bounds.h
            if page_h and page_h > 0 and viewport and viewport > 0 then
                local pages = math.max(1, math.ceil((max_scroll + viewport) / page_h))
                state.scroll[scroll_key] = (pages - 1) * page_h
            else
                state.scroll[scroll_key] = max_scroll
            end
        else
            state.scroll[scroll_key] = max_scroll
        end
    end
    self.max_scroll = max_scroll
end

return AppView
