-- Minimal frame player for tiny easter-egg animations (debug banner).
-- Loads frames ONCE (capped), advances on a timer, and pushes frames to the
-- screen WITHOUT a full widget repaint: the tick blits the frame straight
-- into the compositor buffer (Screen.bb, the same trick the scrollbar thumb
-- uses) and refreshes only the banner rectangle. No looping forever outside
-- its page: players self-stop on page change and the caller must
-- GifAnim.stop_all(app) on navigate/close, or the timer eats battery.
--
-- Sources (see load_frames): a directory of pre-composited full frames (the
-- banner ships this way - the raw GIF's delta sub-rects cannot play through
-- KOReader's giflib) or a .gif via RenderImage want_frames.
--
-- GifAnim.draw is the ONE frame painter, used by both the page paint
-- (banner draw inside paintTo) and the tick (direct blit): it clears the
-- box with the page background first and alpha-blits the frame centered
-- (alphablitFrom, raw blitFrom fallback).
--
-- Lifecycle: the timer self-stops when the page changes (any navigation
-- path that forgot stop_all leaks for at most one interval), pauses while
-- another widget (a modal) covers our view, and stop/stop_all free
-- everything. The decoded GIF document is released right after its frames
-- are materialized, so the full decode is never pinned in RAM.

local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local RenderImage = require("ui/renderimage")
local Theme = require("ktui/theme")

local Screen = Device.screen

local GifAnim = {}

GifAnim.MAX_FRAMES = 24
GifAnim.INTERVAL = 0.12 -- ~8fps: e-ink friendly, still reads as motion
-- Direct-to-compositor painting. Tests set this false to exercise the
-- widget-repaint fallback path (fake views are not in the window stack).
GifAnim.DIRECT = true

local function free_bb(bb)
    if bb and type(bb.free) == "function" then
        pcall(function() bb:free() end)
    end
end

function GifAnim.stop(player)
    if not player then
        return
    end
    player.stopped = true
    -- UIManager matches queued tasks by the action function itself.
    if player.tick then
        pcall(UIManager.unschedule, UIManager, player.tick)
        player.tick = nil
    end
    -- Settle once with a full-quality refresh: ticks run pure a2 (no blink,
    -- ghost masked by motion), so a player stopping with the page standing
    -- still leaves one crisp region behind. Page changes repaint fully anyway.
    if player.rects then
        for _, rect in ipairs(player.rects) do
            if rect and (rect.w or 0) > 0 and (rect.h or 0) > 0 then
                pcall(UIManager.setDirty, UIManager, nil, "ui", Geom:new(rect))
            end
        end
    end
    if player.bbs then
        for _, bb in ipairs(player.bbs) do
            free_bb(bb)
        end
        player.bbs = nil
    end
    if player.frames and player.frames.free then
        pcall(function() player.frames:free() end)
        player.frames = nil
    end
end

function GifAnim.stop_all(app)
    local players = app and app.state and app.state.gif_players
    if type(players) ~= "table" then
        return
    end
    app.state.gif_players = nil
    for _, player in pairs(players) do
        GifAnim.stop(player)
    end
end

-- Current frame buffer (or nil when nothing is playing).
function GifAnim.frame(player)
    if not player or player.stopped or not player.bbs then
        return nil
    end
    return player.bbs[player.idx] or player.bbs[1]
end

-- Draw the current frame centered inside (x, y, w, h) on any blitbuffer.
-- The box is cleared with Theme.bg first: frames blit over what was already
-- there, and a raw blit leaves the previous frame's opaque pixels as a
-- trail behind the transparent parts of the next one. Alpha-carrying frames
-- blend via alphablitFrom (raw blit on fallback). Returns false when there
-- is no frame (the caller paints its static fallback).
-- clip (optional {x,y,w,h}): only the intersection is drawn - used by the
-- tick to keep DIRECT blits inside the view's content region (a rect
-- registered while the node was partially visible must never spill onto
-- the nav bar or the error strip).
function GifAnim.draw(player, bb, x, y, w, h, clip)
    if not player or not bb or not w or w <= 0 or not h or h <= 0 then
        return false
    end
    if clip then
        local x2 = math.max(x, clip.x)
        local y2 = math.max(y, clip.y)
        local x3 = math.min(x + w, clip.x + (clip.w or 0))
        local y3 = math.min(y + h, clip.y + (clip.h or 0))
        if x2 >= x3 or y2 >= y3 then
            return false
        end
        return GifAnim.draw(player, bb, x2, y2, x3 - x2, y3 - y2)
    end
    local frame = GifAnim.frame(player)
    if not frame then
        return false
    end
    -- Clear FIRST (see the header note about transparent pixels/trails).
    pcall(function() bb:paintRect(x, y, w, h, Theme.bg) end)
    local fw = math.min(w, frame:getWidth())
    local fh = math.min(h, frame:getHeight())
    local fx = x + math.floor((w - fw) / 2)
    local fy = y + math.floor((h - fh) / 2)
    local ok = pcall(function()
        bb:alphablitFrom(frame, fx, fy, 0, 0, fw, fh)
    end)
    if not ok then
        pcall(function() bb:blitFrom(frame, fx, fy, 0, 0, fw, fh) end)
    end
    return true
