# Startup and Card Parsing Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the first launch fast on a Kindle by decoding character cards with a table-driven base64 decoder, by not reading the PNG image data, by parsing card metadata only for the cards the dashboard shows, and by loading the app graph only when the plugin is opened.

**Architecture:** `kotaven_png.lua` decodes the card JSON character by character in pure Lua (35.7 ms for a 66 KB card on the harness PC) and reads every PNG chunk payload, including the hundreds of kilobytes of `IDAT` image data. The dashboard (`App:dashboard_items`) then parses **every** card before any filtering or visibility check. On top of that, `main.lua` requires `kt_launcher`, which requires `kt_app`, so the whole 23-module plugin graph (plus 45 KOReader core modules) loads during KOReader boot. The plan fixes the decoder, skips the image data, defers the card metadata to the visible cards, and defers the app graph to the first open.

**Tech Stack:** Lua 5.1/LuaJIT, `io`/`lfs`, KOReader plugin loader, existing headless UI smoke harness (`tools/ui_smoke.lua`).

**Spec:** `docs/superpowers/specs/2026-11-22-performance-scroll-book-fixes-design.md` (sections "First launch", "Approaches considered" → "First launch: table-driven base64, no IDAT, lazy card metadata" and "Boot: load the app on demand", "Decisions", "Review Focus")

## Global Constraints

- Plain Lua 5.1/LuaJIT; no new dependencies; no package manager.
- `local _` remains forbidden as a variable name (it shadows gettext).
- The PNG card format must keep working: `ccv3` wins over `chara`, both are read from uncompressed `tEXt` chunks, and the card JSON is normalized exactly as today (`kotaven_png.lua:104-169`).
- The base64 decoder must keep its current input semantics: characters outside the base64 alphabet are ignored, `=` is padding, and an incomplete trailing group is dropped.
- The dashboard must keep showing the card's own name (`display_name`), its creator, its tags, and the token estimate; the search filter must still match name, creator, and tag.
- `Launcher.open` / `Launcher.close` keep their public API: `main.lua` calls them unchanged.
- Verification gate for every task: `luajit -bl <file> > /dev/null`, `python3 tools/check_i18n.py`, and the headless smoke harness run from `/usr/lib/koreader`.
- Do not commit or push without explicit user confirmation.

## Review Focus

- A character card whose PNG has no `tEXt` chunk (a plain image): the dashboard must show it without an error and without a card name.
- A card with a JSON payload whose length is not a multiple of 3 (base64 padding cases): the decoded JSON must be identical to the original.
- A card with both `ccv3` and `chara` chunks: `ccv3` must win.
- A huge card (a 200 KB JSON): the decode must stay well under a second and must not exhaust the stack.
- A dashboard search: the filter must still match a card by creator or tag even though the metadata is parsed lazily.
- The plugin opened for the first time after this change: the app must still come up with the full UI, the i18n catalogs installed, and the Nerd Font registered.

---

### Task 1: Table-driven base64 decoder and no IDAT read

**Files:**
- Modify: `kotaven_png.lua` (`decode_base64` at `kotaven_png.lua:15-33`; the chunk loop in `Png.extract_json` at `kotaven_png.lua:36-87`)
- Test: `tools/ui_smoke.lua` (new block, next to the existing card fixture block at `tools/ui_smoke.lua:2542-2612`)

**Interfaces:**
- Consumes: the same base64 alphabet and padding rules as today's decoder.
- Produces:
  - A local `decode_base64(data)` in `kotaven_png.lua` that decodes with a 64-entry lookup table (no per-character binary expansion) and returns the same bytes as before.
  - `Png.extract_json(filepath)` that **seeks over** `IDAT` payloads instead of reading them, so the bytes read from a card PNG are the header plus the text chunks only.

- [ ] **Step 1: Write the failing test**

Add a block to `tools/ui_smoke.lua` that reuses the `b64enc` / `chunk` / `make_card` helpers of the existing fixture block (`tools/ui_smoke.lua:2547-2596`) and adds:

