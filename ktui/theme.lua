-- Theme: colors, fonts, metrics
-- Adapted from ZenPM (zenpm.koplugin/ui/theme.lua)

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")

local Screen = Device.screen
local base_font_size = 22
local default_base_font_size = base_font_size

local light_gray = Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_WHITE
local dark_gray = Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK

local palettes = {
    light = {
        bg = Blitbuffer.COLOR_WHITE,
        ink = Blitbuffer.COLOR_BLACK,
        muted = Blitbuffer.COLOR_DARK_GRAY,
        border = Blitbuffer.COLOR_BLACK,
        panel = Blitbuffer.COLOR_WHITE,
        soft = light_gray,
        button_bg = Blitbuffer.COLOR_BLACK,
        button_text = Blitbuffer.COLOR_WHITE,
        danger = Blitbuffer.COLOR_BLACK,
    },
    inverted = {
        bg = Blitbuffer.COLOR_BLACK,
        ink = Blitbuffer.COLOR_WHITE,
        muted = Blitbuffer.COLOR_LIGHT_GRAY,
        border = Blitbuffer.COLOR_WHITE,
        panel = Blitbuffer.COLOR_BLACK,
        soft = dark_gray,
        button_bg = Blitbuffer.COLOR_WHITE,
        button_text = Blitbuffer.COLOR_BLACK,
        danger = Blitbuffer.COLOR_WHITE,
    },
}

-- Chat surface tints (ST SmartThemeChatTintColor analog). gray(level):
-- 0 = white, 1.0 = black. "paper" is a warm-paper tone (the zenpm look);
-- message panels sit on top of it (bot lighter, user darker - ST
-- UserMes/BotMes tints).
local chat_surfaces = {
    light = {
        none = { bg = Blitbuffer.COLOR_WHITE, panel = Blitbuffer.COLOR_WHITE, panel_user = Blitbuffer.gray(0.06) },
        paper = { bg = Blitbuffer.gray(0.05), panel = Blitbuffer.COLOR_WHITE, panel_user = Blitbuffer.gray(0.10) },
        gray = { bg = Blitbuffer.gray(0.09), panel = Blitbuffer.COLOR_WHITE, panel_user = Blitbuffer.gray(0.14) },
    },
    inverted = {
        none = { bg = Blitbuffer.COLOR_BLACK, panel = Blitbuffer.COLOR_BLACK, panel_user = Blitbuffer.gray(0.85) },
        paper = { bg = Blitbuffer.gray(0.94), panel = Blitbuffer.gray(0.89), panel_user = Blitbuffer.gray(0.78) },
        gray = { bg = Blitbuffer.gray(0.90), panel = Blitbuffer.gray(0.84), panel_user = Blitbuffer.gray(0.72) },
    },
}

local current_theme = "light"
local density_factor = 1.0
local bubble_style = "bubbles" -- ST chat_styles.BUBBLES panels are the app default (v0.5)
local chat_bg = "paper"
-- Chat theme color overrides (hex strings; nil key = inherit the palette).
local chat_color_overrides = nil
local line_h_cache = {}
local line_h_widget = nil

local Theme = {
    bg = palettes.light.bg,
    ink = palettes.light.ink,
    muted = palettes.light.muted,
    border = palettes.light.border,
    panel = palettes.light.panel,
    soft = palettes.light.soft,
    button_bg = palettes.light.button_bg,
    button_text = palettes.light.button_text,
    danger = palettes.light.danger,
    -- Chat surface (see chat_surfaces)
    chat_bg = palettes.light.bg,
    chat_panel = palettes.light.panel,
    chat_panel_user = palettes.light.panel,
}

Theme.MIN_BASE_FONT_SIZE = 8
Theme.MAX_BASE_FONT_SIZE = 32

