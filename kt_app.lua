-- KOTavern App Controller
-- Singleton (managed by Launcher). Owns the AppView and global app state.

local UIManager = require("ui/uimanager")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local AppView = require("ktui/app_view")
local Storage = require("kt_storage")
local I18n = require("kt_i18n")
local Constants = require("kt_constants")
local Util = require("kotaven_util")

local App = {}

local SETTINGS_DEFAULTS = {
    theme = "light",
    base_font_size = 22,
    density = "normal",        -- compact | normal | spacious
    bubble_style = "bubbles",  -- ST chat_styles: bubbles (BUBBLES, default) | flat (DEFAULT) | st (legacy boxed) | book (DOCUMENT) | rounded | square | none
    chat_bg = "paper",         -- chat surface tint: paper | gray | none
    show_inline_images = true, -- render message images inline (ST media)
    show_avatars = true,
    show_covers = true,
    avatar_size = "normal",      -- small | normal | large
    outline_user_bubbles = false,
    show_timestamps = false,
    show_tokens = false,       -- ~N tok in the message name row (ST tokenCounter)
    streaming = true,          -- global default for new connections
    api_backend = "curl_bg",   -- http_sync | curl_sync | curl_bg
    stream_chunk_interval = 0.3,
    stream_refresh = "calm",   -- live (every chunk) | calm (1/s) | still (only when done)
    api_timeout = 30,          -- sync request timeout (s)
    stream_timeout = 120,      -- stream idle timeout (s)
    api_retries = 1,           -- automatic retries for HTTP 429/5xx
    dashboard_view = "grid",   -- grid | list
    dashboard_sort = "name_asc",
    last_seen_chats = 0,       -- epoch; nav badge counts chats newer than this
    -- Dashboard customization (Fase I)
    dashboard_columns = 3,        -- 2 | 3 | 4
    dashboard_card_h = "normal",  -- short | normal | tall
    dashboard_show_name = true,
    dashboard_show_tags = true,
    dashboard_show_meta = true,
    dashboard_star = "always",  -- always (outline if not fav) | fav | none
    dashboard_caption = "soft",   -- soft (semi-transparent) | solid | none
    -- AI output post-processing (ST behavior settings)
    trim_sentences = false,
    collapse_newlines = false,
    -- ST Auto-Continue: chain a Continue when finish_reason == length and the
    -- reply is shorter than the target (tokens; 0 = always continue a cut).
    auto_continue = false,
    auto_continue_length = 200,
    send_if_empty = "",        -- ST send_if_empty: placeholder sent on empty submit
    reasoning_auto_parse = true,   -- ST auto-parse: strip <think>…</think> into a collapsible line
    reasoning_prefix = "<think>",
    reasoning_suffix = "</think>",
    -- Regex display/prompt scripts, global character tags and quick replies
    regex_scripts = {},   -- { { id, scriptName, find, replace, placement, disabled } }
    tag_map = {},         -- { [character_path] = { "tag", ... } }
    quick_replies = {},   -- { { label, text } }
}

function App:new(plugin)
    local o = {
        plugin = plugin,
        view = nil,
        state = {
            page = "dashboard",
            previous_page = nil,

            -- Characters
            characters = {},
            character_files = {},

            -- Chat
            current_chat_id = nil,
            current_character = nil,
            current_character_file = nil,
            current_character_data = nil,
            current_chat_path = nil,
            current_chat_persona_id = nil,
            current_chat_preset_id = nil,
            current_connection = nil,
            messages = {},
            is_generating = false,
            stream_buffer = "",

            -- Scroll positions per page
            scroll = {},

            -- Expanded reasoning blocks per message index (chat page)
            reasoning_open = {},
            -- "Show more" override for clamped reasoning blocks
            reasoning_full = {},

            -- UI state
            loading = nil,
            error = nil,
            connections = {},
            presets = {},
            personas = { list = {}, active = nil },
            settings = {},
    chats_index = {},
    chats_query = "",
    chats_sort = "recent",   -- recent | name_asc | name_desc
            dashboard_query = "",
            dashboard_filter = "all",
            _card_cache = nil,
            sheet = nil,
        },
    }
    setmetatable(o, self)
    self.__index = self

    -- Ensure data directories exist
    Storage.ensure_data_dirs()

    -- Install i18n
    I18n.install()

    -- Load persisted settings (theme, font size, backend, etc.)
    o:load_settings()

    local _gt = require("gettext")

    return o
end

-- === Settings ===
function App:load_settings()
    local stored = Storage.load_settings() or {}
    local s = {}
    for k, v in pairs(SETTINGS_DEFAULTS) do
        -- Preserve explicit false/nil-safe values; `and/or` would restore the
        -- default whenever stored[k] == false.
        if stored[k] ~= nil then
            s[k] = stored[k]
        else
            s[k] = v
        end
    end
    -- Preserve persisted keys with no compiled default (update_channel,
    -- plugin_lang, installed_build, default_preset_id, ...): dropping them
    -- silently reverted e.g. the update channel on every restart.
    for k, v in pairs(stored) do
        if s[k] == nil and v ~= nil then
            s[k] = v
        end
    end
    self.state.settings = s
    self:apply_settings()
end

function App:save_setting(key, value)
    self.state.settings[key] = value
    Storage.save_settings(self.state.settings)
    self:apply_settings()
end

function App:apply_settings()
    local Theme = require("ktui/theme")
    local s = self.state.settings
    -- One-time migration: ST-DEFAULT (flat) is the new default chat style.
    -- Old installs carry the pre-v0.4 default ("st"); move them over unless
    -- they explicitly picked a style other than that old default.
    if s.migrated_flat_style ~= true then
        if s.bubble_style == nil or s.bubble_style == "st" or s.bubble_style == "rounded" then
            s.bubble_style = "flat"
        end
        s.migrated_flat_style = true
        Storage.save_settings(s)
    end
    -- One-time migration (v0.5): ST-BUBBLES panels are the new default look.
    -- Everyone the v0.4 migration moved onto flat (plus fresh installs)
    -- moves to bubbles; explicitly non-flat styles stay.
    if s.migrated_bubbles_style ~= true then
        if s.bubble_style == nil or s.bubble_style == "flat" then
            s.bubble_style = "bubbles"
        end
        s.migrated_bubbles_style = true
        Storage.save_settings(s)
    end
    Theme.set_theme(s.theme)
    Theme.set_base_font_size(s.base_font_size)
    Theme.set_density(s.density)
    Theme.set_bubble_style(s.bubble_style)
    Theme.set_chat_bg(s.chat_bg)
end

function App:_active_persona()
    local personas = Storage.list_personas()
    local id = self.state.current_chat_persona_id or personas.active
    if not id then
        return nil
    end
    for _, p in ipairs(personas.list or {}) do
        if p.id == id then
            return p
        end
    end
    return nil
end

function App:_active_persona_name()
    local p = self:_active_persona()
    if p then
        local name = p.name or p.display_name or ""
        if name ~= "" then
            return name
        end
    end
    return "You"
end

function App:_active_persona_avatar()
    local p = self:_active_persona()
    if p and p.avatar and p.avatar ~= "" then
        return p.avatar
    end
    return nil
end

function App:toggle_setting(key)
    self.state.settings[key] = not self.state.settings[key]
    self:save_setting(key, self.state.settings[key])
    self:refresh(true)
end

function App:choose_setting(key, title, options)
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local current = self.state.settings[key]
    local actions = {}
    for _, opt in ipairs(options or {}) do
        table.insert(actions, {
            label = opt.label or tostring(opt.value),
            icon = opt.icon,
            checked = (current == opt.value),
            on_tap = function()
                self:save_setting(key, opt.value)
                self:refresh(true)
            end,
        })
    end
    Sheets.show(self, { title = title, actions = actions })
end

-- Effective UI language: the stored plugin choice, or the device language
-- when following the system (nil). The settings row displays this - never
-- the raw device value alone.
function App:active_lang()
    local pl = self.state.settings and self.state.settings.plugin_lang
    if type(pl) == "string" and pl ~= "" then
        return pl
    end
    return require("kt_i18n").get_lang()
end

-- Apply a language now (through the changeLang hook so our catalog follows).
function App:apply_language(lang)
    local ok, gettext = pcall(require, "gettext")
    if ok and gettext and gettext.changeLang and gettext.current_lang ~= lang then
        gettext.changeLang(lang)
    end
    self:refresh(true)
end

function App:choose_language()
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local I18n = require("kt_i18n")
    local self_ref = self

    local active = self:active_lang()
    local options = {
        { label = _("English"), value = "en" },
        { label = _("Portuguese (Brazil)"), value = "pt_BR" },
        { label = _("Spanish"), value = "es" },
    }
    local actions = {
        { label = _("Follow system"),
          checked = (self.state.settings and self.state.settings.plugin_lang) == nil,
          on_tap = function()
              self_ref.state.settings.plugin_lang = nil
              Storage.save_settings(self_ref.state.settings)
              self_ref:apply_language(I18n.get_lang())
          end },
    }
    for _, opt in ipairs(options) do
        table.insert(actions, {
            label = opt.label or opt.value,
            checked = active == opt.value,
            on_tap = function()
                self_ref.state.settings.plugin_lang = opt.value
                Storage.save_settings(self_ref.state.settings)
                self_ref:apply_language(opt.value)
            end,
        })
    end
    Sheets.show(self, { title = _("Language"), actions = actions })
end

function App:prompt_base_font_size()
    local SpinWidget = require("ui/widget/spinwidget")
    local Theme = require("ktui/theme")
    local _ = require("gettext")
    local self_ref = self
    UIManager:show(SpinWidget:new{
        title_text = _("Font size"),
        value = self.state.settings.base_font_size,
        value_min = Theme.MIN_BASE_FONT_SIZE,
        value_max = Theme.MAX_BASE_FONT_SIZE,
        value_step = 1,
        value_hold_step = 2,
        callback = function(spin)
            self_ref:save_setting("base_font_size", spin.value)
            self_ref:refresh(true)
        end,
    })
end

-- ST send_if_empty: placeholder message sent when the user submits empty input
function App:prompt_send_if_empty()
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self
    Modals.input(_("Send when empty"),
        tostring(self.state.settings.send_if_empty or ""),
        _("Empty to disable"), _("Save"), function(text)
        text = Util.trim(tostring(text or ""))
        self_ref.state.settings.send_if_empty = (text ~= "") and text or ""
        Storage.save_settings(self_ref.state.settings)
        self_ref:refresh(true)
    end)
end

-- Generic text prompt for a settings value (used by the reasoning prefix/
-- suffix fields). Blank input restores the default.
function App:prompt_setting(key, title, default)
    local Modals = require("ktui/modals")
    local self_ref = self
    local current = self.state.settings[key]
    Modals.input(title, (current ~= nil and tostring(current) or tostring(default or "")),
        title, _("Save"), function(text)
        text = Util.trim(tostring(text or ""))
        if text == "" then
            self_ref:save_setting(key, default)
        else
            self_ref:save_setting(key, text)
        end
        self_ref:refresh(true)
    end)
end

-- Auto-Continue target length (ST User Settings: 0-1024 tokens; 0 = every
-- length-cut reply continues, no size gate). SpinWidget - no keyboard on e-ink.
function App:prompt_auto_continue_length()
    local SpinWidget = require("ui/widget/spinwidget")
    local _ = require("gettext")
    local self_ref = self
    local current = tonumber(self.state.settings.auto_continue_length) or 200
    UIManager:show(SpinWidget:new{
        title_text = _("Auto-continue target (tokens)"),
        value = current,
        value_min = 0,
        value_max = 1024,
        value_step = 50,
        value_hold_step = 100,
        callback = function(spin)
            self_ref:save_setting("auto_continue_length", spin.value)
            self_ref:refresh(true)
        end,
    })
end

function App:prompt_chunk_interval()
    local SpinWidget = require("ui/widget/spinwidget")
    local _ = require("gettext")
    local self_ref = self
    local current_ms = math.floor((tonumber(self.state.settings.stream_chunk_interval) or 0.3) * 1000)
    UIManager:show(SpinWidget:new{
        title_text = _("Stream update interval (ms)"),
        value = current_ms,
        value_min = 100,
        value_max = 1000,
        value_step = 50,
        value_hold_step = 100,
        callback = function(spin)
            self_ref:save_setting("stream_chunk_interval", spin.value / 1000)
            self_ref:refresh(true)
        end,
    })
end

function App:scroll_key()
    return self.state.page .. "_" .. tostring(self.state.current_chat_id or "")
end

-- Stream repaint pacing labels (settings.stream_refresh, e-ink flicker).
function App:stream_refresh_label()
    local _ = require("gettext")
    local mode = self.state.settings and self.state.settings.stream_refresh
    if mode == "live" then
        return _("Live")
    elseif mode == "still" then
        return _("Still")
    end
    return _("Calm")
end

function App:choose_stream_refresh()
    local _ = require("gettext")
    self:choose_setting("stream_refresh", _("Stream refresh"), {
        { label = _("Live"), value = "live", icon = "bolt" },
        { label = _("Calm"), value = "calm", icon = "clock" },
        { label = _("Still"), value = "still", icon = "eye" },
    })
end

function App:refresh_chats_index()
    local Storage = require("kt_storage")
    local chats = Storage.list_all_chats()
    local items = {}
    for _, chat in ipairs(chats) do
        table.insert(items, {
            text = chat.name or "Chat",
            subtext = chat.character_name and ("(" .. chat.character_name .. ")") or nil,
            path = chat.path,
            character_name = chat.character_name,
            character_path = chat.character_path,
            connection_id = chat.connection_id,
            modified = chat.modified,
            callback = function()
                local conn = nil
                local connections = Storage.list_connections()
                for _, c in ipairs(connections) do
                    if c.id == chat.connection_id then
                        conn = c
                        break
                    end
                end
                self:open_chat(chat.character_name, chat.path, conn)
            end,
        })
    end
    self.state.chats_index = items
end

