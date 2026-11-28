# Book Look UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The book look gets its settings page: presets, every knob, the label renaming list, and a compact native "Book appearance" dialog reachable from the book itself — plus the Appearance row that opens it.

**Tech Stack:** Lua 5.1/LuaJIT, the canvas UI (`ktui/pages.lua`, `ktui/sheets.lua`, `ktui/widgets.lua`), native KOReader dialogs (`ktui/modals.lua`), the repo's headless harnesses.

**Spec:** `docs/superpowers/specs/2026-11-27-updates-book-default-book-look-design.md` (section "Feature 4 — Book look", the parts about the pages, the entry points and the labels)

**Depends on:** `docs/superpowers/plans/2026-11-27-book-look-engine.md` (the `BookTheme` module and the session wiring must land first).

## Global Constraints

- Plain Lua 5.1/LuaJIT; no new dependencies.
- Never use `_` as a variable or index name.
- New user-visible strings need non-empty `msgstr` in BOTH `locales/pt_BR.po` and `locales/es.po`; never call `_()` at file scope.
- Every row goes through `ktui/widgets.lua` (`Widgets.row`, `Widgets.button`, `Widgets.empty_state`); never hand-draw a row or a pill.
- Sheet/picker rows follow the `pick_row` / `toggle_row` pattern already used by `Pages.theme_edit`.
- Over the native reader only native widgets may be used: the canvas pages are reachable from the app, not from the reader.
- A theme change must refresh the open book (the session reloads it) and the canvas page.
- Verification gates for every task: `luajit -bl <file> > /dev/null`, `python3 tools/check_i18n.py`, `cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy ./luajit <repo>/tools/ui_smoke.lua` (exit 0), `cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy ./luajit <repo>/tools/book_smoke.lua` (exit 0).

## Review Focus

- **A label with a very long text:** the label row must truncate it (`Widgets.truncate`), never overflow the page.
- **A custom label that is an empty string:** it must mean "use the translated default", not "an empty button".
- **Switching a preset after hand-editing a knob:** the preset wins and the theme is marked as that preset (not "custom").
- **Editing one knob after applying a preset:** the theme is marked "custom" and the preset name no longer lies.
- **Changing the look while a book is open:** the book reloads immediately; changing it with no book open must not error.
- **The native dialog over the reader:** the quick appearance dialog must not close the reader and must not leave a dialog behind when the book is closed.
- **A reset:** "Restore defaults" must bring back the default preset, not a half-reset mix.

---

### Task 1: The app-side API for the book look

**Files:**
- Modify: `kt_app.lua`
- Test: `tools/ui_smoke.lua` (the fake app fixture)

