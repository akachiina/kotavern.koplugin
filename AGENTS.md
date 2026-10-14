# AGENTS.md

KOTavern — SillyTavern-style AI chat client for KOReader. This repo root **is** the plugin folder; the name `kotavern.koplugin` must never change (installs/updates depend on it). Plain Lua targeting KOReader's LuaJIT runtime (Lua 5.1 semantics); no package manager — only stdlib + KOReader libs (`ffi/blitbuffer`, `libs/libkoreader-lfs`, `socket`, `json`, `gettext`) + `curl` on device.

## Verification (mirror CI before pushing)

- Syntax (CI runs this on every .lua): `luajit -bl <file> > /dev/null` — LuaJIT is the reference interpreter, not lua/luac 5.4.
- i18n gate: `python3 tools/check_i18n.py` (from repo root). Every `_("…")` msgid in any .lua (`tools/` excluded) must have a non-empty `msgstr` in BOTH `locales/pt_BR.po` and `locales/es.po`, or CI fails. Ship new UI strings with both .po updates in the same change. (2026-10: the HTML-chat/bubble-theme msgids are pending in both files — known red, not a tool bug.)
- UI smoke test (PLAN.md's merge gate): needs a KOReader checkout and its luajit; plain luajit won't load fonts/blitbuffer:
  ```
  cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy \
      ./luajit /path/to/kotavern.koplugin/tools/ui_smoke.lua
  ```
  Exit 0 = pass. PNGs land in `/tmp/kotavern_ui/` — use them for before/after on layout fixes.
- Release: push a `v*` tag; the workflow zips the repo (minus `.git`/`.github`/`data`) into `kotavern.koplugin-<ver>.zip` and attaches it to the GitHub release.

## Architecture

- Entry chain: `main.lua` (KOReader plugin entry; menu + nerd-font registration) → `kt_launcher.lua` (singleton) → `kt_app.lua` (app controller; global state + `SETTINGS_DEFAULTS`) → `ktui/app_view.lua` (canvas UI shell).
- `ktui/` = canvas UI framework adapted from ZenPM: `theme.lua` (palettes/fonts/metrics), `pages.lua` (~3k lines; every screen painter), `primitives/widgets/geom/scroll/sheets/modals`, plus experimental `uidsl.lua`/`kthtml.lua` (Debug-Mode CSS/HTML rendering).
- Root `kt_*.lua` domain modules: `kt_client.lua` (OpenAI Chat Completions; LuaSocket sync + background-curl streaming), `kt_storage.lua` (JSON settings/presets, SillyTavern PNG cards with ccv3 JSON in the tEXt chunk, `.jsonl` chats; mtime-keyed read cache — page painters re-read per paint), `kt_models/kt_world_info/kt_regex_engine/kt_backup/kt_update`, `kt_i18n.lua` (installs pt_BR/es into KOReader gettext).
- `kotaven_*.lua` = low-level helpers (PNG encode/export/util) ported from the old kotaven.koplugin.

## Conventions & gotchas

- Filenames are deliberately `kt_`-prefixed / under `ktui/`: require names must never collide with KOReader core or other plugins. Don't add bare `util.lua`, `theme.lua`, etc. at root.
- Never use `_` as a variable/index name (`for _, x in ipairs(...)`): it shadows gettext's `_()` in nested closures → "attempt to call upvalue '_'" crash (fixed once in 33c14bb; smoke has a self-check).
- Assets are generated, not hand-edited: `lua tools/gen_assets.lua` (SVG icons, run from repo root), `tools/subset_nerd_font.sh` (pyftsubset), `tools/gen_debug_banner.py` (pre-composites GIF frames — KOReader's giflib can't play delta-encoded GIFs; see `ktui/gifanim.lua`).
- `PLAN.md` and `API_CONNECTIONS_PROMPT.md` are gitignored internal notes; `PLAN.md` (Portuguese) is the running plan/changelog — new work gets a dated section with checkboxes. Commits and code comments are in English.
- Version lives in two synced places: `VERSION` and `kt_constants.lua`'s `VERSION` — bump both together (see commit 6549740). `_meta.lua` stays at 0.1.0; PLAN.md's "version frozen at 0.1.0" header is stale.
- `data/` is per-device runtime data: never commit, never ship.
