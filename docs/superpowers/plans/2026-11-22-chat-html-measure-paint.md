# Chat HTML Measure/Paint Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the chat HTML renderer from freezing on long chats by measuring every message with a layout-only MuPDF pass and building the tall bitmap only for the messages that are actually visible.

**Architecture:** `ktui/chat_bubbles.lua` currently builds, for every message, a MuPDF document *and* its tall bitmap during the measure pass (probe layout → relayout at `pages * 96` → `_render()` → `scan_bottom`). The new split keeps a layout-only measure (transparent CSS + `getSinglePageHeight()`, no bitmap) in the measure pass and moves the bitmap build into the paint pass, where only visible messages are painted. The document cache keeps the metadata (height, encoded body, CSS) so an offscreen message can be rebuilt in place when it scrolls back into view.

**Tech Stack:** Lua 5.1/LuaJIT, KOReader `HtmlBoxWidget` + MuPDF (`getSinglePageHeight`, `openPage`), existing headless UI smoke harness (`tools/ui_smoke.lua`).

**Spec:** `docs/superpowers/specs/2026-11-22-performance-scroll-book-fixes-design.md` (sections "Chat HTML freeze", "Approaches considered" → "1. Split measure from paint", "Decisions", "Review Focus")

## Global Constraints

- Plain Lua 5.1/LuaJIT; no new dependencies; no package manager.
- `local _` remains forbidden as a variable name (it shadows gettext).
- The chat must keep rendering through MuPDF HTML with the canvas fallback for every failure (failed layout, failed build, failed blit) — a blank bubble is never acceptable.
- The chat document cache key composition must not change: same content digest, width, theme signature, panel background, reveal signatures, and CSS extra (`ktui/chat_bubbles.lua:994-1007`).
- The measured height must stay within 12 px of the rendered truth (the current regression asserts 8 px against a `scan_bottom` truth; the layout-only measure returns the content box bottom, which is the same value within a few pixels).
- KOReader runtime is `/usr/lib/koreader` (installed version `v2026.07.1`, MuPDF wrapper `1.27.2`); `HtmlBoxWidget:getSinglePageHeight()` and `Page:getUsedBBox()` exist there.
- Verification gate for every task: `luajit -bl <file> > /dev/null` for each touched `.lua`, `python3 tools/check_i18n.py`, and the headless smoke harness run from `/usr/lib/koreader`.
- Do not commit or push without explicit user confirmation.

## Review Focus

- A message whose MuPDF layout fails (unsupported HTML, MuPDF error): the bubble must show the canvas fallback text, not a blank bubble and not a crash.
- A very long message (taller than the measure probe): the measured height must not be capped at the probe height, and no bitmap may be built for it while it is offscreen.
- A streaming partial: the partial body keeps rendering through the same path with no flicker and no stale height.
- A spoiler/details reveal inside one message: only that message is re-measured; the other messages keep their cached heights.
- A message whose visible band is partially clipped: the source offset math (`band_h`, `src_y`, `copy_h`) must still blit the right rows of the document bitmap.
- The reasoning band (expanded `extra.reasoning`): if the visible build fails, the band must fall back to text instead of painting an empty strip.
- A link tap inside an HTML bubble (`kt:spl:`, `kt:det:`, `http(s)://`): the widget must exist at tap time, and a tap on a message whose build failed must not crash.

---

### Task 1: Layout-only height measurement helper

**Files:**
- Modify: `ktui/kthtml.lua` (add `KtHTML.MEASURE_H`, `KtHTML.MEASURE_CSS`, `KtHTML.measure_body`)
- Test: `tools/ui_smoke.lua` (new block, placed right after the existing chat-HTML renderer block at `tools/ui_smoke.lua:2707-2761`)

