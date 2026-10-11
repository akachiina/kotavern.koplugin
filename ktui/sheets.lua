-- Canvas action sheets: bottom-sheet menus, pickers and confirmations.
-- Replaces the KOReader stock ButtonDialog/ConfirmBox so every menu in the
-- app shares the canvas look. Text input keeps using KOReader widgets
-- (the keyboard comes for free).
--
-- Sheet state lives in app.state.sheet; AppView.paintTo draws it LAST (over
-- header/nav) and its hitboxes are registered last, so they win every tap.

local P = require("ktui/primitives")
local Theme = require("ktui/theme")
local Icons = require("ktui/icons")
local Geom = require("ktui/geom")
local Widgets = require("ktui/widgets")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local _ = require("gettext")

local Sheets = {}

-- Compositor snapshot for open/close without repainting the page: opening a
-- sheet used to run a full paintTo (every message/card re-measured) plus a
-- full-screen EPDC wave, which is the "takes a while on e-ink" report. The
-- page pixels are already composed on Screen.bb, so show() photographs them,
-- paints scrim+panel over, and close() blits back - zero Lua paint, zero
-- flash, one EPDC wave each way. ~1 screen BB transient (~1.5MB BB8).
local snap_bb = nil

local function free_snap()
    if snap_bb then
        pcall(function() snap_bb:free() end)
        snap_bb = nil
    end
end

-- Drop the snapshot: any full paint makes it stale (action taps repaint,
-- scroll repaints, navigation). Called from AppView:paintTo and App:close.
function Sheets.drop_snapshot()
    free_snap()
end

-- True when our view is the topmost window: only then is Screen.bb known to
-- hold exactly our last paint (a dialog/modal on top would be photographed
-- instead and restored as a ghost later - those cases use the repaint path).
local function top_is_view(app)
    local view = app and app.view
    if not view then return false end
    local stack = UIManager._window_stack
    if type(stack) ~= "table" or #stack == 0 then return false end
    for i = #stack, 1, -1 do
        local w = stack[i] and stack[i].widget
        if w == view then return true end
        if w then return false end
    end
    return false
end

function Sheets.active(app)
    return app.state.sheet ~= nil
end

-- opts: title, text (optional message), actions = {
--   { label, sublabel, icon, on_tap, enabled, danger, checked } }, on_close
-- Page scroll invariant: show() saves the current page scroll and zeroes it
-- (the sheet paints over a scrubbed screen); close() restores the exact
-- saved position when still on the same page (ST parity: menus never move
-- the reading position). confirm() never touches the page scroll.
function Sheets.show(app, opts)
    local view = app.view
    local saved = nil
    if view and view.app and view.app.state then
        local key = view.app:scroll_key()
        saved = { key = key, value = view.app.state.scroll[key] or 0 }
        -- Nested sheet (Options -> Select Persona): the page scroll is
        -- ALREADY zeroed by the outer sheet, so saving "current" here would
        -- snapshot 0 and close() would restore top-of-page. Carry the outer
        -- sheet's position instead (same page key only).
        local prev = app.state.sheet
        if prev and prev._saved_scroll and prev._saved_scroll.key == key then
            saved = prev._saved_scroll
        end
    end
    app.state.sheet = {
        title = opts.title,
        text = opts.text,
        actions = opts.actions or {},
        on_close = opts.on_close,
        scroll = 0,
        _saved_scroll = saved,
        -- UIDSL tree sheet (data-action="menu"): subtree + flag travel with
        -- the state so draw/scroll/close treat it as content, not actions.
        tree = opts.tree,
        uidsl = opts.uidsl,
    }
    -- Drop the page scroll offset: the sheet opens over a scrubbed screen
    -- (no ghost content under the scrim).
    if saved then
        view.app.state.scroll[saved.key] = 0
    end
    -- Fast path: photograph the composed page and paint over it (no page
    -- repaint at all). Falls back to a full refresh when anything covers us.
    if top_is_view(app) then
        free_snap()
        local m = Theme.metrics()
        local ok, shot = pcall(function()
            local bb = Blitbuffer.new(m.screen_w, m.screen_h, Blitbuffer.TYPE_BB8)
            bb:blitFrom(Device.screen.bb, 0, 0, 0, 0, m.screen_w, m.screen_h)
            return bb
        end)
        if ok and shot then
            snap_bb = shot
            Sheets.draw(view, Device.screen.bb)
            UIManager:setDirty(nil, "ui")
            return
        end
        free_snap()
    end
    view:refresh()
