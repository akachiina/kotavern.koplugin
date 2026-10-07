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
function GifAnim.draw(player, bb, x, y, w, h)
    if not player or not bb or not w or w <= 0 or not h or h <= 0 then
        return false
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

-- True when no other widget sits above our view (a KOReader modal, dialog,
-- keyboard): the animation pauses under them instead of blitting into the
-- region they cover. An uninspectable/empty stack means "assume visible"
-- (tests drive both paths explicitly via GifAnim.DIRECT).
function GifAnim._obscured(view)
    local stack = UIManager._window_stack
    if type(stack) ~= "table" or #stack == 0 then
        return false
    end
    for i = #stack, 1, -1 do
        local w = stack[i] and stack[i].widget
        if w == view then
            return false
        end
    end
    return true -- our view is not on the stack at all: not being displayed
end

-- Advance one frame onto the screen. DIRECT: paint Screen.bb and refresh
-- only the banner region (no widget repaint). Fallback: the widget-repaint
-- path (rect-less callers, tests, odd compositors).
local function push_frame(player)
    local view = player.view
    if not view then
        return
    end
    local rect = player.rect
    if GifAnim.DIRECT and rect and rect.w and rect.w > 0
        and not GifAnim._obscured(view) then
        local ok, bb = pcall(function() return Screen.bb end)
        if ok and bb and GifAnim.draw(player, bb, rect.x, rect.y, rect.w, rect.h) then
            UIManager:setDirty(nil, "ui", Geom:new(rect))
            return
        end
    end
    if view.refresh then
        view:refresh(nil, rect)
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
            player.rect = opts.rect
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