**Interfaces:**
- Consumes: KOReader `HtmlBoxWidget` (`setContent`, `getSinglePageHeight`, `free`), `Constants.PLUGIN_DIR .. "/assets"` as the HTML resource directory.
- Produces:
  - `KtHTML.MEASURE_H = 65536` — probe page height for the layout-only measurement.
  - `KtHTML.MEASURE_CSS` — CSS appended to the measurement stylesheet so the used box contains the content only: `"\nhtml,body{background:transparent !important;} *{background:transparent !important;}"`.
  - `KtHTML.measure_body(body, css, base_px, width, opts) -> height|nil` — lays the body out at `width × (opts.probe_h or KtHTML.MEASURE_H)` with `KtHTML.MEASURE_CSS` appended, and returns the content height in CSS pixels (`HtmlBoxWidget:getSinglePageHeight()`, i.e. `ceil` of the used-box bottom) or `nil` when the content does not fit a single page at the probe height. The function never renders a bitmap and always closes the MuPDF document it opened.

- [ ] **Step 1: Write the failing test**

Add a block to `tools/ui_smoke.lua` that:

1. Counts bitmap renders: wrap `HtmlBoxWidget._render` with a counter (`local orig_render = HtmlBoxWidget._render; HtmlBoxWidget._render = function(self) renders = renders + 1; return orig_render(self) end`) and restore it at the end of the block.
2. Calls `KtHTML.measure_body(ChatBubbles._test_chat_html_body(content), KtHTML.chat_css(), Theme.scale(Theme.get_base_font_size()), 460, nil)` for three bodies — a one-line paragraph, a Markdown list with a quote and a fenced code block, and a body ending with a fenced code block — and asserts the returned height is a number ≥ 16 and that `renders == 0` after the three calls.
3. Compares each measured height with the rendered truth: build a `HtmlBoxWidget` at `Geom:new{ w = 460, h = 20000 }`, `setContent` the same body with the same CSS, `_render()`, then `KtHTML.scan_bottom(widget.bb, 460, KtHTML.css_hex(Theme.chat_bg, "#ffffff"))`; assert `math.abs(measured - truth) <= 12`.
4. Asserts `KtHTML.measure_body` returns `nil` for a body taller than the probe: build one by repeating a 90-character sentence 700 times (≈ 41 000 px at width 460) and assert the call returns `nil`.

Run the harness and confirm the failure is `KtHTML.measure_body` being nil (attempt to call a nil value), not a harness error.

- [ ] **Step 2: Run the focused smoke and verify RED**

```bash
cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy \
    ./luajit /home/salada/Documentos/KOTavern/kotavern.koplugin/tools/ui_smoke.lua 2>&1 | tail -30
```

Expected: the new checks fail with "attempt to call a nil value (field 'measure_body')" and the harness exits non-zero; the pre-existing checks still pass.

- [ ] **Step 3: Implement `KtHTML.measure_body` in `ktui/kthtml.lua`**

Add next to `KtHTML.scan_bottom` (`ktui/kthtml.lua:99-131`):

- `KtHTML.MEASURE_H = 65536` and `KtHTML.MEASURE_CSS` as module constants.
- `function KtHTML.measure_body(body, css, base_px, width, opts)`:
  1. `probe = (opts and opts.probe_h) or KtHTML.MEASURE_H`.
  2. `local widget = HtmlBoxWidget:new{ dimen = Geom:new{ w = width, h = probe } }`.
  3. `widget:setContent(body, css .. KtHTML.MEASURE_CSS, base_px, false, nil, Constants.PLUGIN_DIR .. "/assets")`.
  4. `local height = (widget.page_count or 1) == 1 and widget:getSinglePageHeight() or nil`.
  5. `pcall(function() widget:free() end)` — frees the bitmap (none) and closes the MuPDF document.
  6. `return height` (a number ≥ 0, or `nil`).

Do not call `_render()` anywhere in this function. `KtHTML` already requires `HtmlBoxWidget`, `Geom`, and `Constants`; add the missing `require` only if the module does not already have it.

- [ ] **Step 4: Run the focused smoke and verify GREEN**

Run the same command. Expected: the new measurement checks pass (0 renders, heights within 12 px of the truth, `nil` for the oversized body) and the harness reports `0 failures`.

- [ ] **Step 5: Run the complete verification gate**

