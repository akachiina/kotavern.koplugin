# List Scroll Reset and Chat Mode Label Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every list page (Home, Chats, API, Settings, and their sub-pages) open at scroll offset 0 while the chat keeps its bottom/new-message rule, and rename the "Display mode" label to "Chat mode".

**Architecture:** The scroll offset is stored per key in `app.state.scroll`; today the key is `page .. "_" .. current_chat_id` (`kt_app.lua:667-669`) and it is never reset on page entry, so a page comes back exactly where it was left — usually the bottom. The new policy: non-chat pages use the page name as their key and their offset is zeroed when the page is entered (`navigate`, `go_back`, `show_dashboard`); the chat keeps the per-chat key `chat_<id>` and its `999999` bottom sentinel. The locale change replaces the two `_("Display mode")` literals in `ktui/pages.lua` with `_("Chat mode")` and drops the orphaned PO entries.

**Tech Stack:** Lua 5.1/LuaJIT, KOReader UIManager, `locales/*.po` (KOReader gettext catalogs), existing headless UI smoke harness (`tools/ui_smoke.lua`).

**Spec:** `docs/superpowers/specs/2026-11-22-performance-scroll-book-fixes-design.md` (sections "List pages opening at the bottom", "Approaches considered" → "List scroll: reset on page entry", "Decisions", "Review Focus")

## Global Constraints

- Plain Lua 5.1/LuaJIT; no new dependencies.
- `local _` remains forbidden as a variable name (it shadows gettext).
- The chat keeps its own scroll rule: opening a chat, sending a message, and finishing a generation must still land at the bottom (`999999` sentinel, clamped by `ktui/chat_bubbles.lua:2122-2128`).
- Opening a sheet must still not move the reading position: `Sheets.show` saves the page offset and `Sheets.close` restores it when the page did not change (`ktui/sheets.lua:68-115`, `133-159`).
- New or renamed user-visible strings need a non-empty translation in **both** `locales/pt_BR.po` and `locales/es.po` (`tools/check_i18n.py` fails otherwise).
- The PO catalogs keep their current order: the header states "msgid order matches the sorted extraction in tools (do not reorder)"; only delete the orphaned entry, never move the others.
- Verification gate for every task: `luajit -bl <file> > /dev/null`, `python3 tools/check_i18n.py`, and the headless smoke harness run from `/usr/lib/koreader`.
- Do not commit or push without explicit user confirmation.

## Review Focus

- A page entered while a sheet is open: closing the sheet must not restore the old offset over the freshly reset one.
- The chat must never be reset by a page entry: `navigate("chat")` after `_load_chat_state` wrote `999999` must keep the chat at the bottom.
- A search in the Chats list must reset the Chats offset under the key that the page actually uses (`chats`, not the literal `chats_`).
- Returning from a sub-page (Back button) must open the destination page at the top, like any other entry.
- The "Chat mode" label must exist in English (passthrough), Portuguese, and Spanish, and the retired "Display mode" msgid must not linger in the catalogs.

---

### Task 1: Page-only scroll key for non-chat pages

**Files:**
- Modify: `kt_app.lua:667-669` (`App:scroll_key()`)
- Test: `tools/ui_smoke.lua` (new block, placed next to the other `App` policy blocks, e.g. after the past-chat block at `tools/ui_smoke.lua:5274-5293`)

**Interfaces:**
- Consumes: `app.state.page` and `app.state.current_chat_id`.
- Produces: `App:scroll_key()` returns the page name for every page except the chat, and `"chat_" .. tostring(current_chat_id or "")` for the chat page. No other signature changes.

- [ ] **Step 1: Write the failing test**

Add a block to `tools/ui_smoke.lua` that builds a fake app with the real class (the established harness pattern: `setmetatable({ state = { ... } }, { __index = App })`) and asserts:

