-- KtBookTheme: the Book-mode look.
--
-- The Book mode is rendered by KOReader's own reader (crengine), so its look
-- is NOT the chat theme: it is a mix of reader settings (font, size, line
-- spacing, margins - written per document) and the generated HTML (the
-- structure of the book: cover, message titles, separators, spoilers...).
--
-- This module is the pure-data twin of ktui/chat_theme.lua: the schema, the
-- normalization, the signature and the presets. No UI, no reader, no
-- gettext - the labels are plain English here and are translated by the UI
-- that paints them (an empty override means "use the translated default").
--
-- Public surface:
--   BookTheme.DEFAULTS      -> the schema (normalized shape)
--   BookTheme.normalize(t)  -> validated/coerced theme (never throws)
--   BookTheme.sig(theme)    -> canonical serialization (reload key)
--   BookTheme.PRESETS()     -> { { id, name, theme } } the shipped looks
--   BookTheme.LABEL_KEYS    -> ordered { key, group, default_text }
--   BookTheme.label(t,k,d)  -> the custom label or the given default
--   BookTheme.from_settings(settings) -> the theme of the app settings
--   BookTheme.margin_pair(margin)      -> the reader's margin pair
--   BookTheme.apply_reader_settings(path, theme) -> per-document settings

local BookTheme = {}