```bash
cd /home/salada/Documentos/KOTavern/kotavern.koplugin
luajit -bl ktui/kthtml.lua > /dev/null && echo "syntax ok"
python3 tools/check_i18n.py
cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy \
    ./luajit /home/salada/Documentos/KOTavern/kotavern.koplugin/tools/ui_smoke.lua 2>&1 | tail -3
```

Expected: "syntax ok", the i18n check passes, and the harness ends with `0 failures` (the check count is larger than the current 876).

- [ ] **Step 6: Commit only after explicit confirmation**

If the user asks for a commit: `git add ktui/kthtml.lua tools/ui_smoke.lua` and commit with `perf(chat): add layout-only HTML height measurement`.

---

### Task 2: Chat HTML measures without bitmaps and builds them on demand

**Files:**
- Modify: `ktui/chat_bubbles.lua` (`html_doc_for` → measure + on-demand build; `block_entries`; `measure_reasoning`; `layout_html_alive`; the HTML branch of `draw_blocks`; `chat_html_tap`)
- Test: `tools/ui_smoke.lua` (new block after the doc-sweep block at `tools/ui_smoke.lua:2763-2812`)

**Interfaces:**
- Consumes: `KtHTML.measure_body(body, css, base_px, width, opts)` from Task 1.
- Produces (all local to `ktui/chat_bubbles.lua`, no exported API changes):
  - `html_layout_for(app, view, content, width, revealed, det_revealed, css_extra, role) -> doc|nil` — returns the cached document metadata for that content: `{ key, height, width, tall, css, base_px, body, panel_bg, widget = nil, paint_id }`. `height` is the measured content height, `tall` is the paint height (`height + 8`), `body` is the encoded HTML, `css` is the paint stylesheet (opaque panel background), `base_px` is the layout font size. Returns `nil` when the content does not fit one page at `KtHTML.MEASURE_H` (the caller falls back to the canvas renderer).
  - `html_widget_for(view, doc) -> widget|nil` — returns the live `HtmlBoxWidget` for `doc`, building it on demand at `Geom:new{ w = doc.width, h = doc.tall }` with `doc.body` / `doc.css` / `doc.base_px` and calling `_render()` once; stores it in `doc.widget` and refreshes `doc.paint_id`. Returns `nil` when the build or the render fails (the widget is freed in that case).
  - The document cache `app.state.chat_html_docs` keeps the same key composition and the same `cap`/`n` bookkeeping; entries may have `widget == nil`.
  - HTML entries in the layout cache carry `{ kind = "html", doc_key, h, fallback }`; `entry.widget` is filled by the paint path, not by the measure pass.
  - `layout_html_alive(layout)` keeps its name but now answers "is this layout still backed by a cached document metadata?" — true when `app.state.chat_html_docs[entry.doc_key]` exists and has a numeric `height`. It must not require a live widget.

- [ ] **Step 1: Write the failing test**

Add a block to `tools/ui_smoke.lua` that paints a 50-message chat (alternating user/assistant, each with a three-line body) through `Pages.chat` and asserts:

1. `HtmlBoxWidget._render` was called at most 6 times during the paint (the visible band only). Wrap `_render` with a counter as in Task 1 and restore it afterwards.
2. `HtmlBoxWidget.setContent` was called at most `50 + 6 + 2` times (one measure per message plus one build per visible message).
3. The chat still paints ink (`ink_ratio(bb) > 300`) and registers the expected hitboxes (`count_hits(view) >= 4`).
4. The documents cache holds 50 entries and at most 6 of them carry a widget.
5. **A failing MuPDF must not blank the bubble**: wrap `HtmlBoxWidget.setContent` so it raises for one specific body (match the body text), paint a one-message chat, restore the wrapper, and assert the paint does not raise, the bubble still has ink, and the message entry is not of kind `"html"`.

Run the harness: check 1 fails today (the current code renders every message, so the count is ~50) while checks 2–5 pass.

- [ ] **Step 2: Run the focused smoke and verify RED**

Run the harness command from Task 1. Expected: the new render-count check fails with the current count (~50 renders for 50 messages); no harness error.

