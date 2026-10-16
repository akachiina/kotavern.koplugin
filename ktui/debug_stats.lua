-- Debug header stats (Debug > "Show RAM and CPU in the header"): a compact
-- plugin+device usage readout drawn beside the title dots. Sources are the
-- same /proc files KOReader's own memory watchdog reads (pcall-guarded,
-- "—" placeholders when a kernel lacks one) plus a paint-CPU accumulator
-- fed by AppView:paintTo. Sampling is throttled to a 2s window (CPU deltas
-- need time to mean anything) and piggybacks on paints that already happen:
-- no timers, no forced repaints - e-ink battery comes first.

local DebugStats = {}

local SAMPLE_S = 2

local S = {
    next_t = 0,
    text = nil,
    plugin_cpu = 0,    -- CPU seconds spent painting since the last sample
    cpu_t0 = nil,      -- os.clock at the last sample
    dev_prev = nil,    -- /proc/stat aggregate snapshot { total, idle }
    wall0 = nil,       -- wall clock at the last sample
    last_paint_ms = nil,
    paints = 0,
}

local function wall_now()
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.gettime then
        local ok2, t = pcall(socket.gettime)
        if ok2 and t then return t end
    end
    return os.time()
end

-- /proc/self/statm: field 2 = resident pages. Same math as KOReader's
-- readerdevicestatus (4K pages).
local function read_rss_mb()
    local f = io.open("/proc/self/statm", "r")
    if not f then return nil end
    local rss_pages = f:read("*number", "*number")
    f:close()
    if not rss_pages then return nil end
    return math.floor(rss_pages * 4096 / 1048576)
end

-- /proc/meminfo: used = MemTotal - MemAvailable. Pre-3.14 kernels lack
-- MemAvailable: fall back to Free + Buffers + Cached. Returns used, total (MB).
local function read_device_mem()
    local f = io.open("/proc/meminfo", "r")
    if not f then return nil end
    local total, avail, free_k, buffers, cached = nil, nil, nil, nil, nil
    for line in f:lines() do
        local k, v = line:match("^(%a+):%s*(%d+)")
        if k == "MemTotal" then total = tonumber(v)
        elseif k == "MemAvailable" then avail = tonumber(v)
        elseif k == "MemFree" then free_k = tonumber(v)
        elseif k == "Buffers" then buffers = tonumber(v)
        elseif k == "Cached" then cached = tonumber(v)
        end
    end
    f:close()
    if not total then return nil end
    avail = avail or (free_k and (free_k + (buffers or 0) + (cached or 0)))
    if not avail then return nil end
    return math.floor((total - avail) / 1024), math.floor(total / 1024)
end

-- /proc/stat first line (aggregate row): busy = everything but idle+iowait.
-- Returns the running totals; the percentage comes from deltas.
local function read_cpu_totals()
    local f = io.open("/proc/stat", "r")
    if not f then return nil end
    local line = f:read("*line")
    f:close()
    if not line then return nil end
    local nums = {}
    for n in line:gmatch("(%d+)") do nums[#nums + 1] = tonumber(n) end
    if #nums < 5 then return nil end
    local total, idle = 0, 0
    for i = 1, #nums do
        total = total + nums[i]
        if i == 4 or i == 5 then idle = idle + nums[i] end
    end
    return total, idle
end

-- Called by AppView:paintTo with the os.clock() taken at entry: the plugin
-- CPU share is how much wall time the UI actually spent painting.
function DebugStats.note_paint(t0)
    S.paints = S.paints + 1
    if t0 then
        local dt = os.clock() - t0
        if dt > 0 then
            S.plugin_cpu = S.plugin_cpu + dt
            S.last_paint_ms = dt * 1000
        end
    end
end

-- Drop the sampling baselines (toggle switched, tests).
function DebugStats.reset()
    S.next_t = 0
    S.text = nil
    S.plugin_cpu = 0
    S.cpu_t0 = nil
    S.dev_prev = nil
    S.wall0 = nil
    S.paints = 0
    S.last_paint_ms = nil
end

local function pct_str(p)
    if not p then return "—" end
    return tostring(math.max(0, math.min(999, math.floor(p + 0.5))))
end

local function mb_str(m)
    if not m then return "—" end
    return tostring(m)
end

-- Compact header text: P<lua heap MB> <plugin cpu %>·D<device used MB>
-- <device cpu %>. Reuses the previous sample inside the throttle window.
function DebugStats.text(app)
    local now = wall_now()
    if S.text and now < S.next_t then
        return S.text
    end
    -- Lua heap: the plugin's own tables/strings. C-side buffers (MuPDF
    -- bitmaps, fonts) only show up in the process RSS below.
    local lua_mb = nil
    local okc, kb = pcall(collectgarbage, "count")
    if okc and kb then lua_mb = math.floor(kb / 1024 + 0.5) end
    local plugin_pct = nil
    local cpu_now = os.clock()
    if S.cpu_t0 and S.wall0 and now > S.wall0 then
        plugin_pct = (S.plugin_cpu * 100) / (now - S.wall0)
    end
    local dev_pct = nil
    local dtotal, didle = read_cpu_totals()
    if dtotal and S.dev_prev then
        local dt = dtotal - S.dev_prev[1]
        local di = didle - S.dev_prev[2]
        if dt > 0 then
            dev_pct = (1 - di / dt) * 100
        end
    end
    local used_mb = read_device_mem()
    S.text = string.format("P%sM %s%%·D%sM %s%%",
        mb_str(lua_mb), pct_str(plugin_pct), mb_str(used_mb), pct_str(dev_pct))
    -- Roll the window.
    S.cpu_t0 = cpu_now
    S.plugin_cpu = 0
    S.wall0 = now
    if dtotal then S.dev_prev = { dtotal, didle } end
    S.next_t = now + SAMPLE_S
    return S.text
end

-- Full breakdown for the tap-through modal (debug tooling: plain labels).
function DebugStats.details(app)
    local lines = { "KOTavern debug stats" }
    local okc, kb = pcall(collectgarbage, "count")
    lines[#lines + 1] = string.format("Lua heap: %.1f MB", (okc and kb or 0) / 1024)
    local rss = read_rss_mb()
    lines[#lines + 1] = "Process RSS: " .. (rss and (rss .. " MB") or "—")
    local used, total = read_device_mem()
    if used and total then
        lines[#lines + 1] = string.format("Device RAM: %d / %d MB used", used, total)
    else
        lines[#lines + 1] = "Device RAM: —"
    end
    lines[#lines + 1] = "Header: " .. (S.text or "(sampling)")
    lines[#lines + 1] = string.format("Last paint: %s ms (%d paints)",
        S.last_paint_ms and string.format("%.1f", S.last_paint_ms) or "—", S.paints)
    local docs = app and app.state and app.state.chat_html_docs
    if type(docs) == "table" then
        local n, with_w = 0, 0
        for k, v in pairs(docs) do
            if type(k) == "string" and type(v) == "table" then
                n = n + 1
                if v.widget then with_w = with_w + 1 end
            end
        end
        lines[#lines + 1] = string.format("HTML docs: %d entries, %d with bitmaps", n, with_w)
    end
    return table.concat(lines, "\n")
end

return DebugStats
