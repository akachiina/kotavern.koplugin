-- Experimental screens: full UIDSL pages replacing native ones.
-- Storage: <data>/themes/screens/<name>.html (the whole screen: nodes +
-- <style>) plus an optional <name>.actions.lua (custom action hooks).
-- The gallery page lives in Debug > Experimental (pages.lua rows), with
-- per-screen Edit (device text editor) and a Reset-all at the top.
-- Screens map to native pages by name: chat, dashboard (the two ports).
-- Contract: if <name>.html exists it REPLACES the native screen paint
-- (Pages.* is only the fallback); delete the file back to native.

local UiDSL = nil -- lazy require (module graph: screens loads at settings paint)

local Screens = {}

local SCREEN_DIR_SUB = "themes/screens"

-- Native page names the gallery exposes (v1 ports). docstring-less users
-- never see the raw keys: rows carry display labels below.
Screens.PORTS = {
    {
        name = "dashboard",
        label = "Dashboard",
        desc = "Cards grid + Search/Sort/View toolbar",
    },
    {
        name = "chat",
        label = "Chat",
        desc = "Bubbles (rich text islands), composer, swipes",
    },
}

function Screens.dir()
    local Storage = require("kt_storage")
    return Storage.data_dir() .. "/" .. SCREEN_DIR_SUB
end

function Screens.ensure_dir()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or not lfs then return false end
    local function make(p)
        return pcall(function()
            if lfs.mkdir then lfs.mkdir(p) end
        end)
    end
    local parent = (Screens.dir():match("^(.*)/[^/]+$"))
    -- mkdir makes ONE level: themes/ first, then themes/screens/.
    pcall(function() if lfs.attributes(Screens.dir()) then return end
        if parent then make(parent) end
        make(Screens.dir()) end)
    return true
end

function Screens.html_path(name)
    if not name or name == "" or name:find("[/\\]") then return nil end
    return Screens.dir() .. "/" .. name .. ".html"
end

function Screens.actions_path(name)
    if not name or name == "" or name:find("[/\\]") then return nil end
    return Screens.dir() .. "/" .. name .. ".actions.lua"
end

function Screens.exists(name)
    local path = Screens.html_path(name)
    if not path then return false end
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

-- mtime for the page builder cache (nil when the file is missing: the
-- screen then renders natively and the gallery marks it "not installed").
function Screens.mtime(name)
    local path = Screens.html_path(name)
    if not path then return nil end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return nil end
    local ok, a = pcall(lfs.attributes, path, "modification")
    return ok and a or nil
end

-- Read the custom actions file: returns map (possibly empty) + errors.
-- Executed with a require-free sandbox shell: the file is Lua and TRUSTED
-- (user-owned, like themes), but load() failures surface as errors - no
-- silent dead hooks (permission errors name the file).
function Screens.load_actions(name)
    local path = Screens.actions_path(name)
    if not path then return {}, {} end
    local f = io.open(path, "r")
    if not f then return {}, {} end
    local body = f:read("*a")
    f:close()
    local errors = {}
    local chunk, err = load(body, "screens/" .. name .. ".actions", "t", {})
    if not chunk then
        errors[#errors + 1] = "actions compile: " .. tostring(err)
        return {}, errors
    end
    local ok, map = pcall(chunk)
    if not ok or type(map) ~= "table" then
        errors[#errors + 1] = "actions must return a table: "
            .. tostring(name .. ".actions.lua")
        return {}, errors
    end
    return map, errors
end

-- Reset ALL experimental screens (the gallery's top button): each file is
-- kept as .bak first (user-owned, never silently lost - same contract the
-- CSS sandbox reset honors).
function Screens.reset_all(app)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    local removed = 0
    if ok and lfs then
        local d = Screens.dir()
        local ok_dir, dir_iter, dir_state, dir_ctl = pcall(lfs.dir, d)
        if ok_dir and dir_iter then
            for f in dir_iter, dir_state, dir_ctl do
                if f:sub(-5) == ".html" then
                    local src = d .. "/" .. f
                    local srcf = io.open(src, "r")
                    if srcf then
                        local body = srcf:read("*a")
                        srcf:close()
                        local dst = io.open(src .. ".bak", "w")
                        if dst then
                            dst:write(body)
                            dst:close()
                        end
                    end
                    pcall(os.remove, src)
                    removed = removed + 1
                end
            end
        end
    end
    Screens._page_cache = nil
    return removed
end

-- Page builder: file -> UiDSL tree + sheet + errors, cached by
-- (mtime, theme, font, density) like sandbox_tree. Live binds re-resolve
-- on every read (state, not file). actions passed by the caller merge the
-- custom hooks (name.actions.lua wins precedence for clashing names).
function Screens.page(app, name, actions)
    if not app then return nil end
    local path = Screens.html_path(name)
    local mtime = Screens.mtime(name)
    local ThemeL = require("ktui/theme")
    local appearance = ThemeL.get_theme()
        .. "|" .. tostring(ThemeL.get_base_font_size())
        .. "|" .. tostring(ThemeL.get_density())
    if Screens._page_cache and Screens._page_cache[name]
        and Screens._page_cache[name].mtime == mtime
        and Screens._page_cache[name].appearance == appearance then
        local cached = Screens._page_cache[name]
        if cached.tree and app then
            UiDSL = UiDSL or require("ktui/uidsl")
            UiDSL.resolve_binds(cached.tree, app, {})
        end
        return cached.tree, cached.sheet, cached.errors
    end
    UiDSL = UiDSL or require("ktui/uidsl")
    local errors = {}
    if not mtime or not path then
        error("experimental screen has no file: " .. tostring(name), 2)
    end
    local f = io.open(path, "r")
    local html = f and f:read("*a")
    if f then f:close() end
    if not html then
        errors[#errors + 1] = "screen file unreadable: " .. tostring(path)
    end
    local tree, sheet, page_errors
    if html then
        -- Custom hooks: load and MERGE over the caller's map (custom wins).
        local custom, aerr = Screens.load_actions(name)
        for _, e in ipairs(aerr or {}) do errors[#errors + 1] = e end
        local merged = {}
        for k, v in pairs(actions or {}) do merged[k] = v end
        for k, v in pairs(custom or {}) do merged[k] = v end
        local inline_css
        tree, inline_css, page_errors = UiDSL.from_html(html, merged, {})
        for _, e in ipairs(page_errors or {}) do errors[#errors + 1] = e end
        local inline_sheet = UiDSL.parse(inline_css or "")
        sheet = UiDSL.merge_sheets(UiDSL.current_sheet(app), inline_sheet)
        tree = UiDSL.apply_styles(tree, sheet)
        UiDSL.resolve_binds(tree, app, errors)
    end
    if html then
        Screens._page_cache = Screens._page_cache or {}
        Screens._page_cache[name] = { tree = tree, sheet = sheet,
            errors = errors, mtime = mtime, appearance = appearance }
    end
    return tree, sheet, errors
end

return Screens