- [ ] **Step 3: Implement the measure/build split in `ktui/chat_bubbles.lua`**

1. Replace the body of `html_doc_for` (`ktui/chat_bubbles.lua:941-1141`) with `html_layout_for`:
   - Keep the cache-key construction exactly as it is today (`994-1007`) and the early return for a cached entry (now returning the metadata even when `widget == nil`).
   - Keep the prune block (`1044-1094`) unchanged.
   - On a miss: encode the body with `chat_html_body`, build the paint CSS (`KtHTML.chat_css(resolved)` + `css_extra`) and `base_px` exactly as today, then measure with `KtHTML.measure_body(body, css, base_px, width, nil)`.
   - `height = math.max(16, math.floor(measured + 0.5))`; when `measured` is `nil`, return `nil` (no document is cached) so the caller falls back to the canvas renderer.
   - Store the metadata `{ key, height, width, tall = height + 8, css, base_px, body, panel_bg, widget = nil, paint_id = view._chat_paint_id }` in `app.state.chat_html_docs` and increment `docs.n` as today.
   - Delete the probe/tall/`_render`/`scan_bottom` code path and the "rebuild the widget in place" branch (`1013-1037`): rebuilding now belongs to `html_widget_for`.
2. Add `html_widget_for(view, doc)`:
   - If `doc.widget` exists and `doc.widget.document` is not nil, return it.
   - Otherwise build `HtmlBoxWidget:new{ dimen = Geom:new{ w = doc.width, h = doc.tall } }`, `setContent(doc.body, doc.css, doc.base_px, false, nil, Constants.PLUGIN_DIR .. "/assets")`, and if `widget.page_count` is greater than 1 (the content did not fit the padded height) free the widget and return `nil`.
   - Call `widget:_render()`; on any error free the widget, leave `doc.widget = nil`, and return `nil`.
   - Store the widget in `doc.widget`, refresh `doc.paint_id`, and return it.
3. Add a local helper used by the paint path:
   ```lua
   local function entry_widget(view, entry)
       if entry.widget and entry.widget.document then return entry.widget end
       local docs = view.app and view.app.state and view.app.state.chat_html_docs
       local doc = docs and docs[entry.doc_key]
       if not doc then return nil end
       local widget = html_widget_for(view, doc)
       entry.widget = widget
       return widget
   end
   ```
4. In `block_entries` (`1381-1400`), call `html_layout_for` instead of `html_doc_for` and build the entry as `{ kind = "html", doc_key = doc.key, h = doc.height, pad = 0, offset = 0, fallback = block.text:gsub("<[^>]->", "") }` — the entry no longer carries a widget from the measure pass. Keep the existing canvas fallback branch for a `nil` document.
5. In `measure_reasoning` (`1812-1822`), call `html_layout_for` the same way and store `fallback = reasoning` on the entry, so a failed visible build still paints text.
6. In the HTML branch of `draw_blocks` (`1509-1555`), replace `if entry.widget and band_h > 0 then` with `if band_h > 0 then local widget = entry_widget(view, entry); if widget then ...end end`, keep the existing blit math (`src_y`, `src_h`, `copy_h`, `bb:blitFrom`), and when there is no widget paint `entry.fallback` with `P.scrollable_paragraph` exactly like the current blit-failure path (`1535-1538`). Guard the fallback with `if entry.fallback and entry.fallback ~= "" then`.
7. In `chat_html_tap` (`1234-1263`), return early when `entry.widget` is nil or its document is closed (no link lookup on a dead widget).
8. Change `layout_html_alive` (`1171-1195`) to check the document metadata (`app.state.chat_html_docs[entry.doc_key]` exists with a numeric `height`) instead of the widget's document. The fast path (`1913-1938`) keeps using it.

- [ ] **Step 4: Run the focused smoke and verify GREEN**

