-- Minimal GIF player for tiny easter-egg animations (debug banner).
-- Decodes frames ONCE (capped), advances on a timer, repaints through the
-- normal view refresh. No looping forever outside its page: the caller must
-- GifAnim.stop_all(app) on navigate/close, or the timer eats the battery.
--
-- KOReader's RenderImage returns frame thunks (caller frees each bb) plus
-- frames:free() for the document. We cache at most MAX_FRAMES scaled
-- buffers and free everything on stop.

local UIManager = require("ui/uimanager")
local RenderImage = require("ui/renderimage")

local GifAnim = {}

GifAnim.MAX_FRAMES = 24
GifAnim.INTERVAL = 0.12 -- ~8fps: e-ink friendly, still reads as motion

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

-- Ensure a player for key (one per key); starts the tick on creation.
-- opts: { w, h } target frame size in px.
function GifAnim.ensure(app, view, key, path, opts)
    opts = opts or {}
    if not app or not app.state or not path or path == "" then
        return nil
    end
    app.state.gif_players = app.state.gif_players or {}
    local player = app.state.gif_players[key]
    if player and not player.stopped then
        player.view = view
        return player
    end
    local w = math.max(1, math.floor(opts.w or 100))
    local h = math.max(1, math.floor(opts.h or 100))
    -- NOTE: method call (colon) - the path would land in `self` otherwise.
    local ok, frames = pcall(RenderImage.renderImageFile, RenderImage, path, true, w, h)
    if not ok or type(frames) ~= "table" or (frames[1] == nil and frames[2] == nil) then
        if type(frames) == "table" and frames.free then
            pcall(function() frames:free() end)
        end
        return nil
    end
    local count = #frames
    if count < 2 then
        if frames.free then
            pcall(function() frames:free() end)
        end
        return nil
    end
    player = {
        frames = frames,
        n = math.min(count, GifAnim.MAX_FRAMES),
        idx = 1,
        view = view,
        tick = nil,
        stopped = false,
        bbs = {},
    }
    for i = 1, player.n do
        local okb, bb = pcall(frames[i])
        player.bbs[i] = (okb and bb) or nil
    end
    app.state.gif_players[key] = player
    local function tick()
        if player.stopped then
            return
        end
        player.idx = player.idx % player.n + 1
        if player.view and player.view.refresh then
            player.view:refresh()
        end
        UIManager:scheduleIn(GifAnim.INTERVAL, tick)
    end
    player.tick = tick
    UIManager:scheduleIn(GifAnim.INTERVAL, tick)
    return player
end

return GifAnim
