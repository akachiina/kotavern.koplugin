# Performance, Scroll, and Book Positioning Design

## Intent

Fix the six problems reported from a real Kindle:

1. Chat (HTML mode) freezes with many messages — a 50-message chat locked the
   device until a forced restart — and opening a chat is slow.
2. List pages (Home, Chats, API, Settings, …) sometimes open scrolled to the
   bottom instead of the top.
3. Book mode reloads the native reader (re-rendering the HTML) for actions that
   do not change the HTML at all, e.g. changing the provider.
4. Book mode does not land on the page of the new message after sending a
   message or after the reply arrives; it sometimes goes to the book start
   (page 1) or stays on the last page.
5. The first launch of the plugin is slow compared with other plugins.
6. The locale label "Display mode" must read "chat mode".

## Goals

- A 50-message chat opens and paints without a long freeze, and the peak
  memory of the chat screen stays proportional to the visible messages, not to
  the chat length.
- Every list page opens at scroll offset 0. The chat keeps its own rule
  (bottom / new message).
- Book mode re-renders the native reader only when the generated HTML actually
  changed.
- After sending a message, and after the assistant reply arrives, the book
  shows the new message. It never lands on page 1 as a fallback.
- Opening the plugin does not decode every character card before the first
  paint, and card metadata is read for visible cards only.
- The plugin's Lua modules are not loaded during KOReader boot; they load when
  the user opens the plugin.
- The settings row reads "Chat mode" in English, Portuguese, and Spanish.

## Non-goals

- Rewriting the chat renderer as a single MuPDF document for the whole chat.
  That would need one giant bitmap and would break per-message spoiler and
  link handling. Kept as a future direction.
- Estimating message heights with the canvas text renderer. The estimate would
  drift from the real MuPDF layout and make the scroll jump while refining.
- Spreading the MuPDF work over several frames (progressive first paint). The
  scroll would wobble and the memory peak would stay high.
- Persisting Book reveal state across sessions (already session-only).
- Changing KOReader reader chrome or global font preferences.
- Changing the List-mode visual design.

## Constraints

- Plain Lua 5.1/LuaJIT; no new dependencies; no package manager.
- `local _` remains forbidden as a variable name (it shadows gettext).
- New user-visible strings require non-empty translations in both
  `locales/pt_BR.po` and `locales/es.po`.
- Module names stay namespaced (`kt_*` at root, `ktui/*`).
- The chat fallback to the canvas renderer must survive every failure mode:
  a failed MuPDF layout must never produce a blank bubble.
- Book mode must keep working on KOReader builds where crengine rejects an
  anchor; the fallback chain may not jump to page 1.
- Verification gates: `luajit -bl` on every touched `.lua`,
  `python3 tools/check_i18n.py`, and the headless UI smoke harness
  (`tools/ui_smoke.lua`) run from `/usr/lib/koreader`.

## Root causes (measured, not guessed)

### Chat HTML freeze

`ktui/chat_bubbles.lua:html_doc_for()` builds, for **every** message, a full
MuPDF document plus a tall bitmap: a 96 px probe layout to learn the page
count, a relayout at `pages * 96`, a render, and a `scan_bottom` of the
resulting bitmap. Measured in the real harness (600×800, PC):

| messages | first paint | warm repaint |
|----------|-------------|--------------|
| 10       | 97 ms       | 2.0 ms       |
| 50       | 408 ms      | 1.3 ms       |
| 80       | 645 ms      | 1.4 ms       |

On a Kindle (5–8× slower) the measurement alone is 2–3.5 s, and all 50
bitmaps are alive at once before the offscreen sweep releases them — that
memory peak is the freeze that required a forced restart. The warm path
(layout cache) is already fast; the measure step is the bottleneck.

A layout-only measurement (no bitmap) with `background:transparent` plus
`Page:getUsedBBox()` measured **1.2–2.0 ms per message** (7× faster, no
bitmap) and matched the real height within 3–9 px, including for an 18,000 px
message.

### List pages opening at the bottom

The scroll offset is stored per key (`state.scroll[key]`) and is never reset
when a page is entered, so a page comes back exactly where it was left —
usually the bottom. The Chats reset additionally uses the fixed key
`"chats_"`, which does not match the real key (`scroll_key()` = page + chat
id) when a chat is open.

### Book reload and positioning

`kt_book_ui.lua:choose_connection()` and `App:set_chat_preset()` call
`on_chat_changed(..., { kind = "mutation" })`, which regenerates the HTML and
calls `ui:reloadDocument(...)` even when the HTML is byte-identical.

For positioning, the `"user"` and `"done"` refresh kinds navigate by "last
page" or by an **old** xpointer that is invalid in the newly loaded document;
the fallback is `GotoPage(1)`, i.e. the cover. The `#mN` section anchors that
`kt_book.lua` already emits work natively in crengine, but they are used only
in the mutation path, never in the two paths that the user reported.

### First launch