Run the harness command from Task 1. Expected: the new 50-message checks pass (≤ 6 renders, ≤ 58 `setContent` calls, ink present, ≤ 6 widgets cached, a failing MuPDF still paints the bubble text) and every pre-existing chat-HTML check still passes: the reasoning band (`tools/ui_smoke.lua:398-492`), the streaming partials (`1126-1294`), the doc sweep (`2763-2812`), the long-message scroll integrity (`3209-3389`), the band/source-offset integrity (`3391-3554`), the spoiler and `<details>` end-to-end blocks (`3637-3722`, `4665-4785`), and the user-message block (`4787-4815`).

If the long-message height check (`tools/ui_smoke.lua:3343-3345`) fails because the new measure returns the content-box bottom instead of the last-ink row, relax that assertion to `math.abs(measured_h - truth_h) <= 12` and keep the ink assertions around it — do not change the renderer to satisfy the old tolerance.

- [ ] **Step 5: Run the complete verification gate**

Same commands as Task 1, Step 5, plus `luajit -bl ktui/chat_bubbles.lua > /dev/null`. Expected: syntax ok, i18n ok, harness `0 failures`.

- [ ] **Step 6: Commit only after explicit confirmation**

If the user asks for a commit: `git add ktui/chat_bubbles.lua tools/ui_smoke.lua` and commit with `perf(chat): measure HTML layouts without bitmaps`.

---

### Task 3: Document cache, sweep, and rebuild semantics with widget-less documents

**Files:**
- Modify: `ktui/chat_bubbles.lua` (sweep block `2130-2177`; prune bookkeeping `1044-1094`; `invalidate_doc` `1219-1232`)
- Test: `tools/ui_smoke.lua` (extend the doc-sweep block at `tools/ui_smoke.lua:2763-2812`)

**Interfaces:**
- Consumes: the metadata produced by Task 2 (`doc.widget == nil` for documents that were never painted, `doc.height` always present).
- Produces: a document cache where the offscreen documents hold no bitmap at all, the visible ones hold exactly one, and scrolling back rebuilds the visible documents in place without growing the cache.

- [ ] **Step 1: Write the failing test**

Extend the existing doc-sweep block in `tools/ui_smoke.lua` with two assertions after the first paint (which scrolls to the bottom, `tools/ui_smoke.lua:2788`):

1. Every document whose key is not referenced by a visible layout has `widget == nil` — not merely a freed widget, but never built. Count them and assert the count is at least `total_docs - 4`.
2. After painting at scroll 0 (the top of the chat, `tools/ui_smoke.lua:2804`), the documents that were visible at the bottom now have `widget == nil` and the top ones have a widget, and the total number of document entries is unchanged (the existing "no growth" check at `2809-2811` keeps passing).

Run the harness. Expected: assertion 1 fails today (the offscreen documents were built and then freed, so their `widget` is nil but their build still happened — the assertion must therefore count *builds*, not nil widgets: instrument `HtmlBoxWidget._render` and assert that the total number of renders during the whole block is ≤ 12 for 6 messages, i.e. ≤ 2 per visible message across the three paints).

- [ ] **Step 2: Run the focused smoke and verify RED**

Run the harness command from Task 1. Expected: the new render-count assertion fails (the current code renders 6 messages on the first paint plus rebuilds on the scroll-back paint, so the count is ~12).

- [ ] **Step 3: Adjust the sweep and prune bookkeeping**

1. Sweep block (`2130-2177`): keep the visibility window (`vis_top`/`vis_bottom` with the 100 px margin) and the keep-set construction, but skip documents whose `widget` is already `nil` (nothing to free) and keep the `collectgarbage("step")` only when something was actually freed.
2. Prune bookkeeping (`1044-1094`): the prune counts metadata entries, which is unchanged; verify that removing a victim still frees its widget (`pcall(function() v.widget:free() end)`) and decrements `docs.n`.
3. `invalidate_doc` (`1219-1232`): keep deleting the metadata entry (the next paint re-measures that message) and keep freeing the widget when it exists.

- [ ] **Step 4: Run the focused smoke and verify GREEN**

Run the harness command from Task 1. Expected: the new assertions pass (≤ 12 renders across the three paints of the 6-message chat) and the whole suite ends with `0 failures`.

- [ ] **Step 5: Run the complete verification gate**