function Theme.set_theme(name)
    if name == "inverted" or name == "light" then
        current_theme = name
    end
    local c = palettes[current_theme]
    Theme.bg = c.bg
    Theme.ink = c.ink
    Theme.muted = c.muted
    Theme.border = c.border
    Theme.panel = c.panel
    Theme.soft = c.soft
    Theme.button_bg = c.button_bg
    Theme.button_text = c.button_text
    Theme.danger = c.danger
    Theme._apply_chat_colors()
end

function Theme.get_theme()
    return current_theme
end

function Theme.set_density(value)
    if value == "compact" then
        density_factor = 0.8
    elseif value == "spacious" then
        density_factor = 1.4
    else
        density_factor = 1.0
    end
end

function Theme.get_density()
    return density_factor
end

function Theme.set_bubble_style(value)
    if value == "st" or value == "flat"
        or value == "square" or value == "none" or value == "bubbles" then
        bubble_style = value
    else
        bubble_style = "bubbles"
    end
end

function Theme.get_bubble_style()
    return bubble_style
end

-- Bubble rounding (Appearance > Chat > Bubble rounding): panel corner
-- radius for the bubbles style. small/normal/large -> 6/10/16 (pre-scale).
local bubble_radius_map = { small = 6, normal = 10, large = 16 }
local bubble_radius = "normal"
function Theme.set_bubble_radius(value)
    if bubble_radius_map[value] then bubble_radius = value end
end
function Theme.bubble_radius_px()
    return Theme.scale(bubble_radius_map[bubble_radius] or 10)
end

-- Chat background tint (ST backgrounds/chat tint analog, e-ink safe:
-- solid grays only - no images, no dithering).
function Theme.set_chat_bg(value)
    if value == "none" or value == "paper" or value == "gray" then
        chat_bg = value
    else
        chat_bg = "paper"
    end
    Theme._apply_chat_colors()
end


-- Recompute chat surface colors from theme + chat_bg setting.
function Theme._apply_chat_colors()
    local surfaces = chat_surfaces[current_theme] or chat_surfaces.light
    local s = surfaces[chat_bg] or surfaces.paper
    Theme.chat_bg = s.bg
    Theme.chat_panel = s.panel
    Theme.chat_panel_user = s.panel_user
    -- Chat text ink: defaults to the palette, overridden by a chat theme
    -- (the names/hours/reasoning labels are painted INSIDE themed panels -
    -- black palette ink on a dark theme was unreadable, the print reports).
    Theme.chat_ink = Theme.ink
    Theme.chat_muted = Theme.muted
    -- Panel/band border ink: the theme's border color when it sets one
    -- (the knob used to feed ONLY the doc stylesheet - canvas borders kept
    -- the light palette soft and glowed on dark themes).
    Theme.chat_border = Theme.soft
    -- Chat page chrome (header band + composer + footer): nil = the app
    -- palette paints it; a theme that owns the ink repaints the whole chat
    -- page in its own colors (the "chat is a room" semantic - white chrome
    -- around a dark chat read as broken, per the print reports).
    Theme.chat_chrome = nil
    -- A chat theme may OWN the chat colors (set keys override; unset keys
    -- keep the palette values above). Hex strings -> Blitbuffer colors.
    if chat_color_overrides then
        local function hex_to_bb(hex)
            if not hex or hex == "" then return nil end
            -- This build has NO Blitbuffer.ColorRGB8 (the name boot-looped
            -- the plugin); colorFromString is the sanctioned converter
            -- (ColorRGB32 under the hood) and paints on every buffer type.
            local okc, c = pcall(Blitbuffer.colorFromString, hex)
            if okc and c then return c end
            return nil
        end
        local function mix_over(base_hex, hex)
            -- Themes are e-ink first: a panel tint must never kill text
            -- contrast, but the hex is used as authored (custom_css and the
            -- editor are the escape hatches).
            return hex_to_bb(hex) or base_hex
        end
        local o = chat_color_overrides
        Theme.chat_bg = mix_over(Theme.chat_bg, o.surface)
        Theme.chat_panel = mix_over(Theme.chat_panel, o.ai_panel)
        Theme.chat_panel_user = mix_over(Theme.chat_panel_user, o.user_panel)
        local ink_bb = hex_to_bb(o.text)
        if ink_bb then
            Theme.chat_ink = ink_bb
            -- Secondary chat text (hours, tokens, "Reasoning"): the theme
            -- ink washed 45% toward the surface keeps the hierarchy on
            -- any palette (ChatTheme.composite is pure Lua math).
            local ChatTheme = require("ktui/chat_theme")
            local surf_hex = o.surface
            if not surf_hex or surf_hex == "" then
                surf_hex = require("ktui/kthtml").css_hex(Theme.chat_bg, "#ffffff")
            end
            local okm2, washed = pcall(function()
                -- 55% theme ink over the surface = the muted secondary.
                local ink_c = ChatTheme.parse_color(o.text)
                if not ink_c then return nil end
                ink_c.a = 0.55
                return ChatTheme.composite(ink_c, surf_hex)
            end)
            local muted_bb = okm2 and hex_to_bb(washed) or nil
            if muted_bb then Theme.chat_muted = muted_bb end
            Theme.chat_chrome = {
                bg = Theme.chat_bg,
                ink = Theme.chat_ink,
                muted = Theme.chat_muted,
            }
            local border_bb = hex_to_bb(o.border)
            if border_bb then Theme.chat_border = border_bb end
        end
    end
