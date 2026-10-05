-- Message content parser: Markdown + the HTML subset SillyTavern models
-- emit, converted to paintable blocks. Derived from ZenPM's markdown.lua.
--
-- Md.parse(text) → blocks:
--   {kind="paragraph"|"heading"|"code"|"quote"|"list"|"rule"|"table"|"image", ...}
--   Whole-line markdown images (and HTML <img>) become {kind="image",
--   url=..., alt=...}; images inline inside a paragraph stay placeholders.
-- Md.inline(text) → PTF-encoded line (bold via TextBoxWidget's protocol)

local Md = {}

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

-- === HTML → Markdown (the subset models actually emit) ===

local function prefix_lines(prefix, text)
    return (tostring(text or ""):gsub("\n", "\n" .. prefix))
end

local function html_to_markdown(value)
    local s = tostring(value or "")
    -- Comments and script/style blocks
    s = s:gsub("<!%-%-.-%-%->", "")
    s = s:gsub("<script[^>]*>.-</script>", "")
    s = s:gsub("<style[^>]*>.-</style>", "")
    -- Images → whole-line markdown images (rendered as blocks; see parse)
    s = s:gsub("<img%s+[^>]*>", function(tag)
        local src = tag:match("[sS][rR][cC]%s*=%s*\"([^\"]*)\"")
            or tag:match("[sS][rR][cC]%s*=%s*'([^']*)'")
        local alt = tag:match("[aA][lL][tT]%s*=%s*\"([^\"]*)\"")
            or tag:match("[aA][lL][tT]%s*=%s*'([^']*)'")
        if src and src ~= "" then
            return "\n![" .. (alt or "") .. "](" .. src .. ")\n"
        end
        return "[image: " .. (alt and alt ~= "" and alt or "image") .. "]"
    end)
    -- Links keep only the label
    s = s:gsub("<a%s[^>]*>(.-)</a>", "%1")
    s = s:gsub("</?a>", "")
    -- Line breaks / paragraphs / divs
    s = s:gsub("<br%s*/?>", "\n")
    s = s:gsub("</?p[^>]*>", "\n\n")
    s = s:gsub("</?div[^>]*>", "\n")
    s = s:gsub("<hr%s*/?>", "\n---\n")
    -- Headings
    for level = 1, 6 do
        local hashes = string.rep("#", level)
        s = s:gsub("<h" .. level .. "[^>]*>", "\n" .. hashes .. " ")
        s = s:gsub("</h" .. level .. ">", "\n")
    end
    -- Lists
    s = s:gsub("<li[^>]*>", "\n- ")
    s = s:gsub("</?ul[^>]*>", "\n")
    s = s:gsub("</?ol[^>]*>", "\n")
    s = s:gsub("</li>", "")
    -- Blockquote: prefix the inner lines
    s = s:gsub("<blockquote[^>]*>(.-)</blockquote>", function(inner)
        return "\n" .. prefix_lines("> ", inner) .. "\n"
    end)
    s = s:gsub("</?blockquote[^>]*>", "\n")
    -- Code
    s = s:gsub("<pre[^>]*>", "\n```\n")
    s = s:gsub("</pre>", "\n```\n")
    s = s:gsub("</?code>", "`")
    -- Emphasis (italic/underline render as bold on e-ink: single PTF protocol)
    s = s:gsub("<%s*(b|strong)%s*>", "**")
    s = s:gsub("</%s*(b|strong)%s*>", "**")
    s = s:gsub("<%s*(i|em|u|cite)%s*>", "**")
    s = s:gsub("</%s*(i|em|u|cite)%s*>", "**")
    s = s:gsub("<%s*(s|strike|del|small|sub|sup)%s*>", "")
    s = s:gsub("</%s*(s|strike|del|small|sub|sup)%s*>", "")
    -- Details/summary: summary becomes a bold fold label
    s = s:gsub("<summary[^>]*>", "\n**▸ ")
    s = s:gsub("</summary>", "**\n")
    s = s:gsub("</?details[^>]*>", "\n")
    -- Font/span/center and anything unknown
    s = s:gsub("<[^>]->", "")
    -- Collapse the whitespace the tag stripping left behind (keep \n\n breaks)
    s = s:gsub("[ \t]+\n", "\n"):gsub("\n[ \t]+", "\n"):gsub("\n{3,}", "\n\n")
    return s
end

-- === Inline formatting (PTF bold protocol, from ZenPM) ===

local PTF_HEADER = "\u{FFF1}"
local PTF_BOLD_START = "\u{FFF2}"
local PTF_BOLD_END = "\u{FFF3}"

local function underscore_emphasis(value, marker, bold)
    local output = {}
    local position = 1
    while position <= #value do
        local start = value:find(marker, position, true)
        if not start then
            table.insert(output, value:sub(position))
            break
        end
        local before = start == 1 and "" or value:sub(start - 1, start - 1)
        local ending = value:find(marker, start + #marker, true)
        if before:match("[%w]") or not ending then
            table.insert(output, value:sub(position, start + #marker - 1))
            position = start + #marker
        else
            local text = value:sub(start + #marker, ending - 1)
            local after = value:sub(ending + #marker, ending + #marker)
            if text == "" or text:match("^%s") or text:match("%s$") or after:match("[%w]") then
                table.insert(output, value:sub(position, start + #marker - 1))
                position = start + #marker
            else
                table.insert(output, value:sub(position, start - 1))
                table.insert(output, bold(text))
                position = ending + #marker
            end
        end
    end
    return table.concat(output)
end

function Md.inline(value, plain)
    if plain then
        return tostring(value or "")
    end
    value = tostring(value or "")
    value = value:gsub("`([^`]+)`", "%1")
    local formatted = false
    local function bold(text)
        formatted = true
        return PTF_BOLD_START .. text .. PTF_BOLD_END
    end
    value = value:gsub("%*%*%*([^*]+)%*%*%*", bold)
    value = value:gsub("%*%*([^*]+)%*%*", bold)
    value = underscore_emphasis(value, "__", bold)
    value = value:gsub("%*([^*]+)%*", bold)
    value = underscore_emphasis(value, "_", bold)
    return formatted and PTF_HEADER .. value or value
end

Md.PTF_HEADER = PTF_HEADER

-- === Block parsing (port of ZenPM's parser) ===

local function table_cells(line)
    if not tostring(line):find("|", 1, true) then
        return nil
    end
    line = trim(line)
    line = line:gsub("^|", ""):gsub("|$", "")
    local cells = {}
    for cell in (line .. "|"):gmatch("(.-)|") do
        local value = trim(cell):gsub("\\|", "|")
        table.insert(cells, value)
    end
    return #cells > 1 and cells or nil
end

local function table_separator(line, column_count)
    local cells = table_cells(line)
    if not cells or #cells ~= column_count then
        return false
    end
    for _, cell in ipairs(cells) do
        if not cell:match("^:?-+:?$") then
            return false
        end
    end
    return true
end

function Md.parse(value)
    value = html_to_markdown(value)
    local lines = {}
    for line in (value .. "\n"):gmatch("(.-)\n") do
        table.insert(lines, line)
    end

    local blocks = {}
    local i = 1
    while i <= #lines do
        local line = lines[i]
        if line:match("^%s*$") then
            i = i + 1
        else
            local fence = line:match("^%s*```")
            local hashes, heading = line:match("^%s*(#+)%s+(.+)$")
            local unordered = line:match("^(%s*)[-+*]%s+(.+)$")
            local ordered_indent, ordered_number, ordered_text = line:match("^(%s*)(%d+)[%.)]%s+(.+)$")
            if fence then
                local code = {}
                i = i + 1
                while i <= #lines and not lines[i]:match("^%s*```") do
                    table.insert(code, lines[i])
                    i = i + 1
                end
                table.insert(blocks, { kind = "code", text = table.concat(code, "\n") })
                if i <= #lines then i = i + 1 end
            elseif hashes then
                table.insert(blocks, { kind = "heading", level = #hashes, text = heading })
                i = i + 1
            elseif line:match("^%s*[-*_]%s*[-*_]%s*[-*_][%s-*_]*$") then
                table.insert(blocks, { kind = "rule" })
                i = i + 1
            elseif line:match("^%s*>") then
                local quote = {}
                while i <= #lines and lines[i]:match("^%s*>") do
                    table.insert(quote, (lines[i]:gsub("^%s*>%s?", "")))
                    i = i + 1
                end
                table.insert(blocks, { kind = "quote", text = table.concat(quote, "\n") })
            elseif unordered or ordered_number then
                local items = {}
                local number = tonumber(ordered_number)
                while i <= #lines do
                    local indent, item = lines[i]:match("^(%s*)[-+*]%s+(.+)$")
                    local item_indent, item_number, numbered_item = lines[i]:match("^(%s*)(%d+)[%.)]%s+(.+)$")
                    if number then
                        if not numbered_item then break end
                        table.insert(items, item_indent .. tostring(item_number) .. ". " .. numbered_item)
                    else
                        if not item then break end
                        table.insert(items, indent .. "• " .. item)
                    end
                    i = i + 1
                end
                table.insert(blocks, { kind = "list", text = table.concat(items, "\n") })
            -- Whole-line markdown image → structured block (ST renders
            -- message images inline; see chat_bubbles image entries).
            elseif line:match("^%s*!%[[^%]]*%]%([^)]+%)%s*$") then
                local img_alt, img_url = line:match("^%s*!%[([^%]]*)%]%(([^)]+)%)%s*$")
                table.insert(blocks, { kind = "image", url = trim(img_url), alt = img_alt })
                i = i + 1
            elseif table_cells(line) and table_separator(lines[i + 1], #table_cells(line)) then
                local header = table_cells(line)
                local rows = {}
                i = i + 2
                while i <= #lines do
                    local row = table_cells(lines[i])
                    if not row or #row ~= #header then
                        break
                    end
                    table.insert(rows, row)
                    i = i + 1
                end
                -- Structured table block: rendered as an aligned column grid
                -- with a shaded header (see chat_bubbles block_entries).
                table.insert(blocks, { kind = "table", header = header, rows = rows })
            else
                local paragraph = { line }
                i = i + 1
                while i <= #lines do
                    local next_line = lines[i]
                    if next_line:match("^%s*$")
                        or next_line:match("^%s*```")
                        or next_line:match("^%s*#+%s+")
                        or next_line:match("^%s*>")
                        or next_line:match("^(%s*)[-+*]%s+(.+)$")
                        or next_line:match("^(%s*)(%d+)[%.)]%s+(.+)$")
                        or next_line:match("^%s*!%[[^%]]*%]%([^)]+%)%s*$")
                        or next_line:match("^%s*[-*_]%s*[-*_]%s*[-*_][%s-*_]*$") then
                        break
                    end
                    table.insert(paragraph, next_line)
                    i = i + 1
                end
                local text = trim(table.concat(paragraph, "\n"))
                if text ~= "" then
                    table.insert(blocks, { kind = "paragraph", text = text })
                end
            end
        end
    end
    if #blocks == 0 then
        table.insert(blocks, { kind = "paragraph", text = "" })
    end
    return blocks
end

return Md
