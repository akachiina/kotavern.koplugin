# Book Details, Emoji, Titles, and Chapter Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Book mode continuous and useful per message, with ST-compatible tappable details/spoilers and monochrome emoji, then publish the verified HTML/Book branch.

**Architecture:** Keep the existing crengine Book session and native `kt:` tap interception. Add optional identity prefixes to the List HTML encoder, use that encoder only for Book bodies containing interactive markup, and retain the existing Book renderer for other bodies. Session-owned reveal maps drive debounced rebuild/reload; a scoped emoji span and one-time crengine font registration avoid global fallback changes.

**Tech Stack:** Lua 5.1/LuaJIT, KOReader ReaderUI/crengine, existing Book and UI smoke harnesses, bundled `assets/emoji-noto.ttf`.

**Spec:** `docs/superpowers/specs/2026-11-19-book-details-emoji-titles-design.md`

## Global Constraints

- Plain Lua 5.1/LuaJIT; no new dependencies.
- Generated Book HTML is consumed by KOReader's crengine, not MuPDF.
- Every disclosure tap rebuilds/reloads through the existing Book session and restores reading position.
- List-mode behavior and default `kt:det:N` / `kt:spl:N` URIs remain unchanged.
- Reveal state is session-only; do not persist it.
- Do not change global font fallback preferences, reader chrome, network behavior, or Book themes.
- `local _` remains forbidden as a variable name; new user-visible strings would require pt_BR and es translations.
- Preserve the previously completed streaming/table fixes already in the dirty working tree; do not overwrite them with a checkout/reset.

## Review Focus

- Invalid, negative, non-number, NaN, or infinite `send_date`: omit only the time and retain `#N`; pinned by Task 2 title tests.
- Same-number disclosures in different messages and reasoning channels: only the qualified identity changes; malformed/stale URIs do nothing; pinned by Task 3 isolation and router tests.
- A real native tap during a reload/debounce cycle: the latest state wins and the reader returns to the tapped message rather than the tail; pinned by Task 3 native tap/position tests.
- Emoji next to HTML/Markdown, ZWJ sequences, and ordinary accented/CJK text: wrap emoji text nodes without corrupting tags or wrapping non-emoji; pinned by Task 4 encoder tests.
- List calls without options and the removed Debug renderer row: legacy URIs/reveal sets remain identical and no settings row can reappear silently; pinned by Tasks 1 and 5.

---

### Task 1: Namespace the shared ST HTML encoder without changing List

**Files:**
- Modify: `ktui/chat_bubbles.lua` (`chat_html_body`, spoiler/details emission, exports)
- Test: `tools/ui_smoke.lua` (existing HTML markdown/details section)

**Interfaces:**
- Produces: `ChatBubbles.encode_html(content, revealed, det_revealed, opts) -> string`.
- `opts` is optional; `opts.link_prefix` defaults to `""`. With prefix `"2r:"`, links are `kt:spl:2r:1` and `kt:det:2r:1`, and reveal lookups use string keys `"2r:1"`. With no prefix, numeric reveal keys and legacy URIs remain unchanged.
- Existing internal List calls and `_test_chat_html_body(content, revealed, det_revealed)` retain their signatures and behavior.

- [ ] **Step 1: Write the failing prefix/default regression tests**

Add assertions equivalent to:

```lua
local Chat = require("ktui/chat_bubbles")
local raw = "<details><summary>More</summary>hidden</details> ||secret||"
local masked = Chat.encode_html(raw, nil, nil, { link_prefix = "2r:" })
assert(masked:find('href="kt:det:2r:1"', 1, true))
assert(masked:find('href="kt:spl:2r:1"', 1, true))
assert(not masked:find("hidden", 1, true))
local open = Chat.encode_html(raw, { ["2r:1"] = true },
    { ["2r:1"] = true }, { link_prefix = "2r:" })
assert(open:find("hidden", 1, true))
assert(open:find('<span class="ktspl ktsplopen">secret</span>', 1, true))
assert(Chat.encode_html(raw) == Chat._test_chat_html_body(raw))
```

- [ ] **Step 2: Run UI smoke and verify RED**

Run the full UI smoke from `/usr/lib/koreader` with an initialized temporary `KO_HOME`. Expected: failure because `Chat.encode_html` is nil; existing List tests must otherwise remain green.

- [ ] **Step 3: Implement the optional prefix**

Thread an optional options table through `chat_html_body` into its spoiler/details state. Prefix only the generated URI and, when non-empty, the reveal-map key; retain the current numeric lookup when the prefix is empty. Export `encode_html` as a thin production wrapper around the same encoder used by List, not a second parser.

- [ ] **Step 4: Run UI smoke and verify GREEN**

Expected: all checks pass, including every pre-existing unprefixed details/spoiler test and the new qualified-link checks.

### Task 2: Remove generated chapters and add structured message titles