function App:show()
    -- Re-install every open: closing the view uninstalls i18n (so our
    -- strings don't leak into KOReader core), but the Launcher reuses this
    -- instance - without this, the 2nd open paints English with pt labels.
    I18n.install()
    -- Re-apply a stored plugin language (it dies with uninstall on close).
    local pl = self.state.settings and self.state.settings.plugin_lang
    if type(pl) == "string" and pl ~= "" then
        self:apply_language(pl)
    end
    if not self.view then
        self.view = AppView:new{ app = self }
    end
    self:refresh_characters()
    self:refresh_chats_index()
    UIManager:show(self.view)
    UIManager:setDirty(self.view, "full")
end

function App:close()
    self:_cancel_generation()
    if self.view then
        UIManager:close(self.view)
    end
    I18n.uninstall()
end

function App:refresh(full)
    if self.view then
        UIManager:setDirty(self.view, full and "full" or "ui")
    end
end

function App:refresh_characters()
    local Storage = require("kt_storage")
    self.state.character_files = Storage.list_character_files()
end

-- Navigation
function App:navigate(page, extra)
    self.state.previous_page = self.state.page
    self.state.page = page
    if extra then
        for k, v in pairs(extra) do
            self.state[k] = v
        end
    end
    self:refresh(true)
end

function App:go_back()
    local prev = self.state.previous_page or "dashboard"
    self.state.page = prev
    self.state.previous_page = nil
    self:refresh(true)
end

-- === Dashboard: search / sort / filter / view ===
function App:set_dashboard_query(query)
    self.state.dashboard_query = query or ""
    self:refresh()
end

function App:set_dashboard_sort(sort)
    self.state.settings.dashboard_sort = sort
    Storage.save_settings(self.state.settings)
    self:refresh()
end

function App:set_dashboard_filter(filter)
    self.state.dashboard_filter = filter or "all"
    self:refresh()
end

function App:toggle_dashboard_view()
    local current = self.state.settings.dashboard_view == "list" and "grid" or "list"
    self.state.settings.dashboard_view = current
    Storage.save_settings(self.state.settings)
    self:refresh()
end

-- Toggle favorite from a card/list item (updates the item in place so the
-- drawn star reflects the new state immediately).
function App:toggle_favorite(item)
    local new_state = Storage.toggle_favorite(item.path)
    if item then
        item.fav = new_state
    end
    self:refresh(true)
    return new_state
end

-- Dashboard customization helpers (used by the Settings → Dashboard page and
-- by the dashboard renderer). Missing/odd values fall back to the defaults so
-- old settings files never break the layout.
function App:dashboard_columns()
    local c = tonumber(self.state.settings.dashboard_columns) or 3
    if c < 2 then
        c = 2
    elseif c > 4 then
        c = 4
    end
    return c
end

function App:dashboard_card_h()
    local Theme = require("ktui/theme")
    local heights = {
        short = Theme.scale(320),
        normal = Theme.metrics().card_h,
        tall = Theme.scale(480),
    }
    return heights[self.state.settings.dashboard_card_h] or Theme.metrics().card_h
end

function App:reset_dashboard_settings()
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local keys = {
        "dashboard_view", "dashboard_sort", "dashboard_columns",
        "dashboard_card_h", "dashboard_show_name", "dashboard_show_tags",
        "dashboard_show_meta", "dashboard_star", "dashboard_caption",
        "show_covers",
    }
    Sheets.confirm(self, {
        title = _("Restore defaults"),
        text = _("Reset dashboard settings?"),
        ok_label = _("Reset"),
        on_ok = function()
            for _, k in ipairs(keys) do
                if SETTINGS_DEFAULTS[k] ~= nil then
                    self.state.settings[k] = SETTINGS_DEFAULTS[k]
                end
            end
            Storage.save_settings(self.state.settings)
            self:refresh(true)
        end,
    })
end

function App:show_dashboard_search()
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self
    Modals.search(_("Search characters"), self.state.dashboard_query or "", _("Name, creator or tag"), function(text)
        self_ref:set_dashboard_query(text)
    end)
end

function App:show_chats_search()
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self
    Modals.search(_("Search chats"), self.state.chats_query or "", _("Chat, character or message"), function(text)
        self_ref:set_chats_query(text)
    end)
end

function App:set_chats_sort(sort)
    self.state.chats_sort = sort
    self:refresh()
end

function App:show_chats_sort()
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local self_ref = self
    local current = self.state.chats_sort or "recent"
    local options = {
        { value = "recent", text = _("Recent first") },
        { value = "name_asc", text = _("Name A-Z") },
        { value = "name_desc", text = _("Name Z-A") },
    }
    local actions = {}
    for _, o in ipairs(options) do
        table.insert(actions, {
            label = o.text,
            checked = (current == o.value),
            on_tap = function()
                self_ref:set_chats_sort(o.value)
            end,
        })
    end
    Sheets.show(self, { title = _("Sort chats"), actions = actions })
end

-- Chats modified since the Chats page was last opened (nav badge). First run
-- (last_seen == 0) stays silent so the whole history doesn't badge at once.
function App:chats_unseen_count()
    local last_seen = tonumber(self.state.settings.last_seen_chats) or 0
    if last_seen <= 0 then
        return 0
    end
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not lfs_ok then
        return 0
    end
    local count = 0
    for _, chat in ipairs(self.state.chats_index or {}) do
        local ok, mt = pcall(lfs.attributes, chat.path, "modification")
        if ok and tonumber(mt) and tonumber(mt) > last_seen then
            count = count + 1
        end
    end
    return count
end

-- Chats rows after the query filter + chosen sort. Shared by Pages.chats and
-- the header title's live count so both always agree. "recent" keeps the
-- chats_index's natural (mtime-desc) order.
function App:chats_visible()
    local Storage = require("kt_storage")
    local chats = {}
    local query = (self.state.chats_query or ""):lower()
    for _, chat in ipairs(self.state.chats_index or {}) do
        if query == "" then
            table.insert(chats, chat)
        else
            local name = (chat.text or chat.name or ""):lower()
            local char_name = (chat.character_name or ""):lower()
            local preview = (Storage.chat_preview(chat.path) or ""):lower()
            if name:find(query, 1, true) or char_name:find(query, 1, true) or preview:find(query, 1, true) then
                table.insert(chats, chat)
            end
        end
    end
    local sort = self.state.chats_sort or "recent"
    if sort == "name_asc" or sort == "name_desc" then
        table.sort(chats, function(a, b)
            local an = (a.text or a.name or ""):lower()
            local bn = (b.text or b.name or ""):lower()
            if sort == "name_desc" then
                return an > bn
            end
            return an < bn
        end)
    end
    return chats
end

function App:set_chats_query(query)
    self.state.chats_query = query or ""
    self.state.scroll["chats_"] = 0
    self:refresh(true)
end

function App:show_dashboard_sort()
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local self_ref = self
    local current = self.state.settings.dashboard_sort or "name_asc"
    local options = {
        { value = "name_asc", text = _("Name A-Z") },
        { value = "name_desc", text = _("Name Z-A") },
        { value = "newest", text = _("Newest") },
        { value = "oldest", text = _("Oldest") },
        { value = "recent", text = _("Recent chats") },
        { value = "fav", text = _("Favorites first") },
    }
    local actions = {}
    for _, o in ipairs(options) do
        table.insert(actions, {
            label = o.text,
            checked = (current == o.value),
            on_tap = function()
                self_ref:set_dashboard_sort(o.value)
            end,
        })
    end
    Sheets.show(self, { title = _("Sort characters"), actions = actions })
end

function App:show_dashboard_filter()
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local self_ref = self
    local current = self.state.dashboard_filter or "all"
    local actions = {}
    local function add(label, value)
        table.insert(actions, { label = label, checked = (current == value), on_tap = function()
            self_ref:set_dashboard_filter(value)
        end })
    end
    add(_("All"), "all")
    add(_("Favorites"), "fav")
    -- Tag list (card meta cache + global tags)
    local tags = {}
    for path, meta in pairs(self.state._card_cache or {}) do
        for _, t in ipairs(meta.tags or {}) do
            local tag = tostring(t)
            if tag ~= "" then
                tags[tag] = true
            end
        end
    end
    for path, tlist in pairs(self.state.settings.tag_map or {}) do
        for _, t in ipairs(tlist or {}) do
            local tag = tostring(t)
            if tag ~= "" then
                tags[tag] = true
            end
        end
    end
    for tag in pairs(tags) do
        add("#" .. tag, "tag:" .. tag)
    end
    Sheets.show(self, { title = _("Filter characters"), actions = actions })
end

-- Build the dashboard character items: parsed meta (cached), then filtered by
-- the current query/filter, then sorted by the chosen sort rule.
function App:dashboard_items()
    local items = {}
    for _, path in ipairs(Storage.list_character_files()) do
        table.insert(items, {
            path = path,
            name = Storage.character_name_from_path(path),
            fav = Storage.is_favorite(path),
        })
    end

    local cache = self.state._card_cache
    if not cache then
        cache = {}
        self.state._card_cache = cache
    end
    local Models = require("kt_models")
    for _, it in ipairs(items) do
        local meta = cache[it.path]
        if not meta then
            meta = {}
            local ok, card = pcall(require("kotaven_png").parse_character, it.path)
            if ok and type(card) == "table" then
                meta.version = card.character_version
                meta.creator = card.creator
                meta.tags = card.tags
                meta.card_name = card.name
                -- Token estimate = only what is actually sent to the LLM
                -- (system_prompt + description + personality + scenario +
                -- post_history_instructions). Rough heuristic: 1 token ≈ 4 chars.
                meta.tokens = math.ceil(#Models.build_system_prompt(card) / 4)
            end
            cache[it.path] = meta
        end
        it.version = meta.version or ""
        it.creator = meta.creator or ""
        it.tags = meta.tags or {}
        it.tokens = meta.tokens or 0
        -- Display the card's own name (not the file name); fall back to the
        -- file-derived name when the card has none.
        if type(meta.card_name) == "string" and meta.card_name ~= "" then
            it.display_name = meta.card_name
        else
            it.display_name = it.name
        end
        -- merge global tags (settings.tag_map)
        local global_tags = (self.state.settings.tag_map or {})[it.path]
        if type(global_tags) == "table" then
            local seen = {}
            for _, t in ipairs(it.tags) do seen[tostring(t)] = true end
            for _, t in ipairs(global_tags) do
                if not seen[tostring(t)] then table.insert(it.tags, t) end
            end
        end
    end

    -- Query filter (name / creator / tag, case-insensitive substring).
    -- Matches the displayed card name too, not just the file name.
    local q = (self.state.dashboard_query or ""):lower()
    if q ~= "" then
        local filtered = {}
        for _, it in ipairs(items) do
            local hit = (it.name or ""):lower():find(q, 1, true) ~= nil
            if not hit and it.display_name and it.display_name ~= it.name then
                hit = it.display_name:lower():find(q, 1, true) ~= nil
            end
            if not hit and it.creator ~= "" then
                hit = it.creator:lower():find(q, 1, true) ~= nil
            end
            if not hit then
                for _, t in ipairs(it.tags) do
                    if tostring(t):lower():find(q, 1, true) then
                        hit = true
                        break
                    end
                end
            end
            if hit then
                table.insert(filtered, it)
            end
        end
        items = filtered
    end

    -- Filter menu state
    local flt = self.state.dashboard_filter or "all"
    if flt == "fav" then
        local filtered = {}
        for _, it in ipairs(items) do
            if it.fav then
                table.insert(filtered, it)
            end
        end
        items = filtered
    elseif flt:match("^tag:") then
        local want = flt:sub(5)
        local filtered = {}
        for _, it in ipairs(items) do
            for _, t in ipairs(it.tags) do
                if tostring(t) == want then
                    table.insert(filtered, it)
                    break
                end
            end
        end
        items = filtered
    end

    -- Sort
    local sort = self.state.settings.dashboard_sort or "name_asc"
    local function by_name(a, b)
        return (a.name or ""):lower() < (b.name or ""):lower()
    end
    if sort == "name_asc" or sort == "name_desc" then
        table.sort(items, by_name)
        if sort == "name_desc" then
            local rev = {}
            for i = #items, 1, -1 do
                table.insert(rev, items[i])
            end
            items = rev
        end
    elseif sort == "newest" or sort == "oldest" then
        local lfs = require("libs/libkoreader-lfs")
        local mtimes = {}
        for _, it in ipairs(items) do
            local ok, mtime = pcall(lfs.attributes, it.path, "modification")
            mtimes[it] = (ok and tonumber(mtime)) or 0
        end
        table.sort(items, function(a, b)
            local ma = mtimes[a] or 0
            local mb = mtimes[b] or 0
            if ma == mb then
                return by_name(a, b)
            end
            if sort == "newest" then
                return ma > mb
            end
            return ma < mb
        end)
    elseif sort == "recent" then
        local last_chat = {}
        for _, chat in ipairs(self.state.chats_index or {}) do
            local key = chat.character_path
            local mod = chat.modified or 0
            if not last_chat[key] or mod > last_chat[key] then
                last_chat[key] = mod
            end
        end
        table.sort(items, function(a, b)
            local ma = last_chat[a.path] or 0
            local mb = last_chat[b.path] or 0
            if ma == mb then
                return by_name(a, b)
            end
            return ma > mb
        end)
    elseif sort == "fav" then
        table.sort(items, function(a, b)
            if a.fav ~= b.fav then
                return a.fav
            end
            return by_name(a, b)
        end)
    end

    return items
end

-- === Character Actions ===
App.CHARACTER_FIELDS = {
    { key = "name", title = "Name" },
    { key = "description", title = "Description", multiline = true },
    { key = "personality", title = "Personality", multiline = true },
    { key = "scenario", title = "Scenario", multiline = true },
    { key = "first_mes", title = "First Message", multiline = true },
    { key = "alternate_greetings", title = "Alternate Greetings", multiline = true },
    { key = "mes_example", title = "Example Messages", multiline = true },
    { key = "system_prompt", title = "System Prompt", multiline = true },
    { key = "post_history_instructions", title = "Post-History Instructions", multiline = true },
    { key = "creator_notes", title = "Creator Notes", multiline = true },
    { key = "creator", title = "Creator" },
    { key = "tags", title = "Tags (comma separated)" },
    { key = "character_version", title = "Version" },
}

function App:show_character_actions(item)
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local self_ref = self

    local char_name = item.display_name or Storage.character_name_from_path(item.path)
    local is_fav = item.fav

    local actions = {
        { label = _("New Chat"), icon = "chat", on_tap = function()
                self_ref:start_new_chat(item.path, char_name)
            end,
        },
        { label = is_fav and _("Remove Favorite") or _("Add to Favorites"), icon = is_fav and "star-empty" or "star", on_tap = function()
                self_ref:toggle_favorite(item)
            end,
        },
        { label = _("View Card"), icon = "eye", on_tap = function()
                self_ref:view_character(item)
            end,
        },
        { label = _("Edit Card"), icon = "edit", on_tap = function()
                self_ref:show_character_editor(item)
            end,
        },
        { label = _("Duplicate"), icon = "copy", on_tap = function()
                self_ref:duplicate_character(item)
            end,
        },
        { label = _("Export Card"), icon = "upload", on_tap = function()
                self_ref:export_character(item)
            end,
        },
        { label = _("Edit Tags"), icon = "tag", on_tap = function()
                self_ref:edit_character_tags(item)
            end,
        },
        { label = _("Delete"), icon = "trash", danger = true, on_tap = function()
                Sheets.confirm(self_ref, {
                    title = _("Delete character"),
                    text = _("Delete this character and all its chats?"),
                    ok_label = _("Delete"), danger = true,
                    on_ok = function()
                        self_ref:delete_character(item)
                    end,
                })
            end,
        },
    }

    Sheets.show(self_ref, { title = char_name, actions = actions })
end

-- Global character tags (settings.tag_map, keyed by card path)
function App:edit_character_tags(item)
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self
    local path = item.path
    local current = table.concat((self.state.settings.tag_map or {})[path] or {}, ", ")
    local name = item.display_name or Storage.character_name_from_path(path)
    Modals.input(_("Tags") .. " - " .. name, current, _("Comma separated"), _("Save"), function(text)
        local tags = {}
        for part in tostring(text or ""):gmatch("[^,]+") do
            local t = part:match("^%s*(.-)%s*$")
            if t ~= "" then table.insert(tags, t) end
        end
        self_ref.state.settings.tag_map = self_ref.state.settings.tag_map or {}
        if #tags > 0 then
            self_ref.state.settings.tag_map[path] = tags
        else
            self_ref.state.settings.tag_map[path] = nil
        end
        Storage.save_settings(self_ref.state.settings)
        self_ref.state._card_cache = nil
        self_ref:refresh(true)
    end)
end

function App:view_character(item)
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    local path = item.path
    local ok, card = pcall(require("kotaven_png").parse_character, path)
    if not ok or type(card) ~= "table" then
        UIManager:show(InfoMessage:new{ text = _("Could not read this character card."), timeout = 3 })
        return
    end
    self.state.viewing_character = {
        path = path,
        card = card,
        name = card.name or Storage.character_name_from_path(path),
    }
    -- Token estimate for the header (same heuristic as the dashboard, once
    -- per visit instead of per paint).
    do
        local ok_m, Models = pcall(require, "kt_models")
        if ok_m and Models and Models.build_system_prompt then
            local ok_b, sysprompt = pcall(Models.build_system_prompt, card)
            if ok_b and type(sysprompt) == "string" then
                self.state.viewing_character.tokens = math.ceil(#sysprompt / 4)
            end
        end
    end
    -- Collapsed sections reset per visit (all closed).
    self.state.character_view_open = nil
    self:navigate("character_view")
end

-- Full-screen view of a character card image with zoom (KOReader ImageViewer).
function App:show_character_image_fullscreen(path)
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    local lfs = require("libs/libkoreader-lfs")
    if not path or path == "" or not lfs.attributes(path) then
        return
    end
    -- renderImageFile is a METHOD (RenderImage:renderImageFile(file)) - call
    -- it with self, or the path lands in `self` and the open fails.
    local RenderImage = require("ui/renderimage")
    local ok, bb = pcall(RenderImage.renderImageFile, RenderImage, path)
    if not ok or not bb then
        UIManager:show(InfoMessage:new{ text = _("Could not load the image."), timeout = 3 })
        return
    end
    -- NOTE: the buffer is a raw FFI BlitBuffer struct: never assign custom
    -- fields on it (e.g. bb._disposed crashes with "has no member named").
    -- Ownership passes to the viewer via image_disposable below.
    local viewer = require("ui/widget/imageviewer"):new{
        image = bb,
        fullscreen = true,
        with_title_bar = false,
        image_disposable = true,
    }
    UIManager:show(viewer)
end

function App:show_character_editor(item)
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    local path = item.path
    local card = item._card_cache
    if not card then
        local ok, parsed = pcall(require("kotaven_png").parse_character, path)
        if not ok or type(parsed) ~= "table" then
            UIManager:show(InfoMessage:new{ text = _("Could not read this character card."), timeout = 3 })
            return
        end
        card = parsed
    end
    self.state.editing_character = {
        path = path,
        card = card,
        name = card.name or Storage.character_name_from_path(path),
    }
    self:navigate("character_editor")
end

function App:edit_character_field(key)
    local Modals = require("ktui/modals")
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    local editing = self.state.editing_character
    if not editing or not editing.card then return end
    local fields = App.CHARACTER_FIELDS
    local self_ref = self
    local field = nil
    for _, f in ipairs(fields) do
        if f.key == key then field = f break end
    end
    if not field then return end

    -- Alternate greetings have a dedicated sub-page (add/edit/delete per item)
    if key == "alternate_greetings" then
        self:open_character_greetings()
        return
    end

    local function to_edit_value(k)
        local v = editing.card[k]
        if k == "alternate_greetings" and type(v) == "table" then
            return table.concat(v, "\n\n")
        elseif k == "tags" and type(v) == "table" then
            return table.concat(v, ", ")
        end
        return tostring(v or "")
    end

    Modals.input(_(field.title), to_edit_value(key), _(field.title), _("Save"), function(text)
        text = text or ""
        if key == "alternate_greetings" then
            local arr = {}
            for line in text:gmatch("[^\n]+") do
                if line ~= "" then table.insert(arr, line) end
            end
            editing.card.alternate_greetings = arr
        elseif key == "tags" then
            local arr = {}
            for tag in text:gmatch("[^,]+") do
                local t = tag:match("^%s*(.-)%s*$")
                if t ~= "" then table.insert(arr, t) end
            end
            editing.card.tags = arr
        else
            editing.card[key] = text
        end
        self_ref:refresh(true)
    end, field.multiline)
end

-- === Alternate Greetings (sub-page of the card editor) ===
-- Individual first messages used when starting a new chat. Lives in the
-- character card's `alternate_greetings` array; `first_mes` is separate.
function App:open_character_greetings()
    if not self.state.editing_character then return end
    self:navigate("character_greetings")
end

function App:add_character_greeting()
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local editing = self.state.editing_character
    if not editing or not editing.card then return end
    local self_ref = self
    Modals.input(_("New Greeting"), "", _("First message for a new chat"), _("Add"), function(text)
        text = text or ""
        text = text:gsub("^%s+", ""):gsub("%s+$", "")
        if text == "" then return end
        local greetings = editing.card.alternate_greetings
        if type(greetings) ~= "table" then greetings = {} end
        table.insert(greetings, text)
        editing.card.alternate_greetings = greetings
        self_ref:refresh(true)
    end, true)
end

function App:edit_character_greeting(index)
    local Modals = require("ktui/modals")
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    local editing = self.state.editing_character
    if not editing or not editing.card then return end
    local greetings = editing.card.alternate_greetings
    if type(greetings) ~= "table" or not greetings[index] then return end
    local self_ref = self
    Modals.input(_("Edit Greeting"), greetings[index], _("Greeting for a new chat"), _("Save"), function(text)
        text = text or ""
        text = text:gsub("^%s+", ""):gsub("%s+$", "")
        if text == "" then
            UIManager:show(InfoMessage:new{ text = _("Greeting must not be empty."), timeout = 3 })
            return
        end
        greetings[index] = text
        editing.card.alternate_greetings = greetings
        self_ref:refresh(true)
    end, true)
end

function App:delete_character_greeting(index)
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local editing = self.state.editing_character
    if not editing or not editing.card then return end
    local self_ref = self
    Sheets.confirm(self_ref, {
        title = _("Delete greeting"),
        text = _("Delete this greeting?"),
        ok_label = _("Delete"), danger = true,
        on_ok = function()
            local greetings = editing.card.alternate_greetings
            if type(greetings) ~= "table" then return end
            table.remove(greetings, index)
            self_ref:refresh(true)
        end,
    })
end

function App:save_character_edit()
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    local editing = self.state.editing_character
    if not editing or not editing.card then return end
    local ok, err = pcall(require("kotaven_export").rewrite_png_card, editing.path, editing.card)
    if not ok or not err then
        UIManager:show(InfoMessage:new{ text = _("Failed to save: ") .. tostring(err or "error"), timeout = 4 })
        return
    end
    if self.state._card_cache and self.state._card_cache[editing.path] then
        self.state._card_cache[editing.path] = nil
    end
    self.state.editing_character = nil
    self:refresh_characters()
    self:go_back()
    UIManager:show(InfoMessage:new{ text = _("Character card saved!"), timeout = 2 })
end

function App:duplicate_character(item)
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    local path = item.path
    local base = (item.display_name or Storage.character_name_from_path(path)) .. " (copy)"
    local ext = (path:lower():match("%.([^%.]+)$") or "png")
    local dest = Storage.characters_dir() .. "/" .. Util.safe_filename(base) .. "." .. ext
    local ok, err = pcall(require("kotaven_export").copy_file, path, dest)
    if not ok or not err then
        UIManager:show(InfoMessage:new{ text = _("Failed to duplicate: ") .. tostring(err or "error"), timeout = 4 })
        return
    end
    self:refresh_characters()
    self:refresh(true)
    UIManager:show(InfoMessage:new{ text = _("Character duplicated!"), timeout = 2 })
end

function App:delete_character(item)
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    local path = item.path
    local name = item.display_name or Storage.character_name_from_path(path)
    -- remove favorite
    if Storage.is_favorite(path) then
        Storage.toggle_favorite(path)
    end
    -- remove chats
    Storage.delete_chats_for(name)
    -- remove card file
    os.remove(path)
    if self.state._card_cache then
        self.state._card_cache[path] = nil
    end
    self:refresh_characters()
    self:refresh(true)
    UIManager:show(InfoMessage:new{ text = _("Character deleted."), timeout = 2 })
end

-- === Personas ===
function App:edit_persona(persona)
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self
    persona = persona or {}
    Modals.multi_input(persona.id and _("Edit Persona") or _("New Persona"), {
        { text = persona.name or "", hint = _("Name") },
        { text = persona.description or "", hint = _("Description (sent as context to AI)") },
    }, _("Save"), function(fields)
        local name = fields and fields[1]
        if not name or name == "" then
            UIManager:show(InfoMessage:new{ text = _("Please give the persona a name.") })
            return
        end
        Storage.upsert_persona({
            id = persona.id,
            name = name,
            description = (fields and fields[2]) or "",
        })
        self_ref:refresh(true)
    end)
end

function App:set_persona_image(persona)
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    local self_ref = self
    self:choose_file_path(function(file_path)
        local ext = (file_path:lower():match("%.([^%.]+)$") or "")
        if ext ~= "png" and ext ~= "jpg" and ext ~= "jpeg" and ext ~= "webp" then
            UIManager:show(InfoMessage:new{
                text = _("Please select an image file (.png, .jpg, .webp)."),
                timeout = 3,
            })
            return
        end
        local dest = Storage.personas_images_dir() .. "/" .. (persona.id or "persona") .. "." .. ext
        local f = io.open(file_path, "rb")
        if not f then
            UIManager:show(InfoMessage:new{ text = _("Could not read the image."), timeout = 3 })
            return
        end
        local content = f:read("*a")
        f:close()
        local out = io.open(dest, "wb")
        if not out then
            UIManager:show(InfoMessage:new{ text = _("Could not save the image."), timeout = 3 })
            return
        end
        out:write(content)
        out:close()
        persona.avatar = dest
        Storage.upsert_persona(persona)
        self_ref:refresh(true)
    end)
end

function App:show_persona_actions(persona)
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local self_ref = self
    local data = Storage.list_personas()
    local is_active = (persona.id == data.active)

    local actions = {
        { label = _("Edit"), icon = "edit", on_tap = function()
                self_ref:edit_persona(persona)
            end,
        },
        { label = _("Duplicate"), icon = "copy", on_tap = function()
                local dup = {}
                for k, v in pairs(persona) do dup[k] = v end
                dup.id = nil
                dup.name = (dup.name or "Persona") .. " (copy)"
                Storage.upsert_persona(dup)
                self_ref:refresh(true)
            end,
        },
        { label = _("Set Image"), icon = "image", on_tap = function()
                self_ref:set_persona_image(persona)
            end,
        },
    }
    if persona.avatar and persona.avatar ~= "" then
        table.insert(actions, {
            label = _("Remove Image"), icon = "ban", on_tap = function()
                persona.avatar = nil
                Storage.upsert_persona(persona)
                self_ref:refresh(true)
            end,
        })
    end
    if not is_active then
        table.insert(actions, {
            label = _("Set as Active"), icon = "check", on_tap = function()
                Storage.set_active_persona(persona.id)
                self_ref:refresh(true)
            end,
        })
    end
    table.insert(actions, {
        label = _("Delete"), icon = "trash", danger = true, on_tap = function()
            Sheets.confirm(self_ref, {
                title = _("Delete persona"),
                text = _("Delete this persona permanently?"),
                ok_label = _("Delete"), danger = true,
                on_ok = function()
                    Storage.delete_persona(persona.id)
                    self_ref:refresh(true)
                end,
            })
        end,
    })
    Sheets.show(self_ref, { title = persona.name or "?", actions = actions })
end

function App:choose_chat_persona()
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local self_ref = self
    local data = Storage.list_personas()
    local current = self.state.current_chat_persona_id

    local actions = {
        { label = _("None"), checked = current == nil, on_tap = function()
                self_ref:set_chat_persona(nil)
            end,
        },
    }
    for _, p in ipairs(data.list or {}) do
        table.insert(actions, {
            label = p.name or "?",
            checked = (current == p.id),
            on_tap = function()
                self_ref:set_chat_persona(p.id)
            end,
        })
    end
    Sheets.show(self, { title = _("Select Persona"), actions = actions })
end

function App:set_chat_persona(persona_id)
    self.state.current_chat_persona_id = persona_id
    local path = self.state.current_chat_path
    if path then
        local chat_data = Storage.load_chat(path)
        if chat_data and chat_data.header and chat_data.header.chat_metadata then
            chat_data.header.chat_metadata.persona_id = persona_id
            local p = Storage.get_persona(persona_id)
            chat_data.header.chat_metadata.persona = p and p.name or nil
            Storage.save_chat(path, chat_data.header, chat_data.messages)
        end
    end
    self:refresh(true)
end

-- === Export / Import ===

function App:choose_export_dir(on_pick)
    local PathChooser = require("ui/widget/pathchooser")
    local dir_chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        path = "/home",
        onConfirm = function(dir)
            if dir and dir ~= "" and on_pick then on_pick(dir) end
        end,
    }
    UIManager:show(dir_chooser)
end

function App:export_chat(path)
    local _ = require("gettext")
    path = path or self.state.current_chat_path
    if not path then return end
    local chat_name = "chat"
    local chat_data = Storage.load_chat(path)
    if chat_data and chat_data.header and chat_data.header.chat_metadata
        and chat_data.header.chat_metadata.chat_name then
        chat_name = chat_data.header.chat_metadata.chat_name
    end
    local fname = Util.safe_filename(chat_name) .. ".jsonl"
    self:choose_export_dir(function(dir)
        local Export = require("kotaven_export")
        local ok, res = Export.copy_file(path, dir .. "/" .. fname)
        if ok then
            UIManager:show(InfoMessage:new{ text = _("Chat exported to ") .. res, timeout = 3 })
        else
            UIManager:show(InfoMessage:new{ text = _("Export failed: ") .. tostring(res) })
        end
    end)
end

function App:export_character(item)
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self
    local Png = require("kotaven_png")
    local character, parse_err = Png.parse_character(item.path)
    if not character then
        UIManager:show(InfoMessage:new{ text = _("Could not parse character card.") .. (parse_err and ("\n" .. tostring(parse_err)) or ""), timeout = 3 })
        return
    end
    local char_name = item.display_name or Storage.character_name_from_path(item.path)
    local fname_base = Util.safe_filename(char_name)
    local Sheets = require("ktui/sheets")
    Sheets.show(self_ref, { title = _("Export Card"), actions = {
        { label = _("Export PNG"), icon = "image", on_tap = function()
                self_ref:choose_export_dir(function(dir)
                    local Export = require("kotaven_export")
                    local ok, res = Export.character_to_png(character, dir .. "/" .. fname_base .. ".png")
                    if ok then
                        UIManager:show(InfoMessage:new{ text = _("Card exported to ") .. res, timeout = 3 })
                    else
                        UIManager:show(InfoMessage:new{ text = _("Export failed: ") .. tostring(res) })
                    end
                end)
            end,
        },
        { label = _("Export JSON"), icon = "file", on_tap = function()
                self_ref:choose_export_dir(function(dir)
                    local Export = require("kotaven_export")
                    local ok, res = Export.character_to_json(character, dir .. "/" .. fname_base .. ".json")
                    if ok then
                        UIManager:show(InfoMessage:new{ text = _("Card exported to ") .. res, timeout = 3 })
                    else
                        UIManager:show(InfoMessage:new{ text = _("Export failed: ") .. tostring(res) })
                    end
                end)
            end,
        },
    } })
end

function App:import_chat(file_path)
    local Modals = require("ktui/modals")
    local lfs = require("libs/libkoreader-lfs")
    local _ = require("gettext")

    -- Detect SillyTavern chat: first line is a header with chat_metadata
    local f = io.open(file_path, "rb")
    if not f then
        UIManager:show(InfoMessage:new{ text = _("Could not open file."), timeout = 2 })
        return
    end
    local first_line = f:read("*l")
    f:close()
    local ok, header = pcall(require("json").decode, first_line or "")
    if not ok or type(header) ~= "table" or type(header.chat_metadata) ~= "table" then
        UIManager:show(InfoMessage:new{
            text = _("Unsupported chat file. Expected a SillyTavern JSONL chat."),
            timeout = 3,
        })
        return
    end
    local meta = header.chat_metadata
    local chat_name = "Imported"
    if type(meta.chat_name) == "string" and meta.chat_name ~= "" then
        chat_name = meta.chat_name
    end

    local function do_import(target_char)
        local dir = Storage.chat_dir(target_char)
        local base = Util.safe_filename(chat_name) .. " imported"
        local dest = dir .. "/" .. base .. ".jsonl"
        local n = 2
        while lfs.attributes(dest) do
            dest = dir .. "/" .. base .. " (" .. tostring(n) .. ").jsonl"
            n = n + 1
        end
        local Export = require("kotaven_export")
        local copy_ok, copy_res = Export.copy_file(file_path, dest)
        if not copy_ok then
            UIManager:show(InfoMessage:new{ text = _("Import failed: ") .. tostring(copy_res) })
            return
        end
        self:refresh_chats_index()
        self:refresh(true)
        UIManager:show(InfoMessage:new{ text = _("Chat imported!") .. "\n" .. dest, timeout = 3 })
    end

    -- Our own exports carry character_name in chat_metadata → import directly
    if type(meta.character_name) == "string" and meta.character_name ~= "" then
        do_import(meta.character_name)
        return
    end

    -- SillyTavern native chats: let the user pick the target character
    local Sheets = require("ktui/sheets")
    local actions = {}
    for _, cpath in ipairs(Storage.list_character_files()) do
        local cname = Storage.character_name_from_path(cpath)
        table.insert(actions, {
            label = cname, icon = "user",
            on_tap = function() do_import(cname) end,
        })
    end
    table.insert(actions, {
        label = _("Unknown character"), icon = "question-circle",
        on_tap = function() do_import(_("Unknown")) end,
    })
    Sheets.show(self, { title = _("Import into which character?"), actions = actions })
end

-- === Chat Flow ===

function App:start_new_chat(char_path, char_name)
    local Modals = require("ktui/modals")
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager = require("ui/uimanager")
    local _ = require("gettext")

    -- Step 1: Get connections
    local connections = Storage.list_connections()
    if #connections == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No API connections yet!\nGo to API tab to add one."),
            timeout = 3,
        })
        return
    end

    -- Step 2: Choose connection
    local Sheets = require("ktui/sheets")
    local conn_items = {}
    for _, conn in ipairs(connections) do
        table.insert(conn_items, {
            label = conn.name .. " (" .. (conn.model_id or "?") .. ")",
            icon = "plug",
            on_tap = function()
                self:_finalize_new_chat(char_path, char_name, conn)
            end,
        })
    end

    Sheets.show(self, { title = _("Select API Connection"), actions = conn_items })
