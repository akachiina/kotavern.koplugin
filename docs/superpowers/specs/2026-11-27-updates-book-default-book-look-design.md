# Updates UX, Book Mode Default, and Book Look Design

## Intent

Four asks from the author, in the order they were given:

1. Every time the plugin opens, if an update is available, show a popup with
   **Update now**, **Remind me later**, and **Cancel**.
2. In Settings → Updates, add a **What's new** button that shows the text of the
   release for the version, plus an equivalent for the Artifact (commits)
   channel.
3. Take Book mode out of Debug/Experimental and make it the default,
   recommended chat mode.
4. Give Book mode its own customization, mirroring what the List mode's chat
   themes do, with as many knobs as make sense for the native reader.

The author also confirmed that Book customization must be able to rename the
in-book labels, e.g. the "Book actions" link.

## Goals

- Opening the plugin checks for updates in the background, at most once per
  24 hours, and never blocks the first paint.
- An available update produces a native three-action prompt that works both
  over the canvas and over the native book reader.
- "Remind me later" re-prompts after 24 hours; "Cancel" suppresses that exact
  version until a newer one appears.
- Settings → Updates exposes "What's new" for both channels. Stable shows the
  release body; Artifact shows the commit messages since the installed commit.
  Notes are cached so the page also works offline and after installing.
- Book mode is the default for anyone who never explicitly picked a mode. It
  leaves the Debug category and its forced fallback to List disappears.
