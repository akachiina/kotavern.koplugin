-- Character-card thumbnail cache (dashboard speed on weak devices).
-- Grid/list covers used to decode the FULL original PNG per card per paint
-- (~8ms each on PC, ~40-80ms on Kindle ARM). Thumbs are generated once at
-- 480px on the long side and painted from then on; KOReader's own
-- file_do_cache keeps the decoded bytes in RAM on top.
--
-- Repaint-safe contract (mirrors ktui/images): Thumbs.thumb(src) returns the
-- thumb path when ready, nil while pending (caller paints the initial
-- fallback); generation runs through a paced queue that repaints on settle.
-- Pure helpers (key, sweep picking) are exposed for the headless harness.

local Images = require("ktui/images")

local Thumbs = {}

Thumbs.LONG_SIDE = 480
Thumbs.PER_TICK = 2
Thumbs.MAX_FILES = 500
Thumbs.SWEEP_KEEP = 300

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    lfs = nil
end

local function thumbs_dir()
    local Storage = require("kt_storage")
    local dir = Storage.data_dir() .. "/chat_thumbs"
    if lfs and lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    return dir
end

local function file_sig(path)
    if not lfs then
        return nil
    end
    local size = lfs.attributes(path, "size")
    local mtime = lfs.attributes(path, "modification")
    if not size or not mtime then
        return nil
    end
    return tostring(path) .. "|" .. tostring(size) .. "|" .. tostring(mtime)
end

-- Disk key for a source file. The signature folds mtime+size in, so edits
-- naturally miss the cache (stale thumbs are swept, never served).
function Thumbs.key_for(path)
    local sig = file_sig(path)
    if not sig then
        return nil
    end
    return Images.hash(sig) .. ".png"
end

function Thumbs.thumb_path(path)
    local key = Thumbs.key_for(path)
    if not key then
        return nil
    end
    return thumbs_dir() .. "/" .. key
end

-- Ready thumb path, or nil (missing/stale/empty).
function Thumbs.cached(path)
    local tp = Thumbs.thumb_path(path)
    if not tp or not lfs then
        return nil
    end
    if lfs.attributes(tp, "mode") == "file" and (lfs.attributes(tp, "size") or 0) > 0 then
        return tp
    end
    return nil
end

-- Generate one thumb synchronously (runs inside the paced queue task).
-- Full decode, aspect-preserving downscale to LONG_SIDE, PNG to cache.
-- Returns the thumb path or nil. Never throws.
function Thumbs.generate(path)
    local tp = Thumbs.thumb_path(path)
    if not tp then
        return nil
    end
    if Thumbs.cached(path) then
        return tp
    end
    local ok, err = pcall(function()
        local P = require("ktui/primitives")
        local RenderImage = require("ui/renderimage")
        local iw, ih = P.image_dims(path)
        if not iw or not ih or iw <= 0 or ih <= 0 then
            error("unreadable dimensions")
        end
        local scale = math.min(1, Thumbs.LONG_SIDE / math.max(iw, ih))
        local tw, th = math.max(1, math.floor(iw * scale)), math.max(1, math.floor(ih * scale))
        -- NOTE: method call (colon) - the path would land in `self` otherwise.
        local bb = RenderImage:renderImageFile(path)
        if not bb then
            error("decode failed")
        end
        local scaled = RenderImage:scaleBlitBuffer(bb, tw, th)
        if not scaled then
            error("scale failed")
        end
        local wok, werr = pcall(function() scaled:writePNG(tp) end)
        if scaled.free then
            pcall(function() scaled:free() end)
        end
        if not wok then
            error(werr)
        end
    end)
    if not ok then
        pcall(os.remove, tp)
        return nil, err
    end
    Thumbs.sweep()
    return tp
end

-- Cap the cache dir (delete oldest by mtime past MAX_FILES).
function Thumbs.sweep()
    if not lfs then
        return
    end
    local dir = thumbs_dir()
    local files = {}
    local ok, diter, dstate, dctl = pcall(lfs.dir, dir)
    if not ok or type(diter) ~= "function" then
        return
    end
    for name in diter, dstate, dctl do
        if name:match("%.png$") then
            local full = dir .. "/" .. name
            files[#files + 1] = { path = full, mtime = lfs.attributes(full, "modification") or 0 }
        end
    end
    if #files <= Thumbs.MAX_FILES then
        return
    end
    table.sort(files, function(a, b) return a.mtime < b.mtime end)
    for i = 1, #files - Thumbs.SWEEP_KEEP do
        os.remove(files[i].path)
    end
end

-- Paced queue: PER_TICK generations per pump, one repaint when drained.
-- Deduplicated while pending. Pumps always run off-paint (timers), so a
-- dashboard paint with 10 cold cards schedules exactly one chain.
local queue = { order = {}, pending = {}, scheduled = false }
local refresh_apps = {}
Thumbs._queue = queue

local function repaint_once()
    local UIManager = require("ui/uimanager")
    for app in pairs(refresh_apps) do
        if app.view and app.view.refresh then
            -- Scoped to the content area under the header: one batch of new
            -- thumbnails used to re-waveform the entire screen (header, nav
            -- and all) for pixels that did not change.
            local region = app.view.content_region
            if region then
                pcall(function() app.view:refresh(nil, region) end)
            else
                pcall(function() app.view:refresh() end)
            end
        end
    end
    refresh_apps = {}
end

local function pump()
    queue.scheduled = false
    local budget = 0
    while budget < Thumbs.PER_TICK and #queue.order > 0 do
        local path = table.remove(queue.order, 1)
        queue.pending[path] = nil
        if not Thumbs.cached(path) then
            Thumbs.generate(path)
        end
        budget = budget + 1
    end
    local UIManager = require("ui/uimanager")
    if #queue.order > 0 then
        if not queue.scheduled then
            queue.scheduled = true
            UIManager:scheduleIn(0, pump)
        end
    else
        UIManager:scheduleIn(0.05, repaint_once)
    end
end

-- Repaint-safe entry: thumb path when ready, else enqueue + nil (caller
-- paints the initial fallback). Unreadable sources never queue.
-- Never generates synchronously.
function Thumbs.ensure(path, app)
    local cached = Thumbs.cached(path)
    if cached then
        return cached
    end
    if not path or path == "" or not Thumbs.key_for(path) then
        return nil
    end
    if not queue.pending[path] then
        queue.pending[path] = true
        queue.order[#queue.order + 1] = path
    end
    if app then
        refresh_apps[app] = true
    end
    if not queue.scheduled then
        queue.scheduled = true
        local UIManager = require("ui/uimanager")
        UIManager:scheduleIn(0, pump)
    end
    return nil
end

-- Pending count (harness probe).
function Thumbs.pending_count()
    return #queue.order
end

return Thumbs
