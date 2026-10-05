-- Persistence layer: JSON files on disk
-- Characters: .png files with embedded JSON (SillyTavern format)
-- Connections, presets, personas, settings: .json files
-- Chats: .jsonl files

local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")

local Util = require("kotaven_util")
local Constants = require("kt_constants")

local Storage = {}

-- mtime-keyed read cache: draw functions run on EVERY refresh, and several
-- pages call these loaders per row per paint (chats list, dashboard favorites,
-- lorebooks). Invalidation is automatic - any save bumps the mtime.
local _read_cache = {}
local function cached_table(path, loader)
    local ok_mt, mtime = pcall(lfs.attributes, path, "modification")
    local ent = _read_cache[path]
    if ent and ent.mtime == mtime then
        return ent.value
    end
    local value = loader()
    if ok_mt then
        _read_cache[path] = { mtime = mtime, value = value }
    end
    return value
end

-- Root data directory. A custom root (Settings → Data → Data folder) moves
-- everything under <root>/kotavern; it is honored only while the directory
-- exists (a removed SD card falls back to the default instead of bricking).
local function custom_root()
    local ok, v = pcall(function()
        return G_reader_settings:readSetting("kotavern_data_root")
    end)
    if ok and type(v) == "string" and v ~= "" then
        return v
    end
    return nil
end

local function data_dir()
    local c = custom_root()
    if c then
        local ok, mode = pcall(lfs.attributes, c, "mode")
        if ok and mode == "directory" then
            return c .. "/kotavern"
        end
    end
    return DataStorage:getSettingsDir() .. "/kotavern"
end

local function ensure_dir(path)
    if lfs.attributes(path, "mode") ~= "directory" then
        local ok, err = lfs.mkdir(path)
        if not ok then
            return nil, err
        end
    end
    return path
end

function Storage.ensure_data_dirs()
    local root = data_dir()
    ensure_dir(root)
    ensure_dir(root .. "/characters")
    ensure_dir(root .. "/chats")
    return root
end

-- Debug log (debug.txt): one entry per failed API request, pulled off the
-- device for diagnosis. Capped so it can never fill e-ink storage.
local DEBUG_PATH_TAIL = "/debug.txt"
local DEBUG_MAX_BYTES = 64 * 1024
local DEBUG_KEEP_BYTES = 32 * 1024

function Storage.debug_path()
    return data_dir() .. DEBUG_PATH_TAIL
end

-- Pure trim: append entry to existing text, keeping the tail under the cap.
-- (Exposed for the headless harness; append_debug adds the file I/O.)
function Storage.trim_debug_log(existing, entry)
    existing = tostring(existing or "")
    local combined = existing
    if combined ~= "" and not combined:match("\n$") then
        combined = combined .. "\n"
    end
    combined = combined .. tostring(entry or "") .. "\n"
    if #combined > DEBUG_MAX_BYTES then
        combined = combined:sub(#combined - DEBUG_KEEP_BYTES + 1)
        local nl = combined:find("\n")
        if nl then
            combined = combined:sub(nl + 1)
        end
    end
    return combined
end

-- Append a debug entry atomically (temp + rename). Never throws: a broken
-- debug write must not mask the API error being recorded.
function Storage.append_debug(entry)
    local ok = pcall(function()
        local path = Storage.debug_path()
        ensure_dir(data_dir())
        local f = io.open(path, "r")
        local existing = ""
        if f then
            existing = f:read("*a") or ""
            f:close()
        end
        local combined = Storage.trim_debug_log(existing, entry)
        local tmp = path .. ".tmp"
        local w = io.open(tmp, "w")
        if not w then
            return
        end
        w:write(combined)
        w:close()
        os.rename(tmp, path)
    end)
    return ok
end

-- JSON file helpers
local function read_json_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    if content == "" then
        return nil
    end
    local ok, data = pcall(require("json").decode, content)
    if ok then
        return Util.clean_json(data)
    end
    return nil
end

local function write_json_file(path, data)
    local dir = path:match("^(.*/)")
    if dir then
        ensure_dir(dir)
    end
    local json = require("json")
    -- Defensive: LuaJSON null sentinels that leaked through callers would make
    -- json.encode fail and silently drop the whole write.
    data = Util.clean_json(data)
    local ok, encoded = pcall(json.encode, data)
    if not ok then
        return false, encoded
    end
    -- Atomic write: write to temp, then rename
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "w")
    if not f then
        return false, err
    end
    f:write(encoded)
    f:close()
    os.rename(tmp, path)
    return true
