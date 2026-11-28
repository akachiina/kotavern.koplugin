# Book Details, Emoji, Titles, and Chapter Removal Design

## Intent

Make Book mode match the requested SillyTavern behavior and the user's explicit
follow-up: remove generated chapters, show speaker/time/message number on each
message title, make `<details>` and spoilers expandable like the List view, and
render emoji through the native reader. Ensure the removed Debug HTML-renderer
row cannot silently return and publish the verified branch.

## Goals

- Book messages appear continuously, without generated chapter headings or turn
  grouping.
- Every message title shows the speaker, local `HH:MM` time when available, and
  the one-based message number.
- `<details><summary>…</summary>…</details>` starts collapsed and expands from
  a real tap in the native reader, using the same parsing/sanitization semantics
  as List mode.
- `||spoiler||` starts masked and reveals from a real tap, also matching List.
- Disclosure and spoiler identities are independent per message and per
  reasoning channel.
- Emoji render in Book mode using the bundled Noto Emoji font, without changing
  the reader's global fallback-font preferences.
- Debug has no `HTML chat renderer` row because HTML is the sole normal body
  renderer.
- The branch is committed and pushed only after all verification gates and an
  independent review pass.

## Non-goals

- Book-specific theme editor or full Chat-theme parity. Book theme scope is a
  separate evaluation.
- Color emoji. The bundled Noto Emoji face is monochrome.
- Persisting expanded spoiler/details state across Book sessions.
- Changing native KOReader reader chrome, global font settings, or global
  crengine fallback preferences.
- Restoring the legacy canvas completed-message renderer.

## Constraints

- Plain Lua 5.1/LuaJIT; no new dependencies.
- Generated Book HTML is consumed by KOReader's crengine, not MuPDF.
- Native crengine `<details>` is semantic but not interactive, so Book must use
  private `kt:` links and session-owned reveal state.
- Every tap-triggered disclosure change rebuilds the generated Book and reloads
  the native reader through the existing Book session path.
- List-mode behavior must remain unchanged.
- `local _` remains forbidden as a variable name.
- New user-visible strings require Portuguese and Spanish translations.

## Approaches considered

### 1. Native HTML `<details>` in crengine

Rejected. The installed crengine understands the element structurally but
renders its body as ordinary visible content and does not provide an
interactive disclosure widget. It cannot reproduce List's tap behavior.

### 2. A separate Book-only details parser

Rejected as the primary implementation. It would duplicate List's allowlist,
Markdown, nested-details, summary, and spoiler rules, making "same as ST"
behavior drift over time.

### 3. Reuse List's ST-compatible HTML body encoder

Chosen. The encoder already sanitizes model HTML, understands `<details>` and
`||spoiler||`, numbers disclosures in document order, and distinguishes body
from reasoning. It will gain optional URI prefixes so Book can qualify each
link by message/channel without changing List's default `kt:det:N` and
`kt:spl:N` links.

### 4. Package Book as EPUB to gain richer document semantics

Rejected. It adds a packaging/runtime migration and still does not provide
the required tap-to-expand state through the current crengine HTML document.

## Design

### Continuous messages and titles

`Book.build()` will stop grouping messages into turns and stop emitting
`<h1 class="chapter">` elements. It will emit each message section directly.

The message heading becomes a structured title:

```html
<div class="message-title">
  <span class="speaker">Aria</span>
  <span class="message-meta">14:56 · #3</span>
</div>
```

The speaker follows existing role rules (persona for user, character for the
assistant, System for system messages). Time is omitted when `send_date` is
absent or invalid. The number is the one-based message index.

### ST-compatible details and spoilers

Book will call the shared List HTML encoder for message and reasoning bodies
that contain interactive markup. Link prefixes will qualify identities:

- Body details: `kt:det:<message>:<number>`
- Reasoning details: `kt:det:<message>r:<number>`
- Body spoilers: `kt:spl:<message>:<number>`
- Reasoning spoilers: `kt:spl:<message>r:<number>`

Book session state will hold two temporary maps keyed by qualified identity.
A tap toggles one key, schedules the existing Book refresh/reload, and the
reader restores its current x-pointer/anchor. State is cleared on teardown and
is not persisted.

The generated Book CSS will style summary links and masked spoilers so the
collapsed state is visibly actionable. Expanded bodies use the same HTML as
List after sanitization.

### Emoji rendering

Before opening/reloading a generated Book, the session will ensure crengine is
initialized and register `assets/emoji-noto.ttf` (`Noto Emoji`) once. Book's
inline encoder will wrap emoji code points in a scoped
`<span class="ktemoji">…</span>`, and Book CSS will select `font-family:
"Noto Emoji"` for that span.

This avoids global fallback-font mutation and prevents the emoji face from
replacing ordinary Book text.

### Debug renderer row

The row is already absent from this branch; `origin/main` still contains it.
The branch will gain a UI regression assertion that the Debug page has no hit
row labelled `HTML chat renderer`. After all tests pass, the authorized branch
will be committed and pushed so the removal reaches the version used for
testing.

### Book themes

Theme work is explicitly excluded from this implementation. After these fixes,
Book theme support will be estimated separately using the existing theme schema
and a documented Book-safe subset.

## Verification

- Book smoke must fail before implementation on:
  - generated chapter headings still existing;
  - missing speaker/time/message-number title metadata;
  - details bodies not being collapsed or links not being message-qualified;
  - spoilers not being masked/qualified;
  - emoji not being wrapped for the registered Noto Emoji face.
- Book smoke must exercise a real native-reader disclosure link and verify
  that the generated document reloads with the body revealed.
- UI smoke must prove the Debug renderer row is absent.
- Final gate: Book smoke, UI smoke, LuaJIT syntax for every Lua file, i18n gate,
  `git diff --check`, independent review, then commit and push.