1. `app.state.page = "dashboard"` → `app:scroll_key() == "dashboard"` (today it returns `"dashboard_"`).
2. `app.state.page = "chats"`, `app.state.current_chat_id = "c9"` → `app:scroll_key() == "chats"` (today: `"chats_c9"`).
3. `app.state.page = "chat"`, `app.state.current_chat_id = "c9"` → `app:scroll_key() == "chat_c9"` (unchanged — the chat keeps its per-chat key).

- [ ] **Step 2: Run the focused smoke and verify RED**

```bash
cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy \
    ./luajit /home/salada/Documentos/KOTavern/kotavern.koplugin/tools/ui_smoke.lua 2>&1 | tail -30
```

Expected: checks 1 and 2 fail (the key still carries the chat-id suffix), check 3 passes.

- [ ] **Step 3: Implement the new key composition**

Replace the body of `App:scroll_key()` (`kt_app.lua:667-669`) with:

```lua
function App:scroll_key()
    -- One scroll position per page. The chat keeps a per-chat key (each
    -- conversation has its own reading position); every other page owns a
    -- single slot named after the page.
    if self.state.page == "chat" then
        return "chat_" .. tostring(self.state.current_chat_id or "")
    end
    return self.state.page
end
```

Do not change the explicit chat writes (`kt_app.lua:2302`, `2373`, `3311` already use `"chat_" .. id`); they must keep matching the key.

- [ ] **Step 4: Run the focused smoke and verify GREEN**

