-- Regex scripts engine (ST extension subset). Lua patterns (documented:
-- not PCRE). Replacement supports $1..$9 backreferences mapped to Lua %1..%9.
--
-- RE.apply(text, scripts, placement) → transformed text
--   placement: "display" (rendering only) | "prompt" (API payload only)
--   scripts: { { scriptName, find, replace, placement = "display"|"prompt"|"both", disabled } }

local RE = {}

function RE.apply(text, scripts, placement)
    text = tostring(text or "")
    for _, s in ipairs(scripts or {}) do
        if type(s) == "table" and not s.disabled
            and type(s.find) == "string" and s.find ~= ""
            and (s.placement == "both" or s.placement == placement or s.placement == nil) then
            local repl = tostring(s.replace or ""):gsub("%$(%d+)", "%%%1")
            local ok, result = pcall(function()
                return text:gsub(s.find, repl)
            end)
            if ok and type(result) == "string" then
                text = result
            end
        end
    end
    return text
end

return RE