end

-- JSONL helpers
local read_jsonl_header  -- forward declaration (defined below)

local function read_jsonl(path)
    local f = io.open(path, "r")
    if not f then
        return {}
    end
    local lines = {}
    for line in f:lines() do
        if line ~= "" then
            local ok, data = pcall(require("json").decode, line)
            if ok then
                table.insert(lines, Util.clean_json(data))
            end
        end
    end
    f:close()
    return lines
end

local function write_jsonl(path, items)
    local dir = path:match("^(.*/)")
    if dir then
        ensure_dir(dir)
    end
    local json = require("json")
    local lines = {}
    for _, item in ipairs(items or {}) do
        item = Util.clean_json(item)
        local ok, encoded = pcall(json.encode, item)
        if ok then
            table.insert(lines, encoded)
        end
    end
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "w")
    if not f then
        return false, err
    end
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
    os.rename(tmp, path)
    return true
end

function Storage.data_dir()
    return data_dir()
end

function Storage.characters_dir()
    return data_dir() .. "/characters"
end

function Storage.chats_dir()
    return data_dir() .. "/chats"
end

-- === Disk usage (Settings → Data → Storage usage) ==============================
-- Recursive size walk; never throws (a broken dir must not break the paint).

local function dir_size(path, pattern)
    local bytes, count = 0, 0
    local function walk(dir)
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." and not name:match("%.tmp$") then
                local full = dir .. "/" .. name
                local mode = lfs.attributes(full, "mode")
                if mode == "directory" then
                    walk(full)
                elseif mode == "file" and (not pattern or full:match(pattern)) then
                    bytes = bytes + (lfs.attributes(full, "size") or 0)
                    count = count + 1
                end
            end
        end
    end
    pcall(function()
        if lfs.attributes(path, "mode") == "directory" then
            walk(path)
        end
    end)
    return bytes, count
end

-- Human size: 512 B, 1.9 KB, 3.2 MB, 1.0 GB (units need no translation).
function Storage.format_bytes(n)
    n = tonumber(n) or 0
    if n < 1024 then
        return string.format("%d B", math.floor(n))
    elseif n < 1024 * 1024 then
        return string.format("%.1f KB", n / 1024)
    elseif n < 1024 * 1024 * 1024 then
        return string.format("%.1f MB", n / (1024 * 1024))
    end
    return string.format("%.1f GB", n / (1024 * 1024 * 1024))
end