end

-- True when something sits ABOVE our view in the window stack (a KOReader
-- modal, dialog, keyboard, or another fullscreen app like the File Manager):
-- the animation pauses under them instead of blitting into the region they
-- cover. Top-down scan: ANY widget found before ours hides us - it does not
-- matter whether it declares covers_fullscreen, modals always paint over
-- what is below. Our view missing from the stack entirely also means hidden
-- (plugin closed but a player still ticking). An uninspectable/empty stack
-- means "assume visible" (tests drive both paths via GifAnim.DIRECT).
function GifAnim._obscured(view)
    local stack = UIManager._window_stack
    if type(stack) ~= "table" or #stack == 0 then
        return false
    end
    for i = #stack, 1, -1 do
        local w = stack[i] and stack[i].widget
        if w == view then
            return false -- reached our view first: nothing covers it
        end
        if w then
            return true -- something is stacked above our view: covered
        end
    end
    return true -- our view is not on the stack at all: not being displayed
end

-- Rect guard: a tick may only paint where the page actually shows the
-- animation. Without this, a rect captured while the node was visible (then
-- scrolled out / clipped by the page) keeps blitting frames straight into
-- the compositor buffer OVER whatever is there now - nav bar, error strip,
-- other pages' chrome - because nothing repaints a direct blit afterwards.
-- No content_region on the view (fake views in tests, plain widgets) means
-- "no clip info": assume visible, as before.
local function rects_intersect(a, b)
    return a and b
        and (a.w or 0) > 0 and (a.h or 0) > 0
        and a.x < b.x + (b.w or 0) and b.x < a.x + (a.w or 0)
        and a.y < b.y + (b.h or 0) and b.y < a.y + (a.h or 0)
end

function GifAnim._rect_visible(view, rect)
    if not rect then return false end
    local cr = view and view.content_region
    if not cr then return true end
    return rects_intersect(rect, cr)
end

-- Rects are only valid for the paint that registered them: AppView:paintTo
-- calls this BEFORE painting, so any rect a tick still holds from a previous
-- paint is stale (the page scrolled/moved) and stops animating. Each paint
-- re-registers the current positions (see ensure()). Without this, a drag
-- would leave every passed position animating - the "sonic multiplies" bug.
function GifAnim.invalidate_rects(view)
    local players = view and view.app and view.app.state
        and view.app.state.gif_players
    if type(players) ~= "table" then return end
    for _, player in pairs(players) do
        if not player.stopped and player.view == view then
            player.rects = nil
            player.rect = nil
        end
    end
end