- Book mode gets a global "Book look": typography applied per generated
  document (never the user's global KOReader settings), structure knobs for the
  generated HTML, four presets, and user-renamable labels for both the in-book
  links and the native action dialogs.

## Non-goals

- Per-chat book themes. The schema is theme-shaped so this can be added later
  without a rewrite, but the first release has one global book look.
- A full native ConfigDialog clone inside the reader. The book menu gets a
  compact "Book appearance" dialog for the most-used knobs; the full page lives
  in Settings (canvas).
- Changing KOReader's global reader settings, the reader chrome, or the
  user's real books.
- A dark/inverted book page. Custom CSS can do it; e-ink night mode stays a
  device-level decision.
- Replacing the List mode, removing its themes, or changing the List renderer.
- GitHub tokens, release feeds, or any new network dependency.

## Constraints

- Plain Lua 5.1/LuaJIT; no new dependencies.
- Module names stay namespaced (`kt_*` at root, `ktui/*`).
- New user-visible strings need non-empty translations in both
  `locales/pt_BR.po` and `locales/es.po`; `python3 tools/check_i18n.py` must
  pass.
- Never use `_` as a variable name.
- Book mode cannot paint canvas pages over the reader: anything reachable
  while the book is open must be a native widget.
- Network I/O must never run in the paint path or block the event loop. The
  existing update check is synchronous (`io.popen`); the automatic path needs a
  background variant.
- Per-document reader settings are written through `DocSettings` for the
  generated HTML path only.
- Verification gates: `luajit -bl` on every touched file,
  `python3 tools/check_i18n.py`, `tools/ui_smoke.lua` and
  `tools/book_smoke.lua` run from `/usr/lib/koreader` with
  `KO_HOME=/tmp/kotavern_ko`.

## Approaches considered

### Book customization storage

**A. One global settings table with flat keys.** Cheap, but it duplicates the
normalize/sig/preset machinery and makes a future per-chat override a breaking
migration.

**B. A `BookTheme` module mirroring `ChatTheme` (chosen).** One normalized
table under `settings.book_theme`, with `DEFAULTS`, `normalize`, `sig`,
`PRESETS`, and a label resolver. The UI is a single page today, but the data
model already supports per-chat overrides, import/export, and extra presets
later.

**C. A full theme manager with per-chat overrides in v1.** Rejected: the only
place a book is open is the native reader, where the canvas theme manager
cannot be shown. A per-chat flow would either need a second native UI or force
"open in list view" round-trips.

### Typography application

**A. Emit CSS in the generated HTML only.** Simple, but crengine's CSS support
for hyphenation and justification is partial, and it would bypass the reader's
own font metrics.

**B. Write per-document `copt_*` settings before the reader opens, plus CSS for
what the settings do not cover (chosen).** Uses the exact same mechanism the
reader uses for any book, scoped to the generated HTML's sidecar. The reader's
global preferences are untouched.

### Update check scheduling

**A. Synchronous check on open.** Rejected: a 30 s curl on a Kindle would
freeze the first paint.

**B. Background curl with a status file and a `UIManager` poll (chosen).**
Same pattern as `kt_client.curl_bg`, which is already proven on device.

## Feature 1 — Update prompt on open

### Settings keys

| Key | Type | Meaning |
|-----|------|---------|
| `update_auto_check` | boolean, default `true` | master switch for the automatic check |
| `update_checked_at` | epoch number | last successful automatic check |
| `update_snooze_until` | epoch number | "Remind me later" gate |
| `update_skip_version` | string | tag/commit the user cancelled (`v0.3.0`, `commits:a1b2c3d`) |
| `update_last_entry` | table | last checked entry, for the Updates status row |

### Flow

`App:show()` schedules `_schedule_update_check()` one second after the view is
shown (after the first paint). The scheduler returns early when:

- `update_auto_check` is false;
- `os.time() < update_snooze_until`;
- `os.time() - update_checked_at < 24 * 3600`;
- a check is already in flight;
- the app has no view (closed).

`Update.check_bg(opts, callback)` spawns
`(curl ... -o body -w "%{http_code}" > status) &` with `os.tmpname()` files,
polls the status file every 0.5 s with `UIManager:scheduleIn`, and gives up
after 45 s. Only one check may be in flight; `Update.cancel_bg()` clears the
pending timer. `Update.check` (synchronous) stays for the manual path and the
headless harness.

On completion:

1. Stamp `update_checked_at` and save.
2. On error, stay silent (no popup, no toast). The manual check still reports
   errors.
3. If the entry is not newer than `installed_build`, stop.
4. If `update_skip_version` equals the entry tag, stop.
5. Show the native prompt.

### Prompt

New helper in `ktui/modals.lua`: `Modals.update_prompt(title, on_update,
on_later, on_cancel)` built on `ButtonDialog` with three stacked rows:

- **Update now** → closes the dialog, calls `App:_install_update(entry)`.
- **Remind me later** → `update_snooze_until = os.time() + 24h`; closes.
- **Cancel** → `update_skip_version = tag`; closes.

The title carries "Update available" plus the version tag, because
`ButtonDialog` has no body text. Native widget so it also shows over the
reader in Book mode.

### Install path extraction

The download/install/restart block inside `App:check_updates_now` moves into
`App:_install_update(entry, on_done)`. Both the manual sheet and the popup call
it, so there is one install path. On success it updates `installed_build`, sets
`update_status`, and shows the existing "Update installed / Restart now"
confirm. On failure it shows the error and leaves the app usable.

### Manual check

`App:check_updates_now` keeps its current UX (status dialog, then the action
sheet) and ignores the throttle and snooze. It also writes
`update_checked_at` and the notes cache (Feature 2).

## Feature 2 — What's new

### Data

- `Update.pick_stable_release` keeps `body` (release notes) and `html_url` in
  the returned entry. Selection behavior does not change.
- `Update.entry_tag(entry)` returns `v<version>` for stable and
  `commits:<sha>` for commits; used by the skip key and the prompt title.
- `Update.commit_notes(commits, installed_commit)` is a pure helper: walk the
  commits list (newest first) and stop at `installed_commit` (exclusive),
  returning `{ sha, message, date }`. If the installed commit is not in the
  window, return the window and flag `truncated = true`.
- `Update.notes(opts, installed)` returns
  `{ channel, title, version, body, items, truncated }`:
  - stable: the release whose tag matches the installed version, else the
    latest release.
  - commits: `commit_notes` over `/commits?per_page=30`.

### Cache

`settings.update_notes_cache = { channel, version, commit, title, body, items,
truncated, fetched_at }`. Written by every successful manual or automatic
check and by an explicit "What's new" fetch. The page reads the cache first;
it refetches when the cache is empty or its version/commit no longer matches
the installed build.

### UI

- New row in `Pages.settings_updates`: **What's new**, icon `info-circle`,
  value = installed version tag or "Update available".
- New canvas page `release_notes` (`Pages.release_notes`), header title
  "What's new". Back returns to Updates.
- Renderer: `ktui/md.lua` blocks painted with `P.scrollable_paragraph`
  (headings bold, bullets, quotes, code in a monospace face). No MuPDF, no
  bitmap per block.
- For stable, show the release name and body. For commits, show a list of
  `short_sha · first line`, with the full body available by tapping a commit
  (a second page or an in-page expansion — builder's call).
- If nothing is cached and the fetch fails, show the cached text when present;
  otherwise an empty state with the network error.

### Prompt integration

The startup prompt shows only the three requested actions. The notes are one
tap away in Settings → Updates. No fourth button.

## Feature 3 — Book mode becomes the default

### Changes

- `SETTINGS_DEFAULTS.chat_mode = "book"`.
- `Pages.settings_debug`: remove the Book mode row and its comment block.
- `Pages.settings_appearance`: the Chat mode row is always visible (no
  `debug_mode` gate). Both "Chat themes" (List) and "Book appearance" (Book)
  are always visible; each configures its own mode.
- `Pages.settings_appearance_chat`: remove the redirect to Appearance when
  `chat_mode == "book"`.
- `App:disable_debug_mode`: no longer forces `chat_mode = "list"`.
- `App:toggle_book_mode` stays (used by `book_smoke`), with no UI entry.

### Migration

No forced migration. `chat_mode` is only persisted when the user picks a mode,
so anyone who never touched it inherits the new default (Book); anyone who
explicitly chose List keeps List. The old `book_show_reasoning` key is read
once to seed the new `book_theme.show_reasoning` and then left in place
(harmless, and a downgrade keeps working).

## Feature 4 — Book look

### Module

New `kt_book_theme.lua` (root, pure data; no UI, no reader):

- `BookTheme.DEFAULTS` — the schema below.
- `BookTheme.normalize(raw)` — coerces, never throws; unknown keys dropped.
- `BookTheme.sig(theme)` — stable serialization for the HTML cache/reload key.
- `BookTheme.PRESETS()` — `{ id, name, theme }` for Default, Novel, Compact,
  Minimal.
- `BookTheme.LABEL_KEYS` — ordered `{ key, group, default_msgid }` list.
- `BookTheme.label(theme, key, default_text)` — custom label or the passed
  default (always resolved at paint/build time, never at file scope).
- `BookTheme.apply_reader_settings(book_path, theme)` — opens `DocSettings` for
  the generated path, writes only the keys below, flushes.

### Schema

```
format = "kotavern-book-theme", version = 1
preset = "default"            -- default | novel | compact | minimal | custom

-- page / typography (DocSettings)
font_face = ""                -- "" = follow the reader
font_size = 0                 -- 0 = follow the reader
line_spacing = 0              -- 0 = follow the reader (percent)
font_weight = 0               -- 0 = follow; else usWeightClass (400/600/700)
margin = "normal"             -- narrow | normal | wide
justify = true
hyphenate = true
paragraph_spacing = "normal"  -- compact | normal | airy

-- structure (generated HTML)
cover = true
cover_title = "chat"          -- chat | character | both
cover_date = true
cover_actions = true
toc = false                   -- per-message TOC entries
message_title = "speaker"     -- speaker | speaker_time | time | number | none
user_style = "quote"          -- quote | panel | plain | hidden
system_style = "dim"          -- dim | plain | hidden
show_reasoning = false
colophon = true
message_actions = true
separator = "space"           -- line | ornament | space | none
merge_speakers = false
page_break = false
drop_cap = false

-- content (CSS)
code_style = "box"            -- box | indent | plain
table_border = true
spoiler = "mask"              -- mask | reveal
emoji_size = "normal"         -- small | normal | large
inline_images = "placeholder" -- placeholder | hidden
custom_css = ""

labels = {}                   -- key -> user text; empty = translated default
```

### Typography mapping

Written before the reader opens (and inside the reload window, after the old
reader has saved its position and closed):

| BookTheme | DocSettings key |
|-----------|-----------------|
| `font_face` | `copt_font_face` |
| `font_size` | `copt_font_size` |
| `line_spacing` | `copt_line_spacing` |
| `font_weight` | `copt_font_base_weight` |
| `margin` | `copt_h_page_margins` (`{left,right}` values for narrow/normal/wide) |

Only keys whose theme value is set (non-empty / non-zero) are written; the
others are removed from the sidecar so "follow the reader" really follows it.
`last_xpointer`, `doc_pages`, and everything else in the sidecar are preserved.

`justify`, `hyphenate`, `paragraph_spacing`, and the content knobs go into the
generated stylesheet; they are also part of `BookTheme.sig`.

### Structure mapping (`kt_book.lua`)

`Book.build(data)` gains `data.theme` (normalized) and `data.labels` (resolved
map). It then:

- emits `<meta name="kotavern-book-theme" content="<sig>">` so any theme change
  changes the bytes and forces the session's reload guard to reload;
- builds the stylesheet from the theme (separators, code blocks, tables,
  spoilers, emoji size, paragraph spacing, custom CSS last);
- toggles the cover, its title/date/actions link, the colophon, the per-message
  actions link, and the page-break-per-message rule;
- renders the message title per `message_title` and the speaker labels from
  `data.labels`;
- renders user messages per `user_style`, system messages per `system_style`;
- wraps reasoning in a blockquote only when `show_reasoning`;
- with `merge_speakers`, consecutive messages from the same speaker share one
  title block;
- with `toc`, emits a real `<h2>` per message so crengine's TOC lists them
  (the default keeps the current demoted-heading behavior).

### Labels

`BookTheme.LABEL_KEYS`, grouped:

- **In the book:** `actions`, `go_end`, `write_next`, `continue_last`,
  `book_actions`.
- **Speakers:** `you`, `system`, `assistant`.
- **Dialogs:** `book_actions_title`, `quick_reply`, `regenerate`, `go_last`,
  `show_reasoning`, `hide_reasoning`, `authors_note`, `system_note`,
  `impersonate`, `persona`, `preset`, `api`, `rename`, `export_chat`,
  `export_txt`, `open_list`, `close_book`, `end_of_chat`.

`kt_book.lua` reads labels from `data.labels`; `kt_book_ui.lua` resolves them
at dialog-build time with `BookTheme.label(theme, key, _("default"))`. Empty
value = translated default. The labels page has a per-row "restore" and a
"Restore all labels" action.

### Pages and entry points

- `Pages.settings_book` (`settings_book`): the full page.
  Sections: Presets, Page, Structure, Content, Advanced (custom CSS), Reset.
- `Pages.settings_book_labels` (`settings_book_labels`): the label list.
- Row in `Pages.settings_appearance`: **Book appearance**, icon `book`.
- Sheet pickers reuse the `pick_row` pattern from `theme_edit`; every write
  goes through `App:set_book_theme_key(key, value)` which normalizes, saves,
  marks `preset = "custom"` (unless a preset is being applied), and asks the
  open book session to refresh.
- Native quick dialog in `kt_book_ui.lua`: **Book appearance** in the book
  menu and the reader's KOTavern menu, with Font size, Line spacing, Margins,
  Message titles, Show reasoning, Cover, Colophon, and "Full settings" (closes
  the book and navigates to `settings_book`). Each row opens a small
  `Modals.actions` picker.

### Presets

- **Default** — today's look: cover, speaker titles, user quote, space
  separator, no TOC, no drop caps, follow the reader's typography.
- **Novel** — cover titled by the character, real TOC, ornament separators,
  page break per message, drop caps, speaker-and-time titles.
- **Compact** — no cover, no colophon, no message actions, number titles,
  compact spacing, reasoning hidden.
- **Minimal** — no cover, no titles, no separators, no colophon, no actions:
  pure prose.

Applying a preset writes every key and sets `preset` to its id. Any manual
edit sets `preset = "custom"`.

## Risks and probes

1. **crengine CSS support.** `text-align: justify` is expected to work;
   `hyphens: auto` depends on the language tag and dictionaries. Probe with a
   generated book before shipping the hyphenation row; if unsupported, drop
   the row instead of shipping a dead knob.
2. **Margin key format.** `copt_h_page_margins` is a table; read a real sidecar
   after changing margins in the reader menu to confirm the shape before
   writing it.
3. **Sidecar race.** The reload path must write DocSettings only after the old
   reader closed (the existing `reloadDocument` `after_close` window) so the
   saved position is never clobbered.
4. **Timer leaks.** The background check must cancel its poll on app close and
   invalidate its callback token; a stale callback may never show a dialog.
5. **Prompt over the reader.** The native dialog must be dismissable and must
   not close the reader; installing only offers a restart.
6. **Long labels.** Custom labels are user text: `Widgets.fit_text`/
   `truncate` in the canvas, and the native dialogs wrap on their own.
7. **i18n volume.** This adds roughly 40 msgids; both `.po` files must be
   updated in the same change.

## Testing

- `tools/ui_smoke.lua`: `BookTheme` normalize/sig/presets/labels; the
  `settings_book` and `settings_book_labels` pages paint and their rows react;
  Appearance shows Chat mode without Debug and both look rows; Debug no longer
  shows Book mode; `Update.entry_tag`, `Update.commit_notes`, and the
  snooze/skip pure helpers; the `release_notes` page paints cached notes.
- `tools/book_smoke.lua`: `Book.build` honors structure toggles, labels, and
  the theme meta; `apply_reader_settings` writes/removes the expected
  `copt_*` keys and preserves the position; a theme change reloads the reader
  exactly once.
- `python3 tools/check_i18n.py` green with both locales.
- Manual on device: airplane mode (silent failure), slow network (no freeze),
  prompt over the reader, "Remind me later" after 24 h, "Cancel" across
  restarts, install + restart, What's new on both channels, and each preset.

## Left to the builder

- The exact visual grouping/spacing of the new settings page within
  `Pages.settings_section`.
- Whether the commit-notes page shows full commit bodies inline or on a
  second page.
- The precise `copt_h_page_margins` numbers for narrow/normal/wide (probe and
  match the reader's own menu values).
- Whether the "What's new" row shows the installed tag or "Update available"
  when both are true (prefer the latter when newer).