BookTheme.DEFAULTS = {
    format = "kotavern-book-theme",
    version = 1,
    preset = "default",             -- default | novel | compact | minimal | custom

    -- Page / typography (the reader's own per-document settings)
    font_face = "",                 -- "" = follow the reader
    font_size = 0,                  -- 0 = follow the reader
    line_spacing = 0,               -- 0 = follow the reader (percent)
    font_weight = 0,                -- 0 = follow; else 400 / 600 / 700
    margin = "normal",              -- narrow | normal | wide
    justify = true,
    hyphenate = true,
    paragraph_spacing = "normal",   -- compact | normal | airy

    -- Structure (the generated HTML)
    cover = true,
    cover_title = "chat",           -- chat | character | both
    cover_date = true,
    cover_actions = true,
    toc = false,
    message_title = "speaker",      -- speaker | speaker_time | time | number | none
    user_style = "quote",           -- quote | panel | plain | hidden
    system_style = "dim",           -- dim | plain | hidden
    show_reasoning = false,
    colophon = true,
    message_actions = true,
    separator = "space",            -- line | ornament | space | none
    merge_speakers = false,
    page_break = false,
    drop_cap = false,

    -- Content (the generated CSS)
    code_style = "box",             -- box | indent | plain
    table_border = true,
    spoiler = "mask",               -- mask | reveal
    emoji_size = "normal",          -- small | normal | large
    inline_images = "placeholder",  -- placeholder | hidden
    custom_css = "",

    labels = {},
}

-- The enum fields and their fallback (the default value).
local ENUMS = {
    preset = { default = true, novel = true, compact = true, minimal = true, custom = true },
    margin = { narrow = true, normal = true, wide = true },
    paragraph_spacing = { compact = true, normal = true, airy = true },
    cover_title = { chat = true, character = true, both = true },
    message_title = { speaker = true, speaker_time = true, time = true, number = true, none = true },
    user_style = { quote = true, panel = true, plain = true, hidden = true },
    system_style = { dim = true, plain = true, hidden = true },
    separator = { line = true, ornament = true, space = true, none = true },
    code_style = { box = true, indent = true, plain = true },
    spoiler = { mask = true, reveal = true },
    emoji_size = { small = true, normal = true, large = true },
    inline_images = { placeholder = true, hidden = true },
}

local BOOLEANS = {
    "justify", "hyphenate", "cover", "cover_date", "cover_actions", "toc",
    "show_reasoning", "colophon", "message_actions", "merge_speakers",
    "page_break", "drop_cap", "table_border",
}

-- The label keys: what the user can rename. The default text is the English
-- source; the UI translates it when it paints the row.
BookTheme.LABEL_KEYS = {
    { key = "actions", group = "book", default_text = "Actions" },
    { key = "go_end", group = "book", default_text = "Go to the end" },
    { key = "write_next", group = "book", default_text = "Write next message" },
    { key = "continue_last", group = "book", default_text = "Continue last reply" },
    { key = "book_actions", group = "book", default_text = "Book actions" },
    { key = "you", group = "speaker", default_text = "You" },
    { key = "system", group = "speaker", default_text = "System" },
    { key = "assistant", group = "speaker", default_text = "Assistant" },
    { key = "book_actions_title", group = "dialog", default_text = "Book actions" },
    { key = "quick_reply", group = "dialog", default_text = "Quick Reply" },
    { key = "regenerate", group = "dialog", default_text = "Regenerate last reply" },
    { key = "go_last", group = "dialog", default_text = "Go to last message" },
    { key = "show_reasoning", group = "dialog", default_text = "Show reasoning" },
    { key = "hide_reasoning", group = "dialog", default_text = "Hide reasoning" },
    { key = "authors_note", group = "dialog", default_text = "Author's Note" },
    { key = "system_note", group = "dialog", default_text = "Add System Note" },
    { key = "impersonate", group = "dialog", default_text = "Impersonate" },
    { key = "persona", group = "dialog", default_text = "Persona" },
    { key = "preset", group = "dialog", default_text = "Preset" },
    { key = "api", group = "dialog", default_text = "API connection" },
    { key = "rename", group = "dialog", default_text = "Rename Chat" },
    { key = "export_chat", group = "dialog", default_text = "Export Chat" },
    { key = "export_txt", group = "dialog", default_text = "Export TXT" },
    { key = "open_list", group = "dialog", default_text = "Open in list view" },
    { key = "close_book", group = "dialog", default_text = "Close book" },
    { key = "end_of_chat", group = "dialog", default_text = "End of chat" },
}

local function enum_or(raw, field, allowed, fallback)
    local value = raw[field]
    if type(value) == "string" and allowed[value] then return value end
    return fallback
end

local function number_or(raw, field, low, high, fallback)
    local value = tonumber(raw[field])
    if not value then return fallback end
    value = math.floor(value)
    if value < low or value > high then return fallback end
    return value
end

-- Validate/coerce a raw table into the schema shape. Unknown keys are
-- dropped, values are clamped, and the function never throws.
function BookTheme.normalize(raw)
    local ok, result = pcall(function()
        raw = type(raw) == "table" and raw or {}
        local out = {}
        for k, v in pairs(BookTheme.DEFAULTS) do
            out[k] = v
        end
        for field, allowed in pairs(ENUMS) do
            out[field] = enum_or(raw, field, allowed, BookTheme.DEFAULTS[field])
        end
        for _bi, field in ipairs(BOOLEANS) do
            -- An explicit false is a choice; a missing key keeps the default.
            if raw[field] == nil then
                out[field] = BookTheme.DEFAULTS[field]
            else
                out[field] = raw[field] == true
            end
        end
        out.font_face = (type(raw.font_face) == "string") and raw.font_face or ""
        out.font_size = number_or(raw, "font_size", 0, 96, 0)
        out.line_spacing = number_or(raw, "line_spacing", 0, 200, 0)
        local weight = tonumber(raw.font_weight)
        if weight == 400 or weight == 600 or weight == 700 then
            out.font_weight = weight
        else
            out.font_weight = 0
        end
        out.custom_css = (type(raw.custom_css) == "string") and raw.custom_css or ""
        local labels = {}
        if type(raw.labels) == "table" then
            for key, value in pairs(raw.labels) do
                if type(key) == "string" and type(value) == "string" then
                    labels[key] = value:sub(1, 120)
                end
            end
        end
        out.labels = labels
        return out
    end)
    if not ok then
        return BookTheme.normalize({})
    end
    return result
end

-- Canonical serialization of every knob that changes the output. It is the
-- reload key: a changed signature means the book must be rebuilt.
function BookTheme.sig(theme)
    local t = BookTheme.normalize(theme)
    local parts = {}
    local function put(key, value)
        parts[#parts + 1] = key .. "=" .. tostring(value)
    end
    -- The fields are sorted: a hash-table order would change the signature
    -- when a key is added, and every stored book would look different.
    local enum_fields = {}
    for field in pairs(ENUMS) do enum_fields[#enum_fields + 1] = field end
    table.sort(enum_fields)
    for _ei, field in ipairs(enum_fields) do
        put(field, t[field])
    end
    for _bi, field in ipairs(BOOLEANS) do
        put(field, t[field] and 1 or 0)
    end
    put("font", t.font_face)
    put("fs", t.font_size)
    put("ls", t.line_spacing)
    put("fw", t.font_weight)
    put("css", #t.custom_css .. ":" .. t.custom_css:sub(1, 32) .. ":" .. t.custom_css:sub(-32))
    -- The labels are sorted so the signature does not depend on the table order.
    local keys = {}
    for key in pairs(t.labels) do keys[#keys + 1] = key end
    table.sort(keys)
    for _ki, key in ipairs(keys) do
        put("l:" .. key, t.labels[key])
    end
    return table.concat(parts, "|")
end

-- The shipped looks. Each theme is a full table (the preset's values over the
-- defaults), so normalize(preset.theme) is a valid theme.
function BookTheme.PRESETS()
    local function preset(overrides)
        local theme = {}
        for k, v in pairs(BookTheme.DEFAULTS) do theme[k] = v end
        for k, v in pairs(overrides or {}) do theme[k] = v end
        return BookTheme.normalize(theme)
    end
    return {
        { id = "default", name = "Default", theme = preset({}) },
        { id = "novel", name = "Novel", theme = preset({
            cover = true,
            cover_title = "character",
            toc = true,
            message_title = "speaker_time",
            separator = "ornament",
            page_break = true,
            drop_cap = true,
            paragraph_spacing = "airy",
            user_style = "panel",
        }) },
        { id = "compact", name = "Compact", theme = preset({
            cover = false,
            cover_actions = false,
            colophon = false,
            message_actions = false,
            message_title = "number",
            separator = "none",
            paragraph_spacing = "compact",
            show_reasoning = false,
            user_style = "plain",
        }) },
        { id = "minimal", name = "Minimal", theme = preset({
            cover = false,
            cover_actions = false,
            colophon = false,
            message_actions = false,
            message_title = "none",
            separator = "none",
            toc = false,
            user_style = "plain",
            system_style = "hidden",
            custom_css = "",
        }) },
    }
end

-- The custom label for a key, or the given default when it is not set.
function BookTheme.label(theme, key, default_text)
    local t = BookTheme.normalize(theme)
    local value = t.labels and t.labels[key]
    if type(value) == "string" and value ~= "" then return value end
    return default_text
end

-- The theme of the app settings. Before the theme existed the reasoning
-- flag lived in its own setting: seed it once, then the theme owns it.
function BookTheme.from_settings(settings)
    settings = settings or {}
    local raw = settings.book_theme
    if type(raw) ~= "table" then
        raw = {}
        if settings.book_show_reasoning == true then
            raw.show_reasoning = true
        end
    end
    return BookTheme.normalize(raw)
end

-- The reader's L/R margin pair (KOReader's own defaults: {5,5} small,
-- {10,10} medium, {20,20} large). "normal" follows the reader.
function BookTheme.margin_pair(margin)
    if margin == "narrow" then return { 5, 5 } end
    if margin == "wide" then return { 20, 20 } end
    return nil
end

-- Write the reader's per-document settings for the generated book. Only the
-- generated path is touched: the user's global settings and their real
-- books stay untouched. The keys are the ones KOReader's Configurable reads
-- (prefix "copt_") plus the unprefixed "font_face" the ReaderFont module
-- uses.
function BookTheme.apply_reader_settings(book_path, theme)
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds or not DocSettings then
        return false, "sidecar support is unavailable"
    end
    local t = BookTheme.normalize(theme)
    local ok, ds = pcall(function() return DocSettings:open(book_path) end)
    if not ok or not ds then
        return false, "could not open the book sidecar"
    end
    local function set(key, value)
        if value == nil or value == "" then
            pcall(function() ds:delSetting(key) end)
        else
            pcall(function() ds:saveSetting(key, value) end)
        end
    end
    set("font_face", t.font_face ~= "" and t.font_face or nil)
    set("copt_font_size", t.font_size > 0 and t.font_size or nil)
    set("copt_line_spacing", t.line_spacing > 0 and t.line_spacing or nil)
    set("copt_font_base_weight", t.font_weight > 0 and t.font_weight or nil)
    set("copt_h_page_margins", BookTheme.margin_pair(t.margin))
    local flushed = pcall(function() ds:flush() end)
    if not flushed then
        return false, "could not write the book sidecar"
    end
    return true
end

return BookTheme
