-- Shared image cache (chat inline images).
--
-- Design notes:
--   * Downloads use socket.http for http:// and CURL for https:// - LuaSec
--     (ssl.https) is unavailable in KOReader device builds, so socket-based
--     HTTPS silently produced zero images on the Kindle (v2 fix).
--   * Cache file EXTENSION is inferred from magic bytes: the KOReader
--     ImageWidget picks its decoder via DocumentRegistry:isImageFile(),
--     which is extension-based - extensionless files never rendered even
--     with a valid payload (second half of the v2 image fix).
--   * Remote thumbnails can be rate-limited per-minute by their edge, so
--     network fetches go through a small paced queue: max 2 in flight,
--     backoff 1.5/8/30s on the SAME url (edge-cache friendly), and a
--     5-minute cooldown after a final failure.

local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
local http = require("socket.http")

local Storage = require("kt_storage")

local Images = {}

local MAX_BYTES = 12 * 1024 * 1024
local TIMEOUT = 20

-- Pacing (remote edge budgets): at most 2 simultaneous fetches, retries at
-- the site's own intervals, and only one fetch per URL per 5-minute window.
local MAX_INFLIGHT = 2
local BACKOFF_STEPS = { 1.5, 8, 30 }
local COOLDOWN = 300

local queue = {
    count = 0,          -- in-flight fetches
    pending = {},       -- url -> { task, ... } waiting for a slot
    order = {},         -- FIFO order of pending urls
    inflight = {},      -- url -> task
    attempts = {},      -- url -> next backoff index
    last_fail = {},     -- url -> os.time() of final failure
}

-- 64-bit-ish URL hash (two 32-bit djb2 lanes, different seeds).
function Images.hash(url)
    url = tostring(url or "")
    local h1 = 5381
    local h2 = 52711
    for i = 1, #url do
        local b = url:byte(i)
        h1 = (h1 * 33 + b) % 4294967296
        h2 = (h2 * 31 + b + i) % 4294967296
    end
    return string.format("%08x%08x", h1, h2)
end

-- sniff_ext returns "png", "webp", "gif", "jpg" or nil from magic bytes.
local function sniff_ext(bytes)
    if not bytes or #bytes < 12 then return nil end
    if bytes:sub(1, 8) == "\137PNG\r\n\026\n" then return "png" end
    if bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then return "webp" end
    if bytes:sub(1, 3) == "\255\216\255" then return "jpg" end
    if bytes:sub(1, 6) == "GIF89a" or bytes:sub(1, 6) == "GIF87a" then return "gif" end
    return nil
end

local function cache_dir()
    return Storage.chat_images_dir()
end

-- path_for resolves the cached file for url WITHOUT knowing the extension:
-- any img_<hash>.* present wins. The extension is appended on first save.
function Images.path_for(url)
    local base = cache_dir() .. "/img_" .. Images.hash(url)
    return base
end

-- Cheap, repaint-safe lookup.
function Images.cached_path(url)
    if not url or url == "" or not lfs_ok then
        return nil
    end
    local base = Images.path_for(url)
    for _, ext in ipairs({ "webp", "png", "jpg", "gif" }) do
        local p = base .. "." .. ext
        local attr = lfs.attributes(p, "mode")
        if attr == "file" and (lfs.attributes(p, "size") or 0) > 0 then
            return p
        end
    end
    -- Legacy cache (extensionless, pre-v2) still renders for PNG.
    local attr = lfs.attributes(base, "mode")
    if attr == "file" and (lfs.attributes(base, "size") or 0) > 0 then
        return base
    end
    return nil
end

local function write_cache(url, body)
    local dir = cache_dir()
    if lfs_ok then
        local attr = lfs.attributes(dir, "mode")
        if attr ~= "directory" then
            pcall(function() lfs.mkdir(dir) end)
        end
    end
    local ext = sniff_ext(body) or "bin"
    local path = Images.path_for(url) .. "." .. ext
    local file = io.open(path, "wb")
    if not file then
        return nil, "cannot write cache"
    end
    file:write(body)
    file:close()
    return path
end

-- shell escape for curl args
local function shell_escape(s)
    return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

-- curl_sync fetch: blocking, used for https (and as http fallback). Returns
-- body string, http_code, err.
local function curl_sync(url, timeout)
    local resp_file = os.tmpname()
    local cmd = "curl -s -L --max-time " .. tostring(timeout or TIMEOUT)
        .. " --connect-timeout 10 --max-filesize " .. tostring(MAX_BYTES)
        .. " -w \"%{http_code}\""
        .. " -A " .. shell_escape("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36")
        .. " " .. shell_escape(url)
        .. " -o " .. shell_escape(resp_file)
    local p = io.popen(cmd .. " 2>/dev/null", "r")
    if not p then
        os.remove(resp_file)
        return nil, nil, "failed to spawn curl"
    end
    -- Read the pipe to EOF: p:close() alone does not wait for the process.
    local code_str = p:read("*a")
    p:close()
    local http_code = tonumber(code_str and code_str:match("(%d%d%d)"))
    local fr = io.open(resp_file, "rb")
    local body = fr and fr:read("*a") or ""
    if fr then fr:close() end
    os.remove(resp_file)
    return body, http_code