**Interfaces:**
- Consumes: `BookTheme.normalize`, `BookTheme.from_settings`, `BookTheme.PRESETS`, `BookTheme.LABEL_KEYS` (the engine plan).
- Produces:
  - `App:book_theme() -> table` — the current normalized theme.
  - `App:set_book_theme_key(key, value)` — writes one knob, sets `preset = "custom"`, saves, refreshes the open book and the canvas.
  - `App:apply_book_preset(id)` — writes a whole preset, sets `preset = id`, saves, refreshes.
  - `App:set_book_label(key, value)` — writes (or clears, with an empty value) one label override.
  - `App:reset_book_labels()` — clears every label override.
  - `App:reset_book_look()` — restores the default preset.
  - `App:list_book_fonts() -> { { name = string, path = string } }` — the installed fonts, by NAME (the reader's `font_face` is a font name, not a path).
  - `App:choose_book_font()` — the font picker sheet.
  - `App:prompt_book_custom_css()` — the multiline CSS input.

- [ ] **Step 1: Write the failing smoke checks**

Add to the `tools/ui_smoke.lua` section for the book look:

```lua
-- === 4w-ter. The book look app API ========================================
do
    local App = require("kt_app")
    local BookTheme = require("kt_book_theme")
    local app = fake_app({ page = "settings_book" })
    app.state.settings.book_theme = { cover = false, labels = { actions = "Ações" } }
    ok(app:book_theme().cover == false,
        "book look: the app reads the stored theme")
    ok(app:book_theme().labels.actions == "Ações",
        "book look: the app reads the stored labels")
    ok(type(App.book_theme) == "function",
        "book look: the app exposes the theme API")
    for _, name in ipairs({ "set_book_theme_key", "apply_book_preset",
        "set_book_label", "reset_book_labels", "reset_book_look",
        "list_book_fonts", "choose_book_font", "prompt_book_custom_css" }) do
        ok(type(app[name]) == "function",
            "book look: the app exposes " .. name)
    end
end
```

- [ ] **Step 2: Run the harness to verify the checks fail**

Expected: FAIL on "book look: the app reads the stored theme"; exit non-zero.

- [ ] **Step 3: Implement the API in `kt_app.lua`**

Add a section near the chat-theme API:

```lua
-- === Book look (the Book-mode theme) =======================================

function App:book_theme()
    local BookTheme = require("kt_book_theme")
    return BookTheme.from_settings(self.state.settings)
end

-- Any change to the look asks the open book to reload: the generated HTML
-- and the per-document reader settings both change.
function App:_book_look_changed()
    local ok, Session = pcall(require, "kt_book_session")
    if not ok or not Session then return end
    if not Session.is_active() then return end
    local path = self.state.current_chat_path
    if not path then return end
    pcall(function()
        Session.on_chat_changed(path, { kind = "mutation" })
    end)
end

function App:_save_book_theme(theme)
    self.state.settings.book_theme = theme
    Storage.save_settings(self.state.settings)
    self:_book_look_changed()
    self:refresh(true)
end

function App:set_book_theme_key(key, value)
    local BookTheme = require("kt_book_theme")
    local theme = BookTheme.from_settings(self.state.settings)
    theme[key] = value
    theme.preset = "custom"
    self:_save_book_theme(BookTheme.normalize(theme))
end

function App:apply_book_preset(id)
    local BookTheme = require("kt_book_theme")
    for _, preset in ipairs(BookTheme.PRESETS()) do
        if preset.id == id then
            local theme = BookTheme.normalize(preset.theme)
            theme.preset = id
            self:_save_book_theme(theme)
            return true
        end
    end
    return false
end

function App:set_book_label(key, value)
    local BookTheme = require("kt_book_theme")
    local theme = BookTheme.from_settings(self.state.settings)
    local labels = {}
    for k, v in pairs(theme.labels or {}) do labels[k] = v end
    if value == nil or value == "" then
        labels[key] = nil
    else
        labels[key] = tostring(value):sub(1, 120)
    end
    theme.labels = labels
    theme.preset = "custom"
    self:_save_book_theme(BookTheme.normalize(theme))
end

function App:reset_book_labels()
    local BookTheme = require("kt_book_theme")
    local theme = BookTheme.from_settings(self.state.settings)
    theme.labels = {}
    theme.preset = "custom"
    self:_save_book_theme(BookTheme.normalize(theme))
end

function App:reset_book_look()
    return self:apply_book_preset("default")
end
```

Note: `settings.book_theme` is NOT added to `SETTINGS_DEFAULTS`: a table default would be shared by reference between every settings load. `BookTheme.from_settings` already handles the missing key.

- [ ] **Step 4: Implement the font list and the font picker**

The reader's `font_face` is a font NAME (the reader matches it against `FontList.fontinfo`), so the list must expose names:

```lua
-- The installed fonts, by NAME: the reader's per-document "font_face" is the
-- font name, not the file path.
function App:list_book_fonts()
    local out = {}
    local ok, FontList = pcall(require, "fontlist")
    if not ok or not FontList or type(FontList.fontinfo) ~= "table" then
        return out
    end
    for _, info in ipairs(FontList.fontinfo) do
        local entry = info[1]
        local path = info[2]
        if type(entry) == "table" and type(entry.name) == "string"
            and entry.name ~= "" then
            out[#out + 1] = { name = entry.name, path = tostring(path or "") }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function App:choose_book_font()
    local Sheets = require("ktui/sheets")
    local _ = require("gettext")
    local self_ref = self
    local current = self:book_theme().font_face
    local actions = {
        { label = _("Follow the reader"), checked = current == "",
          on_tap = function()
              self_ref:set_book_theme_key("font_face", "")
          end },
    }
    for _, font in ipairs(self:list_book_fonts()) do
        actions[#actions + 1] = {
            label = font.name,
            checked = current == font.name,
            on_tap = function()
                self_ref:set_book_theme_key("font_face", font.name)
            end,
        }
    end
    Sheets.show(self, { title = _("Book font"), actions = actions })
end

function App:prompt_book_custom_css()
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local self_ref = self
    Modals.input(_("Custom CSS"), self:book_theme().custom_css or "",
        _("e.g. p { margin: 0 0 4px 0; }"), _("Save"), function(text)
            self_ref:set_book_theme_key("custom_css", text)
        end, function()
            self_ref:set_book_theme_key("custom_css", "")
        end, true)
end
```

- [ ] **Step 5: Extend the smoke fixture**

In `tools/ui_smoke.lua`, add to `fake_app`:

```lua
    function app:book_theme()
        local BookTheme = require("kt_book_theme")
        return BookTheme.from_settings(self.state.settings)
    end
    function app:set_book_theme_key(key, value)
        self._book_key = key
        self._book_value = value
    end
    function app:apply_book_preset(id) self._book_preset = id end
    function app:set_book_label(key, value) self._label_key = key end
    function app:reset_book_labels() self._labels_reset = true end
    function app:reset_book_look() self._look_reset = true end
    function app:list_book_fonts() return { { name = "Noto Sans", path = "/fonts/NotoSans.ttf" } } end
    function app:choose_book_font() end
    function app:prompt_book_custom_css() end
```

- [ ] **Step 6: Run the harness to verify the checks pass**

Expected: the new checks print `ok`; exit 0.

- [ ] **Step 7: Commit**

```bash
git add kt_app.lua tools/ui_smoke.lua
git commit -m "feat(book): app API for the book look"
```

---

### Task 2: The "Book appearance" page

**Files:**
- Modify: `ktui/pages.lua` (new `Pages.settings_book`)
- Modify: `ktui/app_view.lua` (dispatch)
- Modify: `ktui/header.lua` (page title)
- Modify: `ktui/pages.lua` (`Pages.settings_appearance`: add the row)
- Test: `tools/ui_smoke.lua`

**Interfaces:**
- Consumes: `App:book_theme`, `App:set_book_theme_key`, `App:apply_book_preset`, `App:choose_book_font`, `App:prompt_book_custom_css`, `App:reset_book_look`, `BookTheme.PRESETS` (Task 1 and the engine plan).
- Produces: the page `settings_book`, reachable from Settings → Appearance → "Book appearance".

- [ ] **Step 1: Write the failing smoke checks**

Add to `tools/ui_smoke.lua`:

```lua
-- === 4w-quater. The book appearance page ===================================
do
    local app = fake_app({ page = "settings_book",
        settings = { chat_mode = "book", book_theme = { cover = false } } })
    function app:navigate(page) self._nav = page end
    function app:refresh() end
    local view = { app = app, hitboxes = {}, refresh = function() end }
    local bb = new_bb()
    local max_scroll = 0
    local okp, err = pcall(function()
        max_scroll = Pages.settings_book(view, bb, 0, 0, VW, VH - Theme.metrics().nav_h, 0)
    end)
    ok(okp, "book look: the page paints (" .. tostring(err) .. ")")
    -- The list only registers hitboxes for the VISIBLE rows, so the page
    -- length is asserted through the scroll extent, not through the hits.
    ok(max_scroll > 0, "book look: the page is longer than the viewport")
    ok(#view.hitboxes >= 5,
        "book look: the visible rows are tappable (got " .. #view.hitboxes .. ")")
    dump(bb, "settings_book")

    -- The preset row opens the preset sheet.
    local app2 = fake_app({ page = "settings_book", settings = {} })
    function app2:navigate(page) self._nav = page end
    function app2:apply_book_preset(id) self._preset = id end
    function app2:refresh() end
    local view2 = { app = app2, hitboxes = {}, refresh = function() end }
    Pages.settings_book(view2, new_bb(), 0, 0, VW, VH - Theme.metrics().nav_h, 0)
    view2.hitboxes[1].callback(0, 0)
    local sheet = app2.state.sheet
    ok(sheet ~= nil and #sheet.actions == 5,
        "book look: the preset sheet offers the four presets plus Custom")
    if sheet and sheet.actions[2] then
        sheet.actions[2].on_tap()
        ok(app2._preset == "novel",
            "book look: picking a preset applies it")
    end
end
```

- [ ] **Step 2: Run the harness to verify the checks fail**

Expected: FAIL on "book look: the page paints" (`Pages.settings_book` is nil); exit non-zero.

- [ ] **Step 3: Implement `Pages.settings_book` in `ktui/pages.lua`**

Follow the `Pages.theme_edit` pattern: local `pick_row`, `toggle_row` and `color_row`-style helpers that build the row tables.

The page is `Pages.settings_section(view, bb, x, y, w, h, scroll, rows)` with these rows, in this order (the section header rows use `{ section = true, text = ... }`):

1. `{ section = true, text = _("Preset") }`
   - "Book preset" — value = the current preset name (from `BookTheme.PRESETS()`, or `_("Custom")`); callback opens a sheet with the four presets plus a "Custom" entry (checked when the theme is custom). Tapping a preset calls `app:apply_book_preset(id)`.
2. `{ section = true, text = _("Page") }`
   - "Book font" — value = the font name or `_("Follow the reader")`; callback `app:choose_book_font()`.
   - "Font size" — value = the number or `_("Follow the reader")`; sheet: Follow the reader, 18, 20, 22, 24, 26, 28, 30, 32 (writes `font_size`).
   - "Line spacing" — value = the percent or `_("Follow the reader")`; sheet: Follow the reader, 90, 100, 110, 120, 130, 150 (writes `line_spacing`).
   - "Font weight" — sheet: Follow the reader (0), Regular (400), Medium (600), Bold (700) (writes `font_weight`).
   - "Margins" — sheet: Narrow, Normal, Wide (writes `margin`).
   - "Justify text" — toggle (`justify`).
   - "Hyphenation" — toggle (`hyphenate`).
   - "Paragraph spacing" — sheet: Compact, Normal, Airy (writes `paragraph_spacing`).
3. `{ section = true, text = _("Structure") }`
   - "Cover" — toggle (`cover`).
   - "Cover title" — sheet: Chat name, Character name, Both (writes `cover_title`).
   - "Show date" — toggle (`cover_date`).
   - "Go to the end link" — toggle (`cover_actions`).
   - "Table of contents" — toggle (`toc`).
   - "Message titles" — sheet: Speaker, Speaker and time, Time, Number, None (writes `message_title`).
   - "User messages" — sheet: Quote, Panel, Plain, Hidden (writes `user_style`).
   - "System messages" — sheet: Dimmed, Plain, Hidden (writes `system_style`).
   - "Show reasoning" — toggle (`show_reasoning`).
   - "Colophon" — toggle (`colophon`).
   - "Actions link per message" — toggle (`message_actions`).
   - "Separator" — sheet: Line, Ornament, Space, None (writes `separator`).
   - "Merge same speaker" — toggle (`merge_speakers`).
   - "Page break per message" — toggle (`page_break`).
   - "Drop cap" — toggle (`drop_cap`).
4. `{ section = true, text = _("Content") }`
   - "Code blocks" — sheet: Boxed, Indented, Plain (writes `code_style`).
   - "Table borders" — toggle (`table_border`).
   - "Spoilers" — sheet: Masked, Reveal (writes `spoiler`).
   - "Emoji size" — sheet: Small, Normal, Large (writes `emoji_size`).
   - "Inline images" — sheet: Placeholder, Hidden (writes `inline_images`).
5. `{ section = true, text = _("Advanced") }`
   - "Custom CSS" — value = the CSS length or `_("None")`; callback `app:prompt_book_custom_css()`.
   - "Text labels" — callback `app:navigate("settings_book_labels")`.
   - "Restore defaults" — opens `Sheets.confirm` (`_("Restore defaults")`, `_("The book look goes back to the default preset. Labels are kept.")`) and calls `app:reset_book_look()` on OK.

Every row callback that writes a knob calls `app:set_book_theme_key(key, value)` (which saves, refreshes the book and repaints).

- [ ] **Step 4: Wire the page in `ktui/app_view.lua` and `ktui/header.lua`**

- `app_view.lua`: add `elseif page == "settings_book" then max_scroll = Pages.settings_book(self, bb, x, y, w, h, scroll)` next to the other settings branches.
- `header.lua`: add `settings_book = _("Book appearance")` to the settings name table.
- `ktui/pages.lua`, `Pages.settings_appearance`: add the row
  `{ text = _("Book appearance"), icon = "book", callback = function() app:navigate("settings_book") end }`
  right after the "Chat themes" row.

- [ ] **Step 5: Run the harness to verify the checks pass**

Expected: the new checks print `ok`; exit 0.

- [ ] **Step 6: Commit**

```bash
git add ktui/pages.lua ktui/app_view.lua ktui/header.lua tools/ui_smoke.lua
git commit -m "feat(book): the book appearance page"
```

---

### Task 3: The label renaming page

**Files:**
- Modify: `ktui/pages.lua` (new `Pages.settings_book_labels`)
- Modify: `ktui/app_view.lua` (dispatch)
- Modify: `ktui/header.lua` (page title)
- Test: `tools/ui_smoke.lua`

**Interfaces:**
- Consumes: `BookTheme.LABEL_KEYS`, `BookTheme.label`, `App:set_book_label`, `App:reset_book_labels`.
- Produces: the page `settings_book_labels`.

- [ ] **Step 1: Write the failing smoke checks**

Add to `tools/ui_smoke.lua`:

```lua
-- === 4w-quin. The book labels page =========================================
do
    local BookTheme = require("kt_book_theme")
    local app = fake_app({ page = "settings_book_labels",
        settings = { book_theme = { labels = { actions = "Ações do livro" } } } })
    function app:navigate(page) self._nav = page end
    function app:refresh() end
    local view = { app = app, hitboxes = {}, refresh = function() end }
    local bb = new_bb()
    local max_scroll = 0
    local okp, err = pcall(function()
        max_scroll = Pages.settings_book_labels(view, bb, 0, 0, VW, VH - Theme.metrics().nav_h, 0)
    end)
    ok(okp, "book labels: the page paints (" .. tostring(err) .. ")")
    ok(max_scroll > 0, "book labels: the page is longer than the viewport")
    -- The row builder is pure, so the COMPLETE list can be checked even
    -- though the page only paints the visible rows.
    local rows = Pages.book_label_rows(app)
    ok(#rows >= #BookTheme.LABEL_KEYS,
        "book labels: every label has a row (got " .. #rows
        .. " rows for " .. #BookTheme.LABEL_KEYS .. " labels)")
    dump(bb, "settings_book_labels")
end
```

- [ ] **Step 2: Run the harness to verify the checks fail**

Expected: FAIL on "book labels: the page paints"; exit non-zero.

- [ ] **Step 3: Implement `Pages.settings_book_labels` in `ktui/pages.lua`**

- Build the rows from `BookTheme.LABEL_KEYS`, grouped by the entry's `group` (a section row per group: `_("In the book")`, `_("Speakers")`, `_("Menus")`).
- The rows live in a PURE builder so the harness can check the complete list: `function Pages.book_label_rows(app) -> table` returns the rows array; `Pages.settings_book_labels` paints that array through `Pages.settings_section`.
- Each label row: `title` = the translated default text for that key; `value` = the custom text or `_("Default")`; `callback` opens `Modals.input(title, current, _("Leave empty to use the default"), _("Save"), function(text) app:set_book_label(key, value) end)`.
- The first row is "Restore all labels" with a `Sheets.confirm` before calling `app:reset_book_labels()`.

The default text of a key is translated at paint time: look the key up in `BookTheme.LABEL_KEYS` and run `_()` on its `default_text`.

- [ ] **Step 4: Wire the page in `ktui/app_view.lua` and `ktui/header.lua`**

- `app_view.lua`: add the `settings_book_labels` branch.
- `header.lua`: add `settings_book_labels = _("Text labels")` to the settings name table.

- [ ] **Step 5: Run the harness to verify the checks pass**

Expected: the new checks print `ok`; exit 0.

- [ ] **Step 6: Commit**

```bash
git add ktui/pages.lua ktui/app_view.lua ktui/header.lua tools/ui_smoke.lua
git commit -m "feat(book): rename the book labels"
```

---

### Task 4: The native "Book appearance" dialog over the reader

**Files:**
- Modify: `kt_book_ui.lua`
- Test: `tools/book_smoke.lua`

**Interfaces:**
- Consumes: `App:book_theme`, `App:set_book_theme_key`, `BookTheme.label` (Task 1 and the engine plan).
- Produces:
  - `BookUI.book_appearance(app)` — the native quick dialog.
  - The entry "Book appearance" in `BookUI.global_actions` and in the reader's KOTavern main menu.

- [ ] **Step 1: Write the failing book_smoke checks**

Add to `tools/book_smoke.lua`, next to the T21 block that already captures `Modals.actions` calls:

```lua
-- === T30: the native book appearance dialog ================================
do
    local _ = require("gettext")
    local Modals = require("ktui/modals")
    local captured = {}
    local real_actions = Modals.actions
    Modals.actions = function(title, rows)
        captured[#captured + 1] = { title = title, rows = rows }
    end
    app.state.settings.book_theme = { font_size = 24 }
    BookUI.book_appearance(app)
    Modals.actions = real_actions
    ok(#captured == 1, "T30a: the quick dialog opens once")
    local rows = captured[1] and captured[1].rows or {}
    ok(#rows >= 7, "T30b: the quick dialog carries the common knobs (got "
        .. #rows .. " rows)")
    local size_row = find_row(rows, "Font size")
    ok(size_row ~= nil, "T30c: the font size row is there")
    if size_row then
        size_row.callback()
        ok(#captured == 2, "T30d: the font size row opens its picker")
        local picker = captured[2] and captured[2].rows or {}
        local pick = find_row(picker, "22")
        if pick then pick.callback() end
        ok(app.state.settings.book_theme.font_size == 22,
            "T30e: the picker writes the book theme")
    end
    app.state.settings.book_theme = nil
end
```

(The block must restore `Modals.actions` before it ends; the harness's existing T21 block does the same.)

- [ ] **Step 2: Run the harness to verify the checks fail**

Expected: FAIL on "T30a: the quick dialog opens once" (`BookUI.book_appearance` does not exist); exit non-zero.

- [ ] **Step 3: Implement `BookUI.book_appearance` in `kt_book_ui.lua`**

```lua
-- The quick appearance dialog: the knobs that matter most, reachable while
-- the reader is on top (the canvas pages are not).
function BookUI.book_appearance(app)
    local Modals = require("ktui/modals")
    local _ = require("gettext")
    local theme = app:book_theme()
    local function pick(title, current, options, on_pick)
        local rows = {}
        for _, option in ipairs(options) do
            rows[#rows + 1] = {
                text = option.label,
                checked = option.value == current,
                callback = function() on_pick(option.value) end,
            }
        end
        Modals.actions(title, rows)
    end
    Modals.actions(_("Book appearance"), {
        {
            text = _("Font size"),
            callback = function()
                pick(_("Font size"), theme.font_size, {
                    { label = _("Follow the reader"), value = 0 },
                    { label = "20", value = 20 },
                    { label = "22", value = 22 },
                    { label = "24", value = 24 },
                    { label = "28", value = 28 },
                }, function(value) app:set_book_theme_key("font_size", value) end)
            end,
        },
        {
            text = _("Line spacing"),
            callback = function()
                pick(_("Line spacing"), theme.line_spacing, {
                    { label = _("Follow the reader"), value = 0 },
                    { label = "90", value = 90 },
                    { label = "100", value = 100 },
                    { label = "115", value = 115 },
                    { label = "130", value = 130 },
                }, function(value) app:set_book_theme_key("line_spacing", value) end)
            end,
        },
        {
            text = _("Margins"),
            callback = function()
                pick(_("Margins"), theme.margin, {
                    { label = _("Narrow"), value = "narrow" },
                    { label = _("Normal"), value = "normal" },
                    { label = _("Wide"), value = "wide" },
                }, function(value) app:set_book_theme_key("margin", value) end)
            end,
        },
        {
            text = _("Message titles"),
            callback = function()
                pick(_("Message titles"), theme.message_title, {
                    { label = _("Speaker"), value = "speaker" },
                    { label = _("Speaker and time"), value = "speaker_time" },
                    { label = _("Time"), value = "time" },
                    { label = _("Number"), value = "number" },
                    { label = _("None"), value = "none" },
                }, function(value) app:set_book_theme_key("message_title", value) end)
            end,
        },
        {
            text = theme.show_reasoning and _("Hide reasoning") or _("Show reasoning"),
            callback = function()
                app:set_book_theme_key("show_reasoning", not theme.show_reasoning)
            end,
        },
        {
            text = theme.cover and _("Hide cover") or _("Show cover"),
            callback = function()
                app:set_book_theme_key("cover", not theme.cover)
            end,
        },
        {
            text = theme.colophon and _("Hide colophon") or _("Show colophon"),
            callback = function()
                app:set_book_theme_key("colophon", not theme.colophon)
            end,
        },
        {
            text = _("Full settings"),
            callback = function()
                -- The canvas pages live under the reader: close the book first.
                app:close_book_reader()
                app:navigate("settings_book")
            end,
        },
    })
end
```

- [ ] **Step 4: Add the entry to the book menus**

- In `BookUI.global_actions(app)`: add a row `{ text = _("Book appearance"), icon = "sliders", callback = function() BookUI.book_appearance(app) end }` right after the "Show/Hide reasoning" row.
- In `BookUI.add_to_main_menu(menu_items)`: add `items[#items + 1] = menu_item(_("Book appearance"), function() BookUI.book_appearance(app) end)` after the reasoning entry.

- [ ] **Step 5: Run the harness to verify the checks pass**

Expected: the T30 checks print `ok`; exit 0.

- [ ] **Step 6: Commit**

```bash
git add kt_book_ui.lua tools/book_smoke.lua
git commit -m "feat(book): quick appearance dialog over the reader"
```

---

### Task 5: Translations and the full gate

**Files:**
- Modify: `locales/pt_BR.po`
- Modify: `locales/es.po`

**Interfaces:**
- Consumes: the msgids introduced by Tasks 1–4.
- Produces: the localized catalogs.

- [ ] **Step 1: Run the i18n gate**

Run: `python3 tools/check_i18n.py`
Expected: the list of missing msgids.

- [ ] **Step 2: Translate every new msgid in both catalogs**

The new ids include at least: "Book appearance", "Text labels", "Book font", "Follow the reader", "Font size", "Line spacing", "Font weight", "Regular", "Medium", "Bold", "Margins", "Narrow", "Wide", "Justify text", "Hyphenation", "Paragraph spacing", "Compact", "Airy", "Preset", "Book preset", "Novel", "Minimal", "Custom", "Cover", "Cover title", "Chat name", "Character name", "Both", "Show date", "Go to the end link", "Table of contents", "Message titles", "Speaker", "Speaker and time", "Time", "Number", "None", "User messages", "Quote", "Panel", "Plain", "Hidden", "System messages", "Dimmed", "Show reasoning", "Hide reasoning", "Colophon", "Hide colophon", "Show cover", "Hide cover", "Actions link per message", "Separator", "Line", "Ornament", "Merge same speaker", "Page break per message", "Drop cap", "Code blocks", "Boxed", "Indented", "Table borders", "Spoilers", "Masked", "Reveal", "Emoji size", "Small", "Large", "Inline images", "Placeholder", "Restore defaults", "Restore all labels", "In the book", "Speakers", "Menus", "Default", "Leave empty to use the default", "Full settings".

- [ ] **Step 3: Run the i18n gate again**

Run: `python3 tools/check_i18n.py`
Expected: exit 0.

- [ ] **Step 4: Run the syntax gate**

Run: `for f in kt_app.lua ktui/pages.lua ktui/app_view.lua ktui/header.lua kt_book_ui.lua; do luajit -bl "$f" > /dev/null || echo "FAIL $f"; done`
Expected: no output.

- [ ] **Step 5: Run both harnesses**

Run: `cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy ./luajit <repo>/tools/ui_smoke.lua` and the same for `tools/book_smoke.lua`.
Expected: both exit 0.

- [ ] **Step 6: Commit**

```bash
git add locales/pt_BR.po locales/es.po
git commit -m "i18n: book look strings"
```

---

### Manual device checklist (not a code step)

- Settings → Appearance → Book appearance: every knob paints, the page scrolls, the presets apply.
- Change the font size while a book is open: the book reloads and the new size is visible.
- Rename "Book actions" to "Ações do livro": the in-book link AND the native dialog title change.
- The quick dialog from the book's own menu: the knobs work and the reader stays open.
- "Full settings" from the quick dialog: the book closes and the book appearance page opens.