end

function App:_finalize_new_chat(char_path, char_name, connection)
    local Modals = require("ktui/modals")
    local _ = require("gettext")

    -- Parse character from PNG (SillyTavern format)
    local Png = require("kotaven_png")
    local character, parse_err = Png.parse_character(char_path)
    if not character then
        -- Fallback: use filename as name
        character = {
            id = char_name,
            name = char_name,
            first_mes = "",
            alternate_greetings = {},
            description = "",
            personality = "",
            scenario = "",
            system_prompt = "",
            post_history_instructions = "",
            png_path = char_path,
        }
    end
    character.png_path = char_path

    -- Gather available greetings (first_mes + alternate_greetings)
    local greetings = {}
    if type(character.first_mes) == "string" and character.first_mes ~= "" then
        table.insert(greetings, character.first_mes)
    end
    if type(character.alternate_greetings) == "table" then
        for _, g in ipairs(character.alternate_greetings) do
            if type(g) == "string" and g ~= "" then
                table.insert(greetings, g)
            end
        end
    end

    local function proceed_with(greeting)
        -- Step 3: Name the chat
        local default_name = "Chat " .. os.date("%Y-%m-%d")
        Modals.input(_("Chat Name"), default_name, _("Enter a name for this chat"), _("Start"), function(chat_name)
            if not chat_name or chat_name == "" then
                chat_name = default_name
            end
            self:_start_new_chat(char_path, char_name, connection, character, chat_name, greeting)
        end)
    end

    -- Step 2b: Let the user pick which greeting to start with (if any choice)
    if #greetings <= 1 then
        proceed_with(greetings[1])
        return
    end

    local items = {}
    local Sheets = require("ktui/sheets")
    local Widgets = require("ktui/widgets")
    for i, g in ipairs(greetings) do
        local preview = Widgets.truncate((g):gsub("\r", " "):gsub("\n", " "), 45)
        table.insert(items, {
            label = tostring(i) .. ". " .. preview,
            on_tap = function() proceed_with(g) end,
        })
    end
    table.insert(items, {
        label = _("No greeting"),
        on_tap = function() proceed_with(nil) end,
    })
    Sheets.show(self, { title = _("Select greeting"), actions = items })
end

function App:_start_new_chat(char_path, char_name, connection, character, chat_name, greeting)
    local _ = require("gettext")

    -- Create the chat in storage
    local persona_id = Storage.get_active_persona()
    local chat_info = Storage.create_chat(char_name, char_path, chat_name, connection.id, persona_id, nil)
    if persona_id then
        local p = Storage.get_persona(persona_id)
        if p then
            local chat_data = Storage.load_chat(chat_info.path)
            if chat_data and chat_data.header and chat_data.header.chat_metadata then
                chat_data.header.chat_metadata.persona = p.name or nil
                Storage.save_chat(chat_info.path, chat_data.header, chat_data.messages)
            end
        end
    end

    -- Build messages with the chosen greeting as initial message.
    -- ST parity: macros in the greeting ({{user}}/{{char}}) expand NOW
    -- against the creation-time persona - a raw greeting would teach the
    -- model to echo "{{user}}" literally in its replies.
    local initial_messages = {}
    if greeting and greeting ~= "" then
        local Models = require("kt_models")
        local persona_name = nil
        if persona_id then
            local pp = Storage.get_persona(persona_id)
            if pp and pp.name and pp.name ~= "" then
                persona_name = pp.name
            end
        end
        greeting = Models.expand_macros(greeting, {
            char = char_name or "",
            user = persona_name or "You",
            persona = "",
        })
        table.insert(initial_messages, {
            role = "assistant",
            content = greeting,
            name = char_name,
            send_date = os.time(),
            swipes = { greeting },
            swipe_id = 1,
        })
        -- Save greeting to JSONL immediately
        Storage.append_message(chat_info.path, "assistant", greeting, { swipes = { greeting }, swipe_id = 1 })
    end
    self.state.chat_first_mes = greeting or ""

    -- Enter chat view
    self.state.current_chat_id = chat_info.id
    self.state.current_character = char_name
    self.state.current_character_file = char_path
    self.state.current_character_data = character
    self.state.current_chat_path = chat_info.path
    self.state.current_chat_persona_id = persona_id
    self.state.current_connection = connection
    self.state.messages = initial_messages
    self.state.scroll["chat_" .. chat_info.id] = 999999
    self:refresh_chats_index()

    self:navigate("chat")
end

-- Enter an existing chat
function App:open_chat(char_name, chat_path, connection)
    -- Cancel any generation still running for the previous chat: its reply
    -- would otherwise land in this chat's in-memory message list (or block
    -- Send here until it finished).
    self:_cancel_generation()
    local chat_data = Storage.load_chat(chat_path)
    if not chat_data then
        UIManager:show(InfoMessage:new{
            text = _("Could not load chat."),
            timeout = 2,
        })
        return
    end

    local metadata = chat_data.header and chat_data.header.chat_metadata or {}
    local active_name = metadata.character_name or char_name or Storage.character_name_from_path(chat_path)
    local character_file = metadata.character_path
    local character_data
    if character_file then
        local Png = require("kotaven_png")
        local parsed_character = Png.parse_character(character_file)
        if parsed_character then
            character_data = parsed_character
        end
    end
    if not character_data then
        character_data = {
            id = active_name,
            name = active_name,
            description = "",
            personality = "",
            scenario = "",
            system_prompt = "",
            post_history_instructions = "",
            png_path = character_file,
        }
    end

    local active_connection = connection
    if not active_connection and metadata.connection_id then
        local connections = Storage.list_connections()
        for _, c in ipairs(connections) do
            if c.id == metadata.connection_id then
                active_connection = c
                break
            end
        end
    end

    self.state.current_chat_id = chat_path:match("([^/]+)%.jsonl$") or "chat"
    self.state.current_character = active_name
    self.state.current_character_file = character_file
    self.state.current_character_data = character_data
    self.state.current_chat_path = chat_path
    self.state.current_chat_persona_id = metadata.persona_id
    self.state.current_chat_preset_id = metadata.preset_id
    self.state.current_connection = active_connection
    self.state.messages = chat_data.messages or {}
    self.state.chat_first_mes = ""
    self.state.scroll["chat_" .. self.state.current_chat_id] = 999999

    self:navigate("chat")
end

-- === Message Flow ===

function App:send_message()
    if self.state.is_generating then return end

    local Modals = require("ktui/modals")
    local _ = require("gettext")

    Modals.input(_("Message"), "", _("Type your message..."), _("Send"), function(text)
        text = tostring(text or "")
        if Util.trim(text) == "" then
            -- ST send_if_empty: a configured placeholder makes empty submits
            -- meaningful; otherwise ignore.
            local placeholder = self.state.settings.send_if_empty
            if type(placeholder) == "string" and placeholder ~= "" then
                self:_do_send_message(placeholder)
            end
            return
        end
        self:_do_send_message(text)
    end)
end