end

-- socket_sync fetch for http:// urls (socket.http + ltn12 sink). Returns
-- body string, http_code, err.
local function socket_sync(url)
    local sink = {}
    local bytes = 0
    local too_big = false
    local ok_req, status_code = pcall(function()
        local a, b = http.request{
            url = url,
            headers = { ["Accept"] = "image/*" },
            sink = function(chunk)
                if chunk then
                    bytes = bytes + #chunk
                    if bytes > MAX_BYTES then
                        too_big = true
                        return nil -- aborts the ltn12 chain
                    end
                    table.insert(sink, chunk)
                end
                return true
            end,
        }
        return b or a
    end)
    local body = table.concat(sink)
    local code = tonumber(status_code)
    if too_big then
        return nil, code, "too large"
    end
    if not ok_req or not code or code < 200 or code >= 300 or #body == 0 then
        return nil, code, "socket.http failed"
    end
    return body, code
end

-- Blocking fetch of one url (runs inside the paced queue task).
-- Returns cached path on success, nil + error otherwise.
function Images.fetch(url)
    if not url or url == "" then
        return nil, "empty url"
    end
    local cached = Images.cached_path(url)
    if cached then
        return cached
    end
    local body, code, err
    if url:match("^https://") then
        body, code, err = curl_sync(url)
    else
        body, code, err = socket_sync(url)
    end
    if not body or #body == 0 or (code and code >= 400) or (not code and err) then
        return nil, "download failed (" .. tostring(err or code or "?") .. ")"
    end
    return write_cache(url, body)
end

-- Queue drain: start pending fetches while slots are free.
local function pump()
    while queue.count < MAX_INFLIGHT and #queue.order > 0 do
        local url = table.remove(queue.order, 1)
        local task = queue.pending[url]
        queue.pending[url] = nil
        if task then
            queue.count = queue.count + 1
            queue.inflight[url] = task
            local UIManager = require("ui/uimanager")
            UIManager:scheduleIn(0, function()
                local ok_task, res, res_err = pcall(Images.fetch, url)
                queue.count = queue.count - 1
                queue.inflight[url] = nil
                local done = ok_task and res ~= nil
                if not done then
                    -- Backoff on the SAME url (edge cache friendly).
                    local step = queue.attempts[url] or 1
                    queue.attempts[url] = step + 1
                    if step <= #BACKOFF_STEPS then
                        local UIManager2 = require("ui/uimanager")
                        UIManager2:scheduleIn(BACKOFF_STEPS[step], function()
                            table.insert(queue.order, url)
                            queue.pending[url] = task
                            pump()
                        end)
                        pump()
                        return
                    end
                    queue.last_fail[url] = os.time()
                    queue.attempts[url] = nil
                else
                    queue.attempts[url] = nil
                end
                if task.on_done then
                    pcall(task.on_done, done and res or nil, res_err)
                end
                -- One repaint after the attempt settles (success or failure).
                local UIManager3 = require("ui/uimanager")
                UIManager3:scheduleIn(0.05, function()
                    if task.app and task.app.view and task.app.view.refresh then
                        pcall(function() task.app.view:refresh() end)
                    end
                end)
                pump()
            end)
        end
    end
end

-- Repaint-safe enqueue: returns the cached path when present; otherwise
-- schedules the download through the paced queue. Replaces the old
-- ensure() contract (same signature, same repaint behaviour).
function Images.ensure(url, app)
    local cached = Images.cached_path(url)
    if cached then
        return cached
    end
    if not app or not url or url == "" then
        return nil
    end
    local now = os.time()
    if queue.inflight[url] or queue.pending[url] then
        return nil
    end
    if queue.last_fail[url] and now - queue.last_fail[url] < COOLDOWN then
        return nil
    end
    queue.pending[url] = { app = app }
    table.insert(queue.order, url)
    pump()
    return nil
end

-- Test hook: number of urls waiting for a slot (harness).
function Images.pending_count()
    return #queue.order
end

-- Test hook: true while any fetch is queued or in flight (harness).
function Images._queue_busy()
    return queue.count > 0 or #queue.order > 0 or next(queue.inflight) ~= nil
end

-- Test hook: remove every cache variant of url (harness; the on-disk cache
-- persists between runs, so tests must scrub all extensions).
function Images._purge(url)
    local base = Images.path_for(url)
    os.remove(base)
    for _, ext in ipairs({ "webp", "png", "jpg", "gif", "bin" }) do
        os.remove(base .. "." .. ext)
    end
end

-- Test hook: wipe the pacing state (harness).
function Images._reset_queue()
    queue.count = 0
    queue.pending = {}
    queue.order = {}
    queue.inflight = {}
    queue.attempts = {}
    queue.last_fail = {}
end

return Images
