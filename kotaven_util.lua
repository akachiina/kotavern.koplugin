local Util = {}

function Util.fixUtf8(str, replacement)
    if not str then
        return ""
    end
    replacement = replacement or ""
    -- Remove invalid UTF-8 sequences
    return tostring(str):gsub("[%z\xc0-\xdf][\x80-\xbf]*", replacement)
        :gsub("[\xe0-\xef][\x80-\xbf][\x80-\xbf]*", replacement)
        :gsub("[\xf0-\xf7][\x80-\xbf][\x80-\xbf][\x80-\xbf]*", replacement)
        :gsub("[\x80-\xbf]", replacement)
        :gsub("[\xc0-\xff]", replacement)
end

function Util.trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

function Util.uuid()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return template:gsub("[xy]", function(c)
        local v = math.random(0, 15)
        if c == "x" then
            return string.format("%x", v)
        else
            return string.format("%x", v % 4 + 8)
        end
    end)
end

function Util.safe_filename(name)
    if not name then return "unknown" end
    -- Replace non-alphanumeric chars with underscores
    local safe = tostring(name):lower():gsub("[^%w_%-]", "_")
    safe = safe:gsub("_+", "_"):gsub("^_", ""):gsub("_$", "")
    if safe == "" then safe = "unknown" end
    return safe
end

function Util.escape_path_segment(segment)
    return tostring(segment or ""):gsub("[\\/:*?\"<>|]", "_")
end

-- Deep-clean a table decoded by KOReader's LuaJSON: JSON `null`/`undefined`
-- decode into sentinel functions, so `t.field or default` picks the sentinel
-- (a function) instead of the default. Replace those sentinels with nil.
function Util.clean_json(value)
    if type(value) ~= "table" then
        return value
    end
    local ok, json = pcall(require, "json")
    if not ok or not json or not json.util then
        return value
    end
    local json_util = json.util
    local stack = { value }
    while #stack > 0 do
        local t = table.remove(stack)
        for k, v in pairs(t) do
            if v == json_util.null or v == json_util.undefined then
                t[k] = nil
            elseif type(v) == "table" then
                table.insert(stack, v)
            end
        end
    end
    return value
end

return Util