end

-- Chat theme color overrides: {surface, ai_panel, user_panel} hex strings.
-- nil/absent keys inherit the palette; call after the style setters so
-- every apply path funnels through _apply_chat_colors.
function Theme.set_chat_color_overrides(overrides)
    chat_color_overrides = overrides
    Theme._apply_chat_colors()
end

function Theme.normalize_base_font_size(value)
    local size = tonumber(value)
    if not size then
        return base_font_size
    end
    return math.max(Theme.MIN_BASE_FONT_SIZE, math.min(Theme.MAX_BASE_FONT_SIZE, math.floor(size + 0.5)))
end

function Theme.set_base_font_size(value)
    base_font_size = Theme.normalize_base_font_size(value)
    for k in pairs(line_h_cache) do
        line_h_cache[k] = nil
    end
    -- The icon size cache is font-size independent, but the glyph fallback
    -- metrics feed chrome_bar_h(); clearing here is one cheap sweep that
    -- keeps a single invalidation point for anything measuring text.
    pcall(function()
        require("ktui/icons").invalidate_size_cache()
    end)
    return base_font_size
end

function Theme.get_base_font_size()
    return base_font_size
end

function Theme.scale(value)
    return Screen:scaleBySize(value)
end

function Theme.font_scale(value)
    local font_ratio = base_font_size / default_base_font_size
    local damped_ratio = 1 + (font_ratio - 1) / 2
    return math.max(1, math.floor(Theme.scale(value) * damped_ratio + 0.5))
end

function Theme.has_color()
    return Device:hasColorScreen()
end

function Theme.metrics()
    local w, h = Screen:getWidth(), Screen:getHeight()
    local d = density_factor
    return {
        screen_w = w,
        screen_h = h,
        pad = Theme.scale(10 * d),
        titlebar_h = Theme.scale(48),
        -- NOTE: no toolbar_h here on purpose. The header pill toolbar height
        -- (btn_h + 16) lives in Header.height/draw (single definition); an
        -- earlier metrics.toolbar_h aliased chrome_bar_h() (the icon+label
        -- bar formula, ~6px taller) but nothing ever read it - keeping it
        -- invited pages to size content against a height Header never paints.
        nav_h = Theme.chrome_bar_h(),
        card_gap = Theme.scale(8 * d),
        card_h = Theme.scale(400),
        touch_min = Theme.scale(44),
        radius = Theme.scale(6),
    }
end

-- Reserved gutter for the scrollbar (thumb + margins). Every scrollable page
-- must subtract this from its content width so rows never sit under the thumb.
function Theme.scrollbar_w()
    return Theme.scale(9) + Theme.scale(7)