end

-- opts: title, text, ok_label (default "Confirm"), cancel_label,
--       danger (ok button emphasized), on_ok
function Sheets.confirm(app, opts)
    app.state.sheet = {
        title = opts.title,
        text = opts.text,
        confirm = true,
        ok_label = opts.ok_label or _("Confirm"),
        cancel_label = opts.cancel_label or _("Cancel"),
        danger = opts.danger,
        on_ok = opts.on_ok,
        scroll = 0,
    }
    app.view:refresh()
end

function Sheets.close(app)
    local sheet = app.state.sheet
    app.state.sheet = nil
    -- Restore the exact pre-sheet scroll position, but only when still on
    -- the same page (an action may have navigated elsewhere - each page owns
    -- its scroll key). The next paint clamps stale values to max_scroll.
    local saved = sheet and sheet._saved_scroll
    if saved and app.state and app.state.scroll
        and type(app.scroll_key) == "function"
        and app:scroll_key() == saved.key then
        app.state.scroll[saved.key] = saved.value
    end
    if sheet and sheet.on_close then
        sheet.on_close()
    end
    -- ALWAYS repaint the view on close. The old fast path blitted the
    -- pre-sheet snapshot straight into Screen.bb and only queued a waveform
    -- (UIManager:setDirty(nil, ...) marks NO widget dirty and queues just
    -- the wave): the view kept the sheet's hitboxes ("tapping Cancel left
    -- ghost menu actions alive") and the blit silently misaligned on real
    -- devices (snapshot BB type/rotation vs Screen.bb - pcall swallows it),
    -- leaving the scrim ghost the dashboard reported. One full "ui"
    -- repaint owns both: the page repaints at its restored scroll and the
    -- sheet's hits die with the paint that erased them. The snapshot still
    -- pays off on open (one wave, no page repaint).
    app.view:refresh()
end

-- Scroll the sheet's action list (kept separate from page scroll).
function Sheets.scroll_by(app, delta)
    local sheet = app.state.sheet
    if not sheet then return false end
    local max = sheet._max_scroll or 0
    local new = math.max(0, math.min((sheet.scroll or 0) + delta, max))
    if new == (sheet.scroll or 0) then return false end
    sheet.scroll = new
    -- Regional repaint: only the panel's rows moved; the page and scrim are
    -- untouched, so a full-dim refresh would repaint identical pixels.
    local rect = Sheets.panel_rect(app)
    if rect then
        app.view:refresh(nil, rect)
    else
        app.view:refresh()
    end
    return true
end

-- Measured height of a UIDSL tree sheet (0 when unavailable): lazy uidsl
-- require keeps the module graph acyclic (uidsl only requires sheets lazily
-- at tap time).
local function tree_measured(sheet, inner_w)
    if not sheet or not sheet.tree then return 0 end
    local ok, UiDSL = pcall(require, "ktui/uidsl")
    if not ok or not UiDSL or not UiDSL.measure then return 0 end
    local okm, h = pcall(UiDSL.measure, sheet.tree, inner_w)
    if not okm or type(h) ~= "number" then return 0 end
    return math.max(0, math.floor(h))
end

