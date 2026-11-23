-- PNG Character Card parser (SillyTavern format)
-- Extracts embedded JSON from PNG tEXt chunks (ccv3 > chara)

local Png = {}

local Util = require("kotaven_util")

local function read_int(file)
    local s = file:read(4)
    if not s or #s < 4 then return nil end
    local b1, b2, b3, b4 = s:byte(1, 4)
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

-- Base64 decode with a lookup table: the old per-character implementation
-- expanded every character into six binary digits (a 66 KB card became a
-- 500 KB intermediate string and took 35 ms per card on a PC - minutes on a
-- Kindle). The table version is ~1 ms for the same payload.
local B64_VALUES = {}
do
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 0, 63 do
        B64_VALUES[alphabet:sub(i + 1, i + 1)] = i
    end
end

local function decode_base64(data)
    if type(data) ~= "string" then return "" end
    -- Ignore everything outside the alphabet (newlines in wrapped payloads)
    -- and the padding ("=" is simply not data).
    data = data:gsub("[^A-Za-z0-9+/]", "")
    local out = {}
    local n = 0
    local i = 1
    local len = #data
    while i + 3 <= len do
        local c1 = B64_VALUES[data:sub(i, i)]
        local c2 = B64_VALUES[data:sub(i + 1, i + 1)]
        local c3 = B64_VALUES[data:sub(i + 2, i + 2)]
        local c4 = B64_VALUES[data:sub(i + 3, i + 3)]
        n = n + 1
        out[n] = string.char(c1 * 4 + math.floor(c2 / 16),
            (c2 % 16) * 16 + math.floor(c3 / 4),
            (c3 % 4) * 64 + c4)
        i = i + 4
    end
    local rest = len - i + 1
    -- A trailing group of 2 or 3 characters carries 1 or 2 whole bytes; the
    -- remaining bits are padding and are DROPPED (the old decoder dropped
    -- the incomplete trailing group too).
    if rest == 2 then
        local c1 = B64_VALUES[data:sub(i, i)]
        local c2 = B64_VALUES[data:sub(i + 1, i + 1)]
        n = n + 1
        out[n] = string.char(c1 * 4 + math.floor(c2 / 16))
    elseif rest == 3 then
        local c1 = B64_VALUES[data:sub(i, i)]
        local c2 = B64_VALUES[data:sub(i + 1, i + 1)]
        local c3 = B64_VALUES[data:sub(i + 2, i + 2)]
        n = n + 1
        out[n] = string.char(c1 * 4 + math.floor(c2 / 16),
            (c2 % 16) * 16 + math.floor(c3 / 4))
    end
    return table.concat(out)
end

-- Extract raw JSON string from a PNG file
function Png.extract_json(filepath)
    local f = io.open(filepath, "rb")
    if not f then return nil, "Cannot open file" end

    local sig = f:read(8)
    if sig ~= "\137PNG\r\n\26\n" then
        f:close()
        return nil, "Not a valid PNG file"
    end

    local ccv3_data = nil
    local chara_data = nil

    while true do
        local len = read_int(f)
        if not len then break end
        local ctype = f:read(4)
        if not ctype then break end
        if ctype == "IDAT" then
            -- Image data: hundreds of kilobytes per card and never needed.
            -- Seek over the payload and the CRC instead of reading them.
            f:seek("cur", len + 4)
        else
            local data = ""
            if len > 0 then
                data = f:read(len)
            end
            f:read(4) -- CRC
            if ctype == "tEXt" then
                local null_pos = data:find("\0")
                if null_pos then
                    local keyword = data:sub(1, null_pos - 1)
                    local text = data:sub(null_pos + 1)
                    if keyword == "ccv3" then
                        ccv3_data = text
                    elseif keyword == "chara" then
                        chara_data = text
                    end
                end
            elseif ctype == "IEND" then
                break
            end
        end
    end
    f:close()

    local target_data = ccv3_data or chara_data
    if not target_data then
        return nil, "No character card data found in PNG"
    end

    local json_str = decode_base64(target_data)
    if not json_str or json_str == "" then
        return nil, "Failed to decode base64 data"
    end

    return json_str
end

local function parse_json_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil, "Cannot open JSON file"
    end
    local content = f:read("*a")
    f:close()
    local ok, data = pcall(require("json").decode, content)
    if not ok then
        return nil, "Failed to parse JSON character file"
    end
    return Util.clean_json(data)
end

-- Parse a PNG character card or JSON character file and return a normalized character table
function Png.parse_character(png_path)
    if png_path:lower():match("%.json$") then
        local data, err = parse_json_file(png_path)
        if not data then
            return nil, err
        end
        local card = data.data or data
        local name = png_path:match("([^/\\]+)%.json$") or "unknown"
        return {
            id = name,
            name = card.name or data.name or name,
            description = card.description or "",
            personality = card.personality or "",
            scenario = card.scenario or "",
            first_mes = card.first_mes or "",
            alternate_greetings = card.alternate_greetings or {},
            mes_example = card.mes_example or "",
            system_prompt = card.system_prompt or "",
            post_history_instructions = card.post_history_instructions or "",
            creator_notes = card.creator_notes or "",
            tags = card.tags or {},
            creator = card.creator or "",
            character_version = card.character_version or "1.0",
            extensions = card.extensions or {},
            -- Preserved so editing+saving a card never destroys embedded lore.
            character_book = card.character_book,
            png_path = png_path,
        }
    end

    local json_str, err = Png.extract_json(png_path)
    if not json_str then
        return nil, err
    end

    local ok, data = pcall(require("json").decode, json_str)
    if not ok then
        return nil, "Failed to parse character JSON"
    end
    data = Util.clean_json(data)

    -- Handle both V3 (spec: chara_card_v3, data: {...}) and V2 (flat)
    local card = data.data or data
    local name = png_path:match("([^/]+)%.png$") or "unknown"

    return {
        id = name,
        name = card.name or data.name or name,
        description = card.description or "",
        personality = card.personality or "",
        scenario = card.scenario or "",
        first_mes = card.first_mes or "",
        alternate_greetings = card.alternate_greetings or {},
        mes_example = card.mes_example or "",
        system_prompt = card.system_prompt or "",
        post_history_instructions = card.post_history_instructions or "",
        creator_notes = card.creator_notes or "",
        tags = card.tags or {},
        creator = card.creator or "",
        character_version = card.character_version or "1.0",
        extensions = card.extensions or {},
        -- Preserved so editing+saving a card never destroys embedded lore.
        character_book = card.character_book,
        png_path = png_path,
    }
end

return Png