-- Advance one frame onto the screen. DIRECT: paint Screen.bb and refresh
-- only each animation region (no widget repaint). Fallback: the
-- widget-repaint path (rect-less callers, tests, odd compositors).
-- One player may drive several on-screen instances of the same source
-- (same src + height -> same key): every painted instance registers its
-- rect via ensure(), and the tick pushes the frame to each visible one.
local function push_frame(player)
    local view = player.view
    if not view then
        return
    end
    -- The content region is the clip for EVERY blit: rects registered while
    -- a node was partially visible (scroll edge) paint only their visible
    -- part, never the chrome below/around (nav bar, error strip).
    local clip = view.content_region
    local chrome = view.chrome_region -- band a page painted over (toolbar)
    if GifAnim.DIRECT and not GifAnim._obscured(view) then
        local ok, bb = pcall(function() return Screen.bb end)
        if ok and bb then
            local pushed = false
            for _, rect in ipairs(player.rects or {}) do
                if rect.w and rect.w > 0 then
                    local vis = rect
                    if clip then
                        local x2 = math.max(rect.x, clip.x)
                        local y2 = math.max(rect.y, clip.y)
                        local x3 = math.min(rect.x + rect.w, clip.x + (clip.w or 0))
                        local y3 = math.min(rect.y + rect.h, clip.y + (clip.h or 0))
                        if x2 >= x3 or y2 >= y3 then
                            -- Fully outside the content region right now:
                            -- nothing to animate (no nav-bar spills).
                            vis = nil
                        else
                            vis = { x = x2, y = y2, w = x3 - x2, h = y3 - y2 }
                        end
                    end
                    if vis and chrome then
                        -- Subtract the chrome band: a rect intersecting the
                        -- toolbar keeps only its below-band part (the page's
                        -- opaque strip owns those pixels).
                        if vis.y + vis.h > chrome.y
                            and vis.y < chrome.y + (chrome.h or 0) then
                            local band_y = math.max(vis.y, chrome.y)
                            local band_end = math.min(vis.y + vis.h,
                                chrome.y + (chrome.h or 0))
                            if vis.y >= chrome.y then
                                vis = nil -- fully inside the band: skip
                            else
                                vis = { x = vis.x, y = vis.y, w = vis.w,
                                    h = band_y - vis.y } -- above-band part
                            end
                            _ = band_end
                        end
                    end
                    if vis then
                        local okd = pcall(function()
                            GifAnim.draw(player, bb, vis.x, vis.y, vis.w, vis.h)
                        end)
                        if okd then
                            -- a2 waveform (not ui): on e-ink every "ui" partial
                            -- is a visible EPDC ripple, and at ~8fps that reads
                            -- as constant blinking (fine on SDL, blinks on
                            -- Kindle). Same precedent as VirtualKey highlights
                            -- ("We use a2 for the highlights"). No periodic
                            -- cleaning: motion masks the ghost, page changes
                            -- repaint fully anyway, and stop() settles once.
                            UIManager:setDirty(nil, "a2", Geom:new(vis))
                            pushed = true
                        end
                    end
                end
            end
            if pushed then
                return
            end
        end
    end
    -- Widget-repaint fallback: only while some instance is actually shown,
    -- otherwise this would be a full-widget refresh every 120ms.
    for _, rect in ipairs(player.rects or {}) do
        -- Chrome check mirrors the DIRECT path: the band is not ours.
        local under_chrome = chrome and rect.y < chrome.y + (chrome.h or 0)
            and rect.y + rect.h > chrome.y
            and rect.x < chrome.x + (chrome.w or 0)
            and rect.x + rect.w > chrome.x
        if GifAnim._rect_visible(view, rect) and not under_chrome then
            if view.refresh then
                view:refresh(nil, rect)
            end
            return
        end
    end
end