Run the same command. Expected: the three new checks pass and the harness ends with `0 failures` (the harness's own fake app already used page-only keys, so the pre-existing checks stay green).

- [ ] **Step 5: Run the complete verification gate**

```bash
cd /home/salada/Documentos/KOTavern/kotavern.koplugin
luajit -bl kt_app.lua > /dev/null && echo "syntax ok"
python3 tools/check_i18n.py
cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy \
    ./luajit /home/salada/Documentos/KOTavern/kotavern.koplugin/tools/ui_smoke.lua 2>&1 | tail -3
```

Expected: "syntax ok", the i18n check passes, the harness reports `0 failures`.

- [ ] **Step 6: Commit only after explicit confirmation**

If the user asks for a commit: `git add kt_app.lua tools/ui_smoke.lua` and commit with `fix(scroll): give each page its own scroll slot`.

---

### Task 2: List pages open at the top

**Files:**
- Modify: `kt_app.lua` (new `App:_reset_page_scroll(page)`; `App:navigate` `1002-1020`; `App:go_back` `1022-1029`; `App:show_dashboard` `6752-6758`; `App:set_chats_query` `1214-1218`)
- Test: `tools/ui_smoke.lua` (extend the block added in Task 1)

**Interfaces:**
- Consumes: `App:scroll_key()` from Task 1 (page-only keys).
- Produces:
  - `App:_reset_page_scroll(page)` — zeroes `state.scroll[page]` for a non-chat page and clears the `_saved_scroll` of an open sheet so a later sheet close cannot resurrect the old offset. It does nothing for the chat page.
  - `App:navigate(page, extra)`, `App:go_back()`, and `App:show_dashboard()` call it for their destination page.

- [ ] **Step 1: Write the failing test**

Extend the Task 1 block with a fake app (`setmetatable({ state = { page = "chats", scroll = {}, sheet = nil } }, { __index = App })`) whose `refresh`, `refresh_characters`, and `refresh_chats_index` are replaced with no-ops, and assert:

1. `state.scroll.chats = 500` → `app:navigate("chats")` → `state.scroll.chats == 0`.
2. `state.page = "chat"`, `state.scroll["chat_c9"] = 999999` → `app:navigate("chat")` → `state.scroll["chat_c9"] == 999999` (the chat is never reset).
3. `state.previous_page = "settings"`, `state.scroll.settings = 500` → `app:go_back()` → `state.scroll.settings == 0`.
4. `state.scroll.dashboard = 500` → `app:show_dashboard()` → `state.scroll.dashboard == 0`.
5. `state.sheet = { _saved_scroll = { key = "chats", value = 500 } }` → `app:navigate("chats")` → `state.sheet._saved_scroll == nil`.
6. `App:set_chats_query("aria")` → `state.scroll.chats == 0` and `state.scroll["chats_"] == nil` (today the function writes the literal `"chats_"`).

- [ ] **Step 2: Run the focused smoke and verify RED**

Run the harness command from Task 1. Expected: checks 1, 3, 4, 5 and 6 fail; check 2 passes.

- [ ] **Step 3: Implement the reset**

1. Add the helper next to `App:scroll_key()` in `kt_app.lua`:

   ```lua
   -- Scroll policy: every list page opens at the top. The chat keeps its own
   -- rule (bottom / new message), so it is never reset here.
   function App:_reset_page_scroll(page)
       if not page or page == "chat" then return end
       if self.state.scroll then
           self.state.scroll[page] = 0
       end
       -- A sheet opened over the old page must not restore the old offset
       -- when it closes: the page was re-entered at the top.
       local sheet = self.state.sheet
       if sheet and sheet._saved_scroll then
           sheet._saved_scroll = nil
       end
   end
   ```

2. `App:navigate` (`kt_app.lua:1002-1020`): after `state.page = page` and the `extra` application, call `self:_reset_page_scroll(page)`.
3. `App:go_back` (`kt_app.lua:1022-1029`): after `state.page = prev`, call `self:_reset_page_scroll(prev)`.
4. `App:show_dashboard` (`kt_app.lua:6752-6758`): after `state.page = "dashboard"`, call `self:_reset_page_scroll("dashboard")`.
5. `App:set_chats_query` (`kt_app.lua:1214-1218`): replace the write to the literal `"chats_"` with `self.state.scroll["chats"] = 0`.

Do not touch the chat's `999999` writes (`kt_app.lua:2302`, `2373`, `2833`, `2894`, `3311`, `5139`, `5273`, `5362`, `5739`, `5978`).

- [ ] **Step 4: Run the focused smoke and verify GREEN**

Run the harness command from Task 1. Expected: all six new checks pass and the harness ends with `0 failures`.

- [ ] **Step 5: Run the complete verification gate**

Same commands as Task 1, Step 5. Expected: syntax ok, i18n ok, harness `0 failures`.

- [ ] **Step 6: Commit only after explicit confirmation**

If the user asks for a commit: `git add kt_app.lua tools/ui_smoke.lua` and commit with `fix(scroll): open list pages at the top`.

---

### Task 3: "Chat mode" label (English, Portuguese, Spanish)

**Files:**
- Modify: `ktui/pages.lua:473` and `ktui/pages.lua:484` (the Appearance row label and the picker sheet title)
- Modify: `locales/pt_BR.po` (the `Chat mode` entry at lines 1882-1883; delete the `Display mode` entry at lines 1885-1886)
- Modify: `locales/es.po` (the `Chat mode` entry at lines 1882-1883; delete the `Display mode` entry at lines 1885-1886)
- Test: `tools/ui_smoke.lua` (new static block, next to the existing source guards at `tools/ui_smoke.lua:1726-1790`)

**Interfaces:**
- Consumes: the gettext catalogs loaded by `kt_i18n.lua` (English is passthrough).
- Produces: the Appearance row and its picker sheet read "Chat mode" in English, "Modo de chat" in Portuguese, and "Modo de chat" in Spanish.

- [ ] **Step 1: Write the failing test**

Add a static block to `tools/ui_smoke.lua` that reads the source and the two catalogs from disk (the harness already reads plugin sources this way at `tools/ui_smoke.lua:1746`) and asserts:

1. `ktui/pages.lua` does not contain the literal `_("Display mode")`.
2. `ktui/pages.lua` contains `_("Chat mode")` at least twice (the row label and the sheet title).
3. `locales/pt_BR.po` contains `msgid "Chat mode"` with a non-empty `msgstr`, and does not contain `msgid "Display mode"`.
4. `locales/es.po` contains `msgid "Chat mode"` with a non-empty `msgstr`, and does not contain `msgid "Display mode"`.

Read the catalogs with a plain `io.open` + `f:read("*a")` and match the msgid/msgstr pairs with a Lua pattern that tolerates the blank line between entries.

- [ ] **Step 2: Run the focused smoke and verify RED**

Run the harness command from Task 1. Expected: checks 1 and 3 and 4 fail (the source still says "Display mode" and the catalogs still carry the entry); check 2 fails (no `_("Chat mode")` literal exists yet).

- [ ] **Step 3: Rename the source literals**

In `ktui/pages.lua`:

- Line 473 (`text = _("Display mode")`) → `text = _("Chat mode")`.
- Line 484 (`title = _("Display mode")`) → `title = _("Chat mode")`.
- Update the stale comment at line 468 so it names "Chat mode".

Keep the surrounding logic untouched: the row still opens the chat-mode picker, whose accepted values stay `"list"` and `"book"` (`kt_app.lua:2464-2472`).

- [ ] **Step 4: Update the two catalogs**

- `locales/pt_BR.po`: set the `Chat mode` msgstr to `Modo de chat` (the requested wording) and delete the two lines of the `Display mode` entry.
- `locales/es.po`: keep the `Chat mode` msgstr as `Modo de chat` and delete the two lines of the `Display mode` entry.
- Do not move any other entry: both files state that the msgid order must not be reordered.

- [ ] **Step 5: Run the focused smoke and verify GREEN**

Run the harness command from Task 1. Expected: the four new checks pass and the harness ends with `0 failures`.

- [ ] **Step 6: Run the complete verification gate**

```bash
cd /home/salada/Documentos/KOTavern/kotavern.koplugin
luajit -bl ktui/pages.lua > /dev/null && echo "syntax ok"
python3 tools/check_i18n.py
cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy \
    ./luajit /home/salada/Documentos/KOTavern/kotavern.koplugin/tools/ui_smoke.lua 2>&1 | tail -3
```

Expected: "syntax ok", the i18n check passes (it prints the number of checked msgids and exits 0), the harness reports `0 failures`.

- [ ] **Step 7: Commit only after explicit confirmation**

If the user asks for a commit: `git add ktui/pages.lua locales/pt_BR.po locales/es.po tools/ui_smoke.lua` and commit with `i18n: rename Display mode to Chat mode`.

---

### Task 4: Documentation of the scroll policy

**Files:**
- Modify: `AGENTS.md` (the "Chat content pipeline" / navigation description — add the scroll policy)
- Modify: `PLAN.md` (dated section with checkboxes; `PLAN.md` is gitignored and must not be committed)

**Interfaces:**
- Consumes: the behavior delivered by Tasks 1–3.
- Produces: the scroll policy documented for the next maintainer.

- [ ] **Step 1: Update `AGENTS.md`**

Add one sentence to the architecture notes: list pages own a single scroll slot named after the page and open at offset 0 on every entry (`navigate`, `go_back`, `show_dashboard`), while the chat keeps a per-chat slot (`chat_<id>`) and its bottom/new-message rule.

- [ ] **Step 2: Update `PLAN.md`**

Add a dated section (Portuguese, matching the file's style) with the checkboxes for the three tasks, the key change (`page` vs `page_chatid`), and the verification command.

- [ ] **Step 3: Run the complete verification gate**

```bash
cd /home/salada/Documentos/KOTavern/kotavern.koplugin
python3 tools/check_i18n.py
cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy \
    ./luajit /home/salada/Documentos/KOTavern/kotavern.koplugin/tools/ui_smoke.lua 2>&1 | tail -3
git diff --check
```

Expected: i18n ok, harness `0 failures`, no whitespace errors.

- [ ] **Step 4: Commit only after explicit confirmation**

If the user asks for a commit: `git add AGENTS.md` (never `PLAN.md` — it is gitignored) and commit with `docs(scroll): document the list-page scroll policy`.