-- Compute panel geometry (shared by draw and gesture handlers).
local function panel_geom(view)
    local m = Theme.metrics()
    local sw, sh = m.screen_w, m.screen_h
    local margin = Theme.scale(12)
    local px, pw = margin, sw - margin * 2
    local sheet = view.app.state.sheet
    -- Two-line rows (label + sublabel) need a taller slot: a single-line
    -- row_h makes every sublabel overflow into the next row, which crammed
    -- the Author's Note sheet into unreadable overlaps (v0.6.8).
    local has_sublabel = false
    if sheet and type(sheet.actions) == "table" then
        for _i, a in ipairs(sheet.actions) do
            if a.sublabel then has_sublabel = true break end
        end
    end
    local row_h
    if has_sublabel then
        row_h = math.max(Theme.scale(48), Theme.line_h("default")
            + Theme.scale(2) + Theme.line_h("tiny") + Theme.scale(12))
    else
        row_h = math.max(Theme.scale(44), Theme.line_h("default") + Theme.scale(16))
    end
    local title_h = Theme.line_h("small") + Theme.scale(14)
    local pad = Theme.pad or Theme.scale(12)
    local max_h = sh - m.titlebar_h - Theme.scale(20)

    local body_h = 0
    if sheet and sheet.confirm then
        -- Reserve the REAL painted height (TextBoxWidget paints ~1px/line
        -- taller than the nominal lines*line_h): the nominal budget let long
        -- confirm text creep into the Cancel/OK row.
        local text_h = (sheet.text and sheet.text ~= "")
            and P.paragraph_height(sheet.text, pw - pad * 2, "default") or 0
        body_h = Theme.scale(6) + title_h
            + (text_h > 0 and (text_h + Theme.scale(12)) or 0)
            + Theme.btn_h() + Theme.scale(12)
    else
        local n = sheet and #sheet.actions or 0
        body_h = Theme.scale(6) + title_h + n * row_h + Theme.scale(12)
            + Theme.btn_h() + Theme.scale(12)
    end

    -- UIDSL tree sheet (data-action="menu"): the band shows what fits of the
    -- measured tree (capped like rows); the rest scrolls. Empty tree still
    -- gets title + Cancel chrome.
    if sheet and sheet.tree and not sheet.confirm then
        local inner_w = math.max(1, pw - pad * 2)
        local tree_total = tree_measured(sheet, inner_w)
        local fixed = Theme.scale(6) + title_h + Theme.scale(12)
            + Theme.btn_h() + Theme.scale(12)
        local avail = math.max(0, max_h - fixed)
        body_h = fixed + math.min(tree_total, avail)
    end

    local ph = math.min(body_h, max_h)
    local py = sh - ph - Theme.scale(10)
    return px, py, pw, ph, row_h, title_h, pad, max_h
end

-- Top edge of the sheet panel (for the swipe-down-to-close gesture).
function Sheets.panel_top(app)
    local view = app.view
    if not view then return nil end
    local _, py = panel_geom(view)
    return py
end

-- Full panel rectangle: the modal tap policy in AppView:onTapKotavern only
-- lets taps inside this rect reach sheet controls, and scroll_by scopes its
-- regional repaint to it.
function Sheets.panel_rect(app)
    local view = app.view
    if not view then return nil end
    local px, py, pw, ph = panel_geom(view)
    return { x = px, y = py, w = pw, h = ph }
end

-- Mini scrollbar affordance (display-only; swipe/wheel already scroll): slim
-- track at the panel's right edge with a proportional thumb, so cut content
-- reads as "more below". Shared by action rows and UIDSL tree sheets.
local function paint_scrollbar(bb, px, pw, pad, list_top, list_bottom,
    scroll, max_scroll)
    if max_scroll <= 0 then return end
    local band_h = list_bottom - list_top
    if band_h <= 0 then return end
    local track_x = px + pw - pad - Theme.scale(7)
    local track_w = Theme.scale(7)
    P.rect(bb, track_x, list_top, track_w, band_h, Theme.soft)
    local total = max_scroll + band_h
    local thumb_h = math.max(Theme.scale(12),
        math.floor(band_h * band_h / math.max(1, total)))
    thumb_h = math.min(band_h, thumb_h)
    local travel = band_h - thumb_h
    local thumb_y = list_top
        + (travel > 0 and math.floor(travel * scroll / max_scroll) or 0)
    P.rect(bb, track_x, thumb_y, track_w, thumb_h, Theme.ink)
end