1. **Padding cases**: build three card PNGs whose JSON payloads have lengths `% 3` equal to 0, 1, and 2 (append a filler character to reach each case), parse each with `require("kotaven_png").parse_character(path)`, and assert the parsed `name` equals the encoded name in all three cases. Delete the fixture files afterwards.
2. **No IDAT read**: build a PNG that contains an `IDAT` chunk with a 2 MB payload **before** the `tEXt` chunk. Wrap `io.open` with a counting proxy (temporarily replacing `io.open` with a function that returns a table whose `read` counts the returned bytes and whose `seek`/`close` delegate to the real handle), call `Png.extract_json(path)`, restore `io.open`, and assert:
   - the extracted JSON is the card payload (the `tEXt` chunk is still found after the image data), and
   - the bytes read are below 200 000 (today the parser reads the whole file, so the count is above 2 000 000).
3. **Keyword precedence**: build a PNG with a `chara` tEXt chunk and a `ccv3` tEXt chunk carrying different names, and assert `parse_character` returns the `ccv3` name.
4. **A plain image**: build a PNG with only `IHDR` and `IEND` (no `tEXt`), and assert `parse_character` does not raise and returns no card name.
5. **A huge card**: build a card whose JSON is ~200 KB and assert the parse takes less than 500 ms (alarm only; the old decoder needed seconds on this payload).

Run the harness: the padding cases pass (the old decoder is correct) and the byte-count assertion fails.

- [ ] **Step 2: Run the focused smoke and verify RED**

```bash
cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy \
    ./luajit /home/salada/Documentos/KOTavern/kotavern.koplugin/tools/ui_smoke.lua 2>&1 | tail -30
```

Expected: the new "the parser does not read the image data" assertion fails (the byte count is above 2 MB); every other check passes.

- [ ] **Step 3: Replace the base64 decoder**

In `kotaven_png.lua`, replace `decode_base64` (`kotaven_png.lua:15-33`) with a table-driven implementation:

```lua
-- Base64 decode with a lookup table: the old per-character implementation
-- expanded every character into six binary digits (a 66 KB card became a
-- 500 KB intermediate string and took 35 ms per card on a PC - minutes on a
-- Kindle). The table version is ~1 ms for the same payload.
local B64_VALUES = {}
do
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 0, 63 do
        B64_VALUES[alphabet:sub(i + 1, i + 1)] = i
    end
end

local function decode_base64(data)
    if type(data) ~= "string" then return "" end
    -- Ignore everything outside the alphabet (newlines in wrapped payloads)
    -- and the padding.
    data = data:gsub("[^A-Za-z0-9+/]", "")
    local out = {}
    local n = 0
    local i = 1
    local len = #data
    while i + 3 <= len do
        local c1 = B64_VALUES[data:sub(i, i)]
        local c2 = B64_VALUES[data:sub(i + 1, i + 1)]
        local c3 = B64_VALUES[data:sub(i + 2, i + 2)]
        local c4 = B64_VALUES[data:sub(i + 3, i + 3)]
        n = n + 1
        out[n] = string.char(c1 * 4 + math.floor(c2 / 16),
            (c2 % 16) * 16 + math.floor(c3 / 4),
            (c3 % 4) * 64 + c4)
        i = i + 4
    end
    local rest = len - i + 1
    if rest == 2 then
        local c1 = B64_VALUES[data:sub(i, i)]
        local c2 = B64_VALUES[data:sub(i + 1, i + 1)]
        n = n + 1
        out[n] = string.char(c1 * 4 + math.floor(c2 / 16), (c2 % 16) * 16)
    elseif rest == 3 then
        local c1 = B64_VALUES[data:sub(i, i)]
        local c2 = B64_VALUES[data:sub(i + 1, i + 1)]
        local c3 = B64_VALUES[data:sub(i + 2, i + 2)]
        n = n + 1
        out[n] = string.char(c1 * 4 + math.floor(c2 / 16),
            (c2 % 16) * 16 + math.floor(c3 / 4), (c3 % 4) * 64)
    end
    return table.concat(out)
end
```

Note the character class drops `=` as well (padding is simply not data), so the "=" characters never reach the lookup table.

- [ ] **Step 4: Skip the image data in the chunk loop**

In `Png.extract_json` (`kotaven_png.lua:36-87`), the chunk loop reads every payload with `f:read(len)`. Change it so the `IDAT` payload is skipped with a seek instead of being read:

```lua
        local len = read_int(file)
        local typ = file:read(4)
        if typ == "IDAT" then
            -- Image data: hundreds of kilobytes per card and never needed.
            -- Seek over the payload and the CRC instead of reading them.
            file:seek("cur", len + 4)
        else
            local data = file:read(len)
            file:read(4) -- CRC
            ... existing tEXt handling with `data` ...
        end
```