Same commands as Task 1, Step 5. Expected: syntax ok, i18n ok, harness `0 failures`.

- [ ] **Step 6: Commit only after explicit confirmation**

If the user asks for a commit: `git add ktui/chat_bubbles.lua tools/ui_smoke.lua` and commit with `perf(chat): keep offscreen chat documents bitmap-free`.

---

### Task 4: Long-chat regression coverage and documentation

**Files:**
- Modify: `tools/ui_smoke.lua` (extend the 50-message block added in Task 2 with the timing alarm and the oversized-message case)
- Modify: `AGENTS.md` (the "Chat content pipeline" paragraph — describe the measure/paint split)
- Modify: `PLAN.md` (dated section with checkboxes; `PLAN.md` is gitignored and must not be committed)

**Interfaces:**
- Consumes: the behavior delivered by Tasks 1–3.
- Produces: a regression test that fails if the chat ever builds a bitmap for an offscreen message again, and updated documentation of the pipeline.

- [ ] **Step 1: Write the failing test**

Extend the 50-message block from Task 2 with:

1. A timing alarm: measure the wall time of the first paint with `os.clock()` and assert it is below 1500 ms (the current implementation takes ~400 ms for 50 messages on the harness PC; the alarm catches a regression back to the bitmap-per-message behavior, it is not expected to fail today).
2. An oversized-message case: add one message whose body repeats a 90-character sentence 700 times (≈ 41 000 px, taller than `KtHTML.MEASURE_H`) and assert the chat still paints without crashing, that the message is rendered through the canvas fallback (its entry `kind` is not `"html"`), and that no bitmap taller than 65 536 px was rendered.

Run the harness. Expected: check 2 fails today if the current code still builds a huge bitmap for that message (the current implementation lays it out at `pages * 96`, which is > 65 536 px), proving the new behavior is in place.

- [ ] **Step 2: Run the focused smoke and verify RED**

Run the harness command from Task 1. Expected: the oversized-message check fails on the current code path (a bitmap taller than 65 536 px is rendered).

- [ ] **Step 3: Make the oversized message fall back to the canvas renderer**

In `html_layout_for`, a `nil` measurement already means "no document" — make sure the caller (`block_entries` and `measure_reasoning`) takes the canvas fallback branch in that case, and that no bitmap is created for that message at any point. No new code path is needed if Task 2 already returns `nil`; this step only verifies the behavior through the test.

- [ ] **Step 4: Run the focused smoke and verify GREEN**

Run the harness command from Task 1. Expected: all new and pre-existing checks pass; the harness ends with `0 failures`.

- [ ] **Step 5: Update the documentation**

- `AGENTS.md`: in the "Chat content pipeline" bullet, state that message bodies are measured with a layout-only MuPDF pass (transparent CSS + `getSinglePageHeight`, no bitmap) and that the tall bitmap is built on demand for the visible messages only, with the offscreen documents holding metadata only.
- `PLAN.md`: add a dated section (Portuguese, matching the file's style) with the checkboxes for the four tasks, the measured numbers (2.0 ms per layout-only measurement on the harness PC, ~50 renders → ~4 renders for a 50-message chat), and the verification command.

- [ ] **Step 6: Run the complete verification gate**

```bash
cd /home/salada/Documentos/KOTavern/kotavern.koplugin
for f in ktui/chat_bubbles.lua ktui/kthtml.lua tools/ui_smoke.lua; do luajit -bl "$f" > /dev/null || echo "SYNTAX FAIL $f"; done
python3 tools/check_i18n.py
cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy \
    ./luajit /home/salada/Documentos/KOTavern/kotavern.koplugin/tools/ui_smoke.lua 2>&1 | tail -3
git diff --check
```

Expected: no syntax failures, i18n ok, harness `0 failures`, no whitespace errors.

- [ ] **Step 7: Commit only after explicit confirmation**

If the user asks for a commit: `git add AGENTS.md tools/ui_smoke.lua` (never `PLAN.md` — it is gitignored) and commit with `perf(chat): document the layout-only chat measure pipeline`.