`kotaven_png.lua:decode_base64()` decodes the card JSON character by
character in pure Lua: **35.7 ms per 66 KB card on the PC** (200 ms+ on a
Kindle), multiplied by every card. The PNG reader also pulls the whole IDAT
chunk (810 KB for a typical card) although only the `tEXt` chunks carry the
card data. The dashboard parses **every** card during the first paint.

Boot: `main.lua` requires `kt_launcher` at load time, which pulls `kt_app`
and 125 Lua modules (1.2 MB of Lua) into the KOReader boot path
(19.9 ms on the PC, roughly 100–160 ms on a Kindle).

## Approaches considered

### 1. Split "measure" from "paint" (chosen)

The measure step performs a layout only (no bitmap) and derives the height
from `getUsedBBox`; the MuPDF bitmap is created on demand, only for the
messages that are actually visible. The layout cache keeps the height always
and the widget only when it exists; the existing offscreen sweep stays the
owner of memory release.

### 2. Estimate heights with the canvas renderer

Rejected: the canvas font differs from MuPDF, so the estimate drifts, the
scroll jumps when the real height arrives, and the end of the chat becomes
imprecise. Trades a freeze for visible imprecision.

### 3. Build the documents a few per frame

Rejected: the first paint shows a half-built chat, the scroll wobbles while
heights arrive, and the memory peak does not improve.

### 4. One MuPDF document for the whole chat

Rejected for now: it needs one bitmap of the full chat height (~20 MB for 50
messages), breaks per-message spoiler/link handling, and every reveal
rebuilds the whole chat.

### Book reload: compare the generated HTML (chosen)

Generate the HTML, compare it with the HTML already written for the book; if
it is identical, skip `reloadDocument` entirely. This covers provider
changes, preset changes, and any future no-op mutation.

### Book positioning: anchor first (chosen)

The `"user"` and `"done"` refresh kinds carry the anchor of the new message
(`#mN`). The position chain becomes: anchor → last page → previous xpointer
(restored only if still valid) → keep the current position. It never falls
back to page 1.

### List scroll: reset on page entry (chosen)

`scroll_key()` becomes the page name for list pages (the chat keeps a
per-chat key). Entering a page sets its offset to 0. The broken fixed key
`"chats_` disappears.

### First launch: table-driven base64, no IDAT, lazy card metadata (chosen)

- `decode_base64` uses a 64-entry lookup table (35.7 ms → ~1 ms for 66 KB).
- The PNG reader skips IDAT entirely and only reads the `tEXt` chunks.
- Card metadata (creator, tags, token estimate) is parsed for the cards the
  dashboard actually shows; the rest is parsed when they scroll into view.

### Boot: load the app on demand (chosen)

`main.lua` keeps registering the nerd font (needed early), but the
`kt_launcher`/`kt_app` graph loads when the user opens the plugin. The
Launcher keeps its public API so `main.lua` keeps working unchanged.

## Decisions

| Item | Decision |
|------|----------|
| Chat measure | Layout only, transparent CSS, `getUsedBBox`; fall back to the current tall probe when the bbox is unavailable or fails. |
| Chat paint | Bitmap built on demand for visible messages only; offscreen widgets released by the existing sweep. |
| List scroll | Always 0 on entry; chat keeps bottom / new-message. |
| Book reload | Identical HTML ⇒ no `reloadDocument`. |
| Book position | Anchor `#mN` → last page → valid old xpointer → keep current position; never page 1. |
| First launch | Table base64, no IDAT read, per-visible-card metadata. |
| Locale | `Display mode` → `Chat mode` in `pt_BR.po` and `es.po`. |
| Boot | `kt_app` graph loads on plugin open, not at KOReader boot. |

## Review Focus

The failure modes a user can hit that the feature list does not mention:

1. **A message whose MuPDF layout fails** (unsupported HTML, MuPDF error) —
   the bubble must still show the canvas fallback text, not a blank bubble or
   a crash.
2. **A very long message** (tens of thousands of pixels) — the layout-only
   measurement must not cap the height at the probe height, and the bitmap
   must not be built for it while it is offscreen.
3. **A chat with a streaming partial** — the partial body must keep streaming
   with the new measure/paint split (no flicker, no stale height).
4. **A spoiler/details reveal inside one message** — only that message's
   layout is invalidated; the other 49 messages keep their cached heights.
5. **A book where crengine refuses the `#mN` anchor** (older KOReader, anchor
   id not in the document) — the reader must keep a sane position, never
   page 1 and never a blank view.
6. **A book where the HTML does not change** — the reader must not reload:
   the page number, the scroll position, and the read history must survive.
7. **A character card whose PNG has no `tEXt` chunk** (plain image) — the
   dashboard must show it without a card JSON and without an error.
8. **A character card with a huge base64 JSON** (a very large card) — the
   decode must not blow the stack or the time budget.
9. **A page entered while a sheet was open** — closing the sheet must not
   restore a stale scroll offset for a different page.
10. **A user who scrolls a list, leaves, and comes back** — the page opens at
    the top (the approved behavior), and the sheet close/restore must not
    resurrect the old offset.
