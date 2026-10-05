-- Backup: full-data export to a single zip + restore.
-- Store-only ZIP writer (no compression dependency; PNGs are compressed
-- already). CRC32 via LuaJIT's bit library. Reading back uses ffi/archiver
-- (same as the updater). Pure helpers are exposed for the headless harness.

local bit = require("bit")

local Constants = require("kt_constants")

local Backup = {}

Backup.MANIFEST_NAME = "kotavern-backup.json"

-- === CRC32 (IEEE, table-driven) ==================================================

local crc_table = {}
do
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if bit.band(c, 1) == 1 then
                c = bit.bxor(0xEDB88320, bit.rshift(c, 1))
            else
                c = bit.rshift(c, 1)
            end
        end
        crc_table[i + 1] = c
    end
end

function Backup.crc32(data)
    local crc = 0xFFFFFFFF
    for i = 1, #data do
        crc = bit.bxor(crc_table[bit.bxor(bit.band(crc, 0xFF), data:byte(i)) + 1], bit.rshift(crc, 8))
    end
    return bit.bxor(crc, 0xFFFFFFFF)
end

-- === Little-endian packing (Lua 5.1 has no string.pack) ===========================

local function u16(n)
    n = math.floor(tonumber(n) or 0) % 65536
    return string.char(n % 256, math.floor(n / 256) % 256)
end

