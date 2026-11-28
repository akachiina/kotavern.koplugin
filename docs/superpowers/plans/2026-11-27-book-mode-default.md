# Book Mode Default Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Book mode becomes the default, recommended chat mode: it leaves the Debug/Experimental category, the Appearance picker shows it unconditionally, and turning Debug Mode off no longer forces the user back to the List mode.

**Tech Stack:** Lua 5.1/LuaJIT, the canvas UI (`ktui/pages.lua`), the repo's headless harnesses.

**Spec:** `docs/superpowers/specs/2026-11-27-updates-book-default-book-look-design.md` (section "Feature 3 — Book mode becomes the default")

## Global Constraints

- Plain Lua 5.1/LuaJIT; no new dependencies.
- Never use `_` as a variable or index name.
- New user-visible strings need non-empty `msgstr` in BOTH `locales/pt_BR.po` and `locales/es.po`.
- Never call `_()` at file scope.
- Module names stay namespaced (`kt_*` at root, `ktui/*`).
- A user who explicitly picked "List" keeps it: the migration must not touch a persisted `chat_mode`.
- Verification gates for every task: `luajit -bl <file> > /dev/null`, `python3 tools/check_i18n.py`, `cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy ./luajit <repo>/tools/ui_smoke.lua` (exit 0), and `cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy ./luajit <repo>/tools/book_smoke.lua` (exit 0).

## Review Focus

- **A user who explicitly chose List before the upgrade:** their chats still open in the List mode after the update (the persisted setting wins over the new default).
- **A user who never touched the mode:** chats open in Book mode from the first launch after the update.
- **A user who turns Debug Mode off while in Book mode:** they stay in Book mode (the switch must not disappear under them).
- **The List-mode chat themes:** they must still be reachable and must still say they only affect the List mode (the Appearance page shows both look rows from now on).
- **The Debug category:** it must still paint and still hold the HTML sandbox rows — only the Book mode row leaves.

---

### Task 1: Make Book the default and free it from Debug Mode

**Files:**
- Modify: `kt_app.lua` (`SETTINGS_DEFAULTS`, `App:disable_debug_mode`)
- Modify: `ktui/pages.lua` (`Pages.settings_appearance`, `Pages.settings_appearance_chat`, `Pages.settings_debug`)
- Test: `tools/ui_smoke.lua`, `tools/book_smoke.lua`

**Interfaces:**
- Consumes: `App:set_chat_mode(mode)` (existing single writer for the setting).
- Produces:
  - `SETTINGS_DEFAULTS.chat_mode == "book"`.
  - `App:disable_debug_mode()` no longer changes `chat_mode`.
  - `Pages.settings_appearance` always renders: Theme, Font size, Chat mode, Chat themes, Dashboard (5 rows).
  - `Pages.settings_appearance_chat` renders in Book mode (no redirect).
  - `Pages.settings_debug` has no Book mode row.

- [ ] **Step 1: Change the existing smoke expectations to the NEW behavior (they fail first)**

In `tools/ui_smoke.lua`, inside the block that starts with the comment "The display mode (List | Book) is an EXPERIMENTAL feature…":

- Replace the "Without Debug Mode" case with: the fixture sets `debug_mode = false, chat_mode = "list"`, and the assertion becomes `ok(#view_nd.hitboxes == 5, "appearance: the Chat mode row shows without Debug Mode (got " .. #view_nd.hitboxes .. " rows)")`.
- Replace the "With Debug Mode" case with: the fixture sets `debug_mode = true, chat_mode = "list"`, and the assertion becomes `ok(#view_d.hitboxes == 5, "appearance: Debug Mode does not change the row count (got " .. #view_d.hitboxes .. " rows)")`.
- Replace the "Book mode" case with: the fixture sets `debug_mode = true, chat_mode = "book"`, and the assertion becomes `ok(#view_b.hitboxes == 5, "appearance: book mode keeps the chat theme launcher (got " .. #view_b.hitboxes .. " rows)")`.
- The sheet check that follows stays: `view_d.hitboxes[3].callback(0, 0)` opens the List/Book sheet (row 3 is still Chat mode) and `sheet.actions[2].on_tap()` sets "book".

In the same file, in the block that starts with the comment "The experimental book switch lives in the Debug category…":

- Delete the fixture `function app_dbg:toggle_book_mode() self._toggled = true end` and the two assertions "debug: page paints with the book mode toggle" and "debug: the first experimental row toggles book mode".
- Replace them with: paint the Debug page, assert `ok(okp_dbg, "debug: page paints without the book mode toggle")`, then assert that the first Experimental row is now the HTML sandbox by tapping `view_dbg.hitboxes[1].callback(0, 0)` and checking `app_dbg._nav == "html_test"` (the fixture must define `function app_dbg:navigate(page) self._nav = page end`, which it already does).

In `tools/book_smoke.lua`, the T19 block:

- Replace
  `ok(app.state.settings.chat_mode == "list" and app.state.settings.debug_mode == false, "T19: disabling Debug Mode forces the display mode back to List")`
  with
  `ok(app.state.settings.chat_mode == "book" and app.state.settings.debug_mode == false, "T19: disabling Debug Mode keeps the Book mode")`.

- [ ] **Step 2: Run both harnesses to verify the checks fail**

Run: `cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy ./luajit <repo>/tools/ui_smoke.lua`
Expected: FAIL on "appearance: the Chat mode row shows without Debug Mode" and on "debug: page paints without the book mode toggle"; exit non-zero.

