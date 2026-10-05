-- Bottom navigation bar rendering for AppView.
-- Uses the shared Bar helper so the nav icons are exactly the same size as
-- the dashboard toolbar's (and nothing overflows the bar).

local P = require("ktui/primitives")
local Theme = require("ktui/theme")
local Bar = require("ktui/bar")
local _ = require("gettext")

local Nav = {}

-- msgids only here: translating at require time would freeze the labels in
-- the boot language forever (I18n.install runs later). Nav.labels()
-- resolves them at paint time so switching language updates the bar.
local NAV_ITEMS = {
    { id = "dashboard",  msgid = "Home",     icon = "home" },
    { id = "chats",      msgid = "Chats",    icon = "comments" },
    { id = "connections", msgid = "API",     icon = "plug" },
    { id = "settings",   msgid = "Settings", icon = "cog" },
}

-- Translated tab labels in item order (pure: follows the active language).
function Nav.labels()
    local out = {}
    for i, item in ipairs(NAV_ITEMS) do
        out[i] = _(item.msgid)
    end
    return out
end

function Nav.draw(view, bb, x, y, w, h)
    local m = Theme.metrics()
    local pad = m.pad
    local n = #NAV_ITEMS
    local item_w = math.floor(w / n)

    -- Background
    P.box(bb, x, y, w, h, { border = false, background = Theme.panel })
    -- Top border (ZenPM: 2px muted line separating content from the nav)
    P.rect(bb, x, y, w, Theme.scale(2), Theme.muted)

    local current_page = view.app.state.page

    for i, item in ipairs(NAV_ITEMS) do
        local ix = x + (i - 1) * item_w
        local iw = (i == n) and (w - (i - 1) * item_w) or item_w
        local is_active = (current_page == item.id)
        local is_dashboard = (current_page == "dashboard" and item.id == "dashboard")

        Bar.item(view, bb, ix, y, iw, h, {
            icon = item.icon,
            label = _(item.msgid),
            active = is_active or is_dashboard,
            cb = function()
                if item.id == "dashboard" then
                    view.app:show_dashboard()
                elseif item.id == "chats" then
                    view.app:show_chats()
                elseif item.id == "connections" then
                    view.app:show_connections()
                elseif item.id == "settings" then
                    view.app:show_settings()
                end
            end,
        }, {
            indicator = true,
            label_bottom = true,
            max_icon = Theme.scale(22),
            min_icon = Theme.scale(10),
        })

        -- ZenPM-style circular badge (Chats tab): number of chats modified
        -- since the last time the Chats page was opened. Drawn after Bar.item
        -- so it sits over the tab without affecting its hitbox (taps open
        -- Chats either way).
        if item.id == "chats" and view.app.chats_unseen_count then
            local unseen = view.app:chats_unseen_count()
            if unseen > 0 then
                local badge_s = Theme.scale(24)
                local badge_x = ix + iw - badge_s - Theme.scale(8)
                local badge_y = y + Theme.scale(5)
                P.box(bb, badge_x, badge_y, badge_s, badge_s, {
                    border = false,
                    background = Theme.ink,
                    radius = math.floor(badge_s / 2),
                })
                local Font = require("ui/font")
                local badge_face = unseen >= 10
                    and Font:getFace("smallinfofont", Theme.font_scale(12)) or nil
                P.center_text_box(bb, tostring(unseen), badge_x, badge_y - Theme.scale(3),
                    badge_s, badge_s, "tiny", { bold = true, color = Theme.bg, face = badge_face })
            end
        end
    end
end

return Nav