Keep the existing chunk-type handling, the `ccv3`/`chara` selection, and the walk to `IEND` exactly as they are.

- [ ] **Step 5: Run the focused smoke and verify GREEN**

Run the command from Step 2. Expected: the new padding and byte-count assertions pass and the harness ends with `0 failures` (the existing dashboard fixture check at `tools/ui_smoke.lua:2605-2611` still passes).

- [ ] **Step 6: Run the complete verification gate**

```bash
cd /home/salada/Documentos/KOTavern/kotavern.koplugin
luajit -bl kotaven_png.lua > /dev/null && echo "syntax ok"
python3 tools/check_i18n.py
cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy \
    ./luajit /home/salada/Documentos/KOTavern/kotavern.koplugin/tools/ui_smoke.lua 2>&1 | tail -3
```

Expected: "syntax ok", the i18n check passes, the harness reports `0 failures`.

- [ ] **Step 7: Commit only after explicit confirmation**

If the user asks for a commit: `git add kotaven_png.lua tools/ui_smoke.lua` and commit with `perf(cards): decode card JSON with a lookup table and skip image data`.

---

### Task 2: Parse card metadata only for the cards the dashboard shows

**Files:**
- Modify: `kt_app.lua` (`App:dashboard_items` at `kt_app.lua:1285-1451`; new `App:card_meta(path)` and `App:apply_card_meta(item)`)
- Modify: `ktui/cards.lua` (`Cards.character` at `ktui/cards.lua:55-170` — apply the metadata before the caption is built)
- Test: `tools/ui_smoke.lua` (extend the block at `tools/ui_smoke.lua:2542-2612`)

**Interfaces:**
- Consumes: `Storage.list_character_files()`, `Storage.character_name_from_path(path)`, `Storage.is_favorite(path)`, `kotaven_png.parse_character(path)`, `Models.build_system_prompt(card)`.
- Produces:
  - `App:card_meta(path) -> table` — the cached dashboard metadata for one card (`version`, `creator`, `tags`, `card_name`, `tokens`), parsing the card on first use. The cache stays `state._card_cache` (keyed by path).
  - `App:apply_card_meta(item)` — fills `item.display_name`, `item.creator`, `item.tags`, `item.tokens`, `item.version` from `App:card_meta(item.path)` and merges the global `settings.tag_map` tags into a **fresh** tag list (never mutating the cached one).
  - `App:dashboard_items()` returns items with `path`, `name`, and `fav` always; the metadata is applied to every item only when a metadata-dependent filter is active (a non-empty `dashboard_query`, or a `tag:` filter). Otherwise the metadata is left to the painter.
  - `Cards.character` calls `app:apply_card_meta(item)` (guarded by `if view.app and view.app.apply_card_meta then`) before it builds the caption, so the visible cards get their name, tags, and meta line.

- [ ] **Step 1: Write the failing test**

Extend the fixture block in `tools/ui_smoke.lua` (`tools/ui_smoke.lua:2542-2612`) with a new sub-block that:

1. Writes 12 card fixtures with `make_card` (distinct paths, distinct names), and stubs `Store.list_character_files` to return them.
2. Replaces `require("kotaven_png").parse_character` with a counting wrapper (remember the original and restore it afterwards) that counts the calls.
3. Builds a fake app with the real class (`setmetatable({ state = { settings = {}, dashboard_query = "", _card_cache = nil } }, { __index = App })`) and asserts:
   - `app:dashboard_items()` returns 12 items and the parse counter is **0** (today it is 12).
   - `app:apply_card_meta(items[1])` fills `items[1].display_name` with the card's own name and makes the parse counter **1**.