**Files:**
- Modify: `kt_book.lua` (document loop, title rendering, CSS, obsolete chapter helpers/comments)
- Test: `tools/book_smoke.lua` (T1, T6, T20 and timestamp fixtures)

**Interfaces:**
- Consumes: existing `Book.build(data)` and `speaker_for(msg, data)` behavior.
- Produces: one `<section class="msg ..." id="mN">` per message directly after the cover; no turn grouping or `<h1 class="chapter">`.
- Each section starts with `<div class="message-title">`, a `span.speaker`, and `span.message-meta` containing `HH:MM · #N` when time is valid, otherwise `#N`.

- [ ] **Step 1: Replace chapter assertions with failing continuous-message/title assertions**

Use a fixed valid timestamp (`1700000000`) on message 1, no timestamp on message 2, a negative timestamp on message 3, and `math.huge` on message 4. Assert:

```lua
assert(count(html, '<section class="msg ') == #fixture_messages)
assert(not html:find('<h1 class="chapter"', 1, true))
assert(not html:find('id="turn-', 1, true))
assert(html:find('<span class="speaker">Tester</span>', 1, true))
assert(html:find('<span class="message-meta">'
    .. os.date("%H:%M", 1700000000) .. ' · #1</span>', 1, true))
for index = 2, 4 do
    assert(html:find('<span class="message-meta">#' .. index .. '</span>', 1, true))
end
assert(count(html, "<h1") == 0 and count(html, "<h2") == 0)
assert(html:find('class="md-h', 1, true))
```

Also cover a string timestamp and NaN in a small direct `Book.build` fixture; neither may abort the build or emit a time.

- [ ] **Step 2: Run Book smoke and verify RED**

Expected: T1/T20 fail because chapter headings remain and structured titles/time metadata are absent.

- [ ] **Step 3: Implement continuous sections and safe local-time formatting**

Iterate `ipairs(messages)` directly in `Book.build`. Replace the speaker-only row with the structured title, formatting positive finite numeric timestamps through protected `os.date("%H:%M", ts)` and always including the one-based index. Remove chapter-only grouping/preview helpers and `.chapter` CSS; retain demoted model headings, message anchors, cover, actions, and colophon.

- [ ] **Step 4: Run Book smoke and verify GREEN**

Expected: all current non-chapter behavior remains green and the new title/timestamp assertions pass.

### Task 3: Add session-owned Book details/spoilers and native tap coverage

**Files:**
- Modify: `kt_book.lua` (interactive body selection, reveal inputs, disclosure CSS)
- Modify: `kt_book_session.lua` (reveal state, data collection, URI routing, reload scheduling)
- Test: `tools/book_smoke.lua` (qualified markup isolation and real ReaderUI taps)

**Interfaces:**
- Consumes: `ChatBubbles.encode_html(content, revealed, det_revealed, { link_prefix = prefix })` from Task 1.
- Extends `Book.build(data)` with optional `data.revealed_spoilers` and `data.revealed_details`, maps keyed by `"N:M"` or `"Nr:M"`.
- Body prefix is `tostring(index) .. ":"`; reasoning prefix is `tostring(index) .. "r:"`.
- `Session.handle_uri(uri)` accepts only `kt:det:N:M`, `kt:det:Nr:M`, `kt:spl:N:M`, and `kt:spl:Nr:M`, toggles the matching session map, and schedules `{ kind = "mutation", anchor = "#m" .. N, tail = false }`.

- [ ] **Step 1: Write failing qualified-markup and isolation tests**

Build at least two messages with one details group and spoiler each, plus reasoning on message 1. Initially assert all six body/reasoning/message-qualified URI forms, hidden details bodies, and masked spoiler anchors. Reveal only body details `1:1` and reasoning spoiler `1r:1`; assert message 1 body details open, reasoning details stay closed, body spoiler stays masked, reasoning spoiler opens, and every message 2 control stays unchanged. Assert ordinary List-style unqualified `kt:det:1` is not emitted by Book.

Add native router tests for malformed (`kt:det:1`, `kt:det:x:1`) and stale (`kt:det:999:1`) URIs: after the debounce interval, the ReaderUI instance and generated HTML must be unchanged and the target bodies must remain hidden.

- [ ] **Step 2: Write the failing real-native-tap test**

Put a details group and spoiler in native fixture message 1. Navigate to `#m1`, locate `kt:det:1:1` in `document:getPageLinks()`, resolve its screen coordinates, and invoke the registered `kotavern_book_tap` zone handler with that position. After reload, assert the details body is present, the spoiler is still masked, and the current page is the message's pre-tap page. Repeat through the real `kt:spl:1:1` link; assert the secret and details body are both visible afterward. On a later new Book session, assert both start collapsed/masked again.

- [ ] **Step 3: Run Book smoke and verify RED**

Expected: qualified links/state are absent and the native disclosure link cannot be found.

