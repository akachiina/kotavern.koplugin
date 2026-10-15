-- Chat Theme engine: ONE JSON object with the WHOLE chat look.
--
-- SillyTavern parity: an ST "UI theme" is a flat snapshot of ~30-40 knobs
-- (colors, chat_display, avatar_style, chat_width, toggles, custom_css)
-- applied with a shallow merge of the keys present. KOTavern adopts the
-- same shape with its own key set plus a bidirectional converter:
--   ChatTheme.from_st(st_tbl)   -> theme (rgba composited over the stack -
--                                    MuPDF ignores rgba(), probes verified)
--   ChatTheme.to_st(theme)      -> ST-shaped table (export = the subset ST
--                                  understands; ST applies present keys only)
-- Resolution chain: per-chat patch > per-chat theme id > active global
-- theme id > unset (inherit the live app Theme). Unset color keys ("")
-- inherit too, so a light default stays night-mode friendly; ST imports
-- always set every color, so imported themes fully own the chat look
-- (dark ST themes render a dark chat inside a light app - by design).
--
-- Public surface:
--   ChatTheme.DEFAULTS          -> the schema (normalized shape)
--   ChatTheme.normalize(tbl)    -> validated/coerced theme (never throws)
--   ChatTheme.sig(theme)        -> canonical serialization for cache keys
--   ChatTheme.from_st(tbl)      -> theme from an ST theme table
--   ChatTheme.to_st(theme)      -> ST theme table (for export)
--   ChatTheme.parse_color(s)    -> {r,g,b,a} | nil (hex/rgb/rgba)
--   ChatTheme.hex_color(s)      -> "#rrggbb" | nil
--   ChatTheme.composite(c,over) -> hex (alpha over base, alpha dropped)
--   ChatTheme.luminance(hex)    -> 0..1 (dark theme detection)
--   ChatTheme.resolved(app)     -> effective theme + rendered extras
--   ChatTheme.BUILTINS          -> { {id, name, theme} } ST preset ports
--   ChatTheme.RENDER_SIG_KEYS   -> keys that change HTML docs (hash inputs)

local ChatTheme = {}
local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
if not lfs_ok or not lfs then
    local ok2, lfs2 = pcall(require, "lfs")
    lfs = ok2 and lfs2 or nil
end

-- ============================================================ schema ====

ChatTheme.DEFAULTS = {
    format = "kotavern-chat-theme",
    version = 1,
    name = "",
    style = "bubbles",        -- bubbles | flat (ST chat_display; document retired)
    chat_width = 100,         -- 25..100 % of the content area (ST chat_width)
    bubble_radius = "normal", -- small | normal | large (KOTavern knob)
    density = "normal",       -- compact | normal | spacious (chrome spacing)
    font_file = "",           -- "" = system default; absolute path otherwise
    font_size = 0,            -- 0 = follow base_font_size
    font_scale = 1.0,         -- 0.5..1.5 multiplier (ST font_scale)
    line_spacing = 100,       -- 70..130 % (KOReader line_spacing parity)
    colors = {
        text = "",            -- "" = inherit Theme ink
        surface = "",         -- "" = inherit the chat surface
        ai_panel = "",        -- "" = inherit assistant panel
        user_panel = "",      -- "" = inherit user panel
        border = "",          -- "" = inherit Theme soft border
        italics = "",         -- "" = same as text
        quote = "",           -- "" = inherit muted
    },
    avatar_shape = "round",   -- round | rounded | square | rect (ST styles)
    avatar_size = "normal",   -- small | normal | large
    show_avatars = true,
    show_timestamps = false,
    show_tokens = false,      -- ST message_token_count_enabled
    show_msg_ids = false,     -- ST mesIDDisplay_enabled
    show_gen_timer = false,   -- ST timer_enabled (generation duration)
    show_inline_images = true,
    custom_css = "",          -- appended last to the chat stylesheet
}

