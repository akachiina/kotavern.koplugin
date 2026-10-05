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

local function decode_base64(data)
    local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    data = string.gsub(data, '[^' .. b .. '=]', '')
    return (data:gsub('.', function(x)
        if x == '=' then return '' end
        local r, f = '', (b:find(x) - 1)
        for i = 6, 1, -1 do
            r = r .. (f % 2^i - f % 2^(i-1) > 0 and '1' or '0')
        end
        return r
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if #x ~= 8 then return '' end
        local c = 0
        for i = 1, 8 do
            c = c + (x:sub(i, i) == '1' and 2^(8 - i) or 0)
        end
        return string.char(c)
    end))
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