-- Regenerate the last assistant reply, keeping the current one as a swipe so
-- the user can navigate back to it (SillyTavern "new swipe" behavior).
function App:regenerate_last()
    if self.state.is_generating then return end
    local msgs = self.state.messages
    if #msgs == 0 or msgs[#msgs].role ~= "assistant" then return end
    self:regenerate_message(#msgs)
end

-- Generate a new alternative response for the assistant message at msg_index.
-- Only the last assistant message is supported (keeps stop/regen simple).
function App:regenerate_message(msg_index)
    if self.state.is_generating then return end
    local msgs = self.state.messages
    local msg = msgs[msg_index]
    if not msg or msg.role ~= "assistant" then return end
    if msg_index ~= #msgs then return end

    -- Ensure the swipes structure exists before generating
    if type(msg.swipes) ~= "table" then
        msg.swipes = {}
    end
    if #msg.swipes == 0 and msg.content and msg.content ~= "" then
        table.insert(msg.swipes, msg.content)
        msg.swipe_id = 1
    end

    -- Persist current swipe set so navigation works even if generation fails
    local path = self.state.current_chat_path
    if path then
        Storage.update_message(path, msg_index, msg)
    end

    -- History excludes this message
    local history = {}
    for i = 1, msg_index - 1 do
        table.insert(history, msgs[i])
    end

    local Models = require("kt_models")
    local persona_desc = self:_active_persona_description()
    local character = self:_resolve_character_data()
    local api_messages = self:_build_api_messages(history)
    self:_do_generate(api_messages, { regenerate = msg, msg_index = msg_index })
end

-- Cycle between alternate responses (swipes) of a message.
function App:cycle_swipe(msg_index, direction)
    if self.state.is_generating then return end
    local msg = self.state.messages[msg_index]
    if not msg or msg.role ~= "assistant" then return end
    local n = #(msg.swipes or {})
    if n <= 1 then return end
    local new_id = (msg.swipe_id or 1) + direction
    if new_id < 1 then
        new_id = n
    elseif new_id > n then
        new_id = 1
    end
    msg.swipe_id = new_id
    msg.content = msg.swipes[new_id]
    local path = self.state.current_chat_path
    if path then
        Storage.update_message(path, msg_index, msg)
    end
    self:refresh(true)
end

-- Append a new swipe to a message and make it the active response.
function App:_append_swipe(msg, new_content)
    if type(msg.swipes) ~= "table" then
        msg.swipes = {}
    end
    table.insert(msg.swipes, new_content)
    msg.swipe_id = #msg.swipes
    msg.content = new_content
    return msg
end

-- Continue the last assistant message (SillyTavern nudge mode): the message
-- stays in the prompt followed by a continue instruction; the generated text
-- is appended to it as the same swipe.
local DEFAULT_CONTINUE_NUDGE = "[Continue your last message without repeating its original content.]"

-- Safety cap for chained Auto-Continues per user action (ST has no hard cap;
-- on mobile data/costs a runaway loop is unacceptable).
local MAX_AUTO_CONTINUES = 5

function App:continue_message(msg_index, auto_continue_n)
    -- auto_continue_n: Auto-Continue chain depth (nil = user-initiated)
    if self.state.is_generating then return end
    local msgs = self.state.messages
    local msg = msgs[msg_index]
    if not msg or msg.role ~= "assistant" then return end
    if msg_index ~= #msgs then return end

    local history = {}
    for i = 1, msg_index - 1 do
        table.insert(history, msgs[i])
    end

    local preset = self:active_preset() or {}

    -- Clone the continued message into the prompt (never mutate the live one)
    -- and apply continue_postfix at the seam so the model resumes cleanly.
    local hist_msg = {}
    for k, v in pairs(msg) do hist_msg[k] = v end
    local postfix = preset.continue_postfix
    if type(postfix) == "string" and postfix ~= ""
        and not tostring(hist_msg.content):match("%s$") then
        hist_msg.content = tostring(hist_msg.content) .. postfix
    end
    table.insert(history, hist_msg)

    local Models = require("kt_models")
    local api_messages = self:_build_api_messages(history)

    local ok_name, user_name = pcall(function() return self:_active_persona_name() end)
    local nudge_tpl = preset.continue_nudge_prompt
    if type(nudge_tpl) ~= "string" or nudge_tpl == "" then
        nudge_tpl = DEFAULT_CONTINUE_NUDGE
    end
    local nudge = Models.expand_macros(nudge_tpl, {
        char = self.state.current_character or "",
        user = (ok_name and user_name) or self.state.current_character or "You",
        model = preset.model_id or "",
        pick_seed = self.state.current_chat_id,
    })
    table.insert(api_messages, { role = "system", content = nudge })

    self:_do_generate(api_messages, { continue_into = msg, msg_index = msg_index,
        auto_continue_n = tonumber(auto_continue_n) or 0 })
end

-- Auto-Continue (ST User Settings): after a reply that stopped on the token
-- limit (finish_reason == "length"), chain a Continue while the message is
-- still shorter than the configured target. Pure decision - returns the opts
-- for the chained generation, or nil when the chain must stop. Callers apply
-- the side effects (toast + schedule).
function App:_auto_continue_decision(target, opts)
    local s = self.state.settings or {}
    if s.auto_continue ~= true then return nil end
    local n = tonumber(opts and opts.auto_continue_n) or 0
    if n >= MAX_AUTO_CONTINUES then return nil end
    -- Only the last assistant message can be Continued (same rule as the
    -- manual Continue action); impersonation never reaches this path.
    local msgs = self.state.messages
    if not target or msgs[#msgs] ~= target or target.role ~= "assistant" then return nil end
    if self.state.is_generating then return nil end
    -- Full-message length: real provider usage when the reply is not a
    -- continuation chunk, otherwise the chars/4 estimate over the merged text.
    local toks
    if not (opts and opts.continue_into) and type(target.completion_tokens) == "number"
        and target.completion_tokens > 0 then
        toks = target.completion_tokens
    else
        toks = math.ceil(#(target.content or "") / 4)
    end
    local target_len = tonumber(s.auto_continue_length) or 0
    -- target 0 = always continue a length-cut reply (no size gate)
    if target_len > 0 and toks >= target_len then return nil end
    local idx
    for i = #msgs, 1, -1 do
        if msgs[i] == target then idx = i break end
    end
    if not idx then return nil end
    return { msg_index = idx, auto_continue_n = n + 1 }
end

-- Apply the Auto-Continue decision: brief toast (so the e-ink user sees why
-- the screen keeps generating) and schedule the chained Continue.
function App:_maybe_auto_continue(target, opts, chat_path)
    local next_opts = self:_auto_continue_decision(target, opts)
    if not next_opts then return false end
    local self_ref = self
    UIManager:show(InfoMessage:new{
        text = _("Auto-continue") .. " (" .. next_opts.auto_continue_n .. "/" .. MAX_AUTO_CONTINUES .. ")",
        timeout = 2,
    })
    UIManager:scheduleIn(0.3, function()
        if self_ref.state.is_generating
            or self_ref.state.current_chat_path ~= (chat_path or self_ref.state.current_chat_path) then
            return
        end
        self_ref:continue_message(next_opts.msg_index, next_opts.auto_continue_n)
    end)
    return true
end

function App:edit_message(msg_index)
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local msg = self.state.messages[msg_index]
    if not msg then return end
    local self_ref = self
    Modals.input(_("Edit message"), msg.content or "", _("Edit the message"), _("Save"), function(text)
        if not text then return end
        text = Util.trim(text)
        if text == "" then return end
        msg.content = text
        if msg.swipes and msg.swipe_id and msg.swipe_id >= 1 and msg.swipe_id <= #msg.swipes then
            msg.swipes[msg.swipe_id] = text
        end
        local path = self_ref.state.current_chat_path
        if path then
            Storage.update_message(path, msg_index, msg)
        end
        self_ref:refresh(true)
    end)
end

-- Edit a user message, drop everything after it, and send it again.
function App:edit_and_resend(msg_index)
    if self.state.is_generating then return end
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local msg = self.state.messages[msg_index]
    if not msg or msg.role ~= "user" then return end
    local self_ref = self
    Modals.input(_("Edit & send"), msg.content or "", _("Edit your message"), _("Send"), function(text)
        if not text then return end
        text = Util.trim(text)
        if text == "" then return end
        msg.content = text

        -- Drop everything after this message
        local msgs = self_ref.state.messages
        for i = #msgs, msg_index + 1, -1 do
            table.remove(msgs)
        end
        local path = self_ref.state.current_chat_path
        if path then
            local chat_data = Storage.load_chat(path)
            if chat_data then
                Storage.save_chat(path, chat_data.header, msgs)
            end
        end

        local Models = require("kt_models")
        local persona_desc = self_ref:_active_persona_description()
        local character = self_ref:_resolve_character_data()
        local api_messages = self_ref:_build_api_messages(msgs)
        self_ref:_do_generate(api_messages)
    end)
end

function App:delete_message(msg_index, from_here)
    if self.state.is_generating then return end
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local msgs = self.state.messages
    local msg = msgs[msg_index]
    if not msg then return end
    local self_ref = self
    local label = from_here and _("Delete this message and all after it?") or _("Delete this message?")
    Modals.confirm(label, _("Delete"), function()
        if from_here then
            for i = #msgs, msg_index, -1 do
                table.remove(msgs)
            end
        else
            table.remove(msgs, msg_index)
        end
        local path = self_ref.state.current_chat_path
        if path then
            local chat_data = Storage.load_chat(path)
            if chat_data then
                Storage.save_chat(path, chat_data.header, msgs)
            end
        end
        self_ref.state.scroll[self_ref:scroll_key()] = 999999
        self_ref:refresh(true)
    end)
end

-- Persist one message back to the chat file (updates its JSONL line).
function App:persist_message(msg_index)
    local path = self.state.current_chat_path
    local msg = self.state.messages[msg_index]
    if path and msg then
        Storage.update_message(path, msg_index, msg)
    end
end

-- Hide a message from the AI context without deleting it (ST /hide).
function App:hide_message(msg_index)
    if self.state.is_generating then return end
    local msg = self.state.messages[msg_index]
    if not msg or msg.hidden then return end
    msg._orig_role = msg.role
    msg.hidden = true
    self:persist_message(msg_index)
    self:refresh(true)
end

function App:unhide_message(msg_index)
    if self.state.is_generating then return end
    local msg = self.state.messages[msg_index]
    if not msg or not msg.hidden then return end
    msg.hidden = nil
    if msg.role == "system" then
        -- Restore the pre-hide role; fall back to user only when the role was
        -- already lost (legacy files).
        msg.role = (msg._orig_role and msg._orig_role ~= "system") and msg._orig_role or "user"
    end
    msg._orig_role = nil
    self:persist_message(msg_index)
    self:refresh(true)
end

-- Narrator / system note: visible in the chat, excluded from the AI context.
function App:add_system_note()
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self
    if not self.state.current_chat_path then return end
    Modals.input(_("System Note"), "", _("Visible in the chat, hidden from the AI"), _("Add"), function(text)
        if text and text ~= "" then
            table.insert(self_ref.state.messages, {
                role = "system", content = text, name = "System", send_date = os.time(),
            })
            local chat_data = Storage.load_chat(self_ref.state.current_chat_path)
            if chat_data then
                Storage.save_chat(self_ref.state.current_chat_path, chat_data.header, self_ref.state.messages)
            end
            self_ref.state.scroll[self_ref:scroll_key()] = 999999
            self_ref:refresh(true)
        end
    end, true)
end

-- Branch: snapshot messages [1..msg_index] into a new chat (ST checkpoint).
function App:branch_from(msg_index)
    if self.state.is_generating then return end
    local _ = require("gettext")
    local path = self.state.current_chat_path
    if not path then return end
    local chat_data = Storage.load_chat(path)
    if not chat_data or not chat_data.header then return end
    local char_name = self.state.current_character or "character"
    local base = (chat_data.header.chat_metadata and chat_data.header.chat_metadata.chat_name) or "Chat"
    local n = 1
    for _, c in ipairs(Storage.list_chats(char_name) or {}) do
        local bn = (c.name or ""):match("Branch #(%d+)$")
        if bn then n = math.max(n, tonumber(bn) + 1) end
    end
    local new_name = base .. " - Branch #" .. n
    local chat_id = "chat_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
    local new_path = Storage.chat_path(char_name, chat_id)
    local header = chat_data.header
    if header.chat_metadata then
        header.chat_metadata.chat_name = new_name
        header.chat_metadata.chat_id = chat_id
    end
    local msgs = {}
    for i = 1, math.min(msg_index, #self.state.messages) do
        table.insert(msgs, self.state.messages[i])
    end
    Storage.save_chat(new_path, header, msgs)
    self:refresh_chats_index()
    UIManager:show(InfoMessage:new{ text = _("Branch created: ") .. new_name, timeout = 3 })
end

-- === Author's Note (chat_metadata note_*, SillyTavern-compatible) ===
function App:set_authors_note_field(key, value)
    local path = self.state.current_chat_path
    if not path then return end
    local chat_data = Storage.load_chat(path)
    if chat_data and chat_data.header and chat_data.header.chat_metadata then
        chat_data.header.chat_metadata[key] = value
        Storage.save_chat(path, chat_data.header, chat_data.messages)
        self:refresh(true)
    end
end

function App:show_authors_note()
    local Sheets = require("ktui/sheets")
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self
    local path = self.state.current_chat_path
    if not path then return end
    local chat_data = Storage.load_chat(path)
    local meta = (chat_data and chat_data.header and chat_data.header.chat_metadata) or {}

    local note = meta.note_prompt
    local depth = tonumber(meta.note_depth) or 4
    local interval = tonumber(meta.note_interval) or 1
    local position = tonumber(meta.note_position) or 1
    local role_num = tonumber(meta.note_role) or 0
    local position_options = {
        { label = _("In-chat @ depth"), value = 1 },
        { label = _("In prompt"), value = 0 },
        { label = _("Before scenario"), value = 2 },
    }
    local position_label = _("In-chat @ depth")
    for _, o in ipairs(position_options) do
        if o.value == position then position_label = o.label end
    end

    Sheets.show(self, {
        title = _("Author's Note"),
        actions = {
            { label = _("Edit Note"), icon = "edit",
                sublabel = note and #note .. " chars" or _("(empty)"),
                on_tap = function()
                    Modals.input(_("Author's Note"), note or "", _("Injected into the AI context"), _("Save"), function(text)
                        self_ref:set_authors_note_field("note_prompt", (text and text ~= "") and text or nil)
                    end, true)
                end },
            { label = _("Depth"), icon = "sliders", sublabel = tostring(depth), on_tap = function()
                local actions = {}
                for d = 0, 8 do
                    table.insert(actions, { label = tostring(d), checked = depth == d,
                        on_tap = function() self_ref:set_authors_note_field("note_depth", d) end })
                end
                Sheets.show(self_ref, { title = _("Insert at depth"), actions = actions })
            end },
            { label = _("Interval"), icon = "refresh", sublabel = tostring(interval), on_tap = function()
                local actions = {}
                for d = 1, 10 do
                    table.insert(actions, { label = tostring(d), checked = interval == d,
                        on_tap = function() self_ref:set_authors_note_field("note_interval", d) end })
                end
                Sheets.show(self_ref, { title = _("Every N user messages"), actions = actions })
            end },
            { label = _("Position"), icon = "list", sublabel = position_label, on_tap = function()
                local actions = {}
                for _, o in ipairs(position_options) do
                    table.insert(actions, { label = o.label, checked = position == o.value,
                        on_tap = function() self_ref:set_authors_note_field("note_position", o.value) end })
                end
                Sheets.show(self_ref, { title = _("Note position"), actions = actions })
            end },
            { label = _("Role"), icon = "user", sublabel = role_num == 1 and "user" or (role_num == 2 and "assistant" or "system"), on_tap = function()
                local actions = {
                    { label = "system", checked = role_num == 0, on_tap = function() self_ref:set_authors_note_field("note_role", 0) end },
                    { label = "user", checked = role_num == 1, on_tap = function() self_ref:set_authors_note_field("note_role", 1) end },
                    { label = "assistant", checked = role_num == 2, on_tap = function() self_ref:set_authors_note_field("note_role", 2) end },
                }
                Sheets.show(self_ref, { title = _("Note role"), actions = actions })
            end },
            { label = _("Clear Note"), icon = "trash", danger = true, on_tap = function()
                self_ref:set_authors_note_field("note_prompt", nil)
            end },
        },
    })
end

-- Message actions triggered by tapping a message bubble
function App:show_message_actions(msg_index)
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local msg = self.state.messages[msg_index]
    if not msg then return end
    local is_last = (msg_index == #self.state.messages)

    local actions = {}

    -- Swipe navigation (assistant messages with alternatives)
    if msg.role == "assistant" and msg.swipes and #msg.swipes > 1 then
        table.insert(actions, {
            label = _("Previous swipe") .. " (" .. tostring(msg.swipe_id) .. "/" .. tostring(#msg.swipes) .. ")",
            icon = "chev-left",
            on_tap = function() self:cycle_swipe(msg_index, -1) end,
        })
        table.insert(actions, {
            label = _("Next swipe") .. " (" .. tostring(msg.swipe_id) .. "/" .. tostring(#msg.swipes) .. ")",
            icon = "chev-right",
            on_tap = function() self:cycle_swipe(msg_index, 1) end,
        })
    end

    if msg.role == "assistant" and is_last then
        table.insert(actions, {
            label = _("Regenerate"), icon = "refresh", on_tap = function()
                self:regenerate_last()
            end,
        })
        table.insert(actions, {
            label = _("New swipe"), icon = "random", on_tap = function()
                self:regenerate_last()
            end,
        })
        table.insert(actions, {
            label = _("Continue"), icon = "forward", on_tap = function()
                self:continue_message(msg_index)
            end,
        })
    end

    table.insert(actions, {
        label = _("View Full"), icon = "eye", on_tap = function()
            UIManager:show(InfoMessage:new{
                text = msg.content or "",
            })
        end,
    })
    table.insert(actions, {
        label = _("Message info"), icon = "info-circle", on_tap = function()
            local chars = #(msg.content or "")
            local info = string.format("%s · %s\n%d chars · ~%d tokens",
                msg.name or (msg.role == "user" and "You" or "assistant"),
                msg.role or "?", chars, math.ceil(chars / 4))
            UIManager:show(InfoMessage:new{ text = info, timeout = 6 })
        end,
    })
    -- Move up/down (skip while streaming)
    if msg_index > 1 and not self.state.is_generating then
        table.insert(actions, {
            label = _("Move Up"), icon = "chev-up", on_tap = function()
                self:move_message(msg_index, -1)
            end,
        })
    end
    if msg_index < #self.state.messages and not self.state.is_generating then
        table.insert(actions, {
            label = _("Move Down"), icon = "chev-down", on_tap = function()
                self:move_message(msg_index, 1)
            end,
        })
    end
    table.insert(actions, {
        label = _("Copy"), icon = "copy", on_tap = function()
            local Device = require("device")
            if Device.input and Device.input.setClipboardText then
                Device.input.setClipboardText(msg.content or "")
                UIManager:show(InfoMessage:new{ text = _("Copied!"), timeout = 2 })
            end
        end,
    })
    table.insert(actions, {
        label = _("Edit"), icon = "edit", on_tap = function()
            self:edit_message(msg_index)
        end,
    })
    -- Hide / Unhide (ST /hide: out of the AI context, still visible)
    if msg.role == "system" or msg.hidden == true then
        table.insert(actions, {
            label = _("Unhide"), icon = "eye", on_tap = function()
                self:unhide_message(msg_index)
            end,
        })
    else
        table.insert(actions, {
            label = _("Hide"), icon = "ban", on_tap = function()
                self:hide_message(msg_index)
            end,
        })
    end
    -- Branch: snapshot up to this message into a new chat (ST checkpoint)
    table.insert(actions, {
        label = _("Branch from here"), icon = "random", on_tap = function()
            self:branch_from(msg_index)
        end,
    })
    if msg.role == "user" and is_last then
        table.insert(actions, {
            label = _("Edit & send"), icon = "forward", on_tap = function()
                self:edit_and_resend(msg_index)
            end,
        })
    end
    table.insert(actions, {
        label = _("Delete"), icon = "trash", danger = true, on_tap = function()
            self:delete_message(msg_index, false)
        end,
    })
    table.insert(actions, {
        label = _("Delete from here"), icon = "trash", danger = true, on_tap = function()
            self:delete_message(msg_index, true)
        end,
    })

    Sheets.show(self, { title = _("Message Actions"), actions = actions })
end

function App:move_message(msg_index, dir)
    if self.state.is_generating then return end
    local msgs = self.state.messages
    local j = msg_index + dir
    if j < 1 or j > #msgs then return end
    msgs[msg_index], msgs[j] = msgs[j], msgs[msg_index]
    local path = self.state.current_chat_path
    if path then
        local chat_data = Storage.load_chat(path)
        if chat_data then
            Storage.save_chat(path, chat_data.header, msgs)
        end
    end
    self:refresh(true)
end

-- Plain-text export (ST format: "name: mes\n\n", hidden/system skipped)
function App:export_chat_txt(path)
    local _ = require("gettext")
    path = path or self.state.current_chat_path
    if not path then return end
    local chat_data = Storage.load_chat(path)
    if not chat_data then return end
    local chat_name = (chat_data.header.chat_metadata and chat_data.header.chat_metadata.chat_name) or "chat"
    local parts = {}
    for _, msg in ipairs(chat_data.messages) do
        if msg.role ~= "system" and msg.hidden ~= true then
            local name = msg.name or (msg.role == "user" and "You" or (msg.role == "assistant" and (self.state.current_character or "Assistant") or msg.role))
            table.insert(parts, name .. ": " .. (msg.content or ""))
        end
    end
    local body = table.concat(parts, "\n\n") .. "\n"
    self:choose_export_dir(function(dir)
        local out_path = dir .. "/" .. Util.safe_filename(chat_name) .. ".txt"
        local out = io.open(out_path, "w")
        if not out then
            UIManager:show(InfoMessage:new{ text = _("Export failed: could not write file") })
            return
        end
        out:write(body)
        out:close()
        UIManager:show(InfoMessage:new{ text = _("Chat exported to ") .. out_path, timeout = 3 })
    end)
end

-- === Chat list actions (used by the Chats page and chat options) ===
function App:rename_chat(path, on_done)
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self
    Modals.input(_("New name"), "", _("Enter chat name"), _("Save"), function(name)
        if name and name ~= "" then
            local chat_data = Storage.load_chat(path)
            if chat_data and chat_data.header and chat_data.header.chat_metadata then
                chat_data.header.chat_metadata.chat_name = name
                Storage.save_chat(path, chat_data.header, chat_data.messages)
                self_ref:refresh_chats_index()
                self_ref:refresh(true)
                if on_done then on_done() end
            end
        end
    end)
end

function App:delete_chat(path, on_done)
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local self_ref = self
    Sheets.confirm(self_ref, {
        title = _("Delete chat"),
        text = _("Delete this chat permanently?"),
        ok_label = _("Delete"), danger = true,
        on_ok = function()
            -- Invalidate in-flight generation first: a pending callback with
            -- the captured path would resurrect the deleted file via
            -- append_message's fallback header.
            if path and self_ref.state.current_chat_path == path then
                self_ref:_cancel_generation()
            end
            os.remove(path or "")
            self_ref:refresh_chats_index()
            self_ref:refresh(true)
            if on_done then on_done() end
        end,
    })
end

function App:show_chat_list_actions(chat)
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local self_ref = self
    Sheets.show(self_ref, {
        title = chat.name or "Chat",
        actions = {
            { label = _("Rename Chat"), icon = "edit", on_tap = function()
                    self_ref:rename_chat(chat.path)
                end,
            },
            { label = _("Export Chat"), icon = "upload", on_tap = function()
                    self_ref:export_chat(chat.path)
                end,
            },
            { label = _("Export TXT"), icon = "file", on_tap = function()
                    self_ref:export_chat_txt(chat.path)
                end,
            },
            { label = _("Delete Chat"), icon = "trash", danger = true, on_tap = function()
                    self_ref:delete_chat(chat.path)
                end,
            },
        },
    })
end

-- === Past Chats (ST "Manage chat files") ================================
-- Per-character chat list: open/rename/delete/export. Lives on its own page
-- (state.past_chats) so the header back button returns to the chat.
function App:show_past_chats()
    local char_name = self.state.current_character
    if not char_name then return end
    self:refresh_chats_index()
    local chats = {}
    local current_path = self.state.current_chat_path
    for _, chat in ipairs(Storage.list_chats(char_name) or {}) do
        if chat.path ~= current_path then
            chat.preview = Storage.chat_preview(chat.path)
            table.insert(chats, chat)
        end
    end
    self:navigate("chat_history", { past_chats = chats })
end

function App:open_past_chat(chat)
    if not chat or not chat.path then return end
    -- Same character: swap in place (keeps the connection/persona context).
    self:_cancel_generation()
    local chat_data = Storage.load_chat(chat.path)
    if not chat_data then
        UIManager:show(InfoMessage:new{ text = _("Could not load this chat."), timeout = 3 })
        return
    end
    local persona_id = chat_data.chat_metadata and chat_data.chat_metadata.persona_id
    local preset_id = chat_data.chat_metadata and chat_data.chat_metadata.preset_id
    local connection_id = chat_data.chat_metadata and chat_data.chat_metadata.connection_id
    self.state.current_chat_id = chat_data.chat_metadata and chat_data.chat_metadata.chat_id or chat.id
    self.state.current_chat_path = chat.path
    self.state.current_character = chat.character_name or self.state.current_character
    self.state.current_character_file = (chat_data.chat_metadata and chat_data.chat_metadata.character_path)
        or self.state.current_character_file
    self.state.current_chat_persona_id = persona_id or self.state.current_chat_persona_id
    self.state.current_chat_preset_id = preset_id or self.state.current_chat_preset_id
    if connection_id then
        for _, c in ipairs(Storage.list_connections()) do
            if c.id == connection_id then self.state.current_connection = c break end
        end
    end
    self.state.messages = chat_data.messages or {}
    self.state.user_scrolled_up = nil
    self.state.reasoning_open = {}
    self.state.reasoning_full = {}
    -- Start at the last message (first paint clamps to max_scroll), same as
    -- open_chat/_start_new_chat.
    self.state.scroll["chat_" .. tostring(self.state.current_chat_id)] = 999999
    self:refresh_chats_index()
    self:navigate("chat")
end

function App:delete_past_chat(chat)
    if not chat or not chat.path then return end
    local Sheets = require("ktui/sheets")
    Sheets.confirm(self, {
        title = _("Delete chat"),
        text = _("Delete ") .. (chat.name or _("this chat")) .. "?",
        ok_label = _("Delete"), danger = true,
        on_ok = function()
            os.remove(chat.path)
            self:show_past_chats() -- re-list
        end,
    })
end

function App:show_chat_options()
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")

    local actions = {
        { label = _("Start new chat"), icon = "plus", on_tap = function()
                self:start_new_chat(self.state.current_character_file, self.state.current_character)
            end,
        },
        { label = _("Past Chats"), icon = "clock", on_tap = function()
                self:show_past_chats()
            end,
        },
        { label = _("Rename Chat"), icon = "edit", on_tap = function()
                self:rename_chat(self.state.current_chat_path)
            end,
        },
        { label = _("Change API Connection"), icon = "plug", on_tap = function()
                local connections = Storage.list_connections()
                if #connections == 0 then
                    UIManager:show(InfoMessage:new{
                        text = _("No API connections available."),
                        timeout = 2,
                    })
                    return
                end
                local items = {}
                for _, c in ipairs(connections) do
                    table.insert(items, {
                        label = c.name .. " (" .. (c.model_id or "?") .. ")",
                        checked = self.state.current_connection and self.state.current_connection.id == c.id,
                        on_tap = function()
                            self.state.current_connection = c
                            local path = self.state.current_chat_path
                            if path then
                                local chat_data = Storage.load_chat(path)
                                if chat_data and chat_data.header and chat_data.header.chat_metadata then
                                    chat_data.header.chat_metadata.connection_id = c.id
                                    Storage.save_chat(path, chat_data.header, chat_data.messages)
                                end
                            end
                        end,
                    })
                end
                Sheets.show(self, { title = _("Select API"), actions = items })
            end,
        },
        { label = _("Persona"), icon = "user", on_tap = function()
                self:choose_chat_persona()
            end,
        },
        { label = _("Preset"), icon = "sliders", on_tap = function()
                self:choose_chat_preset()
            end,
        },
        { label = _("Author's Note"), icon = "edit", on_tap = function()
                self:show_authors_note()
            end,
        },
        { label = _("Lorebooks"), icon = "book", on_tap = function()
                self:show_lorebooks()
            end,
        },
        { label = _("Add System Note"), icon = "info-circle", on_tap = function()
                self:add_system_note()
            end,
        },
        { label = _("Impersonate"), icon = "user", on_tap = function()
                self:impersonate()
            end,
        },
        { label = _("Quick Reply"), icon = "bolt", on_tap = function()
                self:show_quick_replies()
            end,
        },
        { label = _("Save as Profile"), icon = "bookmark", on_tap = function()
                self:save_profile_from_current()
            end,
        },
        { label = _("Switch Profile"), icon = "swap", on_tap = function()
                self:switch_profile()
            end,
        },
        { label = _("Delete Profile"), icon = "trash", on_tap = function()
                self:delete_profile()
            end,
        },
        { label = _("Export Chat"), icon = "upload", on_tap = function()
                self:export_chat()
            end,
        },
        { label = _("Export TXT"), icon = "file", on_tap = function()
                self:export_chat_txt()
            end,
        },
        { label = _("Delete Chat"), icon = "trash", danger = true, on_tap = function()
                self:delete_chat(self.state.current_chat_path, function()
                    self:go_back()
                end)
            end,
        },
    }
    Sheets.show(self, { title = _("Chat Options"), actions = actions })
end

-- Impersonation (ST): generate one reply as the user, then open it in the
-- input dialog so they can edit before actually sending.
local DEFAULT_IMPERSONATION_PROMPT = "[Write your next reply from the point of view of {{user}}, using the chat history so far as a guideline for the writing style of {{user}}. Write 1 reply only in internet RP style. Don't write as {{char}} or system.]"

function App:impersonate()
    if self.state.is_generating then return end
    local _ = require("gettext")
    local Modals = require("ktui/modals")
    if not self.state.current_connection then
        UIManager:show(InfoMessage:new{
            text = _("No API connection configured."),
            timeout = 3,
        })
        return
    end

    local preset = self:active_preset() or {}
    local tpl = preset.impersonation_prompt
    if type(tpl) ~= "string" or tpl == "" then
        tpl = DEFAULT_IMPERSONATION_PROMPT
    end

    local ok_name, user_name = pcall(function() return self:_active_persona_name() end)
    user_name = (ok_name and user_name) or self.state.current_character or "You"
    local Models = require("kt_models")
    local prompt = Models.expand_macros(tpl, {
        char = self.state.current_character or "",
        user = user_name,
        model = preset.model_id or "",
        pick_seed = self.state.current_chat_id,
    })

    -- History WITHOUT the impersonation instruction (it goes last, as system)
    local api_messages = self:_build_api_messages(self.state.messages)
    table.insert(api_messages, { role = "system", content = prompt })

    self.state.is_generating = true
    self.state.thinking = true
    self.state.thinking_frame = 0
    self._stream_partial_count = 0
    self._last_stream_paint = nil
    self:_start_thinking_pulse()
    self:refresh(true)

    local Client = require("kt_client")
    local client = Client:new()
    local conn = self.state.current_connection
    local self_ref = self
    local token = (self._gen_token or 0) + 1
    self._gen_token = token

    UIManager:scheduleIn(0.1, function()
        if self_ref._gen_token ~= token then return end
        local backend = (self_ref.state.settings and self_ref.state.settings.api_backend) or "curl_bg"
        client:chat_completion(api_messages, conn, preset, function(content, err)
            if self_ref._gen_token ~= token then return end
            self_ref:_stop_thinking_pulse()
            self_ref.state.is_generating = false
            if content then
                content = self_ref:_postprocess_ai(content)
                Modals.input(_("Write as ") .. user_name, content,
                    _("Edit your message, then Send"), _("Send"), function(text)
                    text = Util.trim(tostring(text or ""))
                    if text ~= "" then
                        self_ref:_do_send_message(text)
                    end
                end, true)
            else
                UIManager:show(InfoMessage:new{
                    text = _("API Error: ") .. (err or _("Unknown error")),
                    timeout = 5,
                })
            end
            self_ref:refresh(true)
        end, backend)
    end)
end

-- === Prompt Manager (preset prompts/prompt_order) ===
-- Items of the active order list (character_id 100001, fallback 100000),
-- wrapped with their index and prompt object for the UI.
function App:prompt_order_items()
    local preset = self.state.editing_preset
    if type(preset) ~= "table" or type(preset.prompts) ~= "table" then return nil end
    local order_list
    if type(preset.prompt_order) == "table" then
        for _, po in ipairs(preset.prompt_order) do
            if tonumber(po.character_id) == 100001 and type(po.order) == "table" then
                order_list = po.order
                break
            end
        end
        if not order_list then
            for _, po in ipairs(preset.prompt_order) do
                if tonumber(po.character_id) == 100000 and type(po.order) == "table" then
                    order_list = po.order
                    break
                end
            end
        end
    end
    if not order_list then return nil end

    local by_id = {}
    for _, p in ipairs(preset.prompts) do
        if type(p.identifier) == "string" then by_id[p.identifier] = p end
    end
    local items = {}
    for i, item in ipairs(order_list) do
        table.insert(items, {
            index = i,
            identifier = item.identifier,
            enabled = item.enabled ~= false,
            name = (by_id[item.identifier] and by_id[item.identifier].name) or item.identifier,
            prompt = by_id[item.identifier],
        })
    end
    return items
end

function App:toggle_prompt_item(index)
    local preset = self.state.editing_preset
    if not preset then return end
    local order_list = self:_prompt_order_list()
    if order_list and order_list[index] then
        order_list[index].enabled = not (order_list[index].enabled ~= false)
        self:refresh(true)
    end
end

function App:_prompt_order_list()
    local preset = self.state.editing_preset
    if type(preset) ~= "table" or type(preset.prompt_order) ~= "table" then return nil end
    for _, po in ipairs(preset.prompt_order) do
        if tonumber(po.character_id) == 100001 and type(po.order) == "table" then
            return po.order
        end
    end
    for _, po in ipairs(preset.prompt_order) do
        if tonumber(po.character_id) == 100000 and type(po.order) == "table" then
            return po.order
        end
    end
    return nil
end

function App:move_prompt_item(index, dir)
    local list = self:_prompt_order_list()
    if not list then return end
    local j = index + dir
    if j < 1 or j > #list then return end
    list[index], list[j] = list[j], list[index]
    self:refresh(true)
end

function App:edit_prompt_item(index)
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self
    local preset = self.state.editing_preset
    if not preset then return end
    local list = self:_prompt_order_list()
    local item = list and list[index]
    local prompt = item and self:_find_prompt(item.identifier)
    if not prompt or prompt.marker then return end
    Modals.multi_input(_("Edit Prompt"), {
        { text = prompt.content or "", hint = _("Content"), multiline = true },
        { text = prompt.role or "system", hint = _("Role (system/user/assistant)") },
    }, _("Save"), function(fields)
        if fields then
            prompt.content = fields[1] or ""
            local role = fields[2] and fields[2]:match("^%s*(.-)%s*$")
            if role == "user" or role == "assistant" or role == "system" then
                prompt.role = role
            end
            self_ref:refresh(true)
        end
    end)
end

function App:_find_prompt(identifier)
    local preset = self.state.editing_preset
    if not preset or type(preset.prompts) ~= "table" then return nil end
    for _, p in ipairs(preset.prompts) do
        if p.identifier == identifier then return p end
    end
    return nil
end

function App:open_prompt_manager()
    self:navigate("prompt_manager")
end

-- Add a utility prompt (ST Prompt Manager "+"): name it, then it lands
-- (disabled) at the top of the saved order. Markers/chatHistory never come
-- through here - those are structural ST entries, not user prompts.
function App:add_prompt_item()
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self
    local preset = self.state.editing_preset
    if not preset then return end
    self:ensure_preset_prompts(preset)
    Modals.input(_("New Prompt"), "", _("Prompt name"), _("Save"), function(text)
        text = Util.trim(tostring(text or ""))
        if text == "" then return end
        local list = self_ref:_prompt_order_list()
        if not list then return end
        local identifier = Util.uuid()
        table.insert(preset.prompts, {
            identifier = identifier,
            name = text,
            role = "system",
            content = "",
            injection_position = 0,
            injection_depth = 4,
            marker = false,
        })
        table.insert(list, 1, { identifier = identifier, enabled = false })
        self_ref:refresh(true)
    end)
end

-- Remove a utility prompt from the preset: drops its prompts entry and every
-- order reference, so it cannot resurface in the next build. Markers and the
-- chatHistory marker are refused (they are the layout skeleton).
function App:remove_prompt_item(index)
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local self_ref = self
    local preset = self.state.editing_preset
    if not preset then return end
    local list = self:_prompt_order_list()
    local item = list and list[index]
    local prompt = item and self:_find_prompt(item.identifier)
    if not prompt or prompt.marker or item.identifier == "chatHistory" then return end
    Sheets.confirm(self_ref, {
        title = _("Remove prompt"),
        text = _("Remove this prompt from the preset?") .. " (" .. tostring(prompt.name or item.identifier) .. ")",
        ok_label = _("Remove"), danger = true,
        on_ok = function()
            local prompts = preset.prompts or {}
            for i = #prompts, 1, -1 do
                if prompts[i] == prompt then table.remove(prompts, i) end
            end
            for _j, po in ipairs(preset.prompt_order or {}) do
                if type(po.order) == "table" then
                    for i = #po.order, 1, -1 do
                        if po.order[i].identifier == item.identifier then
                            table.remove(po.order, i)
                        end
                    end
                end
            end
            self_ref:refresh(true)
        end,
    })
end

-- Rename a utility prompt (markers and the chatHistory marker are refused -
-- their display names are ST structural identifiers).
function App:rename_prompt_item(index)
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self
    local preset = self.state.editing_preset
    if not preset then return end
    local list = self:_prompt_order_list()
    local item = list and list[index]
    local prompt = item and self:_find_prompt(item.identifier)
    if not prompt or prompt.marker or item.identifier == "chatHistory" then return end
    Modals.input(_("Rename Prompt"), tostring(prompt.name or ""), _("Prompt name"), _("Save"), function(text)
        text = Util.trim(tostring(text or ""))
        if text == "" then return end
        prompt.name = text
        self_ref:refresh(true)
    end)
end

-- === Quick Replies (global set) ===
function App:show_quick_replies()
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local self_ref = self
    local qrs = self.state.settings.quick_replies or {}
    if #qrs == 0 then
        UIManager:show(InfoMessage:new{ text = _("No quick replies. Manage them in Settings → Data."), timeout = 3 })
        return
    end
    local Widgets = require("ktui/widgets")
    local actions = {}
    for i, qr in ipairs(qrs) do
        table.insert(actions, {
            label = qr.label or "?",
            sublabel = type(qr.text) == "string"
                and Widgets.truncate(qr.text:gsub("[\r\n]+", " "), 48) or nil,
            icon = "bolt",
            on_tap = function()
                if self_ref.state.current_chat_path and not self_ref.state.is_generating then
                    self_ref:_do_send_message(qr.text or "")
                end
            end,
        })
    end
    Sheets.show(self, { title = _("Quick Reply"), actions = actions })
end

function App:manage_quick_replies()
    local Sheets = require("ktui/sheets")
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self

    local function save(qrs)
        self_ref.state.settings.quick_replies = qrs
        Storage.save_settings(self_ref.state.settings)
    end

    local function add_or_edit(qr)
        Modals.multi_input(qr and _("Edit Quick Reply") or _("New Quick Reply"), {
            { text = qr and qr.label or "", hint = _("Label") },
            { text = qr and qr.text or "", hint = _("Message"), multiline = true },
        }, _("Save"), function(fields)
            if fields and fields[1] and fields[1] ~= "" then
                local qrs = self_ref.state.settings.quick_replies or {}
                if qr then
                    qr.label = fields[1]
                    qr.text = fields[2] or ""
                else
                    table.insert(qrs, { label = fields[1], text = fields[2] or "" })
                end
                save(qrs)
                self_ref:refresh(true)
            end
        end)
    end

    local qrs = self.state.settings.quick_replies or {}
    local actions = {
        { label = _("New Quick Reply"), icon = "plus", on_tap = function() add_or_edit(nil) end },
    }
    for _, qr in ipairs(qrs) do
        table.insert(actions, {
            label = qr.label or "?",
            icon = "bolt",
            on_tap = function()
                Sheets.show(self_ref, { title = qr.label, actions = {
                    { label = _("Edit"), icon = "edit", on_tap = function() add_or_edit(qr) end },
                    { label = _("Delete"), icon = "trash", danger = true, on_tap = function()
                        local list = {}
                        for _, q in ipairs(self_ref.state.settings.quick_replies or {}) do
                            if q ~= qr then table.insert(list, q) end
                        end
                        save(list)
                        self_ref:refresh(true)
                    end },
                } })
            end,
        })
    end
    Sheets.show(self, { title = _("Quick Replies"), actions = actions })
end

-- === Regex scripts ===
function App:new_regex_script()
    local Util = require("kotaven_util")
    local script = {
        id = Util.uuid(),
        scriptName = _("New script"),
        find = "",
        replace = "",
        placement = "display",
        disabled = false,
    }
    table.insert(self.state.settings.regex_scripts, script)
    Storage.save_settings(self.state.settings)
    self:edit_regex_script(script)
end

function App:edit_regex_script(script)
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self
    Modals.multi_input(_("Edit Script"), {
        { text = script.scriptName or "", hint = _("Name") },
        { text = script.find or "", hint = _("Find (Lua pattern)"), multiline = true },
        { text = script.replace or "", hint = _("Replace ($1..$9)") , multiline = true },
    }, _("Save"), function(fields)
        if fields then
            script.scriptName = fields[1] ~= "" and fields[1] or script.scriptName
            script.find = fields[2] or ""
            script.replace = fields[3] or ""
            Storage.save_settings(self_ref.state.settings)
            self_ref:refresh(true)
        end
    end)
end

function App:toggle_regex_script(script)
    script.disabled = not script.disabled
    Storage.save_settings(self.state.settings)
    self:refresh(true)
end

function App:show_regex_script_actions(script)
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local self_ref = self
    Sheets.show(self, {
        title = script.scriptName or _("Script"),
        actions = {
            { label = _("Edit"), icon = "edit", on_tap = function()
                self_ref:edit_regex_script(script)
            end },
            { label = _("Placement"), icon = "sliders",
                sublabel = script.placement == "prompt" and _("prompt") or (script.placement == "both" and _("both") or _("display")),
                on_tap = function()
                    Sheets.show(self_ref, { title = _("Apply to"), actions = {
                        { label = _("Display only"), checked = script.placement == "display", on_tap = function()
                            script.placement = "display"
                            Storage.save_settings(self_ref.state.settings)
                            self_ref:refresh(true)
                        end },
                        { label = _("Prompt only"), checked = script.placement == "prompt", on_tap = function()
                            script.placement = "prompt"
                            Storage.save_settings(self_ref.state.settings)
                            self_ref:refresh(true)
                        end },
                        { label = _("Both"), checked = script.placement == "both", on_tap = function()
                            script.placement = "both"
                            Storage.save_settings(self_ref.state.settings)
                            self_ref:refresh(true)
                        end },
                    } })
                end },
            { label = _("Delete"), icon = "trash", danger = true, on_tap = function()
                Sheets.confirm(self_ref, {
                    title = _("Delete script"),
                    text = _("Delete this regex script?"),
                    ok_label = _("Delete"), danger = true,
                    on_ok = function()
                        local list = {}
                        for _, s in ipairs(self_ref.state.settings.regex_scripts or {}) do
                            if s.id ~= script.id then table.insert(list, s) end
                        end
                        self_ref.state.settings.regex_scripts = list
                        Storage.save_settings(self_ref.state.settings)
                        self_ref:refresh(true)
                    end,
                })
            end },
        },
    })
end

-- === Lorebooks (World Info) ===
function App:show_lorebooks()
    self:navigate("lorebooks")
end

function App:show_lorebook_actions(item)
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local self_ref = self
    local path = self.state.current_chat_path

    local actions = {}
    if item.kind == "card" then
        -- Card-embedded book: import as a world, then activate
        table.insert(actions, { label = _("Import & Activate"), icon = "download", on_tap = function()
            local WI = require("kt_world_info")
            local character = self_ref:_resolve_character_data()
            local entries = WI.from_character_book(character.character_book)
            if #entries == 0 then
                UIManager:show(InfoMessage:new{ text = _("No entries in this card's lorebook."), timeout = 3 })
                return
            end
            local name = character.name or "card"
            Storage.save_world(name, WI.to_world_file(entries))
            self_ref:activate_lorebook(name)
        end })
    else
        if path then
            local active = self:_active_lorebook_name()
            if active == item.name then
                table.insert(actions, { label = _("Deactivate (this chat)"), icon = "ban", on_tap = function()
                    self_ref:activate_lorebook(nil)
                end })
            else
                table.insert(actions, { label = _("Activate (this chat)"), icon = "check", on_tap = function()
                    self_ref:activate_lorebook(item.name)
                end })
            end
        end
        table.insert(actions, { label = _("Edit"), icon = "edit", on_tap = function()
            self_ref:edit_lorebook(item.name)
        end })
        table.insert(actions, { label = _("Export JSON"), icon = "upload", on_tap = function()
            self_ref:export_lorebook(item.name)
        end })
        table.insert(actions, { label = _("Delete"), icon = "trash", danger = true, on_tap = function()
            Sheets.confirm(self_ref, {
                title = _("Delete lorebook"),
                text = _("Delete ") .. item.name .. "?",
                ok_label = _("Delete"), danger = true,
                on_ok = function()
                    Storage.delete_world(item.name)
                    self_ref:refresh(true)
                end,
            })
        end })
    end
    Sheets.show(self, { title = item.name, actions = actions })
end

function App:_active_lorebook_name()
    local path = self.state.current_chat_path
    if not path then return nil end
    local chat_data = Storage.load_chat(path)
    local cfg = chat_data and chat_data.header and chat_data.header.chat_metadata
        and chat_data.header.chat_metadata.world_info
    return type(cfg) == "table" and cfg.selected or nil
end

function App:activate_lorebook(name)
    local path = self.state.current_chat_path
    if not path then
        UIManager:show(InfoMessage:new{ text = _("Open a chat first to activate a lorebook."), timeout = 3 })
        return
    end
    local chat_data = Storage.load_chat(path)
    if chat_data and chat_data.header and chat_data.header.chat_metadata then
        chat_data.header.chat_metadata.world_info = { selected = name, depth = 2 }
        Storage.save_chat(path, chat_data.header, chat_data.messages)
    end
    if name then
        UIManager:show(InfoMessage:new{ text = _("Lorebook active: ") .. name, timeout = 2 })
    end
    self:refresh(true)
end

function App:new_lorebook()
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self
    Modals.input(_("New Lorebook"), "", _("Lorebook name"), _("Create"), function(name)
        if name and name ~= "" then
            self_ref.state.editing_world = { name = name, entries = {} }
            self_ref:navigate("lorebook_editor")
        end
    end)
end

function App:rename_lorebook()
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self
    local editing = self.state.editing_world
    if not editing then return end
    Modals.input(_("Rename lorebook"), editing.name or "", _("Name"), _("Save"), function(name)
        if name and name ~= "" then
            if editing.old_name and editing.old_name ~= name then
                Storage.delete_world(editing.old_name)
            end
            editing.name = name
            self_ref:refresh(true)
        end
    end)
end

function App:edit_lorebook(name)
    local WI = require("kt_world_info")
    local world = Storage.load_world(name)
    local entries = WI.parse_world(world)
    self.state.editing_world = { name = name, old_name = name, entries = entries }
    self:navigate("lorebook_editor")
end

function App:save_lorebook()
    local WI = require("kt_world_info")
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    local editing = self.state.editing_world
    if not editing or not editing.name or editing.name == "" then
        UIManager:show(InfoMessage:new{ text = _("Give the lorebook a name first."), timeout = 3 })
        return
    end
    Storage.save_world(editing.name, WI.to_world_file(editing.entries))
    if editing.old_name and editing.old_name ~= editing.name then
        Storage.delete_world(editing.old_name)
    end
    self.state.editing_world = nil
    self:go_back()
    UIManager:show(InfoMessage:new{ text = _("Lorebook saved!"), timeout = 2 })
end

function App:export_lorebook(name)
    local _ = require("gettext")
    local world = Storage.load_world(name)
    if not world then return end
    self:choose_export_dir(function(dir)
        local json = require("json")
        local ok_enc, encoded = pcall(json.encode, world)
        if not ok_enc then
            UIManager:show(InfoMessage:new{ text = _("Export failed: encode error") })
            return
        end
        local out = io.open(dir .. "/" .. Util.safe_filename(name) .. ".json", "w")
        if not out then
            UIManager:show(InfoMessage:new{ text = _("Export failed: could not write file") })
            return
        end
        out:write(encoded)
        out:close()
        UIManager:show(InfoMessage:new{ text = _("Lorebook exported"), timeout = 2 })
    end)
end

function App:import_lorebook()
    local _ = require("gettext")
    local self_ref = self
    self:choose_file_path(function(file_path)
        if not file_path or not file_path:match("%.json$") then
            UIManager:show(InfoMessage:new{ text = _("Select a lorebook .json file."), timeout = 3 })
            return
        end
        local f = io.open(file_path, "r")
        if not f then return end
        local content = f:read("*a")
        f:close()
        local ok, data = pcall(function() return require("json").decode(content) end)
        if not ok or type(data) ~= "table" then
            UIManager:show(InfoMessage:new{ text = _("Could not parse the lorebook file."), timeout = 3 })
            return
        end
        data = Util.clean_json(data)
        local name = file_path:match("([^/\\]+)%.json$") or _("Lorebook")
        local saved = Storage.save_world(name, data)
        if not saved then
            UIManager:show(InfoMessage:new{ text = _("Could not save the lorebook."), timeout = 3 })
            return
        end
        self_ref:refresh(true)
        UIManager:show(InfoMessage:new{ text = _("Lorebook imported: ") .. name, timeout = 2 })
    end)
end

function App:new_world_entry()
    local WI = require("kt_world_info")
    self.state.editing_entry = WI.parse_entry({})
    self.state.editing_entry_is_new = true
    self:navigate("lorebook_entry")
end

function App:edit_world_entry(entry)
    self.state.editing_entry = entry
    self.state.editing_entry_is_new = false
    self:navigate("lorebook_entry")
end

function App:save_world_entry()
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    local editing = self.state.editing_world
    local entry = self.state.editing_entry
    if not editing or not entry then return end
    if not entry.key or #entry.key == 0 then
        if not entry.constant then
            UIManager:show(InfoMessage:new{ text = _("Add at least one key (or mark as constant)."), timeout = 3 })
            return
        end
    end
    if self.state.editing_entry_is_new then
        table.insert(editing.entries, entry)
        self.state.editing_entry_is_new = false
    end
    self.state.editing_entry = nil
    self:go_back()
end

function App:edit_world_entry_field(key, numeric)
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self
    local entry = self.state.editing_entry
    if not entry then return end

    -- Key lists are edited as comma-separated text
    if key == "key" or key == "keysecondary" then
        local current = type(entry[key]) == "table" and table.concat(entry[key], ", ") or ""
        Modals.input(_(key == "key" and "Keys" or "Secondary keys"), current, _("Comma separated"), _("Save"), function(text)
            local list = {}
            for part in tostring(text or ""):gmatch("[^,]+") do
                local k = part:match("^%s*(.-)%s*$")
                if k ~= "" then table.insert(list, k) end
            end
            entry[key] = list
            self_ref:refresh(true)
        end)
        return
    end

    local current
    if key == "content" or key == "comment" then
        current = entry[key]
    else
        current = entry[key] ~= nil and tostring(entry[key]) or ""
    end
    Modals.input(_(key), current, numeric and _("Number") or nil, _("Save"), function(text)
        text = text or ""
        if numeric then
            local n = tonumber(text)
            entry[key] = n
        else
            entry[key] = text ~= "" and text or nil
        end
        self_ref:refresh(true)
    end, key == "content")
end

function App:choose_world_entry_enum(key, labels)
    local Sheets = require("ktui/sheets")
    local self_ref = self
    local entry = self.state.editing_entry
    if not entry then return end
    local actions = {}
    for label, value in pairs(labels) do
        table.insert(actions, { label = label, checked = (tonumber(entry[key]) or 0) == value,
            on_tap = function()
                entry[key] = value
                self_ref:refresh(true)
            end })
    end
    Sheets.show(self, { title = _("Select"), actions = actions })
end

-- === Presets ===
-- Resolution order for the active generation preset:
--   chat override (Chat Options → Preset) → global default → connection's
--   default preset → nil (falls back to connection/built-in parameters).
function App:active_preset()
    local presets = Storage.list_presets()
    local wanted = self.state.current_chat_preset_id
        or (self.state.settings and self.state.settings.default_preset_id)
    if not wanted and self.state.current_connection then
        wanted = self.state.current_connection.preset_id
    end
    if not wanted then return nil end
    for _, p in ipairs(presets) do
        if p.id == wanted then
            return p
        end
    end
    return nil
end

function App:set_chat_preset(preset_id)
    self.state.current_chat_preset_id = preset_id
    local path = self.state.current_chat_path
    if path then
        local chat_data = Storage.load_chat(path)
        if chat_data and chat_data.header and chat_data.header.chat_metadata then
            chat_data.header.chat_metadata.preset_id = preset_id
            Storage.save_chat(path, chat_data.header, chat_data.messages)
        end
    end
    self:refresh(true)
end

function App:choose_chat_preset()
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self
    local presets = Storage.list_presets()
    local current = self.state.current_chat_preset_id

    local Sheets = require("ktui/sheets")
    local actions = {
        { label = _("None (connection defaults)"), checked = current == nil, on_tap = function()
                self_ref:set_chat_preset(nil)
            end,
        },
    }
    for _, p in ipairs(presets) do
        table.insert(actions, {
            label = p.name or "?",
            checked = (current == p.id),
            on_tap = function()
                self_ref:set_chat_preset(p.id)
            end,
        })
    end
    Sheets.show(self, { title = _("Select Preset"), actions = actions })
end

-- Preset editor is a canvas page (like the character editor). The draft lives
-- in `state.editing_preset`; PRESET_FIELDS drives the page rows. Tapping a row
-- opens a single-field input dialog; Save writes the draft back to storage.
-- Sections (v0.6.7): the flat list grew past one e-ink screen, so fields are
-- grouped the way SillyTavern's AI Response Configuration panel is; section
-- rows (section = true) are pure labels and not editable.
App.PRESET_FIELDS = {
    { section = true, title = "Main" },
    { key = "name", title = "Name" },
    { key = "model_id", title = "Model ID (blank = connection's)" },
    { key = "streaming", title = "Streaming", boolean = true },
    { section = true, title = "Generation" },
    { key = "temperature", title = "Temperature (0-2, default 0.8)" },
    { key = "max_tokens", title = "Max tokens (default 1024)" },
    { section = true, title = "Context" },
    { key = "openai_max_context", title = "Max context tokens" },
    { key = "stop", title = "Stop strings (comma-separated)" },
    { section = true, title = "Sampler" },
    { key = "top_p", title = "Top P (default 1.0)" },
    { key = "top_k", title = "Top K", numeric = true },
    { key = "top_a", title = "Top A", numeric = true },
    { key = "min_p", title = "Min P", numeric = true },
    { key = "repetition_penalty", title = "Repetition penalty", numeric = true },
    { key = "frequency_penalty", title = "Frequency penalty", numeric = true },
    { key = "presence_penalty", title = "Presence penalty", numeric = true },
    { section = true, title = "Advanced" },
    { key = "seed", title = "Seed", numeric = true },
    { key = "n", title = "N (choices)", numeric = true },
    { key = "reasoning_effort", title = "Reasoning effort", choices = { "", "low", "medium", "high", "minimal" } },
    { key = "verbosity", title = "Verbosity (GPT-5)", choices = { "", "low", "medium", "high" } },
    { key = "continue_postfix", title = "Continue postfix (appended before resuming)" },
}

-- Draft handed to the preset editor. Scalars are copied; nested tables
-- (prompts/prompt_order/st_fields - and any future structure) are shared by
-- REFERENCE with the persisted record, so the Prompt Manager edits the real
-- preset and Save writes them back intact. Text fields the editor exposes but
-- the old whitelist dropped (stop, continue_postfix, reasoning_effort,
-- verbosity) ride along too - losing them on every Edit was a data-loss bug.
App.PRESET_DRAFT_TEXT_FIELDS = { "stop", "continue_postfix", "reasoning_effort", "verbosity" }

function App:present_preset(pre)
    local draft = {
        id = pre.id,
        name = pre.name,
        model_id = pre.model_id,
        temperature = pre.temperature,
        max_tokens = pre.max_tokens,
        openai_max_context = pre.openai_max_context,
        top_p = pre.top_p,
        top_k = pre.top_k,
        top_a = pre.top_a,
        min_p = pre.min_p,
        repetition_penalty = pre.repetition_penalty,
        frequency_penalty = pre.frequency_penalty,
        presence_penalty = pre.presence_penalty,
        seed = pre.seed,
        n = pre.n,
        streaming = pre.streaming,
        st_fields = pre.st_fields,
    }
    for _i, key in ipairs(App.PRESET_DRAFT_TEXT_FIELDS) do
        draft[key] = pre[key]
    end
    -- Shared tables: the editor mutates the persisted structures in place.
    for k, v in pairs(pre) do
        if type(v) == "table" and draft[k] == nil then
            draft[k] = v
        end
    end
    return draft
end

-- Utility prompts every chat-completion preset starts with (SillyTavern
-- defaults). Markers resolve dynamically at build time (kt_models), so they
-- carry no content. Identifiers match ST so exports interoperate.
App.DEFAULT_PROMPTS = {
    { identifier = "main", name = "Main Prompt", role = "system",
      content = "Write {{char}}'s next reply. Be proactive, creative, and drive the plot and conversation forward. Stay in character and avoid repetition.", injection_position = 0, injection_depth = 4, forbid_overrides = false, marker = false },
    { identifier = "nsfw", name = "Auxiliary Prompt", role = "system", content = "", injection_position = 0, injection_depth = 4, marker = false },
    { identifier = "jailbreak", name = "Post-History Instructions", role = "system", content = "", injection_position = 0, injection_depth = 4, marker = false },
    { identifier = "enhanceDefinitions", name = "Enhance Definitions", role = "system", content = "", injection_position = 0, injection_depth = 4, marker = false },
    { identifier = "worldInfoBefore", name = "World Info (before)", role = "system", marker = true, system_prompt = false },
    { identifier = "worldInfoAfter", name = "World Info (after)", role = "system", marker = true, system_prompt = false },
    { identifier = "charDescription", name = "Char Description", role = "system", marker = true, system_prompt = false },
    { identifier = "charPersonality", name = "Char Personality", role = "system", marker = true, system_prompt = false },
    { identifier = "scenario", name = "Scenario", role = "system", marker = true, system_prompt = false },
    { identifier = "dialogueExamples", name = "Chat Examples", role = "system", marker = true, system_prompt = false },
    { identifier = "personaDescription", name = "Persona Description", role = "system", marker = true, system_prompt = false },
    { identifier = "chatHistory", name = "Chat History", marker = true, system_prompt = false },
}

-- Seed prompts/prompt_order on a preset draft that has none (presets created
-- in-app or imports without them), so the Prompt Manager is always editable.
-- Returns true when structures were added (caller must re-render).
function App:ensure_preset_prompts(preset)
    if type(preset) ~= "table" then return false end
    local seeded = false
    if type(preset.prompts) ~= "table" then
        preset.prompts = {}
        for _i, p in ipairs(App.DEFAULT_PROMPTS) do
            local copy = {}
            for k, v in pairs(p) do copy[k] = v end
            table.insert(preset.prompts, copy)
        end
        seeded = true
    end
    if type(preset.prompt_order) ~= "table" or #preset.prompt_order == 0 then
        -- ST 1.13.x default order: main prompt and the context markers before
        -- the chatHistory MARKER (kt_models splices the history there), then
        -- worldInfoAfter and the disabled utility prompts.
        preset.prompt_order = { {
            character_id = 100001,
            order = {
                { identifier = "main", enabled = true },
                { identifier = "worldInfoBefore", enabled = true },
                { identifier = "personaDescription", enabled = true },
                { identifier = "charDescription", enabled = true },
                { identifier = "charPersonality", enabled = true },
                { identifier = "scenario", enabled = true },
                { identifier = "dialogueExamples", enabled = true },
                { identifier = "chatHistory", enabled = true },
                { identifier = "worldInfoAfter", enabled = true },
                { identifier = "nsfw", enabled = false },
                { identifier = "jailbreak", enabled = false },
                { identifier = "enhanceDefinitions", enabled = false },
            },
        } }
        seeded = true
    end
    return seeded
end

function App:edit_preset(existing)
    local draft
    if existing then
        draft = self:present_preset(existing)
    else
        draft = { id = Util.uuid() }
    end
    -- Always-present Prompt Manager: presets without prompts/prompt_order
    -- (created in-app, or imports without them) get the ST defaults seeded so
    -- the utility prompts are editable too.
    self:ensure_preset_prompts(draft)
    self.state.editing_preset = draft
    self:navigate("preset_editor")
end

function App:edit_preset_field(key)
    local Modals = require("ktui/modals")
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    local draft = self.state.editing_preset
    if not draft then return end
    local field = nil
    for _, f in ipairs(App.PRESET_FIELDS) do
        if f.key == key then field = f break end
    end
    if not field then return end
    local self_ref = self

    -- Boolean fields toggle in place.
    if field.boolean then
        draft[key] = not draft[key]
        self_ref:refresh(true)
        return
    end

    -- Enum fields (reasoning_effort/verbosity): bottom-sheet picker, no
    -- keyboard - e-ink parity with the connection editor's intent.
    if field.choices then
        local Sheets = require("ktui/sheets")
        local current = draft[key]
        local actions = {}
        for _i, opt in ipairs(field.choices) do
            local value = opt ~= "" and opt or nil
            table.insert(actions, {
                label = opt == "" and _("Default (not sent)") or opt,
                checked = (current or "") == (value or ""),
                on_tap = function()
                    draft[key] = value
                    self_ref:refresh(true)
                end,
            })
        end
        Sheets.show(self_ref, { title = _(field.title), actions = actions })
        return
    end

    local current = draft[key]
    local current_text = (current == nil or current == "") and "" or tostring(current)
    Modals.input(field.title, current_text, field.title, _("Save"), function(text)
        text = text or ""
        text = text:match("^%s*(.-)%s*$") or ""
        if field.boolean then
            if text == "true" then draft[key] = true
            elseif text == "false" then draft[key] = false
            else draft[key] = nil end
        else
            if field.numeric then
                local n = tonumber(text)
                draft[key] = n or nil
            else
                -- NOT `text == "" and nil or text`: that always yields text
                -- (Lua and/or trap - `true and nil` is nil, so the `or text`
                -- branch always wins), keeping empty strings in the draft.
                draft[key] = (text ~= "") and text or nil
            end
            if key == "name" and draft[key] == "" then draft[key] = nil end
        end
        self_ref:refresh(true)
    end)
end

-- Continue Nudge Prompt (ST "Continue Nudge Prompt", preset-level): the
-- system message sent when the user continues a length-cut reply. Blank
-- restores the built-in default (built at generation time).
function App:edit_continue_nudge()
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local draft = self.state.editing_preset
    if not draft then return end
    Modals.input(_("Continue Nudge Prompt"),
        tostring(draft.continue_nudge_prompt or ""),
        _("Blank = built-in default"), _("Save"), function(text)
        text = Util.trim(tostring(text or ""))
        draft.continue_nudge_prompt = (text ~= "") and text or nil
        self:refresh(true)
    end)
end

function App:save_preset_edit()
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    local draft = self.state.editing_preset
    if not draft then return end
    local name = tostring(draft.name or ""):match("^%s*(.-)%s*$") or ""
    if name == "" then
        UIManager:show(InfoMessage:new{ text = _("Please give the preset a name."), timeout = 3 })
        return
    end
    draft.name = name
    -- Safety net for callers that skipped edit_preset (e.g. imports edited
    -- elsewhere): the Prompt Manager always has structures to edit.
    self:ensure_preset_prompts(draft)
    local presets = Storage.list_presets()
    local found = false
    for i, p in ipairs(presets) do
        if p.id == draft.id then
            presets[i] = draft
            found = true
            break
        end
    end
    if not found then
        table.insert(presets, draft)
    end
    Storage.save_presets(presets)
    self.state.editing_preset = nil
    self:refresh(true)
    self:go_back()
end

function App:export_preset(preset)
    local _ = require("gettext")
    local self_ref = self
    if not preset or not (preset.name and preset.name ~= "") then return end
    local fname = Util.safe_filename(preset.name) .. ".json"
    self:choose_export_dir(function(dir)
        local Export = require("kotaven_export")
        local ok, res = Export.preset_to_json(preset, dir .. "/" .. fname)
        if ok then
            UIManager:show(InfoMessage:new{ text = _("Preset exported to ") .. res, timeout = 3 })
        else
            UIManager:show(InfoMessage:new{ text = _("Export failed: ") .. tostring(res) })
        end
    end)
end

function App:import_preset()
    local _ = require("gettext")
    local self_ref = self
    self:choose_file_path(function(file_path)
        local path = file_path:lower()
        if not path:match("%.json$") then
            UIManager:show(InfoMessage:new{ text = _("Please select a .json preset file."), timeout = 2 })
            return
        end
        local Export = require("kotaven_export")
        local preset, err = Export.read_preset_json(file_path)
        if not preset then
            UIManager:show(InfoMessage:new{ text = _("Import failed: ") .. tostring(err), timeout = 3 })
            return
        end
        -- Name derives from the filename (ST convention: name = filename)
        local base = file_path:match("([^/\\]+)%.json$") or "Preset"
        preset.name = base
        preset.id = Util.uuid()
        -- Presets without a prompt layout get the ST defaults seeded so the
        -- Prompt Manager is editable right after import.
        self_ref:ensure_preset_prompts(preset)
        local presets = Storage.list_presets()
        table.insert(presets, preset)
        Storage.save_presets(presets)
        self_ref:refresh(true)
        UIManager:show(InfoMessage:new{ text = _("Preset imported!") .. " (" .. base .. ")", timeout = 2 })
    end)
end

function App:show_preset_actions(preset)
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local self_ref = self
    local settings = self.state.settings or {}
    local is_default = (settings.default_preset_id == preset.id)

    local actions = {
        { label = _("Edit"), icon = "edit", on_tap = function()
                self_ref:edit_preset(preset)
            end,
        },
        { label = _("Export JSON"), icon = "upload", on_tap = function()
                self_ref:export_preset(preset)
            end,
        },
        { label = _("Duplicate"), icon = "copy", on_tap = function()
                local dup = {}
                for k, v in pairs(preset) do dup[k] = v end
                -- Nested structures must not alias the original: editing the
                -- copy's Prompt Manager would otherwise mutate the source.
                if type(dup.prompts) == "table" then
                    dup.prompts = {}
                    for _i, p in ipairs(preset.prompts) do
                        local cp = {}
                        for pk, pv in pairs(p) do cp[pk] = pv end
                        table.insert(dup.prompts, cp)
                    end
                end
                if type(dup.prompt_order) == "table" then
                    dup.prompt_order = {}
                    for _i, po in ipairs(preset.prompt_order) do
                        local cpo = {}
                        for pk, pv in pairs(po) do cpo[pk] = pv end
                        if type(cpo.order) == "table" then
                            cpo.order = {}
                            for _j, oi in ipairs(po.order) do
                                local ci = {}
                                for ok2, ov in pairs(oi) do ci[ok2] = ov end
                                table.insert(cpo.order, ci)
                            end
                        end
                        table.insert(dup.prompt_order, cpo)
                    end
                end
                if type(dup.st_fields) == "table" then
                    dup.st_fields = {}
                    for sk, sv in pairs(preset.st_fields) do dup.st_fields[sk] = sv end
                end
                dup.id = Util.uuid()
                dup.name = (dup.name or "Preset") .. " (copy)"
                local presets = Storage.list_presets()
                table.insert(presets, dup)
                Storage.save_presets(presets)
                self_ref:refresh(true)
            end,
        },
    }
    if is_default then
        table.insert(actions, {
            label = _("Remove Global Default"), icon = "star-empty", on_tap = function()
                self_ref.state.settings.default_preset_id = nil
                Storage.save_settings(self_ref.state.settings)
                self_ref:refresh(true)
            end,
        })
    else
        table.insert(actions, {
            label = _("Set as Global Default"), icon = "star", on_tap = function()
                self_ref.state.settings.default_preset_id = preset.id
                Storage.save_settings(self_ref.state.settings)
                self_ref:refresh(true)
            end,
        })
    end
    table.insert(actions, {
        label = _("Delete"), icon = "trash", danger = true, on_tap = function()
            Sheets.confirm(self_ref, {
                title = _("Delete preset"),
                text = _("Delete this preset permanently?"),
                ok_label = _("Delete"), danger = true,
                on_ok = function()
                    local presets = Storage.list_presets()
                    local list = {}
                    for _, p in ipairs(presets) do
                        if p.id ~= preset.id then
                            table.insert(list, p)
                        end
                    end
                    Storage.save_presets(list)
                    if self_ref.state.settings.default_preset_id == preset.id then
                        self_ref.state.settings.default_preset_id = nil
                        Storage.save_settings(self_ref.state.settings)
                    end
                    if self_ref.state.current_chat_preset_id == preset.id then
                        self_ref.state.current_chat_preset_id = nil
                    end
                    self_ref:refresh(true)
                end,
            })
        end,
    })
    Sheets.show(self_ref, { title = preset.name or "?", actions = actions })
end

function App:_active_persona_description()
    local p = self:_active_persona()
    if p then
        return p.description or ""
    end
    return ""
end

-- Generation context consumed by Models.build_messages: Author's Note from
-- chat_metadata (SillyTavern keys), the card's depth_prompt and World Info
-- activation (when a lorebook is enabled for this chat).
function App:_gen_context()
    local ctx = {}
    local path = self.state.current_chat_path
    if path then
        local chat_data = Storage.load_chat(path)
        local meta = chat_data and chat_data.header and chat_data.header.chat_metadata
        if meta then
            ctx.note_prompt = meta.note_prompt
            ctx.note_depth = meta.note_depth
            ctx.note_interval = meta.note_interval
            ctx.note_position = meta.note_position
            ctx.note_role = meta.note_role
        end
    end
    local character = self:_resolve_character_data()
    if type(character.extensions) == "table" then
        local dp = character.extensions.depth_prompt
        if type(dp) == "table" and type(dp.prompt) == "string" and dp.prompt ~= "" then
            ctx.depth_prompt = dp.prompt
            ctx.depth_prompt_depth = dp.depth
            ctx.depth_prompt_role = dp.role
        end
    end
    -- World Info (lorebook ativo no chat)
    local ok_wi, WI = pcall(require, "world_info")
    if ok_wi then
        local wi = WI.active_context(self, character)
        if wi then
            ctx.wi_before = wi.before
            ctx.wi_after = wi.after
            ctx.wi_injections = wi.injections
        end
    end
    -- Regex scripts (prompt side; display side is applied in chat_bubbles)
    ctx.regex_scripts = self.state.settings.regex_scripts
    -- Prompt Manager: presets ST com prompts/prompt_order definem o layout
    local ok_preset, preset = pcall(function() return self:active_preset() end)
    if ok_preset and type(preset) == "table" then
        if type(preset.prompts) == "table" then
            ctx.preset = preset
        end
        -- Context budget (Models.enforce_context_budget): trim oldest history
        -- so the prompt fits the model window instead of surfacing a raw API
        -- overflow error.
        ctx.openai_max_context = tonumber(preset.openai_max_context)
        ctx.openai_max_tokens = tonumber(preset.max_tokens)
    end
    -- Macro expansion context ({{user}}/{{char}}/{{random}}...)
    local ok_name, persona_name = pcall(function() return self:_active_persona_name() end)
    if ok_name then
        ctx.user_name = persona_name or self.state.current_character or "You"
    else
        ctx.user_name = self.state.current_character or "You"
    end
    ctx.pick_seed = self.state.current_chat_id or self.state.current_chat_path
    -- ST "[Start a new Chat]" starter: no visible turns → give the model a
    -- user turn to respond to (not persisted; lives only in this prompt).
    local visible = 0
    for _, m in ipairs(self.state.messages or {}) do
        if m.role ~= "system" and m.hidden ~= true then visible = visible + 1 end
    end
    if visible == 0 then
        ctx.new_chat_starter = true
    end
    return ctx
end

-- Build the API message array and surface context trimming once per send.
function App:_build_api_messages(history)
    local Models = require("kt_models")
    local character = self:_resolve_character_data()
    local persona_desc = self:_active_persona_description()
    local messages, trimmed = Models.build_messages(character, persona_desc, history, self:_gen_context())
    if trimmed and not self.state.context_trim_warned then
        self.state.context_trim_warned = true
        UIManager:show(InfoMessage:new{
            text = _("History trimmed to fit the model's context window."),
            timeout = 3,
        })
    end
    -- start_reply_with (SillyTavern parity, experimental): append a partial
    -- assistant message so the model continues from it (works on local
    -- OpenAI-compatible endpoints like vLLM/llama.cpp/TabbyAPI; the official
    -- OpenAI API ignores trailing assistant messages). Configured via the
    -- connection editor field with the same name.
    local conn = self.state.current_connection
    local srw = conn and conn.start_reply_with
    if type(srw) == "string" and srw ~= "" and #messages > 0 then
        local last = messages[#messages]
        if last.role == "assistant" and type(last.content) == "string"
            and last.content:sub(-#srw) == srw then
            -- already prefilled - don't stack it again
        elseif last.role == "assistant" and type(last.content) == "string" then
            last.content = last.content .. srw
        else
            table.insert(messages, { role = "assistant", content = srw })
        end
    end
    return messages
end

function App:_resolve_character_data()
    local character = self.state.current_character_data
    if not character then
        if self.state.current_character_file then
            local Png = require("kotaven_png")
            local parsed_character = Png.parse_character(self.state.current_character_file)
            if parsed_character then
                character = parsed_character
                self.state.current_character_data = parsed_character
            end
        end
    end
    if not character then
        character = {
            name = self.state.current_character,
            description = "",
            personality = "",
            scenario = "",
            system_prompt = "",
            post_history_instructions = "",
        }
    end
    return character
end

function App:_do_send_message(text)
    -- Guard: need connection and chat path
    if not self.state.current_connection or not self.state.current_chat_path then
        UIManager:show(InfoMessage:new{
            text = _("Chat not fully configured."),
            timeout = 2,
        })
        return
    end

    -- Add user message
    local user_msg = {
        role = "user",
        content = text,
        name = "User",
        send_date = os.time(),
    }
    table.insert(self.state.messages, user_msg)

    -- Save user message to JSONL
    Storage.append_message(self.state.current_chat_path, "user", text, nil, "User")

    -- Scroll to the new message
    self.state.scroll[self:scroll_key()] = 999999
    self:refresh(true)

    -- Build messages array for API
    local Models = require("kt_models")
    local character = self:_resolve_character_data()
    local persona_desc = self:_active_persona_description()
    local api_messages = self:_build_api_messages(self.state.messages)

    self:_do_generate(api_messages)
end

-- Generate a reply for the current history WITHOUT appending a user message
-- (the "resume after interrupt" path: the last message is the user's and the
-- reply never came - Continue must trigger generation, ST-style).
function App:generate_reply()
    if self.state.is_generating then return end
    if not self.state.current_connection or not self.state.current_chat_path then
        return
    end
    local api_messages = self:_build_api_messages(self.state.messages)
    self:_do_generate(api_messages)
end

-- Build the user-facing API error text AND record the debug bundle.
-- o = { prefix (already-translated, e.g. _("API Error: ")), connection,
--       model, backend, message }. Returns the full toast string.
function App:report_api_error(o)
    o = o or {}
    local Client = require("kt_client")
    local Storage = require("kt_storage")
    local info = Client.last_http or {}
    local text = tostring(o.prefix or "")
        .. Client.describe_error(o.connection, o.model, info.status, o.message)
    Storage.append_debug(Client.debug_entry{
        backend = o.backend,
        connection = o.connection,
        model = o.model,
        status = info.status,
        body = info.body,
    })
    return text
end

function App:_do_generate(api_messages, opts)
    opts = opts or {}
    -- Re-entry guard: never spawn a second concurrent request (two curl
    -- processes writing the same JSONL corrupts both finalizers).
    if self.state.is_generating then
        UIManager:show(InfoMessage:new{
            text = _("Already generating. Stop the current response first."),
            timeout = 3,
        })
        return
    end
    -- Guard: a chat can be open with a stale/removed connection (Regenerate).
    if not self.state.current_connection then
        self.state.is_generating = false
        self.state.loading = nil
        if opts.regenerate then
            self:_restore_reused_message(opts.regenerate, opts.msg_index)
        end
        UIManager:show(InfoMessage:new{
            text = _("No API connection configured.\nOpen Options → Change API Connection to set one."),
            timeout = 4,
        })
        self:refresh(true)
        return
    end
    -- Guard: hosted endpoints reject keyless requests with HTTP 401, and the
    -- provider's message is often cryptic. Fail fast with an actionable
    -- message instead. Local/LAN servers and Pollinations accept keyless
    -- requests (Client.requires_api_key).
    do
        local Client = require("kt_client")
        local conn = self.state.current_connection
        local key = conn.api_key
        if (key == nil or key == "") and Client.requires_api_key(conn.base_url) then
            self.state.is_generating = false
            self.state.loading = nil
            if opts.regenerate then
                self:_restore_reused_message(opts.regenerate, opts.msg_index)
            end
            UIManager:show(InfoMessage:new{
                text = _("No API key configured for this connection.\nOpen the connection editor and paste your key."),
                timeout = 4,
            })
            self:refresh(true)
            return
        end
    end

    local conn_streaming = self.state.current_connection.streaming
    local global_streaming = self.state.settings and self.state.settings.streaming
    local preset_streaming = self:active_preset() and self:active_preset().streaming
    local use_streaming
    if preset_streaming ~= nil then
        use_streaming = preset_streaming
    elseif conn_streaming ~= nil then
        use_streaming = conn_streaming
    else
        use_streaming = global_streaming ~= false
    end

    if use_streaming then
        self:_do_stream_message(api_messages, opts)
    else
        -- Non-streaming: always run curl in the background + poll by timer so
        -- the UI never freezes (Fase E). A "thinking" bubble is shown instead
        -- of a static full-screen loader and is repainted regionally.
        self.state.is_generating = true
        self.state.loading = nil
        self.state.thinking = true
        self.state.thinking_frame = 0
        self._stream_partial_count = 0
        self._last_stream_paint = nil
        self.state.user_scrolled_up = nil
        -- New generation: collapse reasoning blocks (same rationale as the
        -- streaming path above).
        self.state.reasoning_open = {}
        self.state.reasoning_full = {}
        -- ST parity: on Regenerate the old reply clears IMMEDIATELY (fresh
        -- bubble in place); _streaming_base keeps it for restore on failure.
        if opts.regenerate then
            opts.regenerate._streaming_reuse = true
            opts.regenerate._streaming_base = opts.regenerate.content or ""
            opts.regenerate._streaming_base_reasoning = opts.regenerate.reasoning
            opts.regenerate._reasoning_backed_up = true
            opts.regenerate.content = ""
            opts.regenerate.reasoning = nil
        end
        self.state.scroll[self:scroll_key()] = 999999
        self:refresh(true)

        local Client = require("kt_client")
        local client = Client:new()
        local conn = self.state.current_connection
        local path = self.state.current_chat_path
        local char_name = self.state.current_character
        local self_ref = self

        self:_start_thinking_pulse()

        local token = (self._gen_token or 0) + 1
        self._gen_token = token

        UIManager:scheduleIn(0.1, function()
            if self_ref._gen_token ~= token then return end
            -- Respect the user-selected backend (default curl_bg: never
            -- blocks the UI). http_sync/curl_sync are legacy choices.
            local backend = (self.state.settings and self.state.settings.api_backend) or "curl_bg"
            client:chat_completion(api_messages, conn, self_ref:active_preset() or {}, function(content, err, extra, api_reasoning, usage, finish)
                if self_ref._gen_token ~= token then return end
                self_ref:_stop_thinking_pulse()
                self_ref.state.is_generating = false
                self_ref.state.loading = nil
                local same_chat = self_ref.state.current_chat_path == path

                if content then
                    content = self_ref:_postprocess_ai(content)
                    -- Reasoning (SillyTavern parity): native channel first,
                    -- then auto-parse inline reasoning tags from the content.
                    local reasoning
                    if type(api_reasoning) == "string" and api_reasoning ~= "" then
                        reasoning = api_reasoning
                    end
                    local s = self_ref.state.settings or {}
                    if s.reasoning_auto_parse ~= false then
                        local Models = require("kt_models")
                        local clean, parsed = Models.extract_reasoning(content, s.reasoning_prefix, s.reasoning_suffix)
                        if parsed then
                            content = clean
                            reasoning = reasoning or parsed
                        end
                    end
                    local completion_tokens
                    if type(usage) == "table" and tonumber(usage.completion_tokens) then
                        completion_tokens = tonumber(usage.completion_tokens)
                    end
                    local assistant_msg
                    if opts.regenerate or opts.continue_into then
                        local target = opts.regenerate or opts.continue_into
                        assistant_msg = target
                        local base = target.content or ""
                        local final_text = opts.continue_into and (base .. content) or content
                        self_ref:_finish_reused_message(target, final_text, opts, opts.continue_into and base or nil, path, reasoning)
                        if completion_tokens then target.completion_tokens = completion_tokens end
                    else
                        -- Multi-choice (n>1): every choice becomes a swipe.
                        local swipes = { content }
                        if type(extra) == "table" and #extra > 1 then
                            swipes = {}
                            for _, c in ipairs(extra) do
                                table.insert(swipes, self_ref:_postprocess_ai(c))
                            end
                        end
                        assistant_msg = {
                            role = "assistant",
                            content = swipes[1],
                            name = char_name,
                            send_date = os.time(),
                            swipes = swipes,
                            swipe_id = 1,
                            reasoning = reasoning,
                            completion_tokens = completion_tokens,
                        }
                        Storage.append_message(path, "assistant", swipes[1],
                            { swipes = assistant_msg.swipes, swipe_id = 1, reasoning = reasoning }, char_name)
                        -- Only touch the in-memory list when the reply still
                        -- belongs to the open chat; otherwise it is loaded
                        -- from disk on reopen.
                        if same_chat then
                            table.insert(self_ref.state.messages, assistant_msg)
                            local key = self_ref:scroll_key()
                            self_ref.state.scroll[key] = 999999
                        end
                    end
                else
                    if opts.regenerate or opts.continue_into then
                        self_ref:_restore_reused_message(opts.regenerate or opts.continue_into, opts.msg_index, path)
                    end
                    local preset_now = self_ref:active_preset() or {}
                    local err_msg = self_ref:report_api_error{
                        prefix = _("API Error: "),
                        connection = conn,
                        model = preset_now.model_id or conn.model_id,
                        backend = backend,
                        message = err or _("Unknown error"),
                    }
                    UIManager:show(InfoMessage:new{
                        text = err_msg,
                        timeout = 5,
                    })
                end
                -- Cut-response hint / Auto-Continue on the sync path too (the
                -- stream path handles its own; parity for sync backends).
                if content and finish == "length"
                    and self_ref.state.current_chat_path == path then
                    if not self_ref:_maybe_auto_continue(assistant_msg, opts, path) then
                        UIManager:show(InfoMessage:new{
                            text = _("Response was cut by the token limit - use Continue to finish it."),
                            timeout = 5,
                        })
                    end
                end
                self_ref:refresh(true)
            end, backend)
        end)
    end
end

-- Animates the "thinking" bubble while a non-streaming request is in flight:
-- increments a frame counter on a timer and repaints only the chat page
-- (regional "ui" pass - no full-screen flash).
-- Stream repaint pacing (e-ink flicker control, settings.stream_refresh):
-- live = every chunk (~3/s), calm = at most 1/s, still = only when done.
-- Returns the repaint interval in seconds, or math.huge for still.
function App:_stream_paint_interval()
    local mode = self.state.settings and self.state.settings.stream_refresh
    if mode == "live" then
        return 0
    elseif mode == "still" then
        return math.huge
    end
    return 1.0
end

-- Thinking-pulse tick step: live 0.3s animation, calm 1s, still none.
function App:_stream_tick_interval()
    local mode = self.state.settings and self.state.settings.stream_refresh
    if mode == "live" then
        return 0.3
    elseif mode == "still" then
        return nil
    end
    return 1.0
end

-- Regional refresh during streaming/thinking: repaints only the chat area
-- (below the header) and forces a full refresh every N partials so ghosting
-- cannot accumulate over long generations on e-ink.
local STREAM_PARTIALS_PER_FLASH = 20

function App:_refresh_streaming()
    self._stream_partial_count = (self._stream_partial_count or 0) + 1
    if self._stream_partial_count >= STREAM_PARTIALS_PER_FLASH then
        self._stream_partial_count = 0
        self:refresh(true)
        return
    end
    local view = self.view
    local region = view and view.chat_region or nil
    if region then
        UIManager:setDirty(view, "ui", Geom:new(region))
    else
        self:refresh()
    end
end

function App:_start_thinking_pulse()
    local self_ref = self
    self_ref._thinking_pulse_handle = nil
    local step = self_ref:_stream_tick_interval()
    local function tick()
        if not self_ref.state.thinking then return end
        self_ref.state.thinking_frame = (self_ref.state.thinking_frame or 0) + 1
        self_ref:_refresh_streaming()
        local s = self_ref:_stream_tick_interval()
        -- still mode: static caret, no animation timer.
        if s then
            self_ref._thinking_pulse_handle = UIManager:scheduleIn(s, tick)
        else
            self_ref._thinking_pulse_handle = nil
        end
    end
    if step then
        self_ref._thinking_pulse_handle = UIManager:scheduleIn(step, tick)
    else
        -- still mode: paint the static caret once.
        self_ref:refresh()
    end
end

function App:_stop_thinking_pulse()
    if self._thinking_pulse_handle then
        UIManager:unschedule(self._thinking_pulse_handle)
        self._thinking_pulse_handle = nil
    end
    self.state.thinking = nil
    self.state.thinking_frame = nil
end

-- Cancel any in-flight generation, settling the target chat on disk first.
-- Used when switching chats, deleting a chat or closing the app: without it
-- callbacks would inject replies into the wrong chat or resurrect deleted
-- files via append_message's fallback header.
function App:_cancel_generation()
    local was_generating = self.state.is_generating

    -- Stop timers/streams so no further callbacks mutate state.
    self:_stop_thinking_pulse()
    self._gen_token = (self._gen_token or 0) + 1
    if self._active_stream_id then
        local Client = require("kt_client")
        Client:new():abort_stream(self._active_stream_id)
        self._active_stream_id = nil
    end

    -- Settle the streaming placeholder for the chat being left.
    local msgs = self.state.messages
    if #msgs > 0 and msgs[#msgs].is_streaming then
        local last = msgs[#msgs]
        local path = self.state.current_chat_path
        if last._streaming_reuse then
            -- Regenerate/continue in flight: restore original content; the
            -- disk copy still holds it untouched.
            last.content = last._streaming_base or last.content
            last.is_streaming = nil
            last._streaming_reuse = nil
            last._streaming_base = nil
            if last._reasoning_backed_up then
                last.reasoning = last._streaming_base_reasoning
                last._streaming_base_reasoning = nil
                last._reasoning_backed_up = nil
            end
        else
            local chat_data = path and Storage.load_chat(path) or nil
            if (last.content or "") == "" then
                -- Empty placeholder: drop from memory and from disk.
                table.remove(msgs)
                if chat_data and #chat_data.messages > 0 then
                    table.remove(chat_data.messages)
                    Storage.save_chat(path, chat_data.header, chat_data.messages)
                end
            else
                -- Partial content: commit it so nothing is lost.
                last.is_streaming = nil
                last.swipes = { last.content }
                last.swipe_id = 1
                if chat_data and #chat_data.messages > 0 then
                    local persisted = chat_data.messages[#chat_data.messages]
                    persisted.content = last.content
                    persisted.name = last.name or self.state.current_character
                    persisted.swipes = last.swipes
                    persisted.swipe_id = 1
                    Storage.save_chat(path, chat_data.header, chat_data.messages)
                end
            end
        end
    end

    if was_generating then
        self.state.is_generating = false
        self.state.stream_buffer = ""
    end
end

-- Finalize a regenerated / continued message: append the new text to its swipes
-- and persist. continue_base (if given) means the reply continues the existing
-- swipe instead of starting a new one.
function App:_finish_reused_message(target, final_text, opts, continue_base, chat_path, reasoning)
    target.is_streaming = nil
    target._streaming_reuse = nil
    target._streaming_base = nil
    target._streaming_base_reasoning = nil
    target._reasoning_backed_up = nil
    -- Persist the reasoning block (native channel or auto-parsed tags) so it
    -- round-trips to ST's extra.reasoning via save_chat.
    target.reasoning = (type(reasoning) == "string" and reasoning ~= "") and reasoning or nil
    final_text = self:_postprocess_ai(final_text)
    if continue_base ~= nil then
        if type(target.swipes) ~= "table" or #target.swipes == 0 then
            target.swipes = { continue_base }
            target.swipe_id = 1
        end
        local idx = (target.swipe_id and target.swipe_id >= 1 and target.swipe_id <= #target.swipes) and target.swipe_id or 1
        target.swipes[idx] = final_text
        target.content = final_text
    else
        self:_append_swipe(target, final_text)
    end
    -- Use the chat the generation was started in, not whatever is open now.
    local path = chat_path or self.state.current_chat_path
    if path then
        Storage.update_message(path, opts.msg_index or #self.state.messages, target)
    end
end

-- Post-process finished AI output (ST behavior settings): collapse excess
-- newlines and trim trailing incomplete sentences.
function App:_postprocess_ai(text)    text = tostring(text or "")
    local s = self.state.settings or {}
    if s.collapse_newlines then
        text = text:gsub("\n{3,}", "\n\n")
    end
    if s.trim_sentences then
        local cut
        for pos in text:gmatch("()[.!?…]") do
            local after = text:sub(pos + 1, pos + 1)
            if after == "" or after:match("%s") then
                cut = pos
            end
        end
        if cut then
            text = text:sub(1, cut)
        end
    end
    return text
end

-- Restore a message that was being regenerated/continued back to its original
-- content (used when generation fails or is aborted).
function App:_restore_reused_message(target, msg_index, chat_path)
    target.is_streaming = nil
    target._streaming_reuse = nil
    if target._streaming_base then
        target.content = target._streaming_base
        target._streaming_base = nil
    elseif target.swipes and target.swipe_id and target.swipe_id >= 1 and target.swipe_id <= #target.swipes then
        target.content = target.swipes[target.swipe_id]
    end
    -- Regenerate cleared the old reasoning before the request: put it back.
    if target._reasoning_backed_up then
        target.reasoning = target._streaming_base_reasoning
        target._streaming_base_reasoning = nil
        target._reasoning_backed_up = nil
    end
    local path = chat_path or self.state.current_chat_path
    if path and msg_index then
        Storage.update_message(path, msg_index, target)
    end
end

function App:_do_stream_message(api_messages, opts)
    -- Streaming via curl background process
    local _ = require("gettext")
    opts = opts or {}
    local path = self.state.current_chat_path
    local char_name = self.state.current_character
    local self_ref = self

    local assistant_msg
    local base_content = ""
    local is_reuse = false
    if opts.regenerate or opts.continue_into then
        -- Regenerate/continue: reuse the existing assistant message
        assistant_msg = opts.regenerate or opts.continue_into
        is_reuse = true
        base_content = assistant_msg.content or ""
        assistant_msg.is_streaming = true
        assistant_msg._streaming_reuse = true
        assistant_msg._streaming_base = base_content
        assistant_msg._streaming_base_reasoning = assistant_msg.reasoning
        assistant_msg._reasoning_backed_up = true
        if opts.regenerate then
            -- ST parity: the old reply clears IMMEDIATELY on Regenerate - a
            -- fresh streaming bubble takes its place (old reasoning included;
            -- the new one streams in). The base is kept only for the
            -- restore-on-failure path. Continue keeps appending to the text.
            base_content = ""
            assistant_msg.content = ""
            assistant_msg.reasoning = nil
        end
    else
        -- New assistant message that will be filled incrementally
        assistant_msg = {
            role = "assistant",
            content = "",
            name = char_name,
            send_date = os.time(),
            is_streaming = true,
        }
        table.insert(self.state.messages, assistant_msg)
        -- Save the empty assistant message placeholder
        Storage.append_message(path, "assistant", "")
    end
    -- 1-based index of the target message in both memory and disk (load_chat
    -- excludes the header line, so indices align 1:1).
    local msg_index = opts.msg_index or #self.state.messages

    self.state.is_generating = true
    self.state.loading = nil
    self._stream_partial_count = 0
    self._last_stream_paint = nil
    self.state.user_scrolled_up = nil
    -- New generation: start with all reasoning blocks collapsed (ST parity -
    -- a fresh reply renders clean, no stale expanded section lingering).
    self.state.reasoning_open = {}
    self.state.reasoning_full = {}
    self:refresh(true)

    local Client = require("kt_client")
    local client = Client:new()
    local conn = self.state.current_connection

    -- Apply the user-configured chunk poll interval
    local chunk_interval = self.state.settings and self.state.settings.stream_chunk_interval
    if chunk_interval then
        client:set_poll_interval(chunk_interval)
    end

    -- Configurable network behavior (Settings → Network)
    local s = self.state.settings or {}
    client:set_timeouts(s.api_timeout, s.stream_timeout)
    client:set_retries(s.api_retries)

    local stream_id = client:start_stream(
        api_messages,
        conn,
        self:active_preset() or {},
        -- on_chunk: update the assistant message incrementally.
        -- Auto-follow the stream only while already at (or past) the bottom
        -- of the chat; if the user scrolled up to read, don't yank the view.
        -- Refresh uses the partial "ui" pass (no full-screen flash on e-ink)
        -- on every chunk; the full refresh happens once on done/error.
        function(chunk, accumulated, reasoning_delta, accumulated_reasoning)
            assistant_msg.content = base_content .. accumulated
            -- Native reasoning channel (SillyTavern parity): render the
            -- collapsible reasoning block live while streaming.
            if type(accumulated_reasoning) == "string" and accumulated_reasoning ~= "" then
                assistant_msg.reasoning = accumulated_reasoning
            end
            self_ref.state.stream_buffer = accumulated
            -- Auto-follow only while the user has not scrolled up to read;
            -- a manual scroll sets user_scrolled_up (see AppView). Position
            -- tracks every chunk even when the repaint below is throttled.
            if not self_ref.state.user_scrolled_up then
                local key = self_ref:scroll_key()
                self_ref.state.scroll[key] = 999999
            end
            -- Throttled repaint (e-ink): text accumulates in the background,
            -- the screen only repaints at the stream_refresh pace (still mode
            -- never repaints partials - the done/error pass paints once).
            local interval = self_ref:_stream_paint_interval()
            if interval <= 0 then
                self_ref:_refresh_streaming()
            elseif interval < math.huge then
                local now = require("socket").gettime()
                if not self_ref._last_stream_paint
                    or (now - self_ref._last_stream_paint) >= interval then
                    self_ref._last_stream_paint = now
                    self_ref:_refresh_streaming()
                end
            end
        end,
        -- on_done: finalize the message (text, reasoning, usage, finish_reason)
        function(full_text, stream_reasoning, stream_usage, stream_finish)
            self_ref.state.is_generating = false
            self_ref.state.stream_buffer = ""
            self_ref._active_stream_id = nil

            full_text = self_ref:_postprocess_ai(full_text)
            -- Reasoning finalization (SillyTavern parity): prefer the native
            -- reasoning channel; otherwise auto-parse the <think>...</think> tags out of
            -- the content (settings.reasoning_auto_parse, like Advanced Formatting).
            local reasoning
            if type(stream_reasoning) == "string" and stream_reasoning ~= "" then
                reasoning = stream_reasoning
            end
            local s = self_ref.state.settings or {}
            if s.reasoning_auto_parse ~= false then
                local Models = require("kt_models")
                local clean, parsed = Models.extract_reasoning(full_text, s.reasoning_prefix, s.reasoning_suffix)
                if parsed then
                    full_text = clean
                    reasoning = reasoning or parsed
                end
            end
            if reasoning then
                assistant_msg.reasoning = reasoning
            end
            -- Real token usage (providers that emit usage on the last chunk)
            if type(stream_usage) == "table" and tonumber(stream_usage.completion_tokens) then
                assistant_msg.completion_tokens = tonumber(stream_usage.completion_tokens)
            end
            if is_reuse then
                local final_text = opts.continue_into and (base_content .. full_text) or full_text
                self_ref:_finish_reused_message(assistant_msg, final_text, opts, opts.continue_into and base_content or nil, path, reasoning)
            else
                assistant_msg.content = full_text
                assistant_msg.is_streaming = nil
                local chat_data = Storage.load_chat(path)
                if chat_data then
                    -- Locate by captured index (fall back to the last line);
                    -- never assume blindly that the last line is ours.
                    local idx = (#chat_data.messages >= msg_index) and msg_index or #chat_data.messages
                    local persisted = chat_data.messages[idx]
                    if persisted and not persisted.is_system and persisted.is_user ~= true then
                        persisted.content = full_text
                        persisted.name = char_name
                        persisted.swipes = { full_text }
                        persisted.swipe_id = 1
                        if reasoning then
                            persisted.reasoning = reasoning
                        end
                        if assistant_msg.completion_tokens then
                            persisted.completion_tokens = assistant_msg.completion_tokens
                        end
                        Storage.save_chat(path, chat_data.header, chat_data.messages)
                    end
                end
            end

            -- Cut-response hint / Auto-Continue (ST parity: finish_reason ==
            -- length means max_tokens was hit; Continue finishes it - the
            -- Auto-Continue setting chains it up to the target length).
            if stream_finish == "length" then
                if not self_ref:_maybe_auto_continue(assistant_msg, opts, path) then
                    UIManager:show(InfoMessage:new{
                        text = _("Response was cut by the token limit - use Continue to finish it."),
                        timeout = 5,
                    })
                end
            end

            self_ref:refresh(true)
        end,
        -- on_error
        function(err_msg)
            self_ref.state.is_generating = false
            self_ref.state.stream_buffer = ""
            self_ref._active_stream_id = nil

            if is_reuse then
                self_ref:_restore_reused_message(assistant_msg, opts.msg_index, path)
            elseif assistant_msg.content == "" then
                local msgs = self_ref.state.messages
                if #msgs > 0 and msgs[#msgs] == assistant_msg then
                    table.remove(msgs)
                end
                local chat_data = Storage.load_chat(path)
                if chat_data and #chat_data.messages >= msg_index then
                    local persisted = chat_data.messages[msg_index]
                    if persisted and (persisted.mes or "") == "" then
                        table.remove(chat_data.messages, msg_index)
                        Storage.save_chat(path, chat_data.header, chat_data.messages)
                    end
                end
            else
                local chat_data = Storage.load_chat(path)
                if chat_data then
                    local idx = (#chat_data.messages >= msg_index) and msg_index or #chat_data.messages
                    local persisted = chat_data.messages[idx]
                    if persisted and not persisted.is_system and persisted.is_user ~= true then
                        persisted.content = assistant_msg.content
                        persisted.name = char_name
                        Storage.save_chat(path, chat_data.header, chat_data.messages)
                    end
                end
            end

            UIManager:show(InfoMessage:new{
                text = self_ref:report_api_error{
                    prefix = _("Stream error: "),
                    connection = conn,
                    model = (self_ref:active_preset() or {}).model_id or conn.model_id,
                    backend = "curl_bg",
                    message = err_msg or _("Unknown"),
                },
                timeout = 4,
            })
            self_ref:refresh(true)
        end
    )
    if stream_id then
        self._active_stream_id = stream_id
    else
        -- Stream did not start; clean up placeholder assistant message
        self.state.is_generating = false
        self.state.stream_buffer = ""
        if is_reuse then
            self:_restore_reused_message(assistant_msg, opts.msg_index, path)
        elseif #self.state.messages > 0 and self.state.messages[#self.state.messages] == assistant_msg then
            table.remove(self.state.messages)
            local chat_data = Storage.load_chat(path)
            if chat_data and #chat_data.messages >= msg_index then
                local persisted = chat_data.messages[msg_index]
                if persisted and (persisted.mes or "") == "" then
                    table.remove(chat_data.messages, msg_index)
                    Storage.save_chat(path, chat_data.header, chat_data.messages)
                end
            end
        end
        UIManager:show(InfoMessage:new{
            text = _("Failed to start streaming."),
            timeout = 4,
        })
        self_ref:refresh(true)
    end
end

-- Stop current generation (streaming or sync)
function App:stop_generation()
    if not self.state.is_generating then return end

    self:_stop_thinking_pulse()

    -- Invalidate any in-flight non-streaming callback
    self._gen_token = (self._gen_token or 0) + 1

    -- Abort streaming if active
    if self._active_stream_id then
        local Client = require("kt_client")
        local client = Client:new()
        client:abort_stream(self._active_stream_id)
        self._active_stream_id = nil
    end

    self.state.is_generating = false
    self.state.loading = nil

    local msgs = self.state.messages
    if #msgs > 0 and msgs[#msgs].is_streaming then
        local last = msgs[#msgs]
        local stop_index = #msgs
        local path = self.state.current_chat_path
        if last._streaming_reuse then
            -- Regenerate/continue aborted: restore the original content
            self:_restore_reused_message(last, stop_index, path)
        elseif self.state.stream_buffer == "" then
            -- Empty streaming message: remove it
            table.remove(msgs)
            if path then
                local chat_data = Storage.load_chat(path)
                if chat_data and #chat_data.messages >= stop_index then
                    local persisted = chat_data.messages[stop_index]
                    if persisted and (persisted.mes or "") == "" then
                        table.remove(chat_data.messages, stop_index)
                        Storage.save_chat(path, chat_data.header, chat_data.messages)
                    end
                end
            end
        else
            -- Keep partial content, mark as not streaming
            last.is_streaming = nil
            last.swipes = { last.content }
            last.swipe_id = 1
            if path then
                local chat_data = Storage.load_chat(path)
                if chat_data and #chat_data.messages >= stop_index then
                    local persisted = chat_data.messages[stop_index]
                    if persisted and not persisted.is_system and persisted.is_user ~= true then
                        persisted.content = last.content
                        persisted.name = self.state.current_character
                        persisted.swipes = last.swipes
                        persisted.swipe_id = 1
                        Storage.save_chat(path, chat_data.header, chat_data.messages)
                    end
                end
            end
        end
    end

    self.state.stream_buffer = ""
    self.state.scroll[self:scroll_key()] = 999999
    self:refresh(true)
end

-- === Import ===

-- Generic file picker (PathChooser) for the plugin.
function App:choose_file_path(callback, start_dir)
    local PathChooser = require("ui/widget/pathchooser")
    local start_path = start_dir or "/home"
    if pcall(function() return os.execute("test -d /mnt/onboard") end) then
        start_path = "/mnt/onboard"
    elseif pcall(function() return os.execute("test -d /mnt/us") end) then
        start_path = "/mnt/us"
    end
    local file_chooser = PathChooser:new{
        select_directory = false,
        select_file = true,
        path = start_path,
        onConfirm = function(file_path)
            if not file_path or file_path == "" then return end
            callback(file_path)
        end,
    }
    UIManager:show(file_chooser)
end

function App:show_import()
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    self:choose_file_path(function(file_path)
        local ext = file_path:lower():match("%.([^%.]+)$")
        if ext == "png" or ext == "json" then
            local Storage = require("kt_storage")
            local dest_dir = Storage.characters_dir()
            local filename = file_path:match("([^/]+)$")
            local dest = dest_dir .. "/" .. filename

            local f = io.open(file_path, "rb")
            if f then
                local content = f:read("*a")
                f:close()
                local out = io.open(dest, "wb")
                if out then
                    out:write(content)
                    out:close()
                    self:refresh_characters()
                    self:refresh(true)
                    UIManager:show(InfoMessage:new{
                        text = _("Character imported!"),
                        timeout = 2,
                    })
                end
            end
        elseif ext == "jsonl" then
            self:import_chat(file_path)
        else
            UIManager:show(InfoMessage:new{
                text = _("Unsupported file type. Please use .png, .json or .jsonl"),
                timeout = 3,
            })
        end
    end)
end

function App:show_import_chat()
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    self:choose_file_path(function(file_path)
        local ext = file_path:lower():match("%.([^%.]+)$")
        if ext == "jsonl" then
            self:import_chat(file_path)
        else
            UIManager:show(InfoMessage:new{
                text = _("Please select a .jsonl chat file."),
                timeout = 3,
            })
        end
    end)
end

-- === Connection Management ===

-- Connection editor is a canvas page (like the preset editor). The draft
-- lives in `state.editing_connection`; CONNECTION_FIELDS drives the rows.
-- The model can be typed manually OR fetched from the endpoint's /models
-- (SillyTavern "Custom (OpenAI-compatible)" model dropdown parity).
App.CONNECTION_FIELDS = {
    { key = "name", title = "Connection name" },
    { key = "base_url", title = "API URL (e.g. https://api.openai.com/v1)" },
    { key = "api_key", title = "API Key (optional)" },
    { key = "model_id", title = "Model ID (manual)" },
    { key = "temperature", title = "Temperature (0-2)" },
    { key = "max_tokens", title = "Max tokens" },
    { key = "stop", title = "Stop strings (comma-separated)" },
    { key = "extra_headers", title = "Extra headers (JSON map)" },
    { key = "start_reply_with", title = "Start reply with (experimental)" },
    { key = "post_processing", title = "Post-processing", choices = {
        "none", "merge", "semi_strict", "strict", "single_user", } },
    { key = "extended_samplers", title = "Extended samplers (top_k/top_a/min_p)", choices = {
        "on", "off" } },
    { key = "streaming", title = "Streaming", boolean = true },
}

-- Well-known OpenAI-compatible endpoints (SillyTavern "source" parity):
-- one tap fills the URL (and the name when empty) - typing URLs on e-ink
-- keyboards is the slowest possible interaction.
App.PROVIDER_PRESETS = {
    { name = "OpenAI", url = "https://api.openai.com/v1" },
    { name = "OpenRouter", url = "https://openrouter.ai/api/v1" },
    { name = "DeepSeek", url = "https://api.deepseek.com/v1" },
    { name = "Groq", url = "https://api.groq.com/openai/v1" },
    { name = "Mistral", url = "https://api.mistral.ai/v1" },
    { name = "Gemini (OpenAI-compat)", url = "https://generativelanguage.googleapis.com/v1beta/openai" },
    { name = "Ollama (local)", url = "http://localhost:11434/v1" },
    { name = "LM Studio (local)", url = "http://localhost:1234/v1" },
    { name = "llama.cpp (local)", url = "http://localhost:8080/v1" },
    { name = "TabbyAPI (local)", url = "http://localhost:5000/v1" },
    { name = "Pollinations (free)", url = "https://text.pollinations.ai/openai" },
}

function App:pick_provider()
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")

    local draft = self.state.editing_connection
    if not draft then return end
    local self_ref = self
    local Client = require("kt_client")
    local items = {}
    for _, p in ipairs(App.PROVIDER_PRESETS) do
        table.insert(items, {
            label = p.name .. "  -  " .. p.url,
            -- Normalized so a hand-typed URL (trailing slash, pasted
            -- /chat/completions) still shows its preset as checked.
            checked = Client.provider_name(draft.base_url) == p.name,
            on_tap = function()
                draft.base_url = p.url
                if not draft.name or draft.name == "" then
                    draft.name = p.name
                end
                self_ref:refresh(true)
            end,
        })
    end
    Sheets.show(self, { title = _("Choose provider"), actions = items })
end

function App:present_connection(c)
    return {
        id = c.id,
        name = c.name,
        base_url = c.base_url,
        api_key = c.api_key,
        model_id = c.model_id,
        temperature = c.temperature,
        max_tokens = c.max_tokens,
        stop = c.stop,
        extra_headers = c.extra_headers,
        post_processing = c.post_processing,
        start_reply_with = c.start_reply_with,
        extended_samplers = c.extended_samplers,
        streaming = c.streaming,
    }
end

function App:edit_connection(existing)
    local draft
    if existing then
        draft = self:present_connection(existing)
    else
        draft = { id = Util.uuid(), streaming = true }
    end
    self.state.editing_connection = draft
    self:navigate("connection_editor")
end

function App:edit_connection_field(key)
    local Modals = require("ktui/modals")
    local _ = require("gettext")

    local draft = self.state.editing_connection
    if not draft then return end
    local field = nil
    for _, f in ipairs(App.CONNECTION_FIELDS) do
        if f.key == key then field = f break end
    end
    if not field then return end
    local self_ref = self

    -- Boolean fields toggle in place.
    if field.boolean then
        draft[key] = not draft[key]
        self_ref:refresh(true)
        return
    end

    -- Enum fields (post_processing, extended_samplers): bottom-sheet picker,
    -- no keyboard - e-ink parity with the preset editor's enum fields. The
    -- first row restores the stored default (nil).
    if field.choices then
        local Sheets = require("ktui/sheets")
        local current = draft[key]
        local actions = {
            { label = _("(default)"), checked = current == nil,
              on_tap = function()
                  draft[key] = nil
                  self_ref:refresh(true)
              end },
        }
        for _i, opt in ipairs(field.choices) do
            table.insert(actions, {
                label = opt,
                checked = current == opt,
                on_tap = function()
                    draft[key] = opt
                    self_ref:refresh(true)
                end,
            })
        end
        Sheets.show(self_ref, { title = _(field.title), actions = actions })
        return
    end

    local current = draft[key]
    local current_text = (current == nil or current == "") and "" or tostring(current)
    Modals.input(field.title, current_text, field.title, _("Save"), function(text)
        text = text or ""
        text = text:match("^%s*(.-)%s*$") or ""
        if field.numeric then
            local n = tonumber(text)
            draft[key] = n or nil
        else
            draft[key] = text ~= "" and text or nil
        end
        self_ref:refresh(true)
    end)
end

-- Fetch GET /models from the drafted endpoint and let the user pick a model.
-- Falls back gracefully: 404 means the endpoint has no model list (type it).
function App:search_connection_model()
    local Modals = require("ktui/modals")
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")

    local draft = self.state.editing_connection
    if not draft then return end
    if not draft.base_url or draft.base_url == "" then
        Modals.info(_("Fill the API URL first, then search models."))
        return
    end

    local self_ref = self
    local Client = require("kt_client")
    local client = Client:new()
    -- list_models is synchronous (curl with hard connect/max-time caps); a
    -- 1-2s block on e-ink is fine and matches how test_connection behaves.
    client:list_models({ base_url = draft.base_url, api_key = draft.api_key }, function(models, err)
        if not models then
            UIManager:show(InfoMessage:new{
                text = self_ref:report_api_error{
                    prefix = _("Could not list models: "),
                    connection = { base_url = draft.base_url, api_key = draft.api_key },
                    model = draft.model_id,
                    backend = "curl_sync(models)",
                    message = tostring(err),
                },
                timeout = 5,
            })
            return
        end
        -- Cache the list on the draft and open the full picker page (with a
        -- live search field) - a 300-model bottom sheet is unusable on e-ink.
        draft._models = models
        self_ref:open_model_picker()
    end)
end

-- Full-page model picker with a live filter field. State lives in
-- state.model_picker; rows are computed on refresh so the query filters
-- case-insensitively. A tap on a row selects and returns to the editor.
function App:open_model_picker()
    local draft = self.state.editing_connection
    if not draft or type(draft._models) ~= "table" or #draft._models == 0 then
        return
    end
    self.state.model_picker = {
        query = "",
        models = draft._models,
        selected = draft.model_id,
    }
    self:navigate("model_picker")
end

function App:model_picker_query()
    return self.state.model_picker and self.state.model_picker.query or ""
end

-- Search dialog for the model picker filter (keyboard + live match on the
-- model IDs, case-insensitive substring).
function App:show_model_search()
    local Modals = require("ktui/modals")
    local self_ref = self
    Modals.search(_("Filter models"), self:model_picker_query(), _("Model ID contains…"), function(text)
        self_ref:set_model_picker_query(text)
    end)
end

function App:set_model_picker_query(q)
    local st = self.state.model_picker
    if not st then return end
    st.query = tostring(q or "")
    self:refresh(true)
end

function App:pick_model(model_id)
    local st = self.state.model_picker
    if not st then return end
    local draft = self.state.editing_connection
    if draft then
        draft.model_id = model_id
    end
    self.state.model_picker = nil
    self:go_back()
end

-- === Connection Profiles (SillyTavern parity) ===
-- A profile snapshots the chat's {connection, preset} pair so both switch
-- atomically from the chat options menu. Optional future fields (stop,
-- start_reply_with) ride along in the profile record.

function App:save_profile_from_current()
    local Modals = require("ktui/modals")
    local _ = require("gettext")

    local conn = self.state.current_connection
    if not conn then
        Modals.info(_("No active connection."))
        return
    end
    local preset = self:active_preset()
    local self_ref = self
    Modals.input(_("Profile name"), "", _("Profile name"), _("Save"), function(text)
        text = Util.trim(tostring(text or ""))
        if text == "" then return end
        local profiles = Storage.list_profiles()
        table.insert(profiles, {
            id = Util.uuid(),
            name = text,
            connection_id = conn.id,
            preset_id = preset and preset.id or nil,
        })
        Storage.save_profiles(profiles)
        self_ref:refresh(true)
        Modals.info(_("Profile saved: ") .. text)
    end)
end

function App:apply_profile(pr)
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")

    local conn
    for _, c in ipairs(Storage.list_connections()) do
        if c.id == pr.connection_id then conn = c break end
    end
    if not conn then
        UIManager:show(InfoMessage:new{
            text = _("This profile's connection no longer exists."),
            timeout = 4,
        })
        return
    end
    self.state.current_connection = conn
    self.state.current_chat_preset_id = pr.preset_id
    -- Persist both selections into the open chat's metadata.
    local path = self.state.current_chat_path
    if path then
        local chat_data = Storage.load_chat(path)
        if chat_data and chat_data.header and chat_data.header.chat_metadata then
            chat_data.header.chat_metadata.connection_id = conn.id
            if pr.preset_id then
                chat_data.header.chat_metadata.preset_id = pr.preset_id
            end
            Storage.save_chat(path, chat_data.header, chat_data.messages)
        end
    end
    self:refresh(true)
end

function App:switch_profile()
    local Sheets = require("ktui/sheets")
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")

    local profiles = Storage.list_profiles()
    if #profiles == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No profiles yet - save one from this menu first."),
            timeout = 4,
        })
        return
    end
    local self_ref = self
    local current_conn_id = self.state.current_connection and self.state.current_connection.id
    local current_preset = self:active_preset()
    local items = {}
    for _, pr in ipairs(profiles) do
        local conn_name = "?"
        for _, c in ipairs(Storage.list_connections()) do
            if c.id == pr.connection_id then conn_name = c.name break end
        end
        local preset_name
        if pr.preset_id then
            for _, p in ipairs(Storage.list_presets()) do
                if p.id == pr.preset_id then preset_name = p.name break end
            end
        end
        table.insert(items, {
            label = pr.name .. "  (" .. conn_name .. (preset_name and " · " .. preset_name or "") .. ")",
            checked = current_conn_id == pr.connection_id
                and (pr.preset_id == nil or (current_preset and current_preset.id == pr.preset_id)),
            on_tap = function()
                self_ref:apply_profile(pr)
            end,
        })
    end
    Sheets.show(self, { title = _("Switch Profile"), actions = items })
end

function App:delete_profile()
    local Sheets = require("ktui/sheets")
    local Modals = require("ktui/modals")
    local _ = require("gettext")

    local profiles = Storage.list_profiles()
    if #profiles == 0 then
        Modals.info(_("No profiles saved."))
        return
    end
    local self_ref = self
    local items = {}
    for i, pr in ipairs(profiles) do
        table.insert(items, {
            label = pr.name,
            on_tap = function()
                table.remove(profiles, i)
                Storage.save_profiles(profiles)
                self_ref:refresh(true)
                Modals.info(_("Profile deleted: ") .. pr.name)
            end,
        })
    end
    Sheets.show(self, { title = _("Delete Profile"), actions = items })
end

function App:save_connection_edit()
    local Modals = require("ktui/modals")
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")

    local draft = self.state.editing_connection
    if not draft then return end
    if not draft.name or draft.name == "" or not draft.base_url or draft.base_url == "" then
        Modals.info(_("Name and API URL are required."))
        return
    end

    local Storage = require("kt_storage")
    local connections = Storage.list_connections()
    local saved = false
    for i, c in ipairs(connections) do
        if c.id == draft.id then
            connections[i] = draft
            saved = true
            break
        end
    end
    if not saved then
        table.insert(connections, draft)
    end
    Storage.save_connections(connections)

    -- Keep the open chat in sync when its connection was just edited.
    if self.state.current_connection and self.state.current_connection.id == draft.id then
        self.state.current_connection = draft
    end
    self.state.editing_connection = nil
    self:go_back()
end

-- === Self-update (Settings → Updates, kebab → Check for updates) ==============
-- Two channels (stable Releases, repo snapshot per commit); install swaps
-- the plugin dir with backup + rollback, then restarts KOReader. No token.

function App:update_channel_label()
    local _ = require("gettext")
    local Update = require("kt_update")
    if Update.normalize_channel(self.state.settings and self.state.settings.update_channel) == "commits" then
        return _("Artifact (commits)")
    end
    return _("Stable")
end

function App:choose_update_channel()
    local _ = require("gettext")
    self:choose_setting("update_channel", _("Update channel"), {
        { label = _("Stable"), value = "stable", icon = "check" },
        { label = _("Artifact (commits)"), value = "commits", icon = "bolt" },
    })
end

function App:prompt_update_repo()
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self
    local Update = require("kt_update")
    local current = Util.trim(tostring(self.state.settings.update_repo or ""))
    if current == "" then
        current = Update.default_repo()
    end
    Modals.input(_("Repository"), current,
        "owner/name", _("Save"), function(text)
        text = Util.trim(tostring(text or ""))
        self_ref.state.settings.update_repo = text
        Storage.save_settings(self_ref.state.settings)
        self_ref:refresh(true)
    end)
end

function App:check_updates_now()
    local Modals = require("ktui/modals")
    local InfoMessage = require("ui/widget/infomessage")
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local self_ref = self

    local s = self.state.settings
    local Update = require("kt_update")
    local repo = Util.trim(tostring(s.update_repo or ""))
    if repo == "" then
        repo = Update.default_repo()
    end
    Modals.status(_("Checking for updates…"))
    UIManager:forceRePaint()
    local ok, res = Update.check({
        repo = repo,
        channel = Update.normalize_channel(s.update_channel),
    })
    Modals.close_status()
    if not ok then
        self.state.update_status = tostring(res)
        UIManager:show(InfoMessage:new{ text = tostring(res), timeout = 4 })
        self:refresh(true)
        return
    end
    local installed = Update.installed_build(s.installed_build)
    if not Update.is_newer(res, installed) then
        self.state.update_status = _("Up to date")
        UIManager:show(InfoMessage:new{ text = _("Up to date"), timeout = 3 })
        self:refresh(true)
        return
    end
    local tag = res.channel == "commits" and ("commits " .. tostring(res.commit or ""))
        or ("v" .. tostring(res.version or "?"))
    self.state.update_status = tag
    Sheets.show(self, { title = _("Update available"), actions = {
        { label = _("Download & install") .. " (" .. tag .. ")", icon = "download",
          on_tap = function()
            Modals.status(_("Downloading update…"))
            UIManager:forceRePaint()
            local ok2, ver = Update.install(res)
            Modals.close_status()
            if not ok2 then
                self_ref.state.update_status = tostring(ver)
                UIManager:show(InfoMessage:new{ text = tostring(ver), timeout = 4 })
                self_ref:refresh(true)
                return
            end
            local Constants = require("kt_constants")
            s.installed_build = {
                channel = res.channel,
                version = res.version or Constants.VERSION,
                commit = res.commit,
            }
            Storage.save_settings(s)
            self_ref.state.update_status = _("Up to date")
            Sheets.confirm(self_ref, {
                title = _("Update installed"),
                text = tostring(ver),
                ok_label = _("Restart now"),
                on_ok = function()
                    UIManager:restartKOReader()
                end,
            })
        end },
    } })
end

-- === Storage: usage, backup export/import, data folder ===========================
-- Memoized per data root; refresh_storage() forces a recount.

function App:get_storage_info()
    local Storage = require("kt_storage")
    local root = Storage.data_dir()
    if not self.state.storage_info or self.state.storage_root ~= root then
        local cats = Storage.disk_usage()
        local total = 0
        for _, c in ipairs(cats) do
            total = total + (c.bytes or 0)
        end
        self.state.storage_info = { root = root, total = total, cats = cats }
        self.state.storage_root = root
    end
    return self.state.storage_info
end

function App:refresh_storage()
    self.state.storage_info = nil
    self.state.storage_root = nil
    self:refresh(true)
end

function App:choose_import_file(on_pick)
    local PathChooser = require("ui/widget/pathchooser")
    local file_chooser = PathChooser:new{
        select_directory = false,
        select_file = true,
        path = "/home",
        onConfirm = function(file)
            if file and file ~= "" and on_pick then on_pick(file) end
        end,
    }
    UIManager:show(file_chooser)
end

function App:export_backup()
    local Modals = require("ktui/modals")
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    local self_ref = self
    self:choose_export_dir(function(dir)
        Modals.status(_("Exporting backup…"))
        UIManager:forceRePaint()
        local Backup = require("kt_backup")
        local Storage = require("kt_storage")
        local root = Storage.data_dir()
        local files = Backup.collect_files(root)
        local entries = {}
        for _, rel in ipairs(files) do
            if rel:sub(-1) == "/" then
                entries[#entries + 1] = { name = rel }
            else
                entries[#entries + 1] = { name = rel, path = root .. "/" .. rel }
            end
        end
        local file_count = 0
        for _, rel in ipairs(files) do
            if rel:sub(-1) ~= "/" then file_count = file_count + 1 end
        end
        entries[#entries + 1] = { name = Backup.MANIFEST_NAME, data = Backup.manifest(file_count) }
        local zip = dir .. "/kotavern-backup-" .. os.date("%Y-%m-%d-%H%M") .. ".zip"
        local ok, err = Backup.zip_write(zip, entries)
        Modals.close_status()
        if not ok then
            UIManager:show(InfoMessage:new{
                text = _("Export failed: ") .. tostring(err), timeout = 4 })
        else
            UIManager:show(InfoMessage:new{
                text = _("Backup complete") .. "\n" .. zip, timeout = 4 })
        end
        self_ref:refresh(true)
    end)
end

function App:import_backup()
    local Modals = require("ktui/modals")
    local InfoMessage = require("ui/widget/infomessage")
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local self_ref = self
    self:choose_import_file(function(path)
        if not path:lower():match("%.zip$") then
            UIManager:show(InfoMessage:new{
                text = _("Invalid backup file."), timeout = 3 })
            return
        end
        Modals.status(_("Importing backup…"))
        UIManager:forceRePaint()
        local Backup = require("kt_backup")
        local Storage = require("kt_storage")
        local root = Storage.data_dir()
        local parent = root:match("^(.*)/[^/]+$") or root
        local stage = parent .. "/.kotavern-restore-stage"
        os.execute("rm -rf '" .. stage:gsub("'", "'\"'\"'") .. "'")
        local ok, err = Backup.restore_zip(path, stage)
        local manifest = ok and Backup.read_manifest(stage) or nil
        Modals.close_status()
        if not ok or not manifest then
            os.execute("rm -rf '" .. stage:gsub("'", "'\"'\"'") .. "'")
            UIManager:show(InfoMessage:new{
                text = _("Invalid backup file."), timeout = 3 })
            return
        end
        Sheets.confirm(self_ref, {
            title = _("Import backup"),
            text = _("Replace all current data with this backup?"),
            ok_label = _("Import backup"),
            danger = true,
            on_ok = function()
                local backup_dir = parent .. "/kotavern.backup"
                os.execute("rm -rf '" .. backup_dir:gsub("'", "'\"'\"'") .. "'")
                if not os.rename(root, backup_dir) then
                    UIManager:show(InfoMessage:new{
                        text = _("Operation failed: ") .. root, timeout = 4 })
                    return
                end
                if not os.rename(stage, root) then
                    os.rename(backup_dir, root)
                    UIManager:show(InfoMessage:new{
                        text = _("Operation failed: ") .. root, timeout = 4 })
                    return
                end
                Sheets.confirm(self_ref, {
                    title = _("Restore complete"),
                    text = tostring(manifest.version or ""),
                    ok_label = _("Restart now"),
                    on_ok = function()
                        UIManager:restartKOReader()
                    end,
                })
            end,
        })
    end)
end

function App:move_data_root()
    local Modals = require("ktui/modals")
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    local self_ref = self
    self:choose_export_dir(function(dir)
        Modals.status(_("Moving data…"))
        UIManager:forceRePaint()
        local Storage = require("kt_storage")
        local ok, err = Storage.migrate_data_root(dir)
        Modals.close_status()
        if not ok then
            local msg = _("Invalid folder.")
            if err == "same" then
                msg = _("Already using this folder.")
            elseif err == "copy" then
                msg = _("Operation failed: ") .. dir
            end
            UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
            return
        end
        self_ref.state.storage_info = nil
        self_ref.state.storage_root = nil
        local Sheets = require("ktui/sheets")
        Sheets.confirm(self_ref, {
            title = _("Data folder"),
            text = dir,
            ok_label = _("Restart now"),
            on_ok = function()
                UIManager:restartKOReader()
            end,
        })
        self_ref:refresh(true)
    end)
end

-- === Navigation Shortcuts ===

function App:show_dashboard()
    self.state.page = "dashboard"
    self:refresh_characters()
    self:refresh_chats_index()
    self:refresh(true)
end

function App:show_chats()
    self:refresh_chats_index()
    -- Mark everything as seen for the nav badge (chats_unseen_count).
    self.state.settings.last_seen_chats = os.time()
    Storage.save_settings(self.state.settings)
    self:navigate("chats")
end

function App:show_settings()
    self:navigate("settings")
end

function App:show_connections()
    self:navigate("connections")
end

return App