function Sheets.draw(view, bb)
    local app = view.app
    local sheet = app.state.sheet
    if not sheet then return end

    local m = Theme.metrics()
    local px, py, pw, ph, row_h, title_h, pad, max_h = panel_geom(view)

    -- Scrim the whole screen (page + chrome are already painted underneath).
    P.scrim(bb, 0, 0, m.screen_w, m.screen_h, 0.3)

    -- Tap-anywhere-to-dismiss (registered FIRST inside the sheet, so panel
    -- hits registered after it are checked before it).
    P.hit(view, 0, 0, m.screen_w, m.screen_h, function() Sheets.close(app) end, "sheet:dismiss")

    -- Panel
    P.box(bb, px, py, pw, ph, {
        border = true, border_size = 1, border_color = Theme.soft,
        background = Theme.panel, radius = Theme.scale(10),
    })

    local cy = py + Theme.scale(6)

    -- Title
    if sheet.title and sheet.title ~= "" then
        P.text(bb, Widgets.sanitize(sheet.title), px + pad, cy, pw - pad * 2, "small", { bold = true, color = Theme.muted })
    end
    cy = cy + title_h

    if sheet.confirm then
        -- Message
        if sheet.text and sheet.text ~= "" then
            local text_h = P.paragraph_height(sheet.text, pw - pad * 2, "default")
            P.paragraph(bb, sheet.text, px + pad, cy, pw - pad * 2, text_h, "default")
            cy = cy + text_h + Theme.scale(12)
        end
        -- Cancel / OK
        local gap = Theme.scale(8)
        local bw = math.floor((pw - pad * 2 - gap) / 2)
        Widgets.button(view, bb, {
            x = px + pad, y = cy, w = bw, h = Theme.btn_h(),
            label = sheet.cancel_label, kind = "secondary",
            hit_label = "sheet:cancel",
            on_tap = function() Sheets.close(app) end,
        })
        Widgets.button(view, bb, {
            x = px + pad + bw + gap, y = cy, w = bw, h = Theme.btn_h(),
            label = sheet.ok_label, icon = sheet.danger and "trash" or "check",
            kind = "primary", hit_label = "sheet:ok", on_tap = function()
                app.state.sheet = nil
                if sheet.on_ok then sheet.on_ok() end
                app.view:refresh()
            end,
        })
    else
        -- Content band geometry is shared: action rows size it by row count,
        -- UIDSL trees by measured height. list_bottom matches the Cancel
        -- button top exactly, and body_h reserves the same band, so content
        -- fits the panel with zero slack (no culling when it fits).
        local list_top = cy
        local list_bottom = py + ph - Theme.scale(12) - Theme.btn_h()
        local list_h, total_h
        if sheet.tree then
            list_h = math.max(1, list_bottom - list_top)
            total_h = tree_measured(sheet, math.max(1, pw - pad * 2))
        else
            list_h = math.max(row_h, list_bottom - list_top)
            total_h = #(sheet.actions or {}) * row_h
        end
        local max_scroll = math.max(0, total_h - list_h)
        sheet._max_scroll = max_scroll
        local scroll = math.min(sheet.scroll or 0, max_scroll)
        -- Mini scrollbar affordance (display-only; swipe/wheel already
        -- scroll): slim track at the panel's right edge with a proportional
        -- thumb, so a cut bottom row reads as "more below". Rows yield its
        -- width (the list gutter pattern) so ink never underlaps the track.
        local scrollable = max_scroll > 0
        local sb_gutter = scrollable and (Theme.scale(7) + Theme.scale(4)) or 0

        if sheet.tree then
            -- UIDSL tree sheet (data-action="menu"): binds live per paint
            -- (sandbox parity), tree painted offset by -scroll and clipped
            -- to the band; scroll/scrollbar/Cancel behave like action rows.
            local ok_u, UiDSL = pcall(require, "ktui/uidsl")
            if ok_u and UiDSL and total_h > 0 then
                UiDSL.resolve_binds(sheet.tree, app, {})
                local inner_w = math.max(1, pw - pad * 2)
                P.rect(bb, px + 1, list_top, pw - 2, list_h, Theme.panel)
                UiDSL.paint(sheet.tree, bb, px + pad, list_top - scroll,
                    inner_w, view,
                    { x = px, y = list_top, w = pw, h = list_h })
            end
        else

        -- Clip region: paint a bg rect then rows offset by -scroll. Rows that
        -- don't fit are skipped (same culling rule as scrolled_list).
        P.rect(bb, px + 1, list_top - (scroll > 0 and Theme.scale(6) or 0), pw - 2, list_h + (scroll > 0 and Theme.scale(6) or 0), Theme.panel)
        local ay = list_top - scroll
        for i, action in ipairs(sheet.actions or {}) do
            -- Strict culling: rows never bleed over the title or Cancel
            if ay >= list_top and ay + row_h <= list_bottom + 1 then
                local enabled = action.enabled ~= false
                local color = (not enabled) and Theme.muted or (action.danger and Theme.danger or Theme.ink)
                local tx = px + pad
                local text_right = px + pw - pad - Theme.scale(30) - sb_gutter
                if action.icon then
                    local icon_size = Theme.scale(13)
                    local isz = Icons.text_size(action.icon, icon_size)
                    Icons.draw(bb, action.icon, tx, ay + math.floor((row_h - isz.h) / 2), icon_size, { color = color })
                    tx = tx + isz.w + Theme.scale(12)
                end
                local label_w = text_right - tx
                if action.sublabel then
                    local tlh = Theme.line_h("default")
                    local slh = Theme.line_h("tiny")
                    local block = tlh + Theme.scale(1) + slh
                    local by = ay + math.floor((row_h - block) / 2)
                    P.text(bb, Widgets.sanitize(action.label), tx, by, label_w, "default", { bold = enabled, color = color })
                    P.text(bb, action.sublabel, tx, by + tlh + Theme.scale(1), label_w, "tiny", { color = Theme.muted })
                else
                    P.vcenter_text(bb, Widgets.sanitize(action.label), tx, ay, label_w, row_h, "default", { bold = enabled, color = color })
                    if action.danger and enabled then
                        -- No red on e-ink: a rule under the label is what
                        -- makes destructive rows distinguishable from normal
                        -- ones (danger == ink in both palettes). Anchor it to
                        -- the same centering P.vcenter_text uses (measured box
                        -- centered in row_h), not an assumed row_h/2 center.
                        local tsz = P.text_size(Widgets.sanitize(action.label), label_w, "default")
                        local uy = ay + Geom.center_offset(row_h, tsz.h) + tsz.h + Theme.scale(2)
                        P.rect(bb, tx, uy, math.min(tsz.w, label_w), math.max(1, Theme.scale(1)), color)
                    end
                end
                if action.checked then
                    local icon_size = Theme.scale(12)
                    local isz = Icons.text_size("check", icon_size)
                    local cx = px + pw - pad - isz.w - Theme.scale(4) - sb_gutter
                    Icons.draw(bb, "check", cx, ay + math.floor((row_h - isz.h) / 2), icon_size, { color = Theme.ink })
                end
                local idx = i
                -- Disabled rows paint muted and register NO hit (same contract
                -- as W.button / header pills): a visibly disabled row must not
                -- tear down the sheet on tap.
                if enabled then
                    P.hit(view, px + 1, ay, pw - 2, row_h, function()
                        local act = sheet.actions[idx]
                        -- Close through Sheets.close (never bare nil): it
                        -- restores the pre-sheet page scroll on the same page.
                        -- Bare nil skipped the restore, so a row that opened
                        -- a nested sheet (Options -> Select Persona) snapshotted
                        -- the already-zeroed offset and close() put the page
                        -- back at the top. No on_close side effects exist.
                        Sheets.close(app)
                        if act and act.on_tap then
                            act.on_tap()
                        end
                    end, "sheet:" .. tostring(action.label))
                end
            end
            ay = ay + row_h
        end
        end

        paint_scrollbar(bb, px, pw, pad, list_top, list_bottom, scroll,
            max_scroll)

        -- Cancel
        local cancel_y = list_bottom
        Widgets.button(view, bb, {
            x = px + pad, y = cancel_y, w = pw - pad * 2, h = Theme.btn_h(),
            label = _("Cancel"), kind = "secondary",
            hit_label = "sheet:cancel",
            on_tap = function() Sheets.close(app) end,
        })
    end
end

return Sheets