-- Load an animation source as a table of frame THUNKS (each returns a
-- blitbuffer) plus a needs_doc_free flag.
--
-- * directory of pre-composited full frames (frame_N.png, numeric order):
--   what the debug banner ships (tools/gen_debug_banner.py). KOReader's
--   giflib wrapper renders RAW GIF frames - delta sub-rects scaled to the
--   full canvas and the transparency index flattened to white - so a delta
--   encoded GIF shows only frame 0's body and white boxes afterwards. The
--   PNGs are complete pictures, flipped directly.
-- * a .gif file: RenderImage want_frames thunks (kept for sources that are
--   known to decode correctly).
local function load_frames(path, w, h)
    if path:sub(-4):lower() == ".gif" then
        -- NOTE: method call (colon) - the path would land in `self` otherwise.
        local ok, frames = pcall(RenderImage.renderImageFile, RenderImage, path, true, w, h)
        if not ok or type(frames) ~= "table" or (frames[1] == nil and frames[2] == nil) then
            if type(frames) == "table" and frames.free then
                pcall(function() frames:free() end)
            end
            return nil
        end
        return frames, true
    end
    -- Directory of full frames.
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then
        return nil
    end
    local names = {}
    local okd, diter, dstate, dctl = pcall(lfs.dir, path)
    if okd and type(diter) == "function" then
        for name in diter, dstate, dctl do
            if name:sub(-4):lower() == ".png" then
                names[#names + 1] = name
            end
        end
    end
    table.sort(names, function(a, b)
        local na = tonumber(a:match("(%d+)"))
        local nb = tonumber(b:match("(%d+)"))
        if na and nb then return na < nb end
        return a < b
    end)
    if #names < 2 then
        return nil
    end
    local thunks = {}
    for _i, name in ipairs(names) do
        local full = path .. "/" .. name
        thunks[#thunks + 1] = function()
            local okr, bb = pcall(RenderImage.renderImageFile, RenderImage, full, false, w, h)
            if okr and type(bb) == "cdata" then
                return bb
            end
            return nil
        end
    end
    return thunks, false
end

-- Ensure a player for key (one per key); starts the tick on creation.
-- opts: { w, h } target frame size in px, { rect } repaint region
-- ({x,y,w,h}) for the tick. Without rect the tick repaints whole
-- (fallback for callers that don't track geometry).
function GifAnim.ensure(app, view, key, path, opts)
    opts = opts or {}
    if not app or not app.state or not path or path == "" then
        return nil
    end
    app.state.gif_players = app.state.gif_players or {}
    local player = app.state.gif_players[key]
    if player and not player.stopped then
        player.view = view
        if opts.rect then
            -- Every paint invalidates the rect list first (AppView:paintTo),
            -- then re-registers the CURRENT on-screen instances. Same key +
            -- several visible nodes (e.g. 5 sonics side by side share nothing
            -- here: key includes node.h) - one key, several rects, capped.
            local rects = player.rects or {}
            local found = false
            for _, r in ipairs(rects) do
                if r.x == opts.rect.x and r.y == opts.rect.y
                    and r.w == opts.rect.w and r.h == opts.rect.h then
                    found = true
                    break
                end
            end
            if not found then
                if #rects >= 8 then table.remove(rects, 1) end
                rects[#rects + 1] = opts.rect
            end
            player.rects = rects
            player.rect = rects[1]
        end
        return player
    end
    local w = math.max(1, math.floor(opts.w or 100))
    local h = math.max(1, math.floor(opts.h or 100))
    -- Two source kinds (see load_frames below): a directory of
    -- pre-composited full frames (what the banner ships - the raw GIF's
    -- delta sub-rects cannot play through KOReader's giflib) or a .gif file
    -- via RenderImage want_frames (kept for any source known to play right).
    -- Both come back as a table of thunks; needs_doc_free marks the thunk
    -- table that also carries the decoded document to release.
    local source, needs_doc_free = load_frames(path, w, h)
    if not source then
        return nil
    end
    local count = #source
    if count < 2 then
        if needs_doc_free and source.free then
            pcall(function() source:free() end)
        end
        return nil
    end
    player = {
        n = math.min(count, GifAnim.MAX_FRAMES),
        idx = 1,
        view = view,
        rect = opts.rect,
        rects = opts.rect and { opts.rect } or {},
        app = app,
        key = key,
        page = app.state and app.state.page,
        tick = nil,
        stopped = false,
        bbs = {},
    }
    for i = 1, player.n do
        local okb, bb = pcall(source[i])
        -- LuaJIT: blitbuffers are FFI cdata (type() returns "cdata").
        player.bbs[i] = (okb and type(bb) == "cdata") and bb or nil
    end
    -- The thunks reference the decoded GIF document; every buffer we keep
    -- is materialized now, so release the document immediately instead of
    -- pinning the whole decode in RAM for the lifetime of the player.
    if needs_doc_free and source.free then
        pcall(function() source:free() end)
    end
    app.state.gif_players[key] = player
    local function tick()
        if player.stopped then
            return
        end
        -- Self-healing: any navigation path that forgot stop_all still
        -- kills this timer on its next fire (<=120ms leak). The entry is
        -- removed too, so a later ensure() starts clean.
        local cur_page = player.app and player.app.state and player.app.state.page
        if cur_page ~= player.page then
            if player.app and player.app.state and player.key then
                if player.app.state.gif_players then
                    player.app.state.gif_players[player.key] = nil
                end
            end
            GifAnim.stop(player)
            return
        end
        player.idx = player.idx % player.n + 1
        push_frame(player)
        UIManager:scheduleIn(GifAnim.INTERVAL, tick)
    end
    player.tick = tick
    UIManager:scheduleIn(GifAnim.INTERVAL, tick)
    return player
end

return GifAnim
