-- HTTP client for OpenAI Chat Completions API.
-- Supports both synchronous (LuaSocket) and streaming (curl background) modes.

local socket = require("socket")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")

local ok_https, https = pcall(require, "ssl.https")
local ok_socketutil, socketutil = pcall(require, "socketutil")

local Client = {}

-- Default timeout values
local DEFAULT_TIMEOUT = 30
local STREAM_TIMEOUT = 120
local POLL_INTERVAL = 0.3
-- Configurable at runtime (Settings → Network; see Client:set_timeouts).
local SYNC_TIMEOUT = DEFAULT_TIMEOUT
local STREAM_IDLE_TIMEOUT = STREAM_TIMEOUT
-- Transient-failure retry (SillyTavern backoff parity): 429/5xx only,
-- non-streaming backends. See Client:set_retries / Client.should_retry.
local RETRY_MAX = 1
local RETRY_BASE_DELAY = 2

-- Shared across all Client instances so abort_stream() works even if the
-- caller re-creates a Client (Stop button).
local active_streams = {}

local function chat_url(base)
    base = tostring(base or ""):gsub("/+$", "")
    if base:match("/chat/completions$") then
        return base
    end
    return base .. "/chat/completions"
end

local function shell_escape(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\"'\"'") .. "'"
end

local function build_headers(connection)
    local headers = { ["Content-Type"] = "application/json" }
    if connection.api_key and connection.api_key ~= "" then
        headers["Authorization"] = "Bearer " .. connection.api_key
    end
    -- Per-connection custom headers (SillyTavern custom-endpoint parity):
    -- connection.extra_headers is a JSON map string, e.g.
    --   {"HTTP-Referer": "https://mysite", "X-Title": "KOTavern"}
    -- Content-Type/Authorization set above are never overridden.
    local raw = connection.extra_headers
    local map = raw
    if type(raw) == "string" and raw ~= "" then
        local ok_dec, decoded = pcall(json.decode, raw)
        map = (ok_dec and type(decoded) == "table") and decoded or nil
    end
    if type(map) == "table" then
        for k, v in pairs(map) do
            local lk = type(k) == "string" and k:lower() or nil
            if lk and lk ~= "content-type" and lk ~= "authorization"
                and type(v) == "string" and v ~= "" then
                headers[k] = v
            end
        end
    end
    return headers
end

local function process_alive(pid)
    -- LuaJIT's os.execute returns the raw exit code; Lua 5.x returns nil,"exit",code.
    local a, b, c = os.execute("kill -0 " .. tostring(pid) .. " 2>/dev/null")
    if a == true then return true end
    if type(a) == "number" then return a == 0 end
    if type(b) == "string" and type(c) == "number" then return c == 0 end
    return false
end

function Client:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Configure the SSE poll interval (Settings → streaming chunk interval)
function Client:set_poll_interval(seconds)
    local s = tonumber(seconds)
    if s and s > 0 then
        POLL_INTERVAL = s
    end
end

-- Configure timeouts (seconds): sync request cap and stream idle cap.
function Client:set_timeouts(sync_s, stream_s)
    local n = tonumber(sync_s)
    if n and n > 0 then SYNC_TIMEOUT = n end
    n = tonumber(stream_s)
    if n and n > 0 then STREAM_IDLE_TIMEOUT = n end
end

-- Configure how many times a transient failure (429/5xx) is retried.
function Client:set_retries(n)
    local r = tonumber(n)
    if r and r >= 0 then RETRY_MAX = math.floor(r) end
end

-- Whether a failed attempt should be retried (SillyTavern parity: only
-- transient failures - 429 rate limit and 5xx - with base-2s backoff).
function Client.should_retry(status, attempt)
    if status == nil or attempt > RETRY_MAX then return false end
    return status == 429 or status >= 500
end

-- Build the standard OpenAI chat completion payload
local function to_number(value, default)
    local n = tonumber(value)
    return (n ~= nil) and n or default
end

-- Detect reasoning models whose API rejects legacy sampling fields
-- (SillyTavern parity): o1/o3/o4* and gpt-5* use max_completion_tokens
-- instead of max_tokens and reject temperature/top_p/top_k overrides.
local function is_reasoning_model(model, preset)
    if type(preset) == "table" and type(preset.reasoning_effort) == "string"
        and preset.reasoning_effort ~= "" then
        return true
    end
    local m = tostring(model or ""):lower()
    -- Match anywhere so vendor prefixes work ("openrouter/o3-mini"), and a
    -- bare "o1"/"o3"/"o4" too. "gpt-4o" does NOT match ("o" has no digit).
    if m:match("o[134][%-.:]") or m:match("o[134]$") then return true end
    if m:find("gpt%-5", 1, false) then return true end
    return false
end

