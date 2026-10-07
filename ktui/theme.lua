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

function Theme.get_chat_bg()
    return chat_bg
end

-- Recompute chat surface colors from theme + chat_bg setting.
function Theme._apply_chat_colors()
    local surfaces = chat_surfaces[current_theme] or chat_surfaces.light
    local s = surfaces[chat_bg] or surfaces.paper
    Theme.chat_bg = s.bg
    Theme.chat_panel = s.panel
    Theme.chat_panel_user = s.panel_user
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
        toolbar_h = Theme.chrome_bar_h(),
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