- [ ] **Step 4: Implement Book rendering and session toggles**

For bodies/reasoning containing `<details...>` or `||`, call the shared encoder with the qualified prefix and the two data maps; otherwise retain `render_blocks`. Add visible `.ktdet` and masked `.ktspl` / revealed `.ktsplopen` CSS. Initialize fresh maps on open, pass them through both initial data and `collect()`, clear them on teardown, validate message indices in `handle_uri`, and use the existing debounced refresh path with tail following disabled.

- [ ] **Step 5: Run Book and UI smoke and verify GREEN**

Expected: both suites pass; native taps reload exactly through ReaderUI, state isolation and position checks pass, and List behavior is unchanged.

### Task 4: Render scoped monochrome emoji in Book

**Files:**
- Modify: `kt_book.lua` (emoji text-node wrapping and `.ktemoji` CSS)
- Modify: `kt_book_reader.lua` (one-time crengine font registration)
- Modify: `kt_book_session.lua` (registration before open/reload)
- Modify: `AGENTS.md` (Book/shared-encoder/emoji architecture)
- Test: `tools/book_smoke.lua` (markup, UTF-8 safety, registration count)

**Interfaces:**
- Produces: `Reader.ensure_emoji_font() -> boolean`, idempotent for the process.
- Registration uses the existing crengine initialization path and `cre.registerFont(Constants.ASSET_DIR .. "/emoji-noto.ttf")`; it does not mutate `Font.fallbacks` or reader defaults.
- Book body/reasoning HTML wraps emoji in `<span class="ktemoji">…</span>` and CSS selects `font-family: "Noto Emoji"`.

- [ ] **Step 1: Write failing emoji markup and registration tests**

Include `✅`, `😀`, a ZWJ family emoji, and `Café 漢字` in a body that also contains Markdown and interactive markup. Assert emoji spans survive in both ordinary and shared-encoder bodies, each ZWJ sequence remains inside one span, and accented/CJK text has no `.ktemoji` wrapper. Assert the exact Noto Emoji CSS rule.

Instrument `cre.registerFont` before the first native open, counting only the bundled emoji path. Assert one successful registration after open and still exactly one after disclosure reloads and a later Book reopen.

- [ ] **Step 2: Run Book smoke and verify RED**

Expected: emoji spans/CSS and registration are absent.

- [ ] **Step 3: Implement scoped wrapping and idempotent registration**

Decode UTF-8 with pure Lua, wrap emoji runs only outside HTML tags, and keep variation selectors, skin-tone modifiers, ZWJ, and the following joined emoji in the same run. Leave all other code points unchanged. Apply the wrapper to the final body/reasoning HTML so it covers both renderers. Ensure crengine is initialized, register the bundled face once with protected logging on failure, and call the helper before initial reader open and before `reloadDocument`. Update `AGENTS.md` to document this Book path.

- [ ] **Step 4: Run Book and UI smoke and verify GREEN**

Expected: all checks pass; the font count remains one across reload/reopen and no global fallback setting changes.

### Task 5: Lock the Debug removal, review, and publish

**Files:**
- Test: `tools/ui_smoke.lua` (existing `settings_debug` block)
- Modify: `PLAN.md` (dated implementation/verification notes; gitignored)
- Review: complete branch diff against both HTML streaming and Book specs

**Interfaces:**
- No production renderer setting or toggle is introduced. HTML remains the sole normal List body renderer.

- [ ] **Step 1: Add the Debug-row regression**

Temporarily capture the `rows` argument passed by `Pages.settings_debug` to `Pages.settings_section`, restore the painter, iterate the captured rows, and assert every `row.text ~= _("HTML chat renderer")`. Keep the existing real paint/book-toggle assertions.

- [ ] **Step 2: Run the complete verification gate**

From the repo root, run every Lua file through `luajit -bl`, `python3 tools/check_i18n.py`, and `git diff --check`. From `/usr/lib/koreader`, run both `tools/book_smoke.lua` and `tools/ui_smoke.lua` with fresh writable `KO_HOME` directories and `SDL_VIDEODRIVER=dummy`. Expected: zero script errors/failures, all checks pass, i18n passes, and the diff is clean.

- [ ] **Step 3: Obtain an independent whole-diff review**

Give a fresh reviewer the two specs, the complete diff, and these focus areas: sanitizer safety, qualified identity parsing, reload/position behavior, font registration lifetime, unchanged List defaults, and accidental scope/network/persistence changes. Fix every functional finding and rerun the affected tests plus the final gate.

- [ ] **Step 4: Update notes and publish the authorized branch**

Record the dated Book work and verification in `PLAN.md`. Stage only the intended production/test/architecture files (including the previously verified streaming/table changes), review the staged diff, commit with `feat(chat): improve HTML streaming and Book parity`, and push `fix/html-book-round` to `origin`. Confirm the remote branch advanced; do not implement Book themes in this change.
