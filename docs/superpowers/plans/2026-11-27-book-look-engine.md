# Book Look Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Book mode gets a real theme engine: a normalized `BookTheme` schema with presets and label overrides, a generated HTML that honors the theme's structure and typography rules, and per-document reader settings (font, size, line spacing, margins) that never touch the user's global KOReader preferences.

**Tech Stack:** Lua 5.1/LuaJIT, crengine (the native reader's HTML renderer), KOReader's `DocSettings` sidecar, the repo's headless harnesses.

**Spec:** `docs/superpowers/specs/2026-11-27-updates-book-default-book-look-design.md` (section "Feature 4 — Book look", the parts about the module, the schema, the typography mapping, the structure mapping and the presets)

## Global Constraints

- Plain Lua 5.1/LuaJIT; no new dependencies.
- Never use `_` as a variable or index name.
- New user-visible strings need non-empty `msgstr` in BOTH `locales/pt_BR.po` and `locales/es.po`; never call `_()` at file scope.
- Module names stay namespaced (`kt_*` at root, `ktui/*`).
- The generated book is a pure function of the chat data plus the theme: `Book.build(data)` must stay side-effect free.
- Per-document reader settings are written ONLY for the generated book's path; the user's global reader settings and their real books must never change.
- The reader's saved position (`last_xpointer` in the sidecar) must survive every theme change.
- Verification gates for every task: `luajit -bl <file> > /dev/null`, `python3 tools/check_i18n.py`, `cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy ./luajit <repo>/tools/ui_smoke.lua` (exit 0), `cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy ./luajit <repo>/tools/book_smoke.lua` (exit 0).

## Review Focus

- **A theme change while the book is open:** the reader reloads exactly once, the new look is visible, and the reader stays on the same page/anchor.
- **A theme change that does not alter the HTML (a font-size-only change):** the book must still reload, because the reader settings changed even though the bytes did not.
- **The reader's position:** after a theme change, the reader must not jump to the cover or to page 1.
- **The user's own books:** the sidecar of a normal book must never contain our `copt_*` keys.
- **The global KOReader settings:** changing the book look must not change `G_reader_settings` (font size, margins, cre_font).
- **A malformed stored theme:** `normalize` must never throw and must never return a table with an unknown enum value.
- **A custom label with a very long text:** the label must be truncated, never overflow the dialog.
- **The emoji font:** the scoped `.ktemoji` spans must keep working after the stylesheet is rebuilt from the theme.

---

### Task 1: The `BookTheme` module (pure data)

**Files:**
- Create: `kt_book_theme.lua`
- Test: `tools/ui_smoke.lua` (new section)

**Interfaces:**
- Consumes: nothing (pure module; no KOReader UI imports).
- Produces:
  - `BookTheme.DEFAULTS` — the schema table (below).
  - `BookTheme.normalize(raw) -> table` — validated theme; never throws; unknown keys dropped.
  - `BookTheme.sig(theme) -> string` — stable serialization of every knob that changes the output.
  - `BookTheme.PRESETS() -> { { id, name, theme } }` — `default`, `novel`, `compact`, `minimal` (in that order).
  - `BookTheme.LABEL_KEYS` — ordered list of `{ key, group, default_text }`, where `default_text` is the English default (the UI translates it at paint time).
  - `BookTheme.label(theme, key, default_text) -> string` — the custom label when non-empty, else `default_text`.
  - `BookTheme.from_settings(settings) -> table` — normalized theme from `settings.book_theme`; when `settings.book_theme` is nil, `show_reasoning` is seeded from the legacy `settings.book_show_reasoning`.
  - `BookTheme.apply_reader_settings(book_path, theme) -> ok, err` — writes the per-document reader settings (Task 3).

Schema (exact keys and defaults):

```lua
BookTheme.DEFAULTS = {
    format = "kotavern-book-theme",
    version = 1,
    preset = "default",             -- default | novel | compact | minimal | custom

    font_face = "",                 -- "" = follow the reader
    font_size = 0,                  -- 0 = follow the reader
    line_spacing = 0,               -- 0 = follow the reader (percent)
    font_weight = 0,                -- 0 = follow; else 400 / 600 / 700
    margin = "normal",              -- narrow | normal | wide
    justify = true,
    hyphenate = true,
    paragraph_spacing = "normal",   -- compact | normal | airy

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

    code_style = "box",             -- box | indent | plain
    table_border = true,
    spoiler = "mask",               -- mask | reveal
    emoji_size = "normal",          -- small | normal | large
    inline_images = "placeholder",  -- placeholder | hidden
    custom_css = "",

    labels = {},
}
```

- [ ] **Step 1: Write the failing smoke checks**

Add a new section to `tools/ui_smoke.lua`:

```lua
-- === 4w-bis. Book theme: normalize, sig, presets, labels ===================
do
    local BookTheme = require("kt_book_theme")
    local t = BookTheme.normalize(nil)
    ok(t.preset == "default" and t.cover == true and t.message_title == "speaker",
        "book theme: the defaults are the current look")
    ok(t.margin == "normal" and t.user_style == "quote" and t.separator == "space",
        "book theme: the default knobs match the current book")
    local bad = BookTheme.normalize({ margin = "huge", user_style = 42,
        message_title = "speaker", font_size = 999, line_spacing = -5,
        labels = "not-a-table", custom_css = 12 })
    ok(bad.margin == "normal" and bad.user_style == "quote",
        "book theme: an unknown enum falls back to the default")
    ok(bad.font_size == 0 and bad.line_spacing == 0,
        "book theme: out-of-range numbers fall back")
    ok(type(bad.labels) == "table" and bad.custom_css == "",
        "book theme: a broken table/string never survives")

    local sig_a = BookTheme.sig({ cover = true })
    local sig_b = BookTheme.sig({ cover = false })
    ok(sig_a ~= sig_b, "book theme: the signature changes with a knob")
    ok(sig_a == BookTheme.sig({ cover = true }),
        "book theme: the signature is stable")

    local presets = BookTheme.PRESETS()
    ok(#presets == 4, "book theme: four presets ship")
    local ids = {}
    for _i, p in ipairs(presets) do ids[p.id] = true end
    ok(ids.default and ids.novel and ids.compact and ids.minimal,
        "book theme: the preset ids are default/novel/compact/minimal")
    ok(BookTheme.normalize(presets[2].theme).page_break == true,
        "book theme: the novel preset breaks pages per message")

    local theme = BookTheme.normalize({ labels = { actions = "Ações do livro" } })
    ok(BookTheme.label(theme, "actions", "Actions") == "Ações do livro",
        "book theme: a custom label wins")
    ok(BookTheme.label(theme, "go_end", "Go to the end") == "Go to the end",
        "book theme: an unset label keeps the default")
    ok(#BookTheme.LABEL_KEYS >= 20, "book theme: the label list is complete")

    local legacy = BookTheme.from_settings({ book_show_reasoning = true })
    ok(legacy.show_reasoning == true,
        "book theme: the legacy reasoning flag seeds the theme")
    ok(BookTheme.from_settings({ book_theme = { show_reasoning = false } }).show_reasoning == false,
        "book theme: an explicit theme wins over the legacy flag")
end
```

- [ ] **Step 2: Run the harness to verify the checks fail**

Expected: FAIL on "book theme: the defaults are the current look" (the module does not exist) and exit non-zero.

- [ ] **Step 3: Create `kt_book_theme.lua` with the schema and `normalize`**

The module starts with a short header comment explaining that it is the Book-mode twin of `ktui/chat_theme.lua` (pure data, no UI), then:

- `BookTheme.DEFAULTS` exactly as pinned above.
- Enum tables for the clamped fields: `MARGINS = { narrow = true, normal = true, wide = true }`, `USER_STYLES`, `SYSTEM_STYLES`, `MESSAGE_TITLES`, `SEPARATORS`, `CODE_STYLES`, `SPOILERS`, `EMOJI_SIZES`, `INLINE_IMAGES`, `COVER_TITLES`, `PARAGRAPH_SPACINGS`, `PRESET_IDS`.
- `BookTheme.normalize(raw)`:
  - `raw` is a table or `{}`.
  - copy every default, then override: `preset` (clamped to the preset ids plus `"custom"`), the enums above (falling back to the default), `font_face` (string, else `""`), `font_size` (`0..96`, else `0`), `line_spacing` (`0..200`, else `0`), `font_weight` (`0`, `400`, `600`, `700`; else `0`), booleans (`cover`, `cover_date`, `cover_actions`, `toc`, `justify`, `hyphenate`, `show_reasoning`, `colophon`, `message_actions`, `merge_speakers`, `page_break`, `drop_cap`, `table_border`), `custom_css` (string, else `""`), `labels` (a table; every value coerced to a string, every key that is not a string dropped; values longer than 120 characters truncated).
  - Never throws: wrap the whole body in `pcall` and return `BookTheme.normalize({})` on an internal error.

- [ ] **Step 4: Implement `BookTheme.sig`**

Concatenate every knob that changes the output into one string: the enums, the numbers, the booleans, the font face, the custom CSS length plus its first and last 32 characters, and the label table sorted by key with its values (so a label change also forces a rebuild). The signature must be stable for equal themes and different for any difference.

- [ ] **Step 5: Implement `BookTheme.PRESETS`**

Return a fresh table each call with four entries, in the order `default`, `novel`, `compact`, `minimal`. Each `theme` is a full table (the preset's values merged over the defaults) so `normalize(preset.theme)` is a valid theme. The exact preset values:

- `default`: the defaults, unchanged.
- `novel`: `cover = true`, `cover_title = "character"`, `toc = true`, `message_title = "speaker_time"`, `separator = "ornament"`, `page_break = true`, `drop_cap = true`, `paragraph_spacing = "airy"`, `user_style = "panel"`.
- `compact`: `cover = false`, `cover_actions = false`, `colophon = false`, `message_actions = false`, `message_title = "number"`, `separator = "none"`, `paragraph_spacing = "compact"`, `show_reasoning = false`, `user_style = "plain"`.
- `minimal`: `cover = false`, `cover_actions = false`, `colophon = false`, `message_actions = false`, `message_title = "none"`, `separator = "none"`, `toc = false`, `user_style = "plain"`, `system_style = "hidden"`, `custom_css = ""`.

- [ ] **Step 6: Implement `BookTheme.LABEL_KEYS` and `BookTheme.label`**

`BookTheme.LABEL_KEYS` is an ordered list of `{ key, group, default_text }` entries. The groups are `"book"` (in-book links), `"speaker"` and `"dialog"` (native menus). The keys and English defaults:

- book: `actions` = "Actions", `go_end` = "Go to the end", `write_next` = "Write next message", `continue_last` = "Continue last reply", `book_actions` = "Book actions".
- speaker: `you` = "You", `system` = "System", `assistant` = "Assistant".
- dialog: `book_actions_title` = "Book actions", `quick_reply` = "Quick Reply", `regenerate` = "Regenerate last reply", `go_last` = "Go to last message", `show_reasoning` = "Show reasoning", `hide_reasoning` = "Hide reasoning", `authors_note` = "Author's Note", `system_note` = "Add System Note", `impersonate` = "Impersonate", `persona` = "Persona", `preset` = "Preset", `api` = "API connection", `rename` = "Rename Chat", `export_chat` = "Export Chat", `export_txt` = "Export TXT", `open_list` = "Open in list view", `close_book` = "Close book", `end_of_chat` = "End of chat".

`BookTheme.label(theme, key, default_text)` returns `theme.labels[key]` when it is a non-empty string, else `default_text`.

- [ ] **Step 7: Implement `BookTheme.from_settings`**

```lua
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
```

- [ ] **Step 8: Run the harness to verify the checks pass**

Expected: the new checks print `ok`; exit 0.

- [ ] **Step 9: Commit**

```bash
git add kt_book_theme.lua tools/ui_smoke.lua
git commit -m "feat(book): book theme schema, presets and label overrides"
```

---

### Task 2: The generated book honors the theme

**Files:**
- Modify: `kt_book.lua`
- Test: `tools/book_smoke.lua`

**Interfaces:**
- Consumes: `BookTheme.normalize`, `BookTheme.sig`, `BookTheme.label` (Task 1).
- Produces:
  - `Book.build(data)` accepts `data.theme` (normalized theme; optional — a missing theme means the defaults) and `data.labels` (the theme's `labels` table; optional).
  - The generated HTML carries `<meta name="kotavern-book-theme" content="<sig>">` so any theme change changes the bytes.
  - `Book.build` returns the same bytes for the same data + theme.

- [ ] **Step 1: Write the failing book_smoke checks**

Add a new block to `tools/book_smoke.lua` (after the `T1..T7: content + files` section) that builds books directly with `Book.build` and asserts the HTML:

```lua
-- === T27: the book theme drives the generated HTML ==========================
do
    local BookTheme = require("kt_book_theme")
    local base_data = {
        messages = {
            { role = "user", content = "Hello", name = "User", send_date = 1700000000 },
            { role = "assistant", content = "Hi there", name = "SmokeChar",
                reasoning = "hidden thoughts" },
            { role = "system", content = "A system line" },
        },
        chat_name = "Smoke chat",
        character_name = "SmokeChar",
        persona_name = "Tester",
        created_at = 1700000000,
    }
    local function build(theme, labels)
        local data = {}
        for k, v in pairs(base_data) do data[k] = v end
        data.theme = BookTheme.normalize(theme or {})
        data.labels = labels or {}
        return Book.build(data)
    end

    local plain = build({})
    ok(plain:find('name="kotavern-book-theme"', 1, true) ~= nil,
        "T27a: the book carries the theme signature")
    ok(plain:find("A system line", 1, true) ~= nil,
        "T27b: the default theme keeps the system message")

    local no_cover = build({ cover = false })
    ok(no_cover:find('<div class="book-title">', 1, true) == nil,
        "T27c: cover = false removes the cover")
    ok(no_cover:find('<div class="book-title">', 1, true)
        ~= plain:find('<div class="book-title">', 1, true),
        "T27d: the cover toggle changes the bytes")

    local no_actions = build({ message_actions = false })
    ok(no_actions:find("kt:msg/", 1, true) == nil,
        "T27e: message_actions = false removes the per-message action link")

    local no_colophon = build({ colophon = false })
    ok(no_colophon:find("kt:menu", 1, true) == nil,
        "T27f: colophon = false removes the colophon links")

    local hidden_user = build({ user_style = "hidden" })
    ok(hidden_user:find("Hello", 1, true) == nil,
        "T27g: user_style = hidden drops the user message body")

    local titled = build({ message_title = "number" })
    ok(titled:find('<div class="message-title">', 1, true) ~= nil,
        "T27h: message_title = number still renders a title block")
    local untitled = build({ message_title = "none" })
    ok(untitled:find('<div class="message-title">', 1, true) == nil,
        "T27i: message_title = none removes the title block")

    local toc = build({ toc = true })
    ok(toc:find("<h2", 1, true) ~= nil,
        "T27j: toc = true emits real headings for the native TOC")

    local labeled = build({}, { actions = "Ações do livro" })
    ok(labeled:find("Ações do livro", 1, true) ~= nil,
        "T27k: a custom label reaches the generated HTML")

    local reasoning = build({ show_reasoning = true })
    ok(reasoning:find("hidden thoughts", 1, true) ~= nil,
        "T27l: show_reasoning = true renders the reasoning block")
    ok(plain:find("hidden thoughts", 1, true) == nil,
        "T27m: the default theme hides the reasoning")
end
```

- [ ] **Step 2: Run the harness to verify the checks fail**

Run: `cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy ./luajit <repo>/tools/book_smoke.lua`
Expected: FAIL on "T27c: cover = false removes the cover" (the theme is ignored) and on the other T27 checks; exit non-zero.

- [ ] **Step 3: Make `Book.build` read the theme**

In `kt_book.lua`:

- `local BookTheme = require("kt_book_theme")` at the top.
- In `Book.build(data)`: `local theme = BookTheme.normalize(data.theme)` and `local labels = type(data.labels) == "table" and data.labels or {}`; add a local helper `local function L(key, default) return BookTheme.label(theme, key, default) end`.
- Emit the signature meta tag right after the `<meta charset="utf-8">` line:
  `out[#out + 1] = '<meta name="kotavern-book-theme" content="' .. esc(BookTheme.sig(theme)) .. '">'`.

- [ ] **Step 4: Make the stylesheet theme-driven**

Change `stylesheet()` to `stylesheet(theme)` and build the CSS from the theme:

- Keep the existing base rules (cover, titles, quotes, tables, actions, emoji).
- `paragraph_spacing`: `compact` → `p { margin: .2em 0 .4em 0; }`, `normal` → the current `p` margins, `airy` → doubled margins.
- `justify`: when true, add `p, li, blockquote { text-align: justify; }`.
- `hyphenate`: when true, add `p, li { hyphens: auto; -webkit-hyphens: auto; }` and `html { lang: "en"; }` (best effort: if the engine ignores it, the rule is harmless).
- `separator`: `line` → `.msg + .msg { border-top: 1px solid #888; padding-top: .6em; }`, `ornament` → the same plus a centered `❧` marker paragraph, `space` → a `.6em` gap, `none` → nothing.
- `code_style`: `box` → `pre { border: 1px solid #888; padding: .3em .4em; }`, `indent` → `pre { margin-left: 1.5em; }`, `plain` → no extra rule.
- `table_border`: when false, `td, th { border: none; }`.
- `spoiler`: `mask` → the current `.ktspl` mask rules, `reveal` → `.ktspl { color: inherit !important; background: transparent !important; }` (the text is simply visible; the tap still toggles the class).
- `emoji_size`: `small` → `.ktemoji { font-size: .85em; }`, `normal` → nothing, `large` → `.ktemoji { font-size: 1.15em; }`.
- `drop_cap`: when true, `.ktdropcap { float: left; font-size: 2.2em; line-height: .9; padding-right: .08em; }`.
- `user_style`: `panel` → `.msg-user > blockquote { border: 1px solid #888; padding: .3em .5em; }`, `quote` → the current left bar, `plain` → `blockquote { border: none; padding: 0; margin: .2em 0; }`.
- `system_style`: `dim` → the current `.msg-system { opacity: .7; font-style: italic; }`, `plain` → no opacity, `hidden` → `.msg-system { display: none; }`.
- `custom_css`: appended last, verbatim, inside the same `<style>` block.

- [ ] **Step 5: Make the structure theme-driven**

In `kt_book.lua`:

- Cover: wrap the cover block in `if theme.cover then`; the title uses `theme.cover_title` (`chat` → the chat name, `character` → the character name, `both` → both, joined by ` · `); the date line only when `theme.cover_date`; the "Go to the end" link only when `theme.cover_actions`.
- `message_html(msg, index, data, theme, labels, prev)`: the title block is emitted according to `theme.message_title` (`none` → no title block; `speaker` → the speaker name; `speaker_time` → name + time; `time` → the time only; `number` → `#N`); the timestamp/`#N` meta line follows the same rule.
- `theme.merge_speakers`: when the previous message has the same role and the same speaker name, the title block is skipped.
- `theme.user_style == "hidden"`: the user message body is not rendered (the section still exists so the anchors keep their numbering).
- `theme.system_style == "hidden"`: the system message section is not rendered at all.
- `theme.show_reasoning`: replaces the old `data.show_reasoning` (keep reading `data.show_reasoning` as a fallback when `data.theme` is absent, so old callers keep working).
- `theme.message_actions`: when false, the per-message `kt:msg/N` link is not emitted.
- `theme.colophon`: when false, the colophon block is not emitted.
- `theme.toc`: when true, each message section is preceded by `<h2 class="toc-entry">` carrying the same title text (styled small by the stylesheet).
- `theme.page_break`: when true, each message section gets `style="page-break-before: always;"` (the first message keeps the cover's flow).
- `theme.drop_cap`: when true, the first character of the assistant body is wrapped in `<span class="ktdropcap">`.
- Labels: the in-book strings come from `L(key, default)`: the per-message link text is `L("actions", _("Actions"))`, the cover link `L("go_end", _("Go to the end"))`, the colophon links `L("write_next", _("Write next message"))`, `L("continue_last", _("Continue last reply"))`, `L("book_actions", _("Book actions"))`; the speaker names use `L("you", _("You"))`, `L("system", _("System"))`, `L("assistant", _("Assistant"))`.

- [ ] **Step 6: Run the harness to verify the checks pass**

Run: `cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy ./luajit <repo>/tools/book_smoke.lua`
Expected: the T27 checks print `ok`; the older T1–T26 checks still pass (the default theme reproduces today's look); exit 0.

- [ ] **Step 7: Commit**

```bash
git add kt_book.lua tools/book_smoke.lua
git commit -m "feat(book): the generated book honors the theme"
```

---

### Task 3: Per-document reader settings

**Files:**
- Modify: `kt_book_theme.lua`
- Test: `tools/book_smoke.lua`

**Interfaces:**
- Consumes: `BookTheme.normalize` (Task 1).
- Produces: `BookTheme.apply_reader_settings(book_path, theme) -> ok, err` — writes ONLY these keys into the generated book's sidecar and removes the ones the theme leaves unset:
  - `font_face` (the reader reads this key unprefixed; the prefix `copt_` is for the `Configurable` options).
  - `copt_font_size`
  - `copt_line_spacing`
  - `copt_font_base_weight`
  - `copt_h_page_margins` — a `{ left, right }` table: `narrow` → `{ 5, 5 }`, `wide` → `{ 20, 20 }`, `normal` → the key is removed (follow the reader).

- [ ] **Step 1: Write the failing book_smoke checks**

Add to the `tools/book_smoke.lua` block:

```lua
-- === T28: per-document reader settings ====================================
do
    local BookTheme = require("kt_book_theme")
    local DocSettings = require("docsettings")
    local path = Book.path_for(chat_path)
    local before_ds = DocSettings:open(path)
    local position = before_ds:readSetting("last_xpointer")
    local okp, err = BookTheme.apply_reader_settings(path,
        BookTheme.normalize({ font_size = 30, line_spacing = 120, margin = "wide" }))
    ok(okp, "T28a: the reader settings are written (" .. tostring(err) .. ")")
    local ds = DocSettings:open(path)
    ok(ds:readSetting("copt_font_size") == 30,
        "T28b: the font size lands in the sidecar")
    ok(ds:readSetting("copt_line_spacing") == 120,
        "T28c: the line spacing lands in the sidecar")
    local margins = ds:readSetting("copt_h_page_margins")
    ok(type(margins) == "table" and margins[1] == 20 and margins[2] == 20,
        "T28d: the wide margins land in the sidecar")
    ok(ds:readSetting("last_xpointer") == position,
        "T28e: writing the settings keeps the reader position")

    BookTheme.apply_reader_settings(path, BookTheme.normalize({}))
    local ds2 = DocSettings:open(path)
    ok(ds2:readSetting("copt_font_size") == nil
        and ds2:readSetting("copt_line_spacing") == nil
        and ds2:readSetting("copt_h_page_margins") == nil,
        "T28f: an empty theme removes the settings again (follow the reader)")
end
```

- [ ] **Step 2: Run the harness to verify the checks fail**

Expected: FAIL on "T28a: the reader settings are written" (the function does not exist) and exit non-zero.

- [ ] **Step 3: Implement `BookTheme.apply_reader_settings`**

In `kt_book_theme.lua`:

```lua
-- The reader's own per-document settings, written ONLY for the generated
-- book. The keys are the ones KOReader's Configurable reads (prefix
-- "copt_") plus the unprefixed "font_face" the ReaderFont module uses.
function BookTheme.margin_pair(margin)
    if margin == "narrow" then return { 5, 5 } end
    if margin == "wide" then return { 20, 20 } end
    return nil
end

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
    if not flushed then return false, "could not write the book sidecar" end
    return true
end
```

- [ ] **Step 4: Run the harness to verify the checks pass**

Expected: the T28 checks print `ok`; exit 0.

- [ ] **Step 5: Commit**

```bash
git add kt_book_theme.lua tools/book_smoke.lua
git commit -m "feat(book): per-document reader settings for the generated book"
```

---

### Task 4: The session applies the theme and the reader settings

**Files:**
- Modify: `kt_book_session.lua`
- Test: `tools/book_smoke.lua`

**Interfaces:**
- Consumes: `BookTheme.from_settings`, `BookTheme.apply_reader_settings`, `Book.build` (Tasks 1–3).
- Produces:
  - `Session.theme()` — the current normalized theme (from the app settings).
  - `Session.open` applies the reader settings before the reader opens.
  - `Session.do_refresh` applies them inside the reload window (after the old reader closed and saved its position, before the new reader opens).
  - A theme change reloads the reader exactly once, even when the HTML bytes did not change (a font-size-only change).

- [ ] **Step 1: Write the failing book_smoke checks**

Add to `tools/book_smoke.lua`:

```lua
-- === T29: a theme change reloads the reader and keeps the position =========
do
    local BookTheme = require("kt_book_theme")
    local old_theme = app.state.settings.book_theme
    app.state.settings.book_theme = { cover = false, message_title = "number" }
    local before = read_generated_book()
    local reloads = 0
    local ui = ReaderUI.instance
    local real_reload = ui.reloadDocument
    ui.reloadDocument = function(self, ...)
        reloads = reloads + 1
        return real_reload(self, ...)
    end
    Session.on_chat_changed(chat_path, { kind = "mutation" })
    UIManager:scheduleIn(1.5, function()
        ui.reloadDocument = real_reload
        local after = read_generated_book()
        ok(reloads == 1, "T29a: a theme change reloads the reader once (got "
            .. tostring(reloads) .. ")")
        ok(after ~= before and after:find('<div class="book-title">', 1, true) == nil,
            "T29b: the reloaded book carries the new theme")
        app.state.settings.book_theme = old_theme
        Session.on_chat_changed(chat_path, { kind = "mutation" })
        UIManager:scheduleIn(1.5, function()
            ok(true, "T29c: the theme was restored")
        end)
    end)
end
```

(Place this block where the harness already schedules reader interactions, next to the T13 mutation block, so the reader exists.)

- [ ] **Step 2: Run the harness to verify the checks fail**

Expected: FAIL on "T29b: the reloaded book carries the new theme" (the session ignores the theme) and exit non-zero.

- [ ] **Step 3: Pass the theme into the book**

In `kt_book_session.lua`:

- `local BookTheme = require("kt_book_theme")` at the top.
- Add `function Session.theme()` returning `BookTheme.from_settings(state.app and state.app.state and state.app.state.settings or {})`.
- In `collect()`: add `theme = Session.theme()` and `labels = theme.labels` to the returned table; keep `show_reasoning` for compatibility but make it `theme.show_reasoning`.
- In `Session.open`: build the same `theme`/`labels` into the data table it passes to `Book.build`.

- [ ] **Step 4: Apply the reader settings at the right moments**

In `kt_book_session.lua`:

- In `Session.open`, after `Book.write(chat_path, html)` and BEFORE `reader().open(book_path)`: call `BookTheme.apply_reader_settings(book_path, theme)` (ignore the failure: the book still opens, only the typography falls back to the reader's defaults).
- In `do_refresh`, inside the `ui:reloadDocument(function(file) ... end, true, function() ... end)` `after_close` callback — the window where the old reader has already closed and flushed its sidecar — call `BookTheme.apply_reader_settings(state.book_path, data.theme)` right before/after `Book.save(state.book_path, html)`.

- [ ] **Step 5: Keep the no-op reload guard honest**

In `do_refresh`, the current guard is `if current and current == html then return end`. The theme signature is part of the generated HTML (the `<meta name="kotavern-book-theme">` tag), so a theme change always changes the bytes and the guard already reloads. Keep the guard as it is, and add the signature comparison so the rule is explicit and a future change to the meta tag cannot silently break it:

```lua
    local current = Book.read(state.book_path)
    local current_sig = ""
    if current then
        current_sig = current:match('name="kotavern%-book%-theme" content="([^"]*)"') or ""
    end
    local new_sig = BookTheme.sig(data.theme)
    if current and current == html and current_sig == new_sig then
        return
    end
```

- [ ] **Step 6: Run the harness to verify the checks pass**

Expected: the T29 checks print `ok`; the older checks still pass; exit 0.

- [ ] **Step 7: Commit**

```bash
git add kt_book_session.lua tools/book_smoke.lua
git commit -m "feat(book): the session applies the theme and the reader settings"
```

---

### Manual device checklist (not a code step)

- Settings → the book look knobs change the generated book immediately (the reader reloads on the spot, the position is kept).
- The reader's own settings (font, margins) stay untouched for the user's real books.
- The "Follow the reader" knobs really follow: change the font in the reader menu and the book follows it.
- Each preset produces a visibly different book.
- **Probe the two soft CSS knobs on the device:** turn "Justify text" and "Hyphenation" on and look at a long paragraph. crengine honors `text-align: justify`; `hyphens: auto` depends on the engine's dictionaries. If hyphenation has no effect, REMOVE the hyphenation row from the UI plan's page (a dead knob is worse than no knob) instead of shipping it.