-- Per-category { key, msgid, bytes, count }. Labels resolve via _() at paint.
function Storage.disk_usage()
    local root = data_dir()
    local cats = {
        { key = "characters", msgid = "Character cards", dir = root .. "/characters" },
        { key = "chats", msgid = "Chats", dir = root .. "/chats", pattern = "%.jsonl$" },
        { key = "personas", msgid = "Personas", dir = root .. "/personas" },
        { key = "presets", msgid = "Presets", dir = nil }, -- presets.json + profiles.json below
        { key = "worlds", msgid = "Lorebooks", dir = root .. "/worlds" },
        { key = "images", msgid = "Chat images", dir = root .. "/chat_images" },
        { key = "config", msgid = "Other files", dir = nil }, -- small JSONs + debug log below
    }
    local out = {}
    for _, c in ipairs(cats) do
        local bytes, count = 0, 0
        if c.key == "presets" then
            for _, f in ipairs({ root .. "/presets.json", root .. "/profiles.json" }) do
                local size = lfs.attributes(f, "size")
                if size then
                    bytes = bytes + size
                    count = count + 1
                end
            end
            local presets = Storage.list_presets()
            if type(presets) == "table" then
                count = count + #presets
            end
        elseif c.key == "personas" then
            bytes, count = dir_size(c.dir)
            local size = lfs.attributes(root .. "/personas.json", "size")
            if size then
                bytes = bytes + size
                count = count + 1
            end
        elseif c.key == "config" then
            for _, f in ipairs({ root .. "/connections.json", root .. "/settings.json",
                root .. "/favorites.json", root .. "/personas.json", root .. "/debug.txt" }) do
                local size = lfs.attributes(f, "size")
                if size then
                    bytes = bytes + size
                    count = count + 1
                end
            end
        else
            bytes, count = dir_size(c.dir, c.pattern)
        end
        out[#out + 1] = { key = c.key, msgid = c.msgid, bytes = bytes, count = count }
    end
    return out
end

-- Move the whole data tree to a new root (<root>/kotavern) with a pure-Lua
-- recursive copy (no shell dependency on device), then point the core
-- setting at it. Verifies file counts match. src_override exists only for
-- the headless harness (production always migrates the live data dir).
-- Returns ok, err.
function Storage.migrate_data_root(new_root, src_override)
    new_root = tostring(new_root or ""):gsub("/+$", "")
    local src = src_override or data_dir()
    if new_root == "" or new_root == "/" then
        return false, "invalid"
    end
    local dst = new_root .. "/kotavern"
    if dst == src then
        return true, "same"
    end
    -- Refuse nesting either way (would recurse or orphan data).
    if (dst .. "/"):sub(1, #src + 1) == src .. "/"
        or (src .. "/"):sub(1, #dst + 1) == dst .. "/" then
        return false, "invalid"
    end
    local function copy_file(source, destination)
        local input = io.open(source, "rb")
        if not input then return false end
        local output = io.open(destination, "wb")
        if not output then
            input:close()
            return false
        end
        while true do
            local chunk = input:read(64 * 1024)
            if not chunk then break end
            output:write(chunk)
        end
        input:close()
        output:close()
        return true
    end
    -- mkdir -p (ensure_dir makes a single level only).
    local function ensure_tree(path)
        local parts = {}
        for part in tostring(path):gmatch("[^/]+") do
            parts[#parts + 1] = part
        end
        local cur = path:sub(1, 1) == "/" and "/" or ""
        for _, part in ipairs(parts) do
            cur = cur == "/" and (cur .. part) or (cur ~= "" and cur .. "/" .. part or part)
            if lfs.attributes(cur, "mode") ~= "directory" then
                local ok = lfs.mkdir(cur)
                if not ok then
                    return false
                end
            end
        end
        return true
    end
    local count = 0
    local function copy_tree(from, to)
        if not ensure_tree(to) then
            return false
        end
        local ok, diter, dstate, dctl = pcall(lfs.dir, from)
        if not ok or type(diter) ~= "function" then
            return false
        end
        for name in diter, dstate, dctl do
            if name ~= "." and name ~= ".." then
                local s, d = from .. "/" .. name, to .. "/" .. name
                local mode = lfs.attributes(s, "mode")
                if mode == "directory" then
                    if not copy_tree(s, d) then
                        return false
                    end
                elseif mode == "file" and not name:match("%.tmp$") then
                    if not copy_file(s, d) then
                        return false
                    end
                    count = count + 1
                end
            end
        end
        return true
    end
    if lfs.attributes(src, "mode") == "directory" then
        if not copy_tree(src, dst) then
            return false, "copy"
        end
    else
        if not ensure_tree(dst) then
            return false, "copy"
        end
    end
    -- Verify: same file count on both sides.
    local verify, vcount = 0, 0
    local function count_files(dir)
        local ok, diter, dstate, dctl = pcall(lfs.dir, dir)
        if not ok or type(diter) ~= "function" then return end
        for name in diter, dstate, dctl do
            if name ~= "." and name ~= ".." then
                local full = dir .. "/" .. name
                local mode = lfs.attributes(full, "mode")
                if mode == "directory" then
                    count_files(full)
                elseif mode == "file" and not name:match("%.tmp$") then
                    vcount = vcount + 1
                end
            end
        end
    end
    count_files(dst)
    verify = vcount
    if verify ~= count then
        return false, "copy"
    end
    if G_reader_settings and G_reader_settings.saveSetting then
        G_reader_settings:saveSetting("kotavern_data_root", new_root)
        pcall(function() G_reader_settings:flush() end)
    end
    return true
end

-- === Connections ===
function Storage.list_connections()
    local path = data_dir() .. "/connections.json"
    return read_json_file(path) or {}
end

function Storage.save_connections(connections)
    return write_json_file(data_dir() .. "/connections.json", connections)
end

-- === Connection Profiles (SillyTavern parity) ===
-- A profile snapshots {connection_id, preset_id} so the chat can switch both
-- atomically. Optional fields (stop, start_reply_with) ride along for later.
function Storage.list_profiles()
    local path = data_dir() .. "/profiles.json"
    return read_json_file(path) or {}
end

function Storage.save_profiles(profiles)
    return write_json_file(data_dir() .. "/profiles.json", profiles)
end

-- === Presets ===
function Storage.list_presets()
    local path = data_dir() .. "/presets.json"
    return read_json_file(path) or {}
end

function Storage.save_presets(presets)
    return write_json_file(data_dir() .. "/presets.json", presets)
end

-- === Personas ===
function Storage.personas_images_dir()
    local dir = data_dir() .. "/personas"
    ensure_dir(dir)
    return dir
end

-- === Chat inline images (ST: images inside message markdown) ===
-- Disk cache keyed by a 64-bit hash of the source URL.
function Storage.chat_images_dir()
    local dir = data_dir() .. "/chat_images"
    ensure_dir(dir)
    return dir
end

-- === World Info / Lorebooks (ST format: { entries = { uid: entry } }) ===
function Storage.worlds_dir()
    local dir = data_dir() .. "/worlds"
    ensure_dir(dir)
    return dir
end

function Storage.list_worlds()
    local lfs = require("libs/libkoreader-lfs")
    local dir = Storage.worlds_dir()
    local out = {}
    for name in lfs.dir(dir) do
        local file = name:match("^(.+)%.json$")
        if file then
            table.insert(out, file)
        end
    end
    table.sort(out)
    return out
end

function Storage.load_world(name)
    local path = Storage.worlds_dir() .. "/" .. tostring(name) .. ".json"
    return cached_table(path, function()
        local data = read_json_file(path)
        return type(data) == "table" and data or nil
    end)
end

function Storage.save_world(name, data)
    local path = Storage.worlds_dir() .. "/" .. tostring(name) .. ".json"
    return write_json_file(path, data)
end

function Storage.delete_world(name)
    local path = Storage.worlds_dir() .. "/" .. tostring(name) .. ".json"
    os.remove(path)
    return true
end

function Storage.list_personas()
    local path = data_dir() .. "/personas.json"
    return cached_table(path, function()
        local data = read_json_file(path)
        if not data then
            return { list = {}, active = nil }
        end
        if type(data.list) ~= "table" then
            data.list = {}
        end
        return data
    end)
end

function Storage.save_personas(data)
    return write_json_file(data_dir() .. "/personas.json", data)
end

function Storage.upsert_persona(persona)
    local data = Storage.list_personas()
    if not persona.id or persona.id == "" then
        persona.id = "persona_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
    end
    local found = false
    for i, p in ipairs(data.list) do
        if p.id == persona.id then
            data.list[i] = persona
            found = true
            break
        end
    end
    if not found then
        table.insert(data.list, persona)
    end
    Storage.save_personas(data)
    return persona.id
end

function Storage.delete_persona(id)
    local data = Storage.list_personas()
    local list = {}
    for _, p in ipairs(data.list) do
        if p.id ~= id then
            table.insert(list, p)
        end
    end
    if data.active == id then
        data.active = nil
    end
    data.list = list
    Storage.save_personas(data)
end

function Storage.set_active_persona(id)
    local data = Storage.list_personas()
    data.active = id
    Storage.save_personas(data)
end

-- Remove every chat file belonging to a character (used when deleting the card).
-- The chat dir is keyed on a normalized filename, so distinct names can share
-- one directory ("Anna" vs "anna"); each file's header is the source of truth.
function Storage.delete_chats_for(character_name)
    local dir = Storage.chat_dir(character_name)
    local want = (tostring(character_name or ""):lower())
    for f in lfs.dir(dir) do
        if f:match("%.jsonl$") then
            local path = dir .. "/" .. f
            local header = read_jsonl_header(path)
            local owner = header
                and header.chat_metadata
                and header.chat_metadata.character_name
            -- Keep files whose header names a different character.
            if type(owner) ~= "string" or owner:lower() == want then
                os.remove(path)
            end
        end
    end
end

-- Preview text of a chat's last message (used by the Chats page).
-- Reads only the last JSONL line; cheap even for many chats.
function Storage.chat_preview(path)
    return cached_table(path, function()
        local f = io.open(path, "r")
        if not f then
            return ""
        end
        local last
        for line in f:lines() do
            last = line
        end
        f:close()
        if not last or last == "" then
            return ""
        end
        local ok, msg = pcall(require("json").decode, last)
        if not ok or type(msg) ~= "table" then
            return ""
        end
        msg = Util.clean_json(msg)
        local text = tostring(msg.mes or msg.content or "")
        text = text:gsub("\n", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if #text > 110 then
            text = text:sub(1, 110) .. "…"
        end
        return text
    end)
end

-- === Favorites ===
function Storage.list_favorites()
    local path = data_dir() .. "/favorites.json"
    return cached_table(path, function()
        local data = read_json_file(path)
        if type(data) ~= "table" then
            return {}
        end
        return data
    end)
end

function Storage.save_favorites(favorites)
    return write_json_file(data_dir() .. "/favorites.json", favorites)
end

function Storage.is_favorite(path)
    for _, p in ipairs(Storage.list_favorites()) do
        if p == path then
            return true
        end
    end
    return false
end

-- Toggle favorite state for a character path; returns the new state.
function Storage.toggle_favorite(path)
    local favorites = Storage.list_favorites()
    for i, p in ipairs(favorites) do
        if p == path then
            table.remove(favorites, i)
            Storage.save_favorites(favorites)
            return false
        end
    end
    table.insert(favorites, path)
    Storage.save_favorites(favorites)
    return true
end

function Storage.get_active_persona()
    local data = Storage.list_personas()
    return data.active or nil
end

function Storage.get_persona(id)
    if not id then return nil end
    local data = Storage.list_personas()
    for _, p in ipairs(data.list) do
        if p.id == id then
            return p
        end
    end
    return nil
end

-- === Settings ===
function Storage.load_settings()
    local path = data_dir() .. "/settings.json"
    return read_json_file(path) or {}
end

function Storage.save_settings(settings)
    return write_json_file(data_dir() .. "/settings.json", settings)
end

-- === Characters (PNG-based, basic listing) ===
function Storage.list_character_files()
    local dir = Storage.characters_dir()
    ensure_dir(dir)
    local files = {}
    for f in lfs.dir(dir) do
        if f:match("%.[Pp][Nn][Gg]$") or f:match("%.[Jj][Ss][Oo][Nn]$") then
            table.insert(files, dir .. "/" .. f)
        end
    end
    table.sort(files)
    return files
end

function Storage.character_name_from_path(path)
    local name = path:match("([^/\\]+)%.[Pp][Nn][Gg]$") or path:match("([^/\\]+)%.[Jj][Ss][Oo][Nn]$")
    return name or "unknown"
end

-- === Chats ===
function Storage.chat_dir(character_name)
    local sanitized = Util.safe_filename(character_name)
    local dir = data_dir() .. "/chats/" .. sanitized
    ensure_dir(dir)
    return dir
end

function Storage.chat_path(character_name, chat_id)
    local sanitized = Util.safe_filename(character_name)
    ensure_dir(data_dir() .. "/chats")
    local dir = data_dir() .. "/chats/" .. sanitized
    ensure_dir(dir)
    local filename = Util.escape_path_segment(chat_id or "chat") .. ".jsonl"
    return dir .. "/" .. filename
end

read_jsonl_header = function(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local line = f:read("*l")
    f:close()
    if not line or line == "" then
        return nil
    end
    local ok, data = pcall(require("json").decode, line)
    if ok then
        return Util.clean_json(data)
    end
    return nil
end

-- Header line of a chat file (mtime-cached; cheap enough for per-paint use).
function Storage.chat_header(path)
    return cached_table(tostring(path) .. "#header", function()
        return read_jsonl_header(path)
    end)
end

function Storage.load_chat(path)
    local items = read_jsonl(path)
    if #items == 0 then
        return nil
    end
    local header = table.remove(items, 1)
    local messages = items
    -- Convert ST-schema messages to the internal model (auto-detects legacy too)
    local Models = require("kt_models")
    local meta = Models.from_st_header(header)
    for i, msg in ipairs(messages) do
        messages[i] = Models.normalize_message(msg)
    end
    return {
        header = { chat_metadata = meta },
        messages = messages,
    }
end

-- Replace a single message in the chat file (used for edit / swipe / regen).
function Storage.update_message(chat_path, index, msg)
    local chat = Storage.load_chat(chat_path)
    if not chat then
        return false
    end
    index = tonumber(index)
    if not index or index < 1 or index > #chat.messages then
        return false
    end
    chat.messages[index] = msg
    if chat.header and chat.header.chat_metadata then
        chat.header.chat_metadata.updated_at = os.time()
    end
    return Storage.save_chat(chat_path, chat.header, chat.messages)
end

function Storage.save_chat(path, header, messages)
    local Models = require("kt_models")
    local meta = {}
    if type(header) == "table" then
        if type(header.chat_metadata) == "table" then
            meta = header.chat_metadata
        else
            meta = header
        end
    end
    if not meta.integrity then
        meta.integrity = Util.uuid()
    end
    if not meta.created_at then
        meta.created_at = os.time()
    end
    meta.updated_at = os.time()
    local items = { Models.to_st_header(meta) }
    for _, msg in ipairs(messages or {}) do
        table.insert(items, Models.to_st_message(msg))
    end
    return write_jsonl(path, items)
end

-- Create a new chat for a character
function Storage.create_chat(character_name, chat_path, chat_name, connection_id, persona_id, preset_id)
    local now = os.time()
    local chat_id = "chat_" .. tostring(now) .. "_" .. tostring(math.random(1000, 9999))
    local path = Storage.chat_path(character_name, chat_id)

    local header = {
        chat_metadata = {
            integrity = Util.uuid(),
            created_at = now,
            updated_at = now,
            chat_id = chat_id,
            chat_name = chat_name,
            character_name = character_name,
            character_path = chat_path,
            connection_id = connection_id,
            persona_id = persona_id,
            preset_id = preset_id,
        },
    }

    local messages = {}
    Storage.save_chat(path, header, messages)

    return {
        id = chat_id,
        character_name = character_name,
        name = chat_name,
        connection_id = connection_id,
        persona_id = persona_id,
        preset_id = preset_id,
        path = path,
        created_at = now,
        updated_at = now,
        message_count = 0,
    }
end

local function chat_from_header(path, header)
    header = header or read_jsonl_header(path)
    if not header or not header.chat_metadata then
        return nil
    end
    local meta = header.chat_metadata
    return {
        id = meta.chat_id,
        name = meta.chat_name or (path:match("([^/]+)%.jsonl$") or "Chat"),
        path = path,
        character_name = meta.character_name,
        character_path = meta.character_path,
        connection_id = meta.connection_id,
        persona_id = meta.persona_id,
        preset_id = meta.preset_id,
        created_at = meta.created_at,
        updated_at = meta.updated_at,
    }
end

-- List all chats for a character
function Storage.list_chats(character_name)
    local dir = Storage.chat_dir(character_name)
    local chats = {}
    for f in lfs.dir(dir) do
        if f:match("%.jsonl$") then
            local path = dir .. "/" .. f
            local attr = lfs.attributes(path)
            local chat = chat_from_header(path)
            if chat then
                chat.modified = attr and attr.modification or 0
                table.insert(chats, chat)
            else
                local name = f:match("^(.*)%.jsonl$")
                table.insert(chats, {
                    id = name,
                    name = name,
                    path = path,
                    character_name = character_name,
                    modified = attr and attr.modification or 0,
                })
            end
        end
    end
    table.sort(chats, function(a, b) return a.modified > b.modified end)
    return chats
end

function Storage.list_all_chats()
    local root = data_dir() .. "/chats"
    ensure_dir(root)
    local chats = {}
    for char_dir in lfs.dir(root) do
        if char_dir ~= "." and char_dir ~= ".." then
            local path = root .. "/" .. char_dir
            local mode = lfs.attributes(path, "mode")
            if mode == "directory" then
                for f in lfs.dir(path) do
                    if f:match("%.jsonl$") then
                        local full_path = path .. "/" .. f
                        local attr = lfs.attributes(full_path)
                        local chat = chat_from_header(full_path)
                        if chat then
                            chat.modified = attr and attr.modification or 0
                            table.insert(chats, chat)
                        end
                    end
                end
            end
        end
    end
    table.sort(chats, function(a, b) return a.modified > b.modified end)
    return chats
end

-- Append a message to a chat file
function Storage.append_message(chat_path, role, content, extra, extra_name)
    local chat = Storage.load_chat(chat_path)
    if not chat then
        local header = { chat_metadata = { integrity = Util.uuid(), updated_at = os.time() } }
        local msg = {
            role = role,
            content = content,
            name = (role == "user") and "User" or nil,
            send_date = os.time(),
        }
        if extra then
            for k, v in pairs(extra) do msg[k] = v end
        end
        Storage.save_chat(chat_path, header, { msg })
        return true
    end

    local msg = {
        role = role,
        content = content,
        name = extra_name or ((role == "user") and "User" or nil),
        send_date = os.time(),
    }
    if extra then
        for k, v in pairs(extra) do msg[k] = v end
    end
    table.insert(chat.messages, msg)
    if chat.header and chat.header.chat_metadata then
        chat.header.chat_metadata.updated_at = os.time()
    end
    Storage.save_chat(chat_path, chat.header, chat.messages)
    return true
end

return Storage
