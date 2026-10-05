-- Generates the plugin's SVG icon assets into ../assets/.
-- Design language: 24x24 viewBox, 2px black strokes, round caps/joins
-- (Feather-style). Icons are painted at runtime by ImageWidget's NanoSVG
-- renderer (see ui/icons.lua); the black ink is re-colored / inverted there.
--
-- Run from the plugin root:  lua tools/gen_assets.lua
-- (any Lua 5.1+ works; stdlib io only)

local lfs_ok, lfs = pcall(require, "lfs")

-- Stroke icon wrapper (or a raw body when the icon needs fill-only shapes).
local function svg(body)
    return table.concat({
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"',
        ' fill="none" stroke="#000000" stroke-width="2"',
        ' stroke-linecap="round" stroke-linejoin="round">',
        body,
        "</svg>",
    }, " ")
end

local function filled_svg(body)
    return table.concat({
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"',
        ' fill="#000000" stroke="none">',
        body,
        "</svg>",
    }, " ")
end

local star_path = "M12 2.6l2.9 5.9 6.5.9-4.7 4.6 1.1 6.5L12 17.5l-5.8 3 1.1-6.5L2.6 9.4l6.5-.9z"

local ICONS = {
    -- Chrome / navigation -------------------------------------------------
    home = svg('<path d="M3 11l9-8 9 8"/><path d="M5 10v10h14V10"/><path d="M10 20v-6h4v6"/>'),
    comments = svg('<path d="M14 4H5a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h1v4l4-4h4a2 2 0 0 0 2-2z"/><path d="M18 8h1a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2h-1v4l-4-4h-3"/>'),
    chat = svg('<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>'),
    plug = svg('<path d="M9 2v5"/><path d="M15 2v5"/><path d="M7 7h10v4a5 5 0 0 1-10 0z"/><path d="M12 16v6"/>'),
    cog = svg('<circle cx="12" cy="12" r="3.5"/>' ..
        '<path d="M12 2v3"/><path d="M12 19v3"/><path d="M2 12h3"/><path d="M19 12h3"/>' ..
        '<path d="M4.9 4.9l2.1 2.1"/><path d="M17 17l2.1 2.1"/><path d="M19.1 4.9L17 7"/><path d="M7 17l-2.1 2.1"/>'),
    search = svg('<circle cx="11" cy="11" r="7"/><path d="M16.5 16.5L21 21"/>'),
    sort = svg('<path d="M4 6h12"/><path d="M4 12h8"/><path d="M4 18h5"/><path d="M17 13v7"/><path d="M14 17l3 3 3-3"/>'),
    filter = svg('<path d="M3 5h18l-7 8v6l-4-2v-4z"/>'),
    grid = svg('<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/>' ..
        '<rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>'),
    list = svg('<path d="M8 6h13"/><path d="M8 12h13"/><path d="M8 18h13"/>' ..
        '<circle cx="4" cy="6" r="1" fill="#000000" stroke="none"/>' ..
        '<circle cx="4" cy="12" r="1" fill="#000000" stroke="none"/>' ..
        '<circle cx="4" cy="18" r="1" fill="#000000" stroke="none"/>'),
    plus = svg('<path d="M12 5v14"/><path d="M5 12h14"/>'),
    times = svg('<path d="M18 6L6 18"/><path d="M6 6l12 12"/>'),
    check = svg('<path d="M20 6L9 17l-4-4"/>'),
    ["ellipsis-v"] = filled_svg('<circle cx="12" cy="5" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="12" cy="19" r="2"/>'),
    ["chev-left"] = svg('<path d="M15 18l-6-6 6-6"/>'),
    ["chev-right"] = svg('<path d="M9 18l6-6-6-6"/>'),
    ["chev-up"] = svg('<path d="M6 15l6-6 6 6"/>'),
    ["chev-down"] = svg('<path d="M6 9l6 6 6-6"/>'),
    ["double-chev-left"] = svg('<path d="M18 17l-5-5 5-5"/><path d="M11 17l-5-5 5-5"/>'),
    ["double-chev-right"] = svg('<path d="M6 17l5-5-5-5"/><path d="M13 17l5-5-5-5"/>'),
    back = svg('<path d="M19 12H5"/><path d="M12 19l-7-7 7-7"/>'),
    forward = svg('<path d="M5 12h14"/><path d="M12 5l7 7-7 7"/>'),
    ["arrow-up"] = svg('<path d="M12 19V5"/><path d="M5 12l7-7 7 7"/>'),
    ["arrow-down"] = svg('<path d="M12 5v14"/><path d="M19 12l-7 7-7-7"/>'),
    ["arrow-left"] = svg('<path d="M19 12H5"/><path d="M12 19l-7-7 7-7"/>'),
    ["arrow-right"] = svg('<path d="M5 12h14"/><path d="M12 5l7 7-7 7"/>'),

    -- Objects -------------------------------------------------------------
    user = svg('<circle cx="12" cy="8" r="4"/><path d="M4 21c0-4 3.6-6.5 8-6.5s8 2.5 8 6.5"/>'),
    star = filled_svg('<path d="' .. star_path .. '"/>'),
    ["star-empty"] = svg('<path d="' .. star_path .. '"/>'),
    trash = svg('<path d="M4 7h16"/><path d="M9 7V4h6v3"/><path d="M6 7l1 14h10l1-14"/><path d="M10 11v6"/><path d="M14 11v6"/>'),
    edit = svg('<path d="M4 20l4-1L20.5 6.5a2.1 2.1 0 0 0-3-3L5 16z"/><path d="M14.5 6.5l3 3"/>'),
    download = svg('<path d="M12 3v12"/><path d="M7 10l5 5 5-5"/><path d="M4 21h16"/>'),
    upload = svg('<path d="M12 15V3"/><path d="M7 8l5-5 5 5"/><path d="M4 21h16"/>'),
    copy = svg('<rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>'),
    eye = svg('<path d="M2 12s3.5-6 10-6 10 6 10 6-3.5 6-10 6-10-6-10-6z"/><circle cx="12" cy="12" r="3"/>'),
    tag = svg('<path d="M3 3h8l10 10-8 8L3 11z"/><circle cx="7.5" cy="7.5" r="1.2"/>'),
    random = svg('<path d="M16 3h5v5"/><path d="M4 20L21 3"/><path d="M21 16v5h-5"/><path d="M15 15l6 6"/><path d="M4 4l5 5"/>'),
    ban = svg('<circle cx="12" cy="12" r="9"/><path d="M5.5 5.5l13 13"/>'),
    wrench = svg('<path d="M14.7 6.3a4.5 4.5 0 0 0-6 6L3 18l3 3 5.7-5.7a4.5 4.5 0 0 0 6-6l-3 3-3-3z"/>'),
    refresh = svg('<path d="M21 4v6h-6"/><path d="M20.5 15a9 9 0 1 1-2.1-9.4L21 8"/>'),
    save = svg('<path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z"/><path d="M17 21v-8H7v8"/><path d="M7 3v5h8"/>'),
    folder = svg('<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>'),
    file = svg('<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/>'),
    clock = svg('<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 3"/>'),
    heart = svg('<path d="M12 21s-8-5.3-8-11a4.5 4.5 0 0 1 8-2.8A4.5 4.5 0 0 1 20 10c0 5.7-8 11-8 11z"/>'),
    bolt = svg('<path d="M13 2L4 14h6l-1 8 9-12h-6l1-8z"/>'),
    camera = svg('<path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/><circle cx="12" cy="13" r="4"/>'),
    image = svg('<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="M21 15l-5-5L5 21"/>'),
    book = svg('<path d="M12 6c-2-1.5-5-1.5-8 0v13c3-1.5 6-1.5 8 0 2-1.5 5-1.5 8 0V6c-3-1.5-6-1.5-8 0z"/><path d="M12 6v13"/>'),
    sliders = svg('<path d="M4 21v-7"/><path d="M4 10V3"/><path d="M12 21v-9"/><path d="M12 8V3"/><path d="M20 21v-5"/><path d="M20 12V3"/>' ..
        '<path d="M1 14h6"/><path d="M9 8h6"/><path d="M17 16h6"/>'),
    magic = svg('<path d="M3 21L14 10"/>' ..
        '<path d="M15 4l1-2 1 2 2 1-2 1-1 2-1-2-2-1z"/>' ..
        '<path d="M20 13l.6-1.2.6 1.2 1.2.6-1.2.6-.6 1.2-.6-1.2-1.2-.6z"/>'),

    -- Status / feedback -----------------------------------------------------
    ["question-circle"] = svg('<circle cx="12" cy="12" r="9"/><path d="M9.1 9a3 3 0 0 1 5.8 1c0 2-3 2.5-3 4"/><path d="M12 17.5h.01"/>'),
    ["info-circle"] = svg('<circle cx="12" cy="12" r="9"/><path d="M12 16v-5"/><path d="M12 8h.01"/>'),
    ["exclamation-triangle"] = svg('<path d="M10.3 3.8L1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.8a2 2 0 0 0-3.4 0z"/><path d="M12 9v4"/><path d="M12 17h.01"/>'),

    -- Brand -----------------------------------------------------------------
    logo = svg('<path d="M12 6c-2-1.5-5-1.5-8 0v13c3-1.5 6-1.5 8 0 2-1.5 5-1.5 8 0V6c-3-1.5-6-1.5-8 0z"/><path d="M12 6v13"/><path d="M18 2.5l.7-1.4.7 1.4 1.4.7-1.4.7-.7 1.4-.7-1.4-1.4-.7z"/>'),
}

local dir = arg and arg[1] or (function()
    local source = debug.getinfo(1, "S").source or ""
    return (source:match("^@(.+)/tools/gen_assets%.lua$") or ".") .. "/assets"
end)()

if lfs_ok and lfs and lfs.mkdir and not lfs.isdir(dir) then
    lfs.mkdir(dir)
end

local count = 0
for name, content in pairs(ICONS) do
    local fh = io.open(dir .. "/" .. name .. ".svg", "wb")
    if not fh then
        io.stderr:write("cannot write " .. dir .. "/" .. name .. ".svg\n")
        os.exit(1)
    end
    fh:write(content, "\n")
    fh:close()
    count = count + 1
end
io.write(string.format("gen_assets: wrote %d SVGs to %s\n", count, dir))