local function u32(n)
    n = math.floor(tonumber(n) or 0) % 4294967296
    return string.char(n % 256, math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function dos_datetime(when)
    local t = os.date("*t", when or os.time())
    local time = bit.bor(bit.lshift(math.min(t.hour, 23), 11),
        bit.bor(bit.lshift(math.min(t.min, 59), 5), math.floor(math.min(t.sec, 59) / 2)))
    local date = bit.bor(bit.lshift(math.max(t.year - 1980, 0), 9),
        bit.bor(bit.lshift(t.month, 5), t.day))
    return u16(time), u16(date)
end

-- === Writer ==========================================================================
-- entries: { { name = "dir/file" (dirs end with "/"), path = disk file }
--          | { name = ..., data = "string" } }. Streams file bodies in chunks
-- so multi-MB cards never sit fully in RAM twice. Returns ok, err.

local CHUNK = 64 * 1024

function Backup.zip_write(zip_path, entries)
    local out, err = io.open(zip_path, "wb")
    if not out then
        return false, tostring(err)
    end
    local central = {}
    local offset = 0
    local function write(s)
        out:write(s)
        offset = offset + #s
    end
    for _, e in ipairs(entries or {}) do
        local name = tostring(e.name or "")
        if name ~= "" then
            local is_dir = name:sub(-1) == "/"
            local size, crc = 0, 0
            local mtime, mdate = dos_datetime(os.time())
            write("PK\003\004" .. u16(20) .. u16(0x0800) .. u16(0) .. mtime .. mdate)
            local crc_pos = offset
            write(u32(0) .. u32(0) .. u32(0)) -- crc, csize, usize (patched below)
            write(u16(#name) .. u16(0))
            write(name)
            local data_start = offset
            if not is_dir then
                crc = 0xFFFFFFFF
                if e.data ~= nil then
                    local data = tostring(e.data)
                    size = #data
                    -- table-driven over the string in one go (manifest-sized)
                    for i = 1, #data do
                        crc = bit.bxor(crc_table[bit.bxor(bit.band(crc, 0xFF), data:byte(i)) + 1],
                            bit.rshift(crc, 8))
                    end
                    write(data)
                elseif e.path then
                    local f = io.open(e.path, "rb")
                    if not f then
                        out:close()
                        os.remove(zip_path)
                        return false, "Could not read " .. tostring(e.path)
                    end
                    while true do
                        local chunk = f:read(CHUNK)
                        if not chunk then break end
                        size = size + #chunk
                        for i = 1, #chunk do
                            crc = bit.bxor(crc_table[bit.bxor(bit.band(crc, 0xFF), chunk:byte(i)) + 1],
                                bit.rshift(crc, 8))
                        end
                        write(chunk)
                    end
                    f:close()
                end
                crc = bit.bxor(crc, 0xFFFFFFFF)
            end
            -- Patch crc + sizes (re-seek: cheap, header is small).
            local here = offset
            out:seek("set", crc_pos)
            out:write(u32(crc) .. u32(size) .. u32(size))
            out:seek("set", here)
            offset = here
            central[#central + 1] = {
                name = name, crc = crc, size = size,
                mtime = mtime, mdate = mdate,
                -- local header = 30 bytes + name (sig 4 + fixed 26)
                offset = data_start - (30 + #name),
                is_dir = is_dir,
            }
        end
    end
    local cd_start = offset
    for _, c in ipairs(central) do
        write("PK\001\002" .. u16(20) .. u16(20) .. u16(0x0800) .. u16(0)
            .. c.mtime .. c.mdate .. u32(c.crc) .. u32(c.size) .. u32(c.size)
            .. u16(#c.name) .. u16(0) .. u16(0) .. u16(0) .. u16(0)
            .. u32(c.is_dir and 0x10 or 0) .. u32(c.offset))
        write(c.name)
    end
    local cd_size = offset - cd_start
    write("PK\005\006" .. u16(0) .. u16(0) .. u16(#central) .. u16(#central)
        .. u32(cd_size) .. u32(cd_start) .. u16(0))
    out:close()
    return true
end

-- === File collection ==================================================================
-- Relative paths under root (dirs end with "/"), skipping *.tmp. Pure walk
-- over lfs; missing root yields {} (never throws).

function Backup.collect_files(root)
    local out = {}
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then return out end
    local function walk(dir, rel)
        local ok, diter, dstate, dctl = pcall(lfs.dir, dir)
        if not ok or type(diter) ~= "function" then return end
        for name in diter, dstate, dctl do
            if name ~= "." and name ~= ".." and not name:match("%.tmp$") then
                local full = dir .. "/" .. name
                local rpath = (rel == "" and name or rel .. "/" .. name)
                local mode_ok, mode = pcall(lfs.attributes, full, "mode")
                if mode_ok and mode == "directory" then
                    out[#out + 1] = rpath .. "/"
                    walk(full, rpath)
                elseif mode_ok and mode == "file" then
                    out[#out + 1] = rpath
                end
            end
        end
    end
    pcall(function()
        if lfs.attributes(root, "mode") == "directory" then
            walk(root, "")
        end
    end)
    table.sort(out)
    return out
end

-- Manifest content (JSON-encoded by the caller path).
function Backup.manifest(file_count)
    local json = require("json")
    local ok, encoded = pcall(json.encode, {
        app = "kotavern",
        kind = "backup",
        version = Constants.VERSION,
        date = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        files = file_count or 0,
    })
    if not ok then return nil end
    return encoded
end

-- Validate a decoded manifest table.
function Backup.valid_manifest(m)
    return type(m) == "table" and m.app == "kotavern" and m.kind == "backup"
end

-- Extract a backup zip into stage_dir (guarded paths). Returns ok, err.
-- The manifest itself is NOT validated here - read it from the stage after.
function Backup.restore_zip(zip_path, stage_dir)
    local ok_arch, Archiver = pcall(require, "ffi/archiver")
    if not ok_arch or not Archiver then
        return false, "Archive support is unavailable in this KOReader build."
    end
    local Update = require("kt_update")
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local function ensure(dir)
        if not ok_lfs then return end
        if lfs.attributes(dir, "mode") ~= "directory" then
            lfs.mkdir(dir)
        end
    end
    local archive = Archiver.Reader:new()
    if not archive:open(zip_path) then
        return false, archive.err or "Could not open backup archive."
    end
    local entries = 0
    for entry in archive:iterate() do
        if Update.unsafe_entry(entry.path)
            or (entry.mode ~= "file" and entry.mode ~= "directory") then
            archive:close()
            return false, "Backup archive has an invalid layout."
        end
        if entry.mode == "directory" then
            ensure(stage_dir .. "/" .. entry.path)
        elseif not archive:extractToPath(entry.path, stage_dir .. "/" .. entry.path) then
            local err = archive.err or "Could not unpack backup archive."
            archive:close()
            return false, err
        end
        entries = entries + 1
    end
    local err = archive.err
    archive:close()
    if err or entries == 0 then return false, err or "Backup archive is empty." end
    return true
end

-- Read + validate the manifest from an extracted stage. Returns manifest | nil.
function Backup.read_manifest(stage_dir)
    local f = io.open(stage_dir .. "/" .. Backup.MANIFEST_NAME, "r")
    if not f then return nil end
    local content = f:read("*a") or ""
    f:close()
    local json = require("json")
    local ok, decoded = pcall(json.decode, content)
    if not ok or not Backup.valid_manifest(decoded) then
        return nil
    end
    local Util = require("kotaven_util")
    return Util.clean_json(decoded)
end

return Backup
