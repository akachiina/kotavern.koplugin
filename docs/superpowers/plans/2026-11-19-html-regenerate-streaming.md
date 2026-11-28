# HTML Regenerate Streaming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render regenerated partial responses as MuPDF HTML in List mode while preserving streaming pacing, the caret, fallbacks, and final swipe behavior.

**Architecture:** Reuse the completed-message HTML block path for real streaming messages, with a distinct lightweight branch for the synthetic thinking pulse. Drive the existing `App:regenerate_last()` path in the smoke test and inspect the actual layouts produced by `ChatBubbles.draw()` after chunk callbacks.

**Tech Stack:** Lua 5.1/LuaJIT, KOReader UIManager, MuPDF `HtmlBoxWidget`, existing UI smoke harness.

**Spec:** `docs/superpowers/specs/2026-11-19-html-regenerate-streaming.md`

## Global Constraints

- Preserve `stream_refresh` behavior and stored message content; only rendering changes.
- Keep canvas fallback for MuPDF construction/blit failures and the synthetic thinking pulse.
- Use KOReader's LuaJIT from `/usr/lib/koreader` for UI tests; do not add dependencies.
- Do not use `_` as a loop variable in code that can call gettext.
- Book work and image behavior are out of scope.
- Do not commit or push without explicit user confirmation.

## Review Focus

- Incomplete Markdown/HTML in a chunk: the existing allowlist/MuPDF fallback must leave readable text; exercised by painting real partials in Task 1.
- A synthetic thinking pulse must not incur HTML rendering: add a thinking-layout assertion in Task 1.
- Regional refresh arguments must remain `partial`: assert the actual UIManager arguments in Task 1.
- Completion must invalidate the streaming layout and restore HTML plus `2/2` swipes: paint after `on_done` in Task 1.
- Display regex must apply to partials as it does to completed messages: include formatted Markdown in a chunk and inspect the resulting HTML document in Task 1.

---

### Task 1: HTML partial rendering and real-path regression coverage

**Files:**
- Modify: `tools/ui_smoke.lua` (regenerate streaming section)
- Modify: `ktui/chat_bubbles.lua` (message block selection and stale HTML comments)
- Modify: `AGENTS.md` (Chat HTML architecture description)

**Interfaces:**
- Consumes: `App:regenerate_last()`, captured `on_chunk(delta, accumulated)` / `on_done(...)`, and `ChatBubbles.draw(view, bb, x, y, w, h, scroll, messages, char_name, is_generating, user_name, ...)`.
- Produces: real `msg.is_streaming` messages measured as `kind = "html"` entries; synthetic thinking messages remain canvas paragraphs. No public API changes.

- [x] **Step 1: Write the failing real-path test**

Update the regenerate smoke block to call `ChatBubbles.draw()` after the first and second chunks, locate the reused assistant layout, and assert its body is a live HTML entry whose fallback contains the accumulated text and caret. Assert every captured dirty call has mode `partial` (the third vararg after UIManager self and view). Include Markdown in the accumulated text and confirm the partial uses an HTML document rather than a canvas paragraph. Paint a synthetic thinking layout and assert it stays non-HTML. After `on_done`, paint through the same view and assert the final body is HTML and `swipes_id == 2`, `swipes_n == 2`.

- [x] **Step 2: Run the focused smoke and verify RED**

Run the full UI smoke from `/usr/lib/koreader` with an initialized temporary `KO_HOME`; the harness has no per-test filter. Expected: the new partial-HTML assertion fails because `ktui/chat_bubbles.lua` currently creates a `paragraph` whenever `msg.is_streaming` is true. Fix any harness errors until the failure is specifically the wrong entry kind.

- [x] **Step 3: Implement the minimal renderer change**

In `measure_msg`, apply display regex to real streaming and completed bodies, create the same HTML block for both, and append ` ▌` only to the streaming render text. Keep stored `msg.content` unchanged. Mark the synthetic thinking message explicitly so it alone retains the plain streaming paragraph/caret path. Replace the two stale “Experimental HTML render” comments and update `AGENTS.md` to describe HTML as the sole normal body renderer with canvas fallback.

- [x] **Step 4: Run the focused smoke and verify GREEN**

Run the same UI smoke command. Expected: all checks pass, including partial HTML, thinking fallback, dirty modes, final HTML, and final swipes; no script errors or MuPDF warnings caused by the new path.

- [x] **Step 5: Run the complete verification gate**

Run Book smoke, LuaJIT syntax over every Lua file, `python3 tools/check_i18n.py`, and `git diff --check`. Expected: zero failures and clean syntax/i18n/diff checks. Review the diff for unintended network, pacing, persistence, or Book changes.

- [x] **Step 6: Commit only after explicit confirmation**

If the user requests a commit, stage only the files above and use `fix(chat): stream regenerated messages through HTML`. Otherwise leave the verified changes uncommitted for review.