end

-- Canonical button heights (pill buttons, icon buttons).
function Theme.btn_h()
    return Theme.scale(42)
end

function Theme.icon_btn()
    return Theme.scale(42)
end

-- Height for icon+label bars (nav + dashboard toolbar). The reference icon is
-- the dashboard toolbar's original size (scale(22)); both bars must fit it
-- uncut, so the auto-fit in Bar.item always resolves to the SAME size on both
-- bars. The +6 is the constant-px glyph-ink overshoot margin (see ui/bar.lua).
function Theme.chrome_bar_h()
    -- Nav labels use the tiny face (see ui/bar.lua); the +6 is the
    -- constant-px glyph-ink overshoot margin.
    local label_h = Theme.line_h("tiny")
    local Icons = require("ktui/icons")
    local icon_h = Icons.text_size("home", Theme.scale(22)).h
    return math.max(Theme.scale(64), icon_h + label_h + Theme.scale(9) + 6)
end

local function chrome_size()
    return math.max(12, math.min(16, base_font_size - 6))
end

local function chip_size()
    return math.max(10, math.min(14, base_font_size - 8))
end

-- Chat content font (optional custom): a font FILE path from the installed
-- fonts list plus an absolute size. Both nil = follow the system content
-- face and base size (Theme.face("default")). Used ONLY for message body
-- text (chat bubbles) - chrome, headers and sheets stay on the system face.
local chat_font_path, chat_font_size = nil, nil
local chat_face_cache = {}
function Theme.set_chat_font(path, size)
    chat_font_path = (type(path) == "string" and path ~= "") and path or nil
    size = tonumber(size)
    chat_font_size = (size and size > 0) and math.floor(size) or nil
end
function Theme.chat_face()
    if not chat_font_path and not chat_font_size then return nil end
    local want_size = chat_font_size or base_font_size
    local key = tostring(chat_font_path) .. "|" .. want_size
    local cached = chat_face_cache[key]
    if cached then return cached end
    -- getFace accepts a raw FILE path (fontmap lookup misses, FontList
    -- fallback search hits the installed path). A failure falls back to
    -- system text instead of a blank bubble.
    local ok, face = pcall(Font.getFace, Font, chat_font_path or "cfont", want_size)
    if not ok or not face then return nil end
    chat_face_cache = { [key] = face }
    return face
end

function Theme.face(role)
    if role == "title" then
        return Font:getFace("cfont", base_font_size + 5)
    elseif role == "heading" then
        return Font:getFace("cfont", base_font_size + 2)
    elseif role == "small" then
        -- Floors keep secondary text legible at MIN_BASE_FONT_SIZE (8):
        -- base-2/base-4 with no floor produced 6px/4px ink smears.
        return Font:getFace("smallinfofont", math.max(10, base_font_size - 2))
    elseif role == "tiny" then
        return Font:getFace("smallinfofont", math.max(8, base_font_size - 4))
    elseif role == "chrome" then
        return Font:getFace("smallinfofont", chrome_size())
    elseif role == "chip" then
        return Font:getFace("smallinfofont", chip_size())
    end
    return Font:getFace("cfont", base_font_size)
end

-- Real height of a single text line for a role face (e-ink layout accuracy).
-- Cached; invalidated when base font size changes.
function Theme.line_h(role)
    role = role or "normal"
    local key = base_font_size .. "|" .. role
    local cached = line_h_cache[key]
    if cached then
        return cached
    end
    if not line_h_widget then
        line_h_widget = require("ui/widget/textwidget")
    end
    local widget = line_h_widget:new{
        text = "Mxg",
        face = Theme.face(role),
    }
    local s = widget:getSize()
    widget:free()
    line_h_cache[key] = s.h
    return s.h
end

-- Initial chat surface colors (paper) without waiting for apply_settings.
Theme._apply_chat_colors()

return Theme
