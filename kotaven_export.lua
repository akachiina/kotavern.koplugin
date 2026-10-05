-- Export helpers for KOTavern.
-- PNG character card writer ported from kotaven.koplugin/kotaven_export.lua.
-- Exported files use the SillyTavern formats so they are interchangeable:
--   character PNG → PNG with ccv3 JSON embedded in the tEXt chunk
--   character JSON → ccv3 JSON card
--   chat → the .jsonl on disk IS the SillyTavern format (raw copy)

local JSON = require("json")
local bit = require("bit")
local lfs = require("libs/libkoreader-lfs")

local Export = {}

-- Base64
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function b64enc(data)
    local r = {}
    for i = 1, #data, 3 do
        local b1 = data:byte(i) or 0
        local b2 = data:byte(i + 1) or 0
        local b3 = data:byte(i + 2) or 0
        local c1 = bit.rshift(b1, 2)
        local c2 = bit.bor(bit.lshift(bit.band(b1, 3), 4), bit.rshift(b2, 4))
        local c3 = bit.bor(bit.lshift(bit.band(b2, 15), 2), bit.rshift(b3, 6))
        local c4 = bit.band(b3, 63)
        r[#r + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
        if i + 1 <= #data then
            r[#r] = r[#r] .. B64:sub(c3 + 1, c3 + 1)
        else
            r[#r] = r[#r] .. "="
        end
        if i + 2 <= #data then
            r[#r] = r[#r] .. B64:sub(c4 + 1, c4 + 1)
        else
            r[#r] = r[#r] .. "="
        end
    end
    return table.concat(r)
end

-- CRC32
local crc32_tbl
local function crc32_init()
    crc32_tbl = {}
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if bit.band(c, 1) == 1 then
                c = bit.bxor(0xEDB88320, bit.rshift(c, 1))
            else
                c = bit.rshift(c, 1)
            end
        end
        crc32_tbl[i] = c
    end
end

local function crc32_bytes(data, crc)
    if not crc32_tbl then crc32_init() end
    crc = bit.bxor(crc or 0, 0xFFFFFFFF)
    for i = 1, #data do
        crc = bit.bxor(crc32_tbl[bit.bxor(bit.band(crc, 0xFF), data:byte(i))], bit.rshift(crc, 8))
    end
    return bit.bxor(crc, 0xFFFFFFFF)
end

-- Pre-computed zlib deflate for a 1x1 transparent RGBA pixel
local ZLIB_1x1 = string.char(
    0x08, 0x1D,  -- zlib header
    0x01,        -- BFINAL=1 BTYPE=00
    0x05, 0x00, 0xFA, 0xFF,  -- LEN=5, NLEN=65530
    0x00, 0x00, 0x00, 0x00, 0x00,  -- raw data
    0x00, 0x05, 0x00, 0x01  -- adler32
)

local PNG_SIG = string.char(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

local function png_chunk(ctype, data)
    local len_str = string.char(
        bit.rshift(bit.band(#data, 0xFF000000), 24),
        bit.rshift(bit.band(#data, 0x00FF0000), 16),
        bit.rshift(bit.band(#data, 0x0000FF00), 8),
        bit.band(#data, 0x000000FF)
    )
    local crc_val = crc32_bytes(ctype .. data)
    local crc_str = string.char(
        bit.rshift(bit.band(crc_val, 0xFF000000), 24),
        bit.rshift(bit.band(crc_val, 0x00FF0000), 16),
        bit.rshift(bit.band(crc_val, 0x0000FF00), 8),
        bit.band(crc_val, 0x000000FF)
    )
    return len_str .. ctype .. data .. crc_str
end

local function uint32be_str(n)
    return string.char(
        bit.rshift(bit.band(n, 0xFF000000), 24),
        bit.rshift(bit.band(n, 0x00FF0000), 16),
        bit.rshift(bit.band(n, 0x0000FF00), 8),
        bit.band(n, 0x000000FF)
    )
end

-- Build a ccv3 card object (SillyTavern "chara_card_v3" spec).
local function card_data(char)    local function arr(v)
        return type(v) == "table" and v or {}
    end
    local function str(v)
        return type(v) == "string" and v or ""
    end
    -- strip private/runtime fields (ST unsetPrivateFields): fav + embedded chat
    local ext = {}
    if type(char.extensions) == "table" then
        for k, v in pairs(char.extensions) do
            if k ~= "fav" and k ~= "chat" then
                ext[k] = v
            end
        end
    end
    local out = {
        name = str(char.name),
        description = str(char.description),
        personality = str(char.personality),
        scenario = str(char.scenario),
        first_mes = str(char.first_mes),
        alternate_greetings = arr(char.alternate_greetings),
        mes_example = str(char.mes_example),
        creator_notes = str(char.creator_notes),
        system_prompt = str(char.system_prompt),
        post_history_instructions = str(char.post_history_instructions),
        creator = str(char.creator),
        tags = arr(char.tags),
        character_version = str(char.character_version) ~= "" and str(char.character_version) or "1.0",
        extensions = ext,
    }
    -- Round-trip embedded lorebooks: dropping this destroyed the book on
    -- every card edit/save.
    if type(char.character_book) == "table" then
        out.character_book = char.character_book
    end
    return out
end

-- Full ccv3 wrapper used by every writer.
local function build_card(char)
    return {
        spec = "chara_card_v3",
        spec_version = "3.0",
        data = card_data(char),
    }
end

function Export.character_to_png(char, filepath)
    local card = build_card(char)
    local json_str = JSON.encode(card)
    local b64_data = b64enc(json_str)
    local text_data = "chara" .. "\0" .. b64_data

    local ihdr_data = uint32be_str(1) .. uint32be_str(1) .. string.char(8, 6, 0, 0, 0)
    local png = PNG_SIG
        .. png_chunk("IHDR", ihdr_data)
        .. png_chunk("tEXt", text_data)
        .. png_chunk("IDAT", ZLIB_1x1)
        .. png_chunk("IEND", "")

    local f = io.open(filepath, "wb")
    if not f then return false, "Cannot write " .. filepath end
    f:write(png)
    f:close()
    return true, filepath
end

function Export.character_to_json(char, filepath)
    local card = build_card(char)
    local f = io.open(filepath, "wb")
    if not f then return false, "Cannot write " .. filepath end
    f:write(JSON.encode(card))
    f:close()
    return true, filepath
end

-- Rewrite a character PNG in place: keeps every chunk (image, palette, ...)
-- and only swaps the card tEXt chunk. For .json files the file is rewritten
-- as a ccv3 card.
function Export.rewrite_png_card(filepath, char)
    local ext = (filepath:lower():match("%.([^%.]+)$") or "")
    if ext == "json" then
        return Export.character_to_json(char, filepath)
    end

    local f = io.open(filepath, "rb")
    if not f then return false, "Cannot open " .. filepath end
    local content = f:read("*a")
    f:close()
    if content:sub(1, 8) ~= PNG_SIG then
        return false, "Not a valid PNG file"
    end

    local json_str = JSON.encode(build_card(char))
    local text_data = "chara" .. "\0" .. b64enc(json_str)

    -- Walk chunks, replace any card tEXt, inject ours before the first IDAT.
    local pos = 9
    local out = PNG_SIG
    local injected = false
    while pos <= #content do
        local len = 0
        for i = 0, 3 do
            len = len * 256 + content:byte(pos + i) or 0
        end
        local ctype = content:sub(pos + 4, pos + 7)
        local chunk = content:sub(pos, pos + 8 + len + 4 - 1)
        if ctype == "tEXt" then
            local payload = content:sub(pos + 8, pos + 8 + len - 1)
            local keyword = payload:match("^([^%z]+)%z")
            if keyword == "ccv3" or keyword == "chara" then
                -- drop old card chunk, replaced by ours below
                chunk = nil
            end
        elseif ctype == "IDAT" and not injected then
            out = out .. png_chunk("tEXt", text_data)
            injected = true
        end
        if chunk then
            out = out .. chunk
        end
        pos = pos + 12 + len
    end
    if not injected then
        return false, "No image data (IDAT) found in PNG"
    end

    local tmp = filepath .. ".tmp"
    local out_f = io.open(tmp, "wb")
    if not out_f then return false, "Cannot write " .. filepath end
    out_f:write(out)
    out_f:close()
    os.rename(tmp, filepath)
    return true, filepath
end

-- Raw file copy (chats are already in SillyTavern format on disk).
function Export.copy_file(src, dst)
    local f = io.open(src, "rb")
    if not f then return false, "Cannot open " .. src end
    local content = f:read("*a")
    f:close()
    local out = io.open(dst, "wb")
    if not out then return false, "Cannot write " .. dst end
    out:write(content)
    out:close()
    return true, dst
end

-- Default export directory inside the plugin data dir.
function Export.export_dir()
    local Storage = require("kt_storage")
    local dir = Storage.data_dir() .. "/exports"
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    return dir
end

-- === Presets (SillyTavern flat format) ===
-- ST stores presets as a flat JSON object (file name = preset name + ".json")
-- mapping the fields in settingsToUpdate (openai.js). Round-trip therefore
-- keeps every known ST team member, and unknown keys are preserved.

-- Map our internal fields to the ST flat preset keys.
local ST_PRESET_KEYS = {
    temperature = "temperature",
    top_p = "top_p",
    top_k = "top_k",
    top_a = "top_a",
    min_p = "min_p",
    repetition_penalty = "repetition_penalty",
    frequency_penalty = "frequency_penalty",
    presence_penalty = "presence_penalty",
    seed = "seed",
    n = "n",
    max_tokens = "openai_max_tokens",
    openai_max_context = "openai_max_context",
    model_id = "openai_model",
    continue_postfix = "continue_postfix",
    -- Prompt Manager structures (v0.6.7): exported so a preset edited here
    -- lands in ST with its utility prompts and saved order intact. key+role+
    -- injection_position/depth+marker+forbid_overrides ride inside entries.
    prompts = "prompts",
    prompt_order = "prompt_order",
}

-- Convert a KOTavern preset (as persisted in Storage.list_presets()) into the
-- flat ST preset object. Known fields map to ST names; unknown ST fields are
-- preserved from preset.st_fields (round-trip).
function Export.preset_to_st(preset)
    local st = {}
    for our_key, st_key in pairs(ST_PRESET_KEYS) do
        if preset[our_key] ~= nil then
            st[st_key] = preset[our_key]
        end
    end
    if preset.streaming ~= nil then
        st.stream_openai = not not preset.streaming
    end
    if type(preset.st_fields) == "table" then
        for k, v in pairs(preset.st_fields) do
            if st[k] == nil then
                st[k] = v
            end
        end
    end
    return st
end

-- Convert a flat ST preset object into a KOTavern preset (id/name left to the
-- caller). Fields ST doesn't name get kept in .st_fields for lossless re-export.
function Export.preset_from_st(data)
    data = data or {}
    if type(data) ~= "table" then return {} end
    local preset = {}
    for our_key, st_key in pairs(ST_PRESET_KEYS) do
        if data[st_key] ~= nil then
            preset[our_key] = data[st_key]
        end
    end
    if type(data.stream_openai) == "boolean" then
        preset.streaming = data.stream_openai
    end
    local st_fields = {}
    for k, v in pairs(data) do
        if ST_PRESET_KEYS[k] == nil and k ~= "stream_openai" then
            st_fields[k] = v
        end
    end
    preset.st_fields = st_fields
    return preset
end

-- Write a KOTavern preset as an ST flat JSON preset (name = filename).
function Export.preset_to_json(preset, filepath)
    local st = Export.preset_to_st(preset)
    local tmp = filepath .. ".tmp"
    local out, err = io.open(tmp, "w")
    if not out then return false, "Cannot write " .. filepath end
    out:write(JSON.encode(st))
    out:close()
    os.rename(tmp, filepath)
    return true, filepath
end

-- Read an ST flat JSON preset file.
function Export.read_preset_json(filepath)
    local f = io.open(filepath, "rb")
    if not f then return nil, "Cannot open " .. filepath end
    local content = f:read("*a")
    f:close()
    local ok, data = pcall(JSON.decode, content)
    if not ok or type(data) ~= "table" then
        return nil, "Invalid preset JSON file"
    end
    -- LuaJSON null sentinels would poison st_fields and break later encodes.
    local Util = require("kotaven_util")
    return Export.preset_from_st(Util.clean_json(data))
end

return Export