- [ ] **Step 3: Flip the default in `kt_app.lua`**

In `SETTINGS_DEFAULTS`, change

```lua
    chat_mode = "list",        -- list | book (Debug > Experimental; Appearance > Chat mode)
```

to

```lua
    chat_mode = "book",        -- list | book (Book is the default and recommended mode)
```

- [ ] **Step 4: Stop forcing the List mode in `App:disable_debug_mode`**

Delete this block from `App:disable_debug_mode`:

```lua
    -- Book mode is an experimental feature gated by Debug Mode: leaving it
    -- armed would strand the user in a mode whose switch just disappeared.
    if self.state.settings.chat_mode == "book" then
        self:set_chat_mode("list")
    end
```

Keep the rest of the method (it still saves the settings, re-applies them, and leaves the Debug page).

- [ ] **Step 5: Rework `Pages.settings_appearance` in `ktui/pages.lua`**

- Remove the `if app.state.settings.debug_mode then` wrapper around the Chat mode row: the row is now added unconditionally, right after the Font size row.
- Change the row's `subtext` from `_("List (SillyTavern) or Book (experimental)")` to `_("List (SillyTavern) or Book (native reader)")`.
- Replace the `if app.state.settings.chat_mode ~= "book" then` wrapper around the Chat themes row with an unconditional row (the themes configure the List mode; they are visible in both modes).
- Add the "Book appearance" row in this plan ONLY as a placeholder navigation target that the Book-look plan replaces:
  `{ text = _("Book appearance"), icon = "book", callback = function() app:navigate("settings_book") end }`
  — the page itself lands in the Book-look plan; until then `app:navigate("settings_book")` paints an unknown page, which the app tolerates (it falls back to the dashboard). Prefer omitting this row in this task and adding it in the Book-look plan; if you add it, the smoke expectation of 5 rows must become 6.

- [ ] **Step 6: Unblock `Pages.settings_appearance_chat` in `ktui/pages.lua`**

Delete the redirect block:

```lua
    -- Book mode renders the chat in KOReader's own reader: the theme
    -- launcher has nothing to customize. Bounce back to Appearance instead
    -- of showing a page whose rows do nothing.
    if app.state.settings.chat_mode == "book" then
        app:navigate("settings_appearance")
        return 0
    end
```

- [ ] **Step 7: Remove the Book mode row from `Pages.settings_debug` in `ktui/pages.lua`**

Delete the row

```lua
        { text = _("Book mode"), icon = "book", toggle = true,
          subtext = _("Open chats as a native KOReader book (experimental)"),
          value = function() return app.state.settings.chat_mode == "book" end,
          callback = function() app:toggle_book_mode() end },
```

from the Experimental section. Keep `App:toggle_book_mode` in `kt_app.lua` (the harness still calls it); it simply has no UI entry.

- [ ] **Step 8: Run both harnesses to verify the checks pass**

Run: `cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy ./luajit <repo>/tools/ui_smoke.lua`
Expected: exit 0.

Run: `cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy ./luajit <repo>/tools/book_smoke.lua`
Expected: exit 0; the T19 check now reads "disabling Debug Mode keeps the Book mode".

- [ ] **Step 9: Commit**

```bash
git add kt_app.lua ktui/pages.lua tools/ui_smoke.lua tools/book_smoke.lua
git commit -m "feat(book): book mode is the default and leaves the debug category"
```

---

### Task 2: Translations and the full gate

**Files:**
- Modify: `locales/pt_BR.po`
- Modify: `locales/es.po`

**Interfaces:**
- Consumes: the msgids touched by Task 1.
- Produces: the localized catalogs.

- [ ] **Step 1: Run the i18n gate**

Run: `python3 tools/check_i18n.py`
Expected: a list of missing or empty msgids (the "Book mode" / experimental strings become unused, and "List (SillyTavern) or Book (native reader)" is new).

- [ ] **Step 2: Update both catalogs**

- Add `msgid "List (SillyTavern) or Book (native reader)"` with a non-empty `msgstr` in `locales/pt_BR.po` and `locales/es.po`.
- The now-unused msgids ("Book mode" and "Open chats as a native KOReader book (experimental)") may stay in the catalogs: the checker only requires that every msgid used in the code is translated. Leaving them is harmless; removing them is also fine as long as the checker stays green.

- [ ] **Step 3: Run the i18n gate again**

Run: `python3 tools/check_i18n.py`
Expected: exit 0.

- [ ] **Step 4: Run the syntax gate**

Run: `for f in kt_app.lua ktui/pages.lua; do luajit -bl "$f" > /dev/null || echo "FAIL $f"; done`
Expected: no output.

- [ ] **Step 5: Run both harnesses one final time**

Run: `cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy ./luajit <repo>/tools/ui_smoke.lua && cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy ./luajit <repo>/tools/book_smoke.lua`
Expected: both exit 0.

- [ ] **Step 6: Commit**

```bash
git add locales/pt_BR.po locales/es.po
git commit -m "i18n: chat mode labels"
```

---

### Manual device checklist (not a code step)

- Fresh install: opening a chat lands in the native reader (Book mode).
- A profile that previously chose List: chats still open in List mode.
- Settings → Appearance: the Chat mode row is there without arming Debug Mode, and both look rows are visible.
- Settings → Debug: no Book mode row; turning Debug Mode off while in Book mode keeps Book mode.