local STYLES = { bubbles = true, flat = true }
local RADII = { small = true, normal = true, large = true }
local DENSITIES = { compact = true, normal = true, spacious = true }
local SHAPES = { round = true, rounded = true, square = true, rect = true }
local AV_SIZES = { small = true, normal = true, large = true }
local COLOR_KEYS = { "text", "surface", "ai_panel", "user_panel", "border", "italics", "quote" }

-- Keys that change MuPDF documents (cache-key inputs alongside width):
-- everything chat_css() bakes in must participate in the doc hash.
ChatTheme.RENDER_SIG_KEYS = {
    "font_file", "font_size", "font_scale", "line_spacing", "custom_css",
}

-- ============================================================ colors ====

-- "#rgb" | "#rrggbb" | "rgb(r,g,b)" | "rgba(r,g,b,a)" -> {r,g,b,a} | nil.
function ChatTheme.parse_color(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    local hex = s:match("^#(%x%x%x)$")
    if hex then
        return {
            r = tonumber(hex:sub(1, 1):rep(2), 16),
            g = tonumber(hex:sub(2, 2):rep(2), 16),
            b = tonumber(hex:sub(3, 3):rep(2), 16),
            a = 1,
        }
    end
    hex = s:match("^#(%x%x%x%x%x%x)$")
    if hex then
        return {
            r = tonumber(hex:sub(1, 2), 16),
            g = tonumber(hex:sub(3, 4), 16),
            b = tonumber(hex:sub(5, 6), 16),
            a = 1,
        }
    end
    local r, g, b = s:match("^[rR][gG][bB][aA]?%s*%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
    if r then
        local a = tonumber(s:match(",%s*([%d%.]+)%s*%)%s*$") or "1") or 1
        return {
            r = math.min(255, math.max(0, math.floor(tonumber(r) or 0))),
            g = math.min(255, math.max(0, math.floor(tonumber(g) or 0))),
            b = math.min(255, math.max(0, math.floor(tonumber(b) or 0))),
            a = math.min(1, math.max(0, a)),
        }
    end
    return nil
end

function ChatTheme.hex_color(s)
    local c = ChatTheme.parse_color(s)
    if not c then return nil end
    if c.a <= 0.001 then return nil end
    return string.format("#%02x%02x%02x", c.r, c.g, c.b)
end

-- Alpha composite of color `c` over base hex (alpha dropped): MuPDF
-- ignores rgba() (probe-verified), so ST tints flatten at conversion.
function ChatTheme.composite(c, over)
    local b = ChatTheme.parse_color(over) or { r = 255, g = 255, b = 255, a = 1 }
    local a = math.min(1, math.max(0, c.a or 1))
    local function mix(v, o)
        return math.floor(v * a + o * (1 - a) + 0.5)
    end
    return string.format("#%02x%02x%02x",
        math.min(255, mix(c.r, b.r)),
        math.min(255, mix(c.g, b.g)),
        math.min(255, mix(c.b, b.b)))
end

function ChatTheme.luminance(hex)
    local c = ChatTheme.parse_color(hex)
    if not c then return nil end
    return (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) / 255
end

-- ========================================================== normalize ===

local function clamp01_enum(v, allowed, default)
    if type(v) ~= "string" or not allowed[v] then return default end
    return v
end

local function clamp_num(v, lo, hi, default)
    local n = tonumber(v)
    if not n then return default end
    return math.min(hi, math.max(lo, n))
end

-- Validate/coerce a raw table into the schema shape. Unknown keys are
-- dropped (ST import parity: only known knobs survive), never throws.
function ChatTheme.normalize(raw)
    raw = type(raw) == "table" and raw or {}
    local out = {}
    for k, v in pairs(ChatTheme.DEFAULTS) do
        out[k] = v
    end
    out.name = tostring(raw.name or ""):sub(1, 64)
    -- Retired style: saved "document" themes land on flat (the geometry
    -- document actually painted), not on the enum default bubbles.
    out.style = (raw.style == "document") and "flat"
        or clamp01_enum(raw.style, STYLES, "bubbles")
    out.chat_width = math.floor(clamp_num(raw.chat_width, 25, 100, 100))
    out.bubble_radius = clamp01_enum(raw.bubble_radius, RADII, "normal")
    out.density = clamp01_enum(raw.density, DENSITIES, "normal")
    out.font_file = (type(raw.font_file) == "string" and raw.font_file) or ""
    out.font_size = math.floor(clamp_num(raw.font_size, 0, 96, 0))
    out.font_scale = clamp_num(raw.font_scale, 0.5, 1.5, 1.0)
    out.line_spacing = math.floor(clamp_num(raw.line_spacing, 70, 130, 100))
    out.colors = {}
    local rc = type(raw.colors) == "table" and raw.colors or {}
    for ci = 1, #COLOR_KEYS do
        local key = COLOR_KEYS[ci]
        out.colors[key] = ChatTheme.hex_color(rc[key] or "") or ""
    end
    out.avatar_shape = clamp01_enum(raw.avatar_shape, SHAPES, "round")
    out.avatar_size = clamp01_enum(raw.avatar_size, AV_SIZES, "normal")
    out.show_avatars = raw.show_avatars ~= false
    out.show_timestamps = raw.show_timestamps == true
    out.show_tokens = raw.show_tokens == true
    out.show_msg_ids = raw.show_msg_ids == true
    out.show_gen_timer = raw.show_gen_timer == true
    out.show_inline_images = raw.show_inline_images ~= false
    out.custom_css = (type(raw.custom_css) == "string" and raw.custom_css) or ""
    return out
end

-- =============================================================== sig ====

-- Canonical serialization: stable key order, colors flattened. Used as
-- the HTML doc cache key component and the layout-cache signature (a
-- theme change must rebuild every cached layout/doc).
function ChatTheme.sig(theme)
    local t = ChatTheme.normalize(theme)
    local parts = {}
    local function put(k, v)
        parts[#parts + 1] = k .. "=" .. tostring(v)
    end
    put("style", t.style)
    put("w", t.chat_width)
    put("rad", t.bubble_radius)
    put("den", t.density)
    put("font", t.font_file)
    put("fs", t.font_size)
    put("fx", t.font_scale)
    put("ls", t.line_spacing)
    for ci = 1, #COLOR_KEYS do
        local key = COLOR_KEYS[ci]
        put(key, t.colors[key])
    end
    put("shape", t.avatar_shape)
    put("avs", t.avatar_size)
    put("av", t.show_avatars)
    put("ts", t.show_timestamps)
    put("tok", t.show_tokens)
    put("mid", t.show_msg_ids)
    put("gen", t.show_gen_timer)
    put("img", t.show_inline_images)
    -- custom_css can be long; the render sig only needs to distinguish
    -- content, so a cheap fingerprint (len + head + tail) is enough.
    local cc = t.custom_css
    put("css", #cc .. ":" .. cc:sub(1, 48) .. ":" .. cc:sub(-48))
    return table.concat(parts, "|")
end

-- ====================================================== ST conversion ===

-- ST chat_display -> our style. ST: 0 DEFAULT(flat), 1 BUBBLES, 2 DOCUMENT
-- (document retired: ST document imports as flat - the same geometry,
-- chrome on; a "book mode" without the chat affordances did not read well
-- on e-ink per the author).
local ST_DISPLAY = { [0] = "flat", [1] = "bubbles", [2] = "flat" }
local KT_DISPLAY = { flat = 0, bubbles = 1 }
-- ST avatar_styles: 0 ROUND, 1 RECTANGULAR, 2 SQUARE, 3 ROUNDED.
local ST_AVATAR = { [0] = "round", [1] = "rect", [2] = "square", [3] = "rounded" }
local KT_AVATAR = { round = 0, rect = 1, square = 2, rounded = 3 }

-- Import an ST theme table. Colors composite the way ST stacks them:
-- UI bg (blur tint) -> chat tint -> message tints, flattened to hex
-- (MuPDF ignores rgba; probes verified). Keys with no e-ink meaning
-- (blur/shadow/toastr/zen/lab/hotswap/...) are dropped silently - ST
-- itself only applies the keys a file happens to carry.
function ChatTheme.from_st(st)
    st = type(st) == "table" and st or {}
    local name = tostring(st.name or "")
    if name == "" then
        return nil, "name"
    end
    -- Surface stack: blur tint under chat tint, flattened over white.
    local blur = ChatTheme.parse_color(st.blur_tint_color or "")
        or { r = 255, g = 255, b = 255, a = 1 }
    local surface_hex = "#ffffff"
    local chat_tint = ChatTheme.parse_color(st.chat_tint_color or "")
    if chat_tint and chat_tint.a > 0.001 then
        surface_hex = ChatTheme.composite(chat_tint, "#ffffff")
    elseif blur.a > 0.001 then
        surface_hex = ChatTheme.composite(blur, "#ffffff")
    end
    local function panel(st_key)
        local c = ChatTheme.parse_color(st[st_key] or "")
        if not c or c.a <= 0.001 then return "" end
        return ChatTheme.composite(c, surface_hex)
    end
    local function flat(st_key)
        return ChatTheme.hex_color(st[st_key] or "") or ""
    end
    local raw = {
        name = name,
        style = ST_DISPLAY[math.floor(tonumber(st.chat_display) or 0)] or "flat",
        -- e-ink legibility floor: ST defaults to 50vw chat windows, which
        -- reads as wasteful razor-thin bubbles on a reader (print report);
        -- imports land at >= 70 (the theme still carries the real value for
        -- the export round-trip below).
        chat_width = math.max(70, tonumber(st.chat_width) or 50),
        colors = {
            text = flat("main_text_color"),
            surface = surface_hex,
            ai_panel = panel("bot_mes_blur_tint_color"),
            user_panel = panel("user_mes_blur_tint_color"),
            border = flat("border_color"),
            italics = flat("italics_text_color"),
            quote = flat("quote_text_color"),
        },
        show_avatars = st.hideChatAvatars_enabled ~= true,
        show_timestamps = st.timestamps_enabled == true,
        show_tokens = st.message_token_count_enabled == true,
        show_msg_ids = st.mesIDDisplay_enabled == true,
        show_gen_timer = st.timer_enabled == true,
        font_scale = tonumber(st.font_scale) or 1.0,
        custom_css = (type(st.custom_css) == "string" and st.custom_css) or "",
    }
    local av = ST_AVATAR[math.floor(tonumber(st.avatar_style) or 0)]
    if av then raw.avatar_shape = av end
    return ChatTheme.normalize(raw)
end

-- Export to the ST theme shape: only the keys ST understands (ST applies
-- present keys and skips absent ones, so a minimal export is fully valid
-- there). waifuMode was retired with chat_height and is simply omitted.
function ChatTheme.to_st(theme)
    local t = ChatTheme.normalize(theme)
    local function rgba(hex)
        local c = ChatTheme.parse_color(hex or "")
        if not c then return nil end
        return string.format("rgba(%d, %d, %d, 1)", c.r, c.g, c.b)
    end
    local out = {
        name = t.name,
        main_text_color = rgba(t.colors.text),
        italics_text_color = rgba(t.colors.italics),
        quote_text_color = rgba(t.colors.quote),
        border_color = rgba(t.colors.border),
        chat_tint_color = rgba(t.colors.surface),
        user_mes_blur_tint_color = rgba(t.colors.user_panel),
        bot_mes_blur_tint_color = rgba(t.colors.ai_panel),
        chat_display = KT_DISPLAY[t.style] or 0,
        avatar_style = KT_AVATAR[t.avatar_shape] or 0,
        chat_width = t.chat_width,
        font_scale = t.font_scale,
        timestamps_enabled = t.show_timestamps,
        message_token_count_enabled = t.show_tokens,
        mesIDDisplay_enabled = t.show_msg_ids,
        timer_enabled = t.show_gen_timer,
        hideChatAvatars_enabled = not t.show_avatars,
        custom_css = t.custom_css,
    }
    for k, v in pairs(out) do
        if v == nil then out[k] = nil end
    end
    return out
end

-- =========================================================== resolved ===

-- The render-side view of the theme: the applied chat theme (state.
-- chat_theme_applied, set by kt_app) with unset keys FILLED from the
-- plain settings, and colors resolved against the live Theme palette
-- (apply_bubble_theme already pushed theme surface/panel overrides into
-- Theme, so "unset" simply reads what the palette says). Everything the
-- stylesheet builder and the doc cache need sits in ONE table, and .sig
-- changes whenever any of it does.
function ChatTheme.resolved(app)
    local state = (app and app.state) or nil
    local s = (state and state.settings) or {}
    local applied = state and state.chat_theme_applied or nil
    local t = ChatTheme.normalize(applied or {})
    local Theme = require("ktui/theme")
    local KtHTML = require("ktui/kthtml")
    -- Text knobs: theme wins when set, plain settings otherwise.
    local font_file = (t.font_file ~= "") and t.font_file or (s.chat_font_file or "")
    local font_size = (t.font_size > 0) and t.font_size
        or math.floor(tonumber(s.chat_font_size) or 0)
    local custom_css = (t.custom_css ~= "") and t.custom_css
        or tostring(s.custom_css or "")
    local line_spacing = t.line_spacing
    -- Colors: theme set > live palette (the palette already carries the
    -- theme's surface/panel overrides when a theme is applied).
    local function pick(hex, live)
        if hex and hex ~= "" then return hex end
        return KtHTML.css_hex(live, "#000000")
    end
    local colors = {
        surface = pick(t.colors.surface, Theme.chat_bg),
        text = pick(t.colors.text, Theme.ink),
        ai_panel = pick(t.colors.ai_panel, Theme.chat_panel),
        user_panel = pick(t.colors.user_panel, Theme.chat_panel_user),
        border = pick(t.colors.border, Theme.soft),
        italics = pick(t.colors.italics, Theme.ink),
        quote = pick(t.colors.quote, Theme.muted),
    }
    -- The spoiler mask / fence band must CONTRAST the surface whatever the
    -- palette: on a dark chat a near-black border would vanish. Lighten
    -- toward white on dark surfaces, darken toward black on light ones.
    local lum = ChatTheme.luminance(colors.surface) or 1
    local toward = lum < 0.5 and "#ffffff" or "#000000"
    local bcol = ChatTheme.parse_color(colors.border)
        or { r = 128, g = 128, b = 128, a = 1 }
    colors.mask = ChatTheme.composite(
        { r = bcol.r, g = bcol.g, b = bcol.b, a = 0.55 }, toward)
    -- Fence/code text sits ON the mask band: hard luminance contrast
    -- either way (the authored text color could match the band - the
    -- "rosa claro sobre lilás" print report).
    colors.mask_text = (ChatTheme.luminance(colors.mask) or 1) < 0.5
        and "#f2f2f2" or "#161616"
    -- One signature for the whole render config: layout caches and HTML
    -- doc keys embed this so any knob change rebuilds.
    local sig = ChatTheme.sig(t)
        .. "|rf:" .. font_file .. ":" .. font_size .. ":" .. line_spacing
        .. ":" .. #custom_css .. ":" .. custom_css:sub(1, 48) .. ":"
        .. custom_css:sub(-48)
        .. "|rc:" .. colors.surface .. colors.text .. colors.ai_panel
        .. colors.user_panel .. colors.border .. colors.italics .. colors.quote
    return {
        theme = t,
        font_file = font_file,
        font_size = font_size,
        font_scale = t.font_scale,
        line_spacing = line_spacing,
        custom_css = custom_css,
        colors = colors,
        sig = sig,
    }
end

-- ============================================================== builtins

-- The five shipped ST presets, embedded as their original JSON (converted
-- through from_st once per load; the smoke round-trips every one of them).
-- e-ink renders them as grayscale/soft tints; dark ones own the chat
-- surface (dark chat inside a light app - the "room" semantic).
local BUILTIN_ST_JSON = {
    azure = [[{"name":"Azure","blur_strength":11,"main_text_color":"rgba(171, 198, 223, 1)","italics_text_color":"rgba(255, 255, 255, 1)","underline_text_color":"rgba(188, 231, 207, 1)","quote_text_color":"rgba(111, 133, 253, 1)","blur_tint_color":"rgba(23, 30, 33, 0.61)","chat_tint_color":"rgba(23, 23, 23, 0)","user_mes_blur_tint_color":"rgba(0, 28, 174, 0.2)","bot_mes_blur_tint_color":"rgba(0, 13, 57, 0.22)","shadow_color":"rgba(0, 0, 0, 1)","shadow_width":5,"border_color":"rgba(0, 0, 0, 0.5)","font_scale":1,"fast_ui_mode":false,"waifuMode":false,"avatar_style":1,"chat_display":1,"noShadows":false,"chat_width":50,"timer_enabled":true,"timestamps_enabled":true,"timestamp_model_icon":false,"mesIDDisplay_enabled":true,"hideChatAvatars_enabled":false,"message_token_count_enabled":false,"expand_message_actions":false,"enableZenSliders":false,"enableLabMode":false,"hotswap_enabled":true,"custom_css":"","bogus_folders":false,"reduced_motion":false,"compact_input_area":false}]],
    cappuccino = [[{"name":"Cappuccino","blur_strength":3,"main_text_color":"rgba(235, 235, 235, 1)","italics_text_color":"rgba(230, 210, 190, 1)","underline_text_color":"rgba(205, 180, 160, 1)","quote_text_color":"rgba(165, 140, 115, 1)","blur_tint_color":"rgba(34, 30, 32, 0.95)","chat_tint_color":"rgba(50, 45, 50, 0.75)","user_mes_blur_tint_color":"rgba(34, 30, 32, 0.75)","bot_mes_blur_tint_color":"rgba(34, 30, 32, 0.75)","shadow_color":"rgba(0, 0, 0, 0.3)","shadow_width":1,"border_color":"rgba(80, 80, 80, 0.89)","font_scale":1,"fast_ui_mode":false,"waifuMode":false,"avatar_style":0,"chat_display":1,"noShadows":false,"chat_width":50,"timer_enabled":false,"timestamps_enabled":true,"timestamp_model_icon":true,"mesIDDisplay_enabled":true,"hideChatAvatars_enabled":false,"message_token_count_enabled":false,"expand_message_actions":false,"enableZenSliders":false,"enableLabMode":false,"hotswap_enabled":true,"custom_css":"","bogus_folders":true,"reduced_motion":false,"compact_input_area":true}]],
    celestial = [[{"name":"Celestial Macaron","blur_strength":10,"main_text_color":"rgba(229, 175, 162, 1)","italics_text_color":"rgba(146, 147, 161, 1)","underline_text_color":"rgba(157, 215, 198, 1)","quote_text_color":"rgba(197, 202, 206, 1)","blur_tint_color":"rgba(23, 36, 55, 0.9)","chat_tint_color":"rgba(18, 26, 40, 0.9)","user_mes_blur_tint_color":"rgba(51, 67, 90, 0.7)","bot_mes_blur_tint_color":"rgba(23, 36, 55, 0.75)","shadow_color":"rgba(0, 0, 0, 0.3)","shadow_width":1,"border_color":"rgba(60, 74, 110, 0.93)","font_scale":1,"fast_ui_mode":false,"waifuMode":false,"avatar_style":0,"chat_display":1,"noShadows":false,"chat_width":58,"timer_enabled":true,"timestamps_enabled":true,"timestamp_model_icon":false,"mesIDDisplay_enabled":true,"hideChatAvatars_enabled":false,"message_token_count_enabled":true,"expand_message_actions":true,"enableZenSliders":false,"enableLabMode":false,"hotswap_enabled":true,"custom_css":"","bogus_folders":true,"zoomed_avatar_magnification":false,"reduced_motion":false,"compact_input_area":true}]],
    dark_lite = [[{"name":"Dark Lite","blur_strength":10,"main_text_color":"rgba(220, 220, 210, 1)","italics_text_color":"rgba(145, 145, 145, 1)","underline_text_color":"rgba(188, 231, 207, 1)","quote_text_color":"rgba(225, 138, 36, 1)","blur_tint_color":"rgba(23, 23, 23, 1)","chat_tint_color":"rgba(23, 23, 23, 1)","user_mes_blur_tint_color":"rgba(30, 30, 30, 0.9)","bot_mes_blur_tint_color":"rgba(30, 30, 30, 0.9)","shadow_color":"rgba(0, 0, 0, 1)","shadow_width":2,"border_color":"rgba(0, 0, 0, 1)","font_scale":1,"fast_ui_mode":true,"waifuMode":false,"avatar_style":0,"chat_display":0,"noShadows":true,"chat_width":50,"timer_enabled":false,"timestamps_enabled":true,"timestamp_model_icon":true,"mesIDDisplay_enabled":false,"hideChatAvatars_enabled":false,"message_token_count_enabled":false,"expand_message_actions":false,"enableZenSliders":"","enableLabMode":"","hotswap_enabled":true,"custom_css":"","bogus_folders":true,"reduced_motion":false,"compact_input_area":true}]],
    dark_v = [[{"name":"Dark V 1.0","blur_strength":13,"main_text_color":"rgba(207, 207, 197, 1)","italics_text_color":"rgba(145, 145, 145, 1)","underline_text_color":"rgba(145, 145, 145, 1)","quote_text_color":"rgba(198, 193, 151, 1)","blur_tint_color":"rgba(29, 33, 40, 0.9)","chat_tint_color":"rgba(29, 33, 40, 0.9)","user_mes_blur_tint_color":"rgba(29, 33, 40, 0.9)","bot_mes_blur_tint_color":"rgba(29, 33, 40, 0.9)","shadow_color":"rgba(0, 0, 0, 0.9)","shadow_width":2,"border_color":"rgba(0, 0, 0, 1)","font_scale":1,"fast_ui_mode":false,"waifuMode":false,"avatar_style":0,"chat_display":0,"noShadows":false,"chat_width":55,"timer_enabled":false,"timestamps_enabled":false,"timestamp_model_icon":false,"mesIDDisplay_enabled":false,"hideChatAvatars_enabled":false,"message_token_count_enabled":false,"expand_message_actions":false,"enableZenSliders":false,"enableLabMode":false,"hotswap_enabled":true,"custom_css":"","bogus_folders":true,"zoomed_avatar_magnification":true,"reduced_motion":true,"compact_input_area":false}]],
}

local builtins_cache = nil
function ChatTheme.BUILTINS()
    if builtins_cache then return builtins_cache end
    local JSON = require("json")
    builtins_cache = {}
    local order = { "azure", "cappuccino", "celestial", "dark_lite", "dark_v" }
    for bi = 1, #order do
        local key = order[bi]
        local ok, tbl = pcall(JSON.decode, BUILTIN_ST_JSON[key])
        if ok and tbl then
            local theme = ChatTheme.from_st(tbl)
            if theme then
                builtins_cache[#builtins_cache + 1] = {
                    id = "builtin:" .. key,
                    name = theme.name,
                    theme = theme,
                }
            end
        end
    end
    return builtins_cache
end

return ChatTheme