-- Human name of a well-known provider preset matching base_url (nil when
-- custom/empty). Used so the connection editor shows WHICH provider is
-- configured instead of a permanent "(empty)". Comparison ignores a trailing
-- slash and a trailing /chat/completions (both are stripped by chat_url).
function Client.provider_name(base_url)
    if not base_url or base_url == "" then return nil end
    local norm = tostring(base_url):gsub("/+$", ""):gsub("/chat/completions$", "")
    local ok_app, App = pcall(require, "kt_app")
    local presets = (ok_app and App.PROVIDER_PRESETS) or {}
    for _, p in ipairs(presets) do
        local pu = tostring((p and p.url) or ""):gsub("/+$", "")
        if pu ~= "" and norm == pu then
            return p.name
        end
    end
    return nil
end

-- Last HTTP failure detail for diagnostics (set by every error decoder,
-- cleared when a new request starts; single-threaded UI, last-wins).
-- Shape: { status = number|nil, body = string|nil }.
Client.last_http = nil

local function note_http(status, body)
    Client.last_http = { status = status, body = body }
end

local function url_host(base_url)
    return tostring(base_url or ""):lower():match("^%w+://([^/]+)") or ""
end

-- One-line error context prefix: "Name (host) · model". All parts are
-- dynamic (provider names/URLs are never translated); missing pieces are
-- omitted. Status appended only when known (mid-stream errors have none -
-- HTTP 200 was already committed when the error event arrived).
function Client.describe_error(connection, model, status, message)
    local parts = {}
    if type(connection) == "table" then
        local name = connection.name
        local host = url_host(connection.base_url)
        if type(name) == "string" and name ~= "" and host ~= "" then
            parts[#parts + 1] = name .. " (" .. host .. ")"
        elseif type(name) == "string" and name ~= "" then
            parts[#parts + 1] = name
        elseif host ~= "" then
            parts[#parts + 1] = host
        end
    end
    if type(model) == "string" and model ~= "" then
        parts[#parts + 1] = model
    end
    local head = (#parts > 0) and (table.concat(parts, " · ") .. ": ") or ""
    local tail = (type(status) == "number") and (" (HTTP " .. tostring(status) .. ")") or ""
    return head .. tostring(message or "") .. tail
end

-- Key fingerprint for the debug log: length + last4 + anomaly flags.
-- NEVER the key value.
function Client.key_fingerprint(key)
    if type(key) ~= "string" or key == "" then
        return "none"
    end
    local last4 = (#key >= 4) and key:sub(-4) or key
    local flags = {}
    if key:lower():match("^bearer%s+") then
        flags[#flags + 1] = "bearer-prefix"
    end
    if key ~= key:match("^%s*(.-)%s*$") then
        flags[#flags + 1] = "whitespace"
    end
    local fp = "len=" .. tostring(#key) .. " …" .. last4
    if #flags > 0 then
        fp = fp .. " [" .. table.concat(flags, ",") .. "]"
    end
    return fp
end

-- Names of the headers a request would carry (values never leave here).
function Client.header_names(connection)
    local names = {}
    for k in pairs(build_headers(connection or {})) do
        names[#names + 1] = k
    end
    table.sort(names)
    return names
end

local DEBUG_BODY_CAP = 4000

-- Multi-line debug bundle for debug.txt. No secrets: key fingerprint only.
function Client.debug_entry(o)
    o = o or {}
    local conn = (type(o.connection) == "table") and o.connection or {}
    local lines = { "=== kotavern api error @ " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===" }
    lines[#lines + 1] = "connection: " .. tostring(conn.name or "?")
    lines[#lines + 1] = "url: " .. tostring(conn.base_url or "?")
    lines[#lines + 1] = "model: " .. tostring(o.model or "?")
    lines[#lines + 1] = "backend: " .. tostring(o.backend or "?")
    lines[#lines + 1] = "key: " .. Client.key_fingerprint(conn.api_key)
    local headers = o.headers
    if type(headers) ~= "table" then
        headers = Client.header_names(conn)
    end
    lines[#lines + 1] = "headers: " .. table.concat(headers, ", ")
    lines[#lines + 1] = "status: " .. tostring((o.status ~= nil) and o.status or "none")
    local body = tostring(o.body or "")
    if #body > DEBUG_BODY_CAP then
        body = body:sub(1, DEBUG_BODY_CAP) .. " …[truncated]"
    end
    lines[#lines + 1] = "body: " .. (body ~= "" and body or "(empty)")
    return table.concat(lines, "\n")
end

-- Endpoint families for extended-sampler gating (v0.6.8, SillyTavern source
-- parity: only sources that declare the extended samplers send them). Strict
-- OpenAI-compatible endpoints reject unknown params with HTTP 400
-- ("Validation: Unsupported parameter(s): `top_a`"). Returns
-- allow_extended, allow_top_a:
--   openrouter.ai   → full set (ST OPENROUTER source parity)
--   localhost / LAN → top_k/min_p/repetition_penalty (llama.cpp, koboldcpp,
--                     LM Studio and friends accept them; top_a is rare)
--   everything else → base set only (ST CUSTOM parity)
-- Whether the endpoint family normally requires an API key (pre-flight guard
-- support: a missing key fails fast with an actionable message instead of a
-- cryptic provider 401). Local/LAN servers and Pollinations accept keyless
-- requests; everything else (OpenAI/OpenRouter/DeepSeek/...) needs a key.
function Client.requires_api_key(base_url)
    local url = tostring(base_url or ""):lower()
    if url:find("//localhost", 1, true) or url:find("127%.0%.0%.1")
        or url:find("0%.0%.0%.0")
        or url:find("192%.168%.") or url:find("//10%.")
        or url:find("//172%.1[6-9]%.") or url:find("//172%.2%d%.") or url:find("//172%.3[01]%.") then
        return false
    end
    if url:find("pollinations.ai", 1, true) then
        return false
    end
    return true
end

-- 401/403 means the endpoint rejected our credentials (missing, wrong or
-- revoked key). Provider messages are often cryptic ("pi error", a bare
-- "missing authenticator header"), so append an actionable hint. Kept in
-- plain English like the other client-level messages (no _() by convention).
local function with_auth_hint(msg, code)
    if code == 401 or code == 403 then
        return tostring(msg or "") .. " (check the API key)"
    end
    return msg
end

function Client.extended_sampler_caps(base_url)
    local url = tostring(base_url or ""):lower()
    if url:find("openrouter", 1, true) then
        return true, true
    end
    if url:find("//localhost", 1, true) or url:find("127%.0%.0%.1")
        or url:find("0%.0%.0%.0")
        or url:find("192%.168%.") or url:find("//10%.")
        or url:find("//172%.1[6-9]%.") or url:find("//172%.2%d%.") or url:find("//172%.3[01]%.") then
        return true, false
    end
    return false, false
end

function Client:build_payload(messages, connection, preset, stream)
    preset = preset or {}
    local model = preset.model_id or connection.model_id or connection.model or "gpt-4o-mini"
    local payload = {
        model = model,
        messages = messages,
        stream = not not stream,
    }

    -- Optional sampling parameters (only sent when set) - shared helper for
    -- both branches below (seed/n apply to reasoning models too).
    local function maybe(key, preset_v, conn_v)
        local v = to_number(preset_v, conn_v)
        if v ~= nil then
            payload[key] = v
        end
    end

    if is_reasoning_model(model, preset) then
        -- Reasoning models: max_completion_tokens only, no sampling overrides.
        local mt = to_number(preset.max_tokens or connection.max_tokens, 1024)
        if mt then payload.max_completion_tokens = mt end
        if type(preset.reasoning_effort) == "string" and preset.reasoning_effort ~= "" then
            payload.reasoning_effort = preset.reasoning_effort
        end
        if type(preset.verbosity) == "string" and preset.verbosity ~= "" then
            payload.verbosity = preset.verbosity
        end
    else
        payload.temperature = to_number(preset.temperature or connection.temperature, 0.8)
        payload.max_tokens = to_number(preset.max_tokens or connection.max_tokens, 1024)
        payload.top_p = to_number(preset.top_p or connection.top_p, 1.0)
        -- Extended samplers are source-gated (SillyTavern parity): top_k/
        -- top_a/min_p/repetition_penalty only go where they are supported.
        local allow_ext, allow_top_a = Client.extended_sampler_caps(connection.base_url)
        local mode = tostring(connection.extended_samplers or "auto"):lower()
        if mode == "on" then
            allow_ext, allow_top_a = true, true
        elseif mode == "off" then
            allow_ext, allow_top_a = false, false
        end
        -- Neutral values are no-ops on every backend, and some strict ones
        -- validate the bare KEY, so imported ST defaults (top_k: 0,
        -- min_p: 0, top_a: 0, repetition_penalty: 1) never go out.
        local function ext(key, preset_v, conn_v, neutral)
            if not allow_ext then return end
            local v = to_number(preset_v, conn_v)
            if v == nil or math.abs(v - neutral) < 1e-9 then return end
            payload[key] = v
        end
        ext("top_k", preset.top_k, connection.top_k, 0)
        ext("min_p", preset.min_p, connection.min_p, 0)
        ext("repetition_penalty", preset.repetition_penalty, connection.repetition_penalty, 1)
        if allow_top_a then
            local ta = to_number(preset.top_a, connection.top_a)
            if ta and ta > 0 then payload.top_a = ta end
        end
        maybe("frequency_penalty", preset.frequency_penalty, connection.frequency_penalty)
        maybe("presence_penalty", preset.presence_penalty, connection.presence_penalty)
        if type(preset.reasoning_effort) == "string" and preset.reasoning_effort ~= "" then
            payload.reasoning_effort = preset.reasoning_effort
        end
        if type(preset.verbosity) == "string" and preset.verbosity ~= "" then
            payload.verbosity = preset.verbosity
        end
    end

    -- Shared controls (both model families)
    maybe("seed", preset.seed, connection.seed)
    maybe("n", preset.n or connection.n, nil)

    -- Stop strings (SillyTavern "Custom Stopping Strings" parity): stored
    -- comma-separated in the editors, sent as an array. Max 32 (ST cap).
    local stop_src = preset.stop or connection.stop
    local stop_arr = {}
    if type(stop_src) == "string" and stop_src ~= "" then
        for raw_part in stop_src:gmatch("[^,]+") do
            local part = raw_part:match("^%s*(.-)%s*$")
            if part ~= "" then table.insert(stop_arr, part) end
        end
    elseif type(stop_src) == "table" then
        for _, s in ipairs(stop_src) do
            if type(s) == "string" and s ~= "" then table.insert(stop_arr, s) end
        end
    end
    if #stop_arr > 0 then
        while #stop_arr > 32 do table.remove(stop_arr) end
        payload.stop = stop_arr
    end

    return payload
end

-- Extract the native reasoning channel from a delta/message object
-- (SillyTavern "Request model reasoning" parity):
--   DeepSeek / OpenAI-compatible: reasoning_content
--   OpenRouter / xAI / others:   reasoning
-- LuaJSON null decodes as a sentinel FUNCTION, so only real strings count.
-- Returns the reasoning text or nil.
function Client.parse_reasoning_delta(obj)
    if type(obj) ~= "table" then
        return nil
    end
    if type(obj.reasoning_content) == "string" and obj.reasoning_content ~= "" then
        return obj.reasoning_content
    end
    if type(obj.reasoning) == "string" and obj.reasoning ~= "" then
        return obj.reasoning
    end
    return nil
end

-- Forward declarations (defined below chat_completion)
local handle_http_response
local curl_completion

function Client:chat_completion(messages, connection, preset, callback, backend)
    if type(preset) == "function" then
        callback = preset
        preset = {}
    end
    preset = preset or {}
    if not connection or not connection.base_url then
        local err = "No API URL configured"
        if callback then callback(nil, err) end
        return nil, err
    end
    -- Fresh diagnostics per request (stale details must never attach to a
    -- later, unrelated failure).
    Client.last_http = nil

    -- Prompt post-processing (SillyTavern custom-endpoint parity): shape the
    -- message array for restrictive endpoints before building the payload.
    local post = connection.post_processing
    if post and post ~= "" and post ~= "none" then
        messages = require("kt_models").post_process_messages(messages, post)
    end

    local url = chat_url(connection.base_url)
    local payload = self:build_payload(messages, connection, preset, false)

    local ok, encoded = pcall(json.encode, payload)
    if not ok then
        local err = "Failed to encode request: " .. tostring(encoded)
        if callback then callback(nil, err) end
        return nil, err
    end

    local headers = build_headers(connection)
    backend = backend or "curl_bg"

    if backend ~= "http_sync" then
        return curl_completion(url, headers, encoded, callback, backend)
    end

    headers["Content-Length"] = tostring(#encoded)

    -- Sync socket retries transient failures (429/5xx) with backoff.
    local attempt = 0
    while true do
        local sink = {}
        local request = {
            url = url,
            method = "POST",
            headers = headers,
            source = ltn12.source.string(encoded),
            sink = ltn12.sink.table(sink),
        }

        local requester = http
        if url:match("^https://") then
            if not ok_https then
                local err = "HTTPS support unavailable in this build"
                if callback then callback(nil, err) end
                return nil, err
            end
            requester = https
        end

        if ok_socketutil then
            socketutil:set_timeout(SYNC_TIMEOUT, SYNC_TIMEOUT * 3)
        end

        local res_status, res_status_code, _, status = requester.request(request)

        if ok_socketutil then
            socketutil:reset_timeout()
        end

        if not res_status then
            local err = "Connection failed: " .. tostring(res_status_code or status or "unknown error")
            if callback then callback(nil, err) end
            return nil, err
        end

        local body = table.concat(sink)
        local code = tonumber(res_status_code)
        if Client.should_retry(code, attempt + 1) then
            attempt = attempt + 1
            socket.sleep(RETRY_BASE_DELAY * attempt)
        else
            return handle_http_response(body, code, callback)
        end
    end
end

-- Parse a (status_code, body) pair into the callback contract.
-- (Exposed on Client for the headless harness: exact-shape error bodies.)
handle_http_response = function(body, code, callback)
    if code and (code < 200 or code >= 300) then
        note_http(code, body)
        local ok_err, decoded_err = pcall(json.decode, body)
        local err_msg = "API error (HTTP " .. tostring(code) .. ")"
        if ok_err and decoded_err and decoded_err.error and decoded_err.error.message then
            err_msg = "API error: " .. decoded_err.error.message
        elseif ok_err and decoded_err and type(decoded_err.message) == "string"
            and decoded_err.message ~= "" then
            -- OpenRouter-style flat errors: {"message": "...", "code": 400}
            err_msg = "API error: " .. decoded_err.message
        elseif body ~= "" then
            err_msg = err_msg .. ": " .. body:sub(1, 200)
        end
        err_msg = with_auth_hint(err_msg, code)
        if callback then callback(nil, err_msg) end
        return nil, err_msg
    end

    local ok_data, data = pcall(json.decode, body)
    if not ok_data or not data then
        local err = "Invalid API response: " .. (body:sub(1, 200))
        if callback then callback(nil, err) end
        return nil, err
    end
    -- LuaJSON decodes null into a truthy sentinel function; without this,
    -- `"content": null` would leak through the guard below as content.
    if type(data) == "table" then
        local Util = require("kotaven_util")
        data = Util.clean_json(data)
    end

    if data.error then
        local err_msg = data.error.message or json.encode(data.error)
        if callback then callback(nil, "API error: " .. err_msg) end
        return nil, "API error: " .. err_msg
    end

    -- Extract content from OpenAI response format
    local content = data.choices
        and data.choices[1]
        and data.choices[1].message
        and data.choices[1].message.content

    if not content or type(content) ~= "string" then
        if callback then callback(nil, "Unexpected API response format") end
        return nil, "Unexpected API response format"
    end

    -- Multi-choice (preset `n > 1`): collect every choice's text so callers
    -- can turn them into swipes.
    local choices
    if type(data.choices) == "table" and #data.choices > 1 then
        choices = {}
        for _, ch in ipairs(data.choices) do
            local c = type(ch) == "table" and ch.message and ch.message.content or nil
            if type(c) == "string" then
                table.insert(choices, c)
            end
        end
    end

    -- Native reasoning channel, usage and finish_reason on the sync path
    -- (SillyTavern parity: collapsible reasoning block, token counters,
    -- cut-response hint).
    local reasoning, usage, finish
    local first_choice = data.choices and data.choices[1]
    if type(first_choice) == "table" then
        reasoning = Client.parse_reasoning_delta(first_choice.message)
        if type(first_choice.finish_reason) == "string" then
            finish = first_choice.finish_reason
        end
    end
    if type(data.usage) == "table" then
        usage = data.usage
    end

    if callback then callback(content, nil, choices, reasoning, usage, finish) end
    return content, nil, reasoning, usage, finish
end

-- Non-streaming completion via curl.
-- curl_sync: blocks until curl finishes (io.popen).
-- curl_bg:   spawns curl in background, polls for the HTTP code, fires the
--            callback asynchronously so the UI never freezes.
curl_completion = function(url, headers, encoded, callback, backend)
    local req_file = os.tmpname()
    local resp_file = os.tmpname()
    local status_file = os.tmpname()

    local f = io.open(req_file, "w")
    if not f then
        if callback then callback(nil, "Failed to create temp file") end
        return nil, "Failed to create temp file"
    end
    f:write(encoded)
    f:close()

    local cmd = 'curl -s --max-time ' .. tostring(math.floor(SYNC_TIMEOUT * 4)) .. ' -X POST -w "%{http_code}"'
    for k, v in pairs(headers) do
        cmd = cmd .. " -H " .. shell_escape(k .. ": " .. v)
    end
    cmd = cmd
        .. " -d @" .. shell_escape(req_file)
        .. " " .. shell_escape(url)
        .. " -o " .. shell_escape(resp_file)

    local function cleanup()
        os.remove(req_file)
        os.remove(resp_file)
        os.remove(status_file)
    end

    local function handle(code_str)
        local code_match = code_str and code_str:match("%d%d%d")
        if not code_match then
            -- No usable status (curl killed, disk full...): report as network
            -- failure instead of pretending HTTP 200 with an empty body.
            cleanup()
            if callback then callback(nil, "No response from server") end
            return
        end
        local http_code = tonumber(code_match)
        local fr = io.open(resp_file, "r")
        local resp = fr and fr:read("*a") or ""
        if fr then fr:close() end
        cleanup()
        return handle_http_response(resp, http_code, callback)
    end

    if backend == "curl_sync" then
        -- Sync curl retries transient failures (429/5xx) with backoff.
        local attempt = 0
        while true do
            local p = io.popen(cmd .. " 2>/dev/null", "r")
            if not p then
                cleanup()
                if callback then callback(nil, "Failed to spawn curl") end
                return nil, "Failed to spawn curl"
            end
            local code_str = p:read("*a")
            p:close()
            local http_code = tonumber(code_str and code_str:match("(%d%d%d)"))
            if Client.should_retry(http_code, attempt + 1) then
                attempt = attempt + 1
                socket.sleep(RETRY_BASE_DELAY * attempt)
            else
                return handle(code_str)
            end
        end
    end

    -- curl_bg: run in the background, poll for the HTTP code
    local bg_cmd = string.format("(%s > %s 2>/dev/null) &", cmd, shell_escape(status_file))
    os.execute(bg_cmd)

    local UIManager = require("ui/uimanager")
    local start_time = socket.gettime()
    local timer

    local function poll()
        local fs = io.open(status_file, "r")
        if fs then
            local content = fs:read("*a")
            fs:close()
            if content and content:match("%d%d%d") then
                handle(content)
                return
            end
        end
        if socket.gettime() - start_time > DEFAULT_TIMEOUT * 4 then
            cleanup()
            if callback then callback(nil, "Request timed out") end
            return
        end
        timer = UIManager:scheduleIn(POLL_INTERVAL, poll)
    end
    timer = UIManager:scheduleIn(POLL_INTERVAL, poll)
    return nil, "background"
end

-- Streaming chat completion via curl background process.
-- Calls on_chunk(chunk_text, accumulated_text) for each SSE chunk
-- Calls on_done(full_text) when stream completes
-- Calls on_error(error_message) on failure
-- Returns a stream_id that can be used to abort via abort_stream()
function Client:start_stream(messages, connection, preset, on_chunk, on_done, on_error)
    preset = preset or {}
    -- Fresh diagnostics per request (see chat_completion).
    Client.last_http = nil
    if not connection or not connection.base_url then
        if on_error then on_error("No API URL configured") end
        return nil
    end

    -- Prompt post-processing (SillyTavern custom-endpoint parity).
    local post = connection.post_processing
    if post and post ~= "" and post ~= "none" then
        messages = require("kt_models").post_process_messages(messages, post)
    end

    local url = chat_url(connection.base_url)
    local payload = self:build_payload(messages, connection, preset, true)

    local ok, encoded = pcall(json.encode, payload)
    if not ok then
        if on_error then on_error("Failed to encode request") end
        return nil
    end

    -- Temp files for request and response
    local req_file = os.tmpname()
    local resp_file = os.tmpname()
    local status_file = os.tmpname()

    local f = io.open(req_file, "w")
    if not f then
        if on_error then on_error("Failed to create temp file") end
        return nil
    end
    f:write(encoded)
    f:close()

    -- Build curl command (auth header only if an API key is present).
    -- The HTTP status is captured to status_file when curl exits so that
    -- 4xx/5xx bodies can be reported instead of a generic stream error.
    local headers = build_headers(connection)
    local cmd = "curl -s -N -X POST"
    for k, v in pairs(headers) do
        cmd = cmd .. " -H " .. shell_escape(k .. ": " .. v)
    end
    cmd = cmd
        .. " -d @" .. shell_escape(req_file)
        .. " " .. shell_escape(url)
        .. " -o " .. shell_escape(resp_file)
        .. " -w %{http_code}"
        .. " > " .. shell_escape(status_file)
        .. " 2>/dev/null & echo $!"

    local pipe = io.popen(cmd, "r")
    if not pipe then
        if on_error then on_error("Failed to spawn curl") end
        os.remove(req_file)
        os.remove(resp_file)
        return nil
    end

    local pid_str = pipe:read("*a")
    pipe:close()
    local pid = tonumber(pid_str:match("%d+"))
    if not pid then
        if on_error then on_error("Failed to start curl stream") end
        os.remove(req_file)
        os.remove(resp_file)
        return nil
    end

    local stream_id = tostring(pid) .. "_" .. tostring(math.random(100000, 999999))
    local accumulated = ""
    local accumulated_reasoning = ""
    local accumulated_usage = nil
    local last_size = 0
    local last_data_time = socket.gettime()
    local running = true
    local timer
    local remnant = ""
    local UIManager = require("ui/uimanager")

    local function cleanup()
        running = false
        if timer then
            UIManager:unschedule(timer)
            timer = nil
        end
        -- Kill curl process
        if pid then
            os.execute("kill " .. tostring(pid) .. " 2>/dev/null")
        end
        os.remove(req_file)
        os.remove(resp_file)
        os.remove(status_file)
        active_streams[stream_id] = nil
    end

    -- Read the HTTP status captured by -w when curl has exited.
    local function read_status()
        local fs = io.open(status_file, "r")
        if not fs then return nil end
        local content = fs:read("*a")
        fs:close()
        return tonumber(content:match("(%d%d%d)"))
    end

    -- Handle a single SSE line. Returns true when the stream should end.
    local function handle_line(line)
        local data_str = line:match("^data:%s*(.*)$")
        if not data_str then return false end

        if data_str == "[DONE]" then
            cleanup()
            if on_done then
                on_done(accumulated,
                    accumulated_reasoning ~= "" and accumulated_reasoning or nil,
                    accumulated_usage, nil)
            end
            return true
        end

        local ok_data, data = pcall(json.decode, data_str)
        if ok_data and type(data) == "table" then
            -- Mid-stream error event (OpenAI/OpenRouter emit these on overload;
            -- some providers use flat {"message", "code"} shapes)
            if (type(data.error) == "table" or (type(data.message) == "string"
                    and type(data.code) == "number")) and not data.choices then
                local msg = (type(data.error) == "table" and data.error.message)
                    or data.message or "API error"
                local scode = (type(data.code) == "number") and data.code or nil
                msg = with_auth_hint(msg, scode)
                -- Mid-stream: HTTP 200 was already committed, so there is no
                -- status - but the raw event line is the evidence. Keep it.
                note_http(nil, data_str)
                cleanup()
                if on_error then on_error(msg) end
                return true
            end
            -- Usage chunk (OpenRouter/OpenAI-compat emit usage on the last
            -- chunk even without stream_options): keep the latest one.
            if type(data.usage) == "table" then
                accumulated_usage = data.usage
            end

            if data.choices and data.choices[1] then
                local choice = data.choices[1]
                local delta = choice.delta
                local finish = choice.finish_reason

                -- delta.content may decode as JSON.null (lightuserdata), not nil
                if type(delta) == "table" and type(delta.content) == "string" and delta.content ~= "" then
                    accumulated = accumulated .. delta.content
                    if on_chunk then
                        on_chunk(delta.content, accumulated, nil, accumulated_reasoning ~= "" and accumulated_reasoning or nil)
                    end
                end

                -- Native reasoning channel (SillyTavern "Request model reasoning"
                -- parity): DeepSeek sends reasoning_content, OpenRouter/xAI send
                -- reasoning. Forwarded as separate callback args so the caller
                -- can render a collapsible reasoning block live.
                local rdelta = Client.parse_reasoning_delta(delta)
                if rdelta then
                    accumulated_reasoning = accumulated_reasoning .. rdelta
                    if on_chunk then
                        on_chunk("", accumulated, rdelta, accumulated_reasoning)
                    end
                end

                -- finish_reason: null decodes as JSON.null; only a string means done
                if type(finish) == "string" and finish ~= "" then
                    cleanup()
                    if on_done then
                        on_done(accumulated,
                            accumulated_reasoning ~= "" and accumulated_reasoning or nil,
                            accumulated_usage, finish)
                    end
                    return true
                end
            end
        end
        return false
    end

    -- Parse new data, buffering partial lines. Returns true when the stream ended.
    local function parse_data(new_data)
        local full_data = remnant .. new_data
        remnant = ""
        while true do
            local nl = full_data:find("\n", 1, true)
            if not nl then break end
            local line = full_data:sub(1, nl - 1)
            full_data = full_data:sub(nl + 1)
            -- Some servers send \r\n
            line = line:gsub("\r$", "")
            if line ~= "" and handle_line(line) then
                remnant = full_data
                return true
            end
        end
        remnant = full_data
        return false
    end

    local function poll()
        if not running then return end

        -- Idle timeout: only fire when no new data arrived for the configured
        -- stream idle cap. A total-duration cap would kill legitimately long
        -- local-model streams that are actively producing tokens.
        if socket.gettime() - last_data_time > STREAM_IDLE_TIMEOUT then
            cleanup()
            if on_error then on_error("Request timed out") end
            return
        end

        local finished = false
        local had_new = false

        -- Read response file
        local f = io.open(resp_file, "r")
        if f then
            local content = f:read("*a")
            f:close()

            if #content > last_size then
                had_new = true
                last_data_time = socket.gettime()
                local new_data = content:sub(last_size + 1)
                last_size = #content
                finished = parse_data(new_data)
            end
        end

        -- If curl died without a clean termination, finish the stream now.
        -- Only checked when no new data arrived, to avoid shelling out every poll.
        if not finished and not had_new and not process_alive(pid) then
            local http_code = read_status()
            cleanup()
            if http_code and http_code >= 400 then
                local fr = io.open(resp_file, "r")
                local body = fr and fr:read("*a") or ""
                if fr then fr:close() end
                local ok_err, decoded = pcall(json.decode, body)
                local msg = "API error (HTTP " .. tostring(http_code) .. ")"
                if ok_err and type(decoded) == "table" and type(decoded.error) == "table"
                    and type(decoded.error.message) == "string" then
                    msg = "API error: " .. decoded.error.message
                elseif ok_err and type(decoded) == "table"
                    and type(decoded.message) == "string" and decoded.message ~= "" then
                    -- OpenRouter-style flat errors (no "error" wrapper)
                    msg = "API error: " .. decoded.message
                elseif body ~= "" then
                    msg = msg .. ": " .. body:sub(1, 200)
                end
                msg = with_auth_hint(msg, http_code)
                note_http(http_code, body)
                if on_error then on_error(msg) end
            elseif accumulated == "" then
                if on_error then on_error("Connection closed before response") end
            else
                -- Truncated stream (no finish_reason/[DONE]): surface as an
                -- error so the caller keeps partial content but knows it is
                -- incomplete, instead of committing it as a full reply.
                if on_error then on_error("Response ended unexpectedly") end
            end
            return
        end

        if running and not finished then
            timer = UIManager:scheduleIn(POLL_INTERVAL, poll)
        end
    end

    -- Start polling
    timer = UIManager:scheduleIn(POLL_INTERVAL, poll)

    active_streams[stream_id] = cleanup
    return stream_id
end

-- Abort an active stream
function Client:abort_stream(stream_id)
    if stream_id and active_streams[stream_id] then
        active_streams[stream_id]()
        active_streams[stream_id] = nil
    end
end

-- Parse a GET /models response body into a sorted list of model IDs.
-- Tolerates the common shapes:
--   OpenAI/OpenRouter/DeepSeek/Groq/Gemini-compat: { data: [{ id }] }
--   Ollama:                                        { models: [{ name }] }
--   bare array:                                    [ "id" | { id|name|model } ]
-- Returns models, err. (Exposed for the headless harness.)
function Client:parse_models_response(body)
    local ok_data, data = pcall(json.decode, tostring(body or ""))
    if not ok_data or type(data) ~= "table" then
        return nil, "Invalid response"
    end
    -- LuaJSON null sentinels become FUNCTIONS; clean before indexing.
    data = require("kotaven_util").clean_json(data)
    local entries
    if type(data.data) == "table" then
        entries = data.data
    elseif type(data.models) == "table" then
        entries = data.models
    else
        entries = data
    end
    if type(entries) ~= "table" or #entries == 0 then
        return nil, "Unexpected response format"
    end
    local ids, seen = {}, {}
    local function push(v)
        if type(v) == "string" and v ~= "" and not seen[v] then
            seen[v] = true
            table.insert(ids, v)
        end
    end
    for _, m in ipairs(entries) do
        if type(m) == "string" then
            push(m)
        elseif type(m) == "table" then
            push(m.id or m.name or m.model)
        end
    end
    if #ids == 0 then
        return nil, "Unexpected response format"
    end
    table.sort(ids)
    return ids, nil
end

-- Fetch the model list of an OpenAI-compatible endpoint (GET /models).
-- Synchronous (curl): quick enough for a picker on e-ink. Calls
-- callback(models, err); models is nil on failure. Returns models, err.
function Client:list_models(connection, callback)
    if not connection or not connection.base_url or connection.base_url == "" then
        if callback then callback(nil, "No API URL configured") end
        return nil, "No API URL configured"
    end
    -- Fresh diagnostics per request (see chat_completion).
    Client.last_http = nil
    local base = tostring(connection.base_url):gsub("/+$", "")
    if base:match("/chat/completions$") then
        base = base:gsub("/chat/completions$", "")
    end
    local url = base .. "/models"
    local headers = build_headers(connection)

    local resp_file = os.tmpname()
    -- Hard caps so a hanging endpoint can never freeze the UI (sync call).
    local cmd = "curl -s --max-time " .. tostring(math.floor(SYNC_TIMEOUT * 2))
        .. " --connect-timeout 10 -w \"%{http_code}\" -X GET"
    for k, v in pairs(headers) do
        cmd = cmd .. " -H " .. shell_escape(k .. ": " .. v)
    end
    cmd = cmd .. " " .. shell_escape(url) .. " -o " .. shell_escape(resp_file)

    local p = io.popen(cmd .. " 2>/dev/null", "r")
    if not p then
        os.remove(resp_file)
        if callback then callback(nil, "Failed to spawn curl") end
        return nil, "Failed to spawn curl"
    end
    local code_str = p:read("*a")
    p:close()
    local http_code = tonumber(code_str and code_str:match("(%d%d%d)"))
    local fr = io.open(resp_file, "r")
    local body = fr and fr:read("*a") or ""
    if fr then fr:close() end
    os.remove(resp_file)

    if not http_code or http_code < 200 or http_code >= 300 then
        note_http(http_code, body)
        local msg = "HTTP " .. tostring(http_code or "?")
        if http_code == 401 or http_code == 403 then
            msg = "API key missing or invalid (" .. msg .. ")"
        elseif http_code == 404 then
            msg = msg .. " (endpoint does not expose /models - set the ID manually)"
        end
        if callback then callback(nil, msg) end
        return nil, msg
    end

    local models, err = self:parse_models_response(body)
    if callback then callback(models, err) end
    return models, err
end

-- Test a connection by sending a simple prompt
-- Forced to the synchronous backend so the result is available immediately.
function Client:test_connection(connection, on_result)
    local test_msgs = {
        { role = "user", content = "Reply with just 'ok'" },
    }
    -- curl_sync: same transport as production calls (curl handles HTTPS even
    -- where LuaSec is unavailable) and synchronous like http_sync.
    local content, err = self:chat_completion(test_msgs, connection, {}, nil, "curl_sync")
    if content then
        if on_result then on_result(true, content) end
        return true, content
    else
        if on_result then on_result(false, err) end
        return false, err
    end
end

--- Handle an HTTP error body and return the user-facing message.
-- (Exposed for the headless harness: exact-shape provider error bodies.)
function Client:decode_error_body(body, code)
    local _, msg = handle_http_response(tostring(body or ""), code or 400, nil)
    return msg
end

return Client