4. Sets `app.state.dashboard_query = "Card 3"` and asserts `app:dashboard_items()` returns exactly the matching item and the parse counter grew by 12 (the search needs every card's metadata).
5. Removes the fixture files and restores every stub.

Also update the existing assertion at `tools/ui_smoke.lua:2605-2611`: after `items = app:dashboard_items()`, call `app:apply_card_meta(items[1])` before checking `items[1].display_name == "Real Card Name"`.

Run the harness: the new assertions fail today (the counter is 12 after `dashboard_items()`), and the updated existing assertion still passes today because `apply_card_meta` does not exist yet — make the updated assertion call it only when it exists (`if app.apply_card_meta then app:apply_card_meta(items[1]) end`) so the block fails on the new assertions, not on a missing method.

- [ ] **Step 2: Run the focused smoke and verify RED**

Run the command from Task 1, Step 2. Expected: the new "the dashboard does not parse every card" assertion fails (the counter is 12).

- [ ] **Step 3: Implement the lazy metadata**

In `kt_app.lua`:

1. Add the two methods next to `App:dashboard_items`:

   ```lua
   -- Dashboard metadata for one card, parsed on first use and cached.
   -- The old code parsed EVERY card before the filter and the visibility
   -- check; on a Kindle with a large library that was the first-launch
   -- stall (the base64 decode alone was ~200 ms per card).
   function App:card_meta(path)
       local cache = self.state._card_cache
       if not cache then
           cache = {}
           self.state._card_cache = cache
       end
       local meta = cache[path]
       if meta then return meta end
       meta = {}
       local ok, card = pcall(require("kotaven_png").parse_character, path)
       if ok and type(card) == "table" then
           meta.version = card.character_version
           meta.creator = card.creator
           meta.tags = card.tags
           meta.card_name = card.name
           -- Token estimate = only what is actually sent to the LLM
           -- (system_prompt + description + personality + scenario +
           -- post_history_instructions). Rough heuristic: 1 token = 4 chars.
           local Models = require("kt_models")
           meta.tokens = math.ceil(#Models.build_system_prompt(card) / 4)
       end
       cache[path] = meta
       return meta
   end

   -- Fill the metadata a card painter needs. The tag list is copied so the
   -- global tag_map merge never mutates the cached metadata.
   function App:apply_card_meta(item)
       if not item or not item.path then return item end
       local meta = self:card_meta(item.path)
       item.version = meta.version or ""
       item.creator = meta.creator or ""
       item.tokens = meta.tokens or 0
       local tags = {}
       for _, t in ipairs(meta.tags or {}) do tags[#tags + 1] = t end
       local global_tags = (self.state.settings.tag_map or {})[item.path]
       if type(global_tags) == "table" then
           local seen = {}
           for _, t in ipairs(tags) do seen[tostring(t)] = true end
           for _, t in ipairs(global_tags) do
               if not seen[tostring(t)] then
                   tags[#tags + 1] = t
                   seen[tostring(t)] = true
               end
           end
       end
       item.tags = tags
       -- Display the card's own name (not the file name); fall back to the
       -- file-derived name when the card has none.
       if type(meta.card_name) == "string" and meta.card_name ~= "" then
           item.display_name = meta.card_name
       else
           item.display_name = item.name
       end
       return item
   end
   ```

2. In `App:dashboard_items` (`kt_app.lua:1285-1451`): remove the parse loop (`1295-1338`) and replace it with a conditional application:

   ```lua
       -- Metadata is needed to filter by name/creator/tag. Without such a
       -- filter the cards are parsed lazily, when they are painted.
       local q = (self.state.dashboard_query or ""):lower()
       local flt = self.state.dashboard_filter or "all"
       local needs_meta = (q ~= "") or flt:match("^tag:") ~= nil
       if needs_meta then
           for _, it in ipairs(items) do
               self:apply_card_meta(it)
           end
       end
   ```

   Keep the rest of the function (query filter, favorite filter, tag filter, sorts) unchanged; the query filter and the tag filter then read `it.creator`, `it.tags`, and `it.display_name`, which `apply_card_meta` has filled.

3. In `ktui/cards.lua`, at the top of `Cards.character` (before `meta_text(item)` and `tags_text(item.tags)` are used, `ktui/cards.lua:80-81`), add:

   ```lua
       -- Lazy card metadata: the dashboard parses a card when it is painted.
       if view.app and view.app.apply_card_meta then
           view.app:apply_card_meta(item)
       end
   ```

- [ ] **Step 4: Run the focused smoke and verify GREEN**

Run the command from Task 1, Step 2. Expected: the new assertions pass (0 parses without a filter, 1 parse when a single card is painted, 12 parses with a search) and the harness ends with `0 failures`.

- [ ] **Step 5: Run the complete verification gate**

Same commands as Task 1, Step 6, with `kt_app.lua` and `ktui/cards.lua` added to the syntax check. Expected: syntax ok, i18n ok, harness `0 failures`.

- [ ] **Step 6: Commit only after explicit confirmation**

If the user asks for a commit: `git add kt_app.lua ktui/cards.lua tools/ui_smoke.lua` and commit with `perf(dashboard): parse card metadata only for the visible cards`.

---

### Task 3: Load the app graph when the plugin is opened, not at KOReader boot

**Files:**
- Modify: `kt_launcher.lua:4` (move `require("kt_app")` inside `Launcher.open`)
- Test: `tools/ui_smoke.lua` (new block placed **before** the first `require("kt_app")` in the harness, which is at `tools/ui_smoke.lua:581`)

**Interfaces:**
- Consumes: `main.lua`'s existing calls to `Launcher.open(self)` and `Launcher.close()`.
- Produces: `kt_launcher.lua` with no file-scope requires: `require("kt_app")` happens inside `Launcher.open`, the first time the plugin is opened. `Launcher.open` / `Launcher.close` keep their signatures and behavior.

- [ ] **Step 1: Write the failing test**

Add a block to `tools/ui_smoke.lua`, placed **before** the first `require("kt_app")` of the harness (line 581), that:

1. Requires `kt_launcher` and asserts `package.loaded["kt_app"] == nil` (the launcher must not pull the app graph in).
2. Reads `kt_launcher.lua` and asserts it has no file-scope `require("kt_app")` line (a line that starts with `local App = require`).

Run the harness: both assertions fail today (`kt_launcher.lua:4` requires `kt_app` at file scope).

- [ ] **Step 2: Run the focused smoke and verify RED**

Run the command from Task 1, Step 2. Expected: the new assertions fail (`package.loaded["kt_app"]` is not nil).

- [ ] **Step 3: Defer the app require**

In `kt_launcher.lua`, remove the file-scope `local App = require("kt_app")` (line 4) and require it inside `Launcher.open`:

```lua
function Launcher.open(plugin)
    if not instance then
        -- The app graph (23 plugin modules + the KOReader UI modules) loads
        -- here, not while KOReader boots: the plugin is only opened on demand.
        local App = require("kt_app")
        instance = App:new(plugin)
    end
    instance:show()
    return instance
end
```

`main.lua` keeps `local Launcher = require("kt_launcher")` — the launcher itself is tiny and stays cheap to load.

- [ ] **Step 4: Run the focused smoke and verify GREEN**

Run the command from Task 1, Step 2. Expected: the new assertions pass and the harness ends with `0 failures` (the harness's own `require("kt_app")` calls load the app directly, which is unaffected).

- [ ] **Step 5: Run the complete verification gate**

Same commands as Task 1, Step 6, with `kt_launcher.lua` added to the syntax check. Expected: syntax ok, i18n ok, harness `0 failures`.

- [ ] **Step 6: Commit only after explicit confirmation**

If the user asks for a commit: `git add kt_launcher.lua tools/ui_smoke.lua` and commit with `perf(boot): load the app graph on first open`.

---

### Task 4: Documentation of the startup path

**Files:**
- Modify: `AGENTS.md` (the architecture section — describe the lazy card metadata and the deferred app graph)
- Modify: `PLAN.md` (dated section with checkboxes; `PLAN.md` is gitignored and must not be committed)

**Interfaces:**
- Consumes: the behavior delivered by Tasks 1–3.
- Produces: the startup path documented for the next maintainer.

- [ ] **Step 1: Update `AGENTS.md`**

Add to the architecture notes: character cards are decoded with a lookup-table base64 decoder and the PNG image data is skipped (only the `tEXt` chunks are read); the dashboard parses a card's metadata only when the card is painted (a search or tag filter parses every card, because the filter needs the metadata); the app graph loads when the plugin is opened, not during KOReader boot.

- [ ] **Step 2: Update `PLAN.md`**

Add a dated section (Portuguese, matching the file's style) with the checkboxes for the three tasks, the measured numbers (base64 35.7 ms → ~1 ms per 66 KB card; the app graph 23 plugin modules moved out of the boot phase), and the verification command.

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

If the user asks for a commit: `git add AGENTS.md` (never `PLAN.md` — it is gitignored) and commit with `docs(startup): document the lazy card parsing path`.
