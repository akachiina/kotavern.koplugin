# Update Prompt and Release Notes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The plugin checks for updates in the background when it opens and prompts with three native actions (Update now / Remind me later / Cancel), and Settings → Updates gains a "What's new" page that shows the release notes for the Stable channel and the commit messages for the Artifact channel.

**Architecture:** `kt_update.lua` grows pure helpers (tag, commit notes, release notes, prompt decision) plus a background check that spawns curl detached and polls a status file through an injectable scheduler. `kt_app.lua` owns the throttle/snooze/skip state in the settings table and drives a native `ButtonDialog` prompt. The notes are cached in the settings so the page works offline and after an install.

**Tech Stack:** Lua 5.1/LuaJIT, KOReader widgets (`ButtonDialog`, `InfoMessage`), `curl` via `os.execute`/`io.popen`, the repo's headless harnesses (`tools/ui_smoke.lua`).

**Spec:** `docs/superpowers/specs/2026-11-27-updates-book-default-book-look-design.md` (sections "Feature 1 — Update prompt on open" and "Feature 2 — What's new")

## Global Constraints

- Plain Lua 5.1/LuaJIT; no new dependencies; no package manager.
- Never use `_` as a variable or index name (it shadows gettext).
- New user-visible strings must be wrapped in `_("…")` with a plain literal and must have a non-empty `msgstr` in BOTH `locales/pt_BR.po` and `locales/es.po`.
- Never call `_()` at file scope; translate at paint/build time.
- No GitHub token, ever: API calls carry only `User-Agent` and `Accept`.
- Downloads may only land on the trusted hosts in `Update.trusted_url`.
- The automatic check must never block the event loop and must never run in the paint path.
- Module names stay namespaced (`kt_*` at root, `ktui/*`).
- Verification gates for every task: `luajit -bl <file> > /dev/null` on each touched file, `python3 tools/check_i18n.py`, and the headless harness from KOReader's root:
  `cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy ./luajit <repo>/tools/ui_smoke.lua` (exit 0; the check count must grow).

## Review Focus

- **Airplane mode at boot:** the automatic check fails; the app must show nothing, log nothing user-visible, and still paint. The prompt must never appear with a stale or partial entry.
- **The user cancels version X, then X+1 ships:** the prompt must appear for X+1 (the skip key is per version, not a boolean).
- **"Remind me later" then reopening the app 10 minutes later:** no prompt (24 h gate), and the plugin does not spend a second network call in that window either.
- **The app is closed while the background check is in flight:** the poll timer must die and the callback must never open a dialog on a closed app.
- **The user is reading a book (native reader on top) when the check lands:** the prompt must be a native dialog (it works over the reader) and must not close or disturb the reader.
- **Offline "What's new":** the page shows the cached notes instead of an empty page or a crash.
- **A release body that is empty or huge:** the page renders the cached/empty state and never crashes the markdown renderer.

---

### Task 1: Pure helpers for tags, release notes, and commit notes

**Files:**
- Modify: `kt_update.lua`
- Test: `tools/ui_smoke.lua` (new section after `4m. Self-update selection/validation`)

**Interfaces:**
- Consumes: nothing (pure module).
- Produces:
  - `Update.entry_tag(entry) -> string|nil` — `"v0.3.0"` for a stable entry, `"commits:a1b2c3d"` for a commits entry, `nil` for anything else.
  - `Update.commit_notes(commits, installed_commit) -> table` — `{ truncated = boolean, items = { { sha = string, message = string, date = string } } }`, newest first, stopping before `installed_commit` (a full or short SHA; empty/nil means "everything is new").
  - `Update.notes(opts, installed) -> table` — `opts = { repo, channel }`, `installed = { channel, version, commit }`; returns `{ channel, title, version, commit, body, items, truncated }`.
  - `Update.pick_stable_release(releases)` now also returns `body`, `name`, and `html_url` from the release object (selection rules unchanged).

- [ ] **Step 1: Write the failing smoke checks**

Add a new block to `tools/ui_smoke.lua` right after the `4m` section, using the existing `ok(cond, name)` helper:

```lua
-- === 4m-bis. Update tags, release notes and commit notes ====================
do
    local Update = require("kt_update")
    ok(Update.entry_tag({ channel = "stable", version = "0.3.0" }) == "v0.3.0",
        "update: stable entry tag")
    ok(Update.entry_tag({ channel = "commits", commit = "a1b2c3d" }) == "commits:a1b2c3d",
        "update: commits entry tag")
    ok(Update.entry_tag(nil) == nil and Update.entry_tag({}) == nil,
        "update: entry tag of a broken entry")

    local commits = {
        { sha = "cccccccccccccccc", commit = { message = "third\n\nbody", author = { date = "2026-11-20T10:00:00Z" } } },
        { sha = "bbbbbbbbbbbbbbbb", commit = { message = "second", author = { date = "2026-11-19T10:00:00Z" } } },
        { sha = "aaaaaaaaaaaaaaa", commit = { message = "first", author = { date = "2026-11-18T10:00:00Z" } } },
    }
    local notes = Update.commit_notes(commits, "bbbbbbbb")
    ok(notes.items and #notes.items == 1 and notes.items[1].sha == "ccccccc",
        "update: commit notes stop at the installed commit")
    ok(notes.items[1].message == "third" and notes.items[1].date == "2026-11-20T10:00:00Z",
        "update: commit note carries the first line and the date")
    ok(notes.truncated == false, "update: commit notes are not truncated when the anchor is found")
    local all = Update.commit_notes(commits, "")
    ok(#all.items == 3 and all.truncated == false,
        "update: an empty anchor returns every commit")
    local far = Update.commit_notes(commits, "dddddddd")
    ok(#far.items == 3 and far.truncated == true,
        "update: a missing anchor truncates the window")
    ok(Update.commit_notes(nil, "") and #Update.commit_notes(nil, "").items == 0,
        "update: commit notes of an empty list")
end
```

- [ ] **Step 2: Run the harness to verify the checks fail**

Run: `cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy ./luajit <repo>/tools/ui_smoke.lua`
Expected: FAIL on "update: stable entry tag" (function missing) and the harness exits non-zero.

- [ ] **Step 3: Implement `Update.entry_tag` and `Update.commit_notes` in `kt_update.lua`**

Add next to the other pure helpers (after `Update.normalize_channel`):

- `entry_tag(entry)`: returns `nil` when `entry` is not a table; for `entry.channel == "commits"` returns `"commits:" .. tostring(entry.commit or "")` when the commit is a non-empty string, else `nil`; otherwise `"v" .. tostring(entry.version)` when the version is a non-empty string, else `nil`.
- `commit_notes(commits, installed_commit)`: iterate `commits` in order; for each entry read `entry.sha` and `entry.commit.message` / `entry.commit.author.date`; the message is truncated at the first newline; stop (exclusive) when the entry's SHA starts with `installed_commit` or `installed_commit` starts with the entry's SHA (both short and full SHAs must match); set `truncated = true` when the loop ends without finding the anchor and `installed_commit` is non-empty; return `{ truncated = bool, items = items }` with `items` ordered newest first.

- [ ] **Step 4: Extend `Update.pick_stable_release` with the release text**

In the entry table built by `pick_stable_release`, add `body = type(r.body) == "string" and r.body or ""`, `name = type(r.name) == "string" and r.name or ""`, and `html_url = type(r.html_url) == "string" and r.html_url or ""`. Do not change the selection or ordering rules.

- [ ] **Step 5: Implement `Update.notes`**

`Update.notes(opts, installed)` returns
`{ channel, target, title, version, commit, body, items, truncated }`, where
`target` is `"new"` (there is something newer than the installed build) or
`"installed"` (the user is up to date and wants the notes of what they run).

- stable: fetch `repo_api(repo) .. "/releases?per_page=100"` with the existing `api_get`; build the release list; find the newest stable release (`pick_stable_release`) and the release whose `tag_name` equals `"v" .. installed.version`. If the newest stable release is newer than the installed version, `target = "new"` and the notes come from the NEWEST release; otherwise `target = "installed"` and the notes come from the installed release, falling back to the newest one when the installed tag is gone (an old build, a deleted release). The body is `release.body or ""`; the title is `release.name or release.tag_name`. On a fetch error return `nil, err`.
- commits: fetch `repo_api(repo) .. "/commits?per_page=30&sha=" .. Update.BRANCH`; run `commit_notes(commits, installed and installed.commit or "")`. When the list has items, `target = "new"` and `items` are the commits since the installed one; otherwise `target = "installed"` and `items` is empty (the page shows the "up to date" empty state). The title is the translated `_("Commits")`.

The title strings are translated at call time (never `_()` at file scope).

- [ ] **Step 6: Run the harness to verify the checks pass**

Run: `cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy ./luajit <repo>/tools/ui_smoke.lua`
Expected: the new checks print `ok`; the harness exits 0 and the final check count is higher than before this task.

- [ ] **Step 7: Commit**

```bash
git add kt_update.lua tools/ui_smoke.lua
git commit -m "feat(update): entry tags, release notes and commit notes"
```

---

### Task 2: Background check that never blocks the UI

**Files:**
- Modify: `kt_update.lua`
- Test: `tools/ui_smoke.lua` (extend the `4m-bis` block)

**Interfaces:**
- Consumes: `Update.api_cmd(url)`, `Update.api_get(url)`, `Update.pick_stable_release`, `Update.pick_latest_commit` (existing).
- Produces:
  - `Update.api_bg_cmd(url, body_file, status_file) -> string` — a shell string that runs the API GET detached, writes the body to `body_file` and the HTTP code to `status_file`.
  - `Update.check_bg(opts, callback, deps) -> boolean` — `opts = { repo, channel }`; `callback(ok, entry_or_err)`; `deps = { cmd = function(body_file, status_file) -> string, sched = function(fn, delay), now = function() -> seconds }` (all optional, with production defaults). Returns `true` when a check was started, `false` when one is already in flight.
  - `Update.cancel_bg()` — stops the pending poll and invalidates the callback.

- [ ] **Step 1: Write the failing smoke checks**

Append to the `4m-bis` block:

```lua
    local bg = Update.api_bg_cmd("https://api.github.com/x", "/tmp/body", "/tmp/status")
    ok(bg:find("https://api.github.com/x", 1, true) ~= nil
        and bg:find("/tmp/body", 1, true) ~= nil
        and bg:find("/tmp/status", 1, true) ~= nil
        and bg:find("&", 1, true) ~= nil,
        "update: the background command detaches and names both files")
    ok(bg:find("Authorization", 1, true) == nil,
        "update: the background command carries no token")

    -- The background runner must be testable without the network: inject the
    -- command and the scheduler. The command runs DETACHED, so the poll has
    -- to wait for the files to land: the scheduler only queues the poll and
    -- the test drains the queue.
    local fixture = '[{"tag_name":"v0.4.0","prerelease":false,"published_at":"2026-11-20",'
        .. '"body":"notes here","name":"Nightly",'
        .. '"assets":[{"name":"kotavern.koplugin-0.4.0.zip",'
        .. '"browser_download_url":"https://github.com/o/r/releases/download/v0.4.0/kotavern.koplugin-0.4.0.zip",'
        .. '"digest":"sha256:' .. string.rep("c", 64) .. '"}]}]'
    local got = nil
    local queue = {}
    local started = Update.check_bg({ repo = "o/r", channel = "stable" },
        function(okc, res) got = { okc, res } end,
        {
            cmd = function(body_file, status_file)
                return "printf '%s' '" .. fixture .. "' > " .. body_file
                    .. " && printf '200' > " .. status_file
            end,
            sched = function(fn) queue[#queue + 1] = fn end,
        })
    ok(started == true, "update: the background check starts")
    local socket = require("socket")
    local tries = 0
    while not got and tries < 100 do
        tries = tries + 1
        local fn = table.remove(queue, 1)
        if fn then fn() else socket.sleep(0.02) end
    end
    ok(got ~= nil and got[1] == true and got[2] and got[2].version == "0.4.0",
        "update: the background check parses the fixture release")
    ok(got ~= nil and got[2] and got[2].body == "notes here",
        "update: the background check carries the release body")
    Update.cancel_bg()
```

- [ ] **Step 2: Run the harness to verify the checks fail**

Expected: FAIL on "update: the background command detaches…" (`api_bg_cmd` missing) and the harness exits non-zero.

- [ ] **Step 3: Implement `Update.api_bg_cmd`**

In `kt_update.lua`, next to `api_cmd`:

```lua
-- The same GET, detached: the body lands in body_file, the HTTP code in
-- status_file. The trailing "&" is what makes it non-blocking.
function Update.api_bg_cmd(url, body_file, status_file)
    local cmd = "curl -s --max-time 30 --connect-timeout 15"
    for k, v in pairs(api_headers()) do
        cmd = cmd .. " -H " .. shell_quote(k .. ": " .. v)
    end
    return cmd .. " " .. shell_quote(url)
        .. " -o " .. shell_quote(body_file)
        .. " -w '%{http_code}' > " .. shell_quote(status_file)
        .. " 2>/dev/null &"
end
```

- [ ] **Step 4: Implement `Update.check_bg` and `Update.cancel_bg`**

State (file scope in `kt_update.lua`): `bg_state = { active = false, token = 0, timer = nil }`.

`Update.check_bg(opts, callback, deps)`:
1. If `bg_state.active` is true, return `false`.
2. `deps = deps or {}`; `cmd_for = deps.cmd or function(body_file, status_file) return Update.api_bg_cmd(url, body_file, status_file) end`; `sched = deps.sched or function(fn, delay) return require("ui/uimanager"):scheduleIn(delay, fn) end`; `now = deps.now or function() return require("socket").gettime() end`.
3. Build the URL exactly like `Update.check` does for the channel (`repo_api(repo) .. "/releases?per_page=100"` for stable, `repo_api(repo) .. "/commits?per_page=1&sha=" .. Update.BRANCH` for commits).
4. `body_file = os.tmpname()`, `status_file = os.tmpname()`, `token = bg_state.token + 1`, `bg_state.token = token`, `bg_state.active = true`.
5. `os.execute("(" .. cmd_for(body_file, status_file) .. ") >/dev/null 2>&1 &")`.
6. Poll function: if `bg_state.token ~= token`, return (stale). Read `status_file`; if it contains three digits, read `body_file`, decode with `JSON.decode` + `Util.clean_json`, remove both temp files, set `bg_state.active = false`, and call `callback(true, parsed)` — but the CALLER decides what the parsed payload means, so `check_bg` must apply the same selection rules as `Update.check`: for stable run `pick_stable_release`, for commits run `pick_latest_commit` — and on a failure call `callback(false, "Could not read the GitHub response.")`.
7. If the status file is not ready and `now() - started > 45`, remove both files, set `bg_state.active = false`, and call `callback(false, "The update check timed out.")`.
8. Otherwise schedule the next poll with `sched(poll, 0.5)`.

`Update.cancel_bg()`: bump `bg_state.token`, set `bg_state.active = false`, and drop the stored timer reference (the scheduled callback sees the stale token and returns without calling back).

Store the timer handle returned by `sched` in `bg_state.timer` so `cancel_bg` can invalidate it.

- [ ] **Step 5: Run the harness to verify the checks pass**

Expected: the new checks print `ok`; exit 0.

- [ ] **Step 6: Commit**

```bash
git add kt_update.lua tools/ui_smoke.lua
git commit -m "feat(update): background update check that never blocks"
```

---

### Task 3: The three-action prompt and the automatic check flow

**Files:**
- Modify: `ktui/modals.lua`
- Modify: `kt_app.lua`
- Test: `tools/ui_smoke.lua` (extend the `4m-bis` block)

**Interfaces:**
- Consumes: `Update.check_bg`, `Update.cancel_bg`, `Update.entry_tag`, `Update.is_newer`, `Update.installed_build`, `Modals` helpers.
- Produces:
  - `Modals.build_update_prompt(tag, on_update, on_later, on_cancel) -> ButtonDialog` — builds the dialog WITHOUT showing it (headless-testable): title `_("Update available") .. " " .. tag`, three stacked button rows, in this order: `_("Update now")`, `_("Remind me later")`, `_("Cancel")`.
  - `Modals.update_prompt(tag, on_update, on_later, on_cancel)` — builds and shows it (`UIManager:show`).
  - `Update.should_prompt(entry, installed, settings) -> boolean, string` — pure decision: `false, "up_to_date"` when the entry is not newer; `false, "skipped"` when `settings.update_skip_version` equals `Update.entry_tag(entry)`; `true, "ok"` otherwise.
  - `App:_schedule_update_check()` — schedules `App:_auto_check_updates()` 1 s after the app is shown.
  - `App:_auto_check_updates()` — the throttle + skip gate + `Update.check_bg` call + prompt.
  - `App:_install_update(entry, on_done)` — download, install, update `installed_build`, show the restart confirm; `on_done(ok, message)` is optional.

- [ ] **Step 1: Write the failing smoke checks**

Append to the `4m-bis` block:

```lua
    ok(Update.should_prompt({ channel = "stable", version = "0.3.0" },
        { channel = "stable", version = "0.2.0" }, {}) == true,
        "update: a newer stable entry prompts")
    local skipped, reason = Update.should_prompt({ channel = "stable", version = "0.3.0" },
        { channel = "stable", version = "0.2.0" }, { update_skip_version = "v0.3.0" })
    ok(skipped == false and reason == "skipped",
        "update: a cancelled version never prompts again")
    local same, same_reason = Update.should_prompt({ channel = "stable", version = "0.2.0" },
        { channel = "stable", version = "0.2.0" }, {})
    ok(same == false and same_reason == "up_to_date",
        "update: the installed version never prompts")

    local Modals = require("ktui/modals")
    local dialog = Modals.build_update_prompt("v0.3.0", function() end, function() end, function() end)
    ok(dialog and dialog.buttons and #dialog.buttons == 3,
        "update: the prompt has three actions")
    local labels = {}
    for _i, row in ipairs(dialog.buttons) do
        for _j, button in ipairs(row) do labels[#labels + 1] = button.text end
    end
    ok(labels[1] == require("gettext")("Update now")
        and labels[2] == require("gettext")("Remind me later")
        and labels[3] == require("gettext")("Cancel"),
        "update: the prompt order is now / later / cancel")
```

- [ ] **Step 2: Run the harness to verify the checks fail**

Expected: FAIL on "update: a newer stable entry prompts" and on the prompt checks; exit non-zero.

- [ ] **Step 3: Implement `Update.should_prompt` in `kt_update.lua`**

```lua
-- Should the automatic check open the prompt for this entry?
function Update.should_prompt(entry, installed, settings)
    settings = settings or {}
    if not Update.is_newer(entry, installed) then
        return false, "up_to_date"
    end
    local tag = Update.entry_tag(entry)
    if tag and settings.update_skip_version == tag then
        return false, "skipped"
    end
    return true, "ok"
end
```

- [ ] **Step 4: Implement `Modals.build_update_prompt` and `Modals.update_prompt` in `ktui/modals.lua`**

```lua
-- The update prompt: three stacked native buttons. Built separately from
-- the show call so the headless harness can assert the actions without
-- putting a real dialog on the screen.
function Modals.build_update_prompt(tag, on_update, on_later, on_cancel)
    local dialog
    local function row(text, callback)
        return { { text = text, callback = function()
            UIManager:close(dialog)
            if callback then callback() end
        end } }
    end
    dialog = ButtonDialog:new{
        title = _("Update available") .. " " .. tostring(tag or ""),
        title_align = "center",
        buttons = {
            row(_("Update now"), on_update),
            row(_("Remind me later"), on_later),
            row(_("Cancel"), on_cancel),
        },
    }
    return dialog
end

function Modals.update_prompt(tag, on_update, on_later, on_cancel)
    UIManager:show(Modals.build_update_prompt(tag, on_update, on_later, on_cancel))
end
```

- [ ] **Step 5: Implement the app-side flow in `kt_app.lua`**

Add near the existing self-update section:

```lua
App.UPDATE_CHECK_INTERVAL = 24 * 3600  -- one automatic check per day
App.UPDATE_SNOOZE = 24 * 3600
```

- `App:_schedule_update_check()`: `UIManager:scheduleIn(1, function() self:_auto_check_updates() end)`. Call it at the end of `App:show()` (after `self:refresh(true)`), and only when `self.view` exists.
- `App:_auto_check_updates()`:
  1. `local s = self.state.settings`; return when `s.update_auto_check == false`.
  2. `local now = os.time()`; return when `now < (tonumber(s.update_snooze_until) or 0)`.
  3. Return when `now - (tonumber(s.update_checked_at) or 0) < App.UPDATE_CHECK_INTERVAL`.
  4. Return when `self._update_check_token` is set (a check is in flight).
  5. Build `opts = { repo = trimmed settings.update_repo or Update.default_repo(), channel = Update.normalize_channel(s.update_channel) }`.
  6. `self._update_check_token = (self._update_check_token or 0) + 1`; `local token = self._update_check_token`.
  7. `Update.check_bg(opts, function(okc, res) ... end)`; inside the callback: if `token ~= self._update_check_token` or `not self.view` then return; `self._update_check_token = nil`; stamp `s.update_checked_at = os.time()` and save; on failure return silently; otherwise `s.update_last_entry = { channel = res.channel, version = res.version, commit = res.commit, tag = Update.entry_tag(res) }` and save; `local installed = Update.installed_build(s.installed_build)`; `local prompt, reason = Update.should_prompt(res, installed, s)`; when not `prompt` return; then show the prompt:
     - `on_update` → `self:_install_update(res)`.
     - `on_later` → `s.update_snooze_until = os.time() + App.UPDATE_SNOOZE`; save.
     - `on_cancel` → `s.update_skip_version = Update.entry_tag(res)`; save.
  8. The prompt uses `Modals.update_prompt(tag, ...)`.
- `App:close()` must call `Update.cancel_bg()` and bump `self._update_check_token` so a late callback never opens a dialog.
- `App:_install_update(entry, on_done)`: move the existing install block out of `App:check_updates_now` into this method — `Modals.status(_("Downloading update…"))`, `UIManager:forceRePaint()`, `Update.install(entry)`, `Modals.close_status()`, on failure show the error via `InfoMessage` and call `on_done(false, err)`; on success update `settings.installed_build`, save, set `update_status`, and show the existing `Sheets.confirm` restart box (`_("Update installed")`, `_("Restart now")`, `UIManager.restartKOReader`), then `on_done(true, version)`.
- `App:check_updates_now()` keeps its current behavior but calls `App:_install_update(res)` instead of inlining the install, and also stamps `s.update_checked_at = os.time()` plus the notes cache (Task 4).

- [ ] **Step 6: Run the harness to verify the checks pass**

Expected: the new checks print `ok`; exit 0.

- [ ] **Step 7: Commit**

```bash
git add ktui/modals.lua kt_app.lua kt_update.lua tools/ui_smoke.lua
git commit -m "feat(update): prompt on open with update / later / cancel"
```

---

### Task 4: The "What's new" row and the release notes page

**Files:**
- Modify: `ktui/pages.lua` (new `Pages.release_notes`, new rows in `Pages.settings_updates`)
- Modify: `ktui/app_view.lua` (dispatch the new page)
- Modify: `ktui/header.lua` (page titles)
- Modify: `kt_app.lua` (settings key `update_notes_cache`, `App:show_release_notes()`, cache writes)
- Test: `tools/ui_smoke.lua` (new section)

**Interfaces:**
- Consumes: `Update.notes`, `Update.entry_tag`, `Update.installed_build`, `ktui/md.lua` (`Md.parse`), `P.scrollable_paragraph`.
- Produces:
  - `settings.update_notes_cache` — `{ channel, target, version, commit, title, body, items, truncated, fetched_at }` (`target` is `"new"` or `"installed"`; a cache without it is read as `"installed"`).
  - `App:show_release_notes()` — navigates to the `release_notes` page.
  - `App:refresh_release_notes()` — fills `settings.update_notes_cache` from `Update.notes` (network) when the cache is empty or stale.
  - `Pages.release_notes(view, bb, x, y, w, h, scroll)` — paints the cached notes.

- [ ] **Step 1: Write the failing smoke checks**

Add a new section to `tools/ui_smoke.lua`:

```lua
-- === 4m-ter. Release notes page ===========================================
do
    local app = fake_app({ page = "release_notes" })
    app.state.settings.update_notes_cache = {
        channel = "stable", target = "new", title = "Nightly", version = "0.4.0",
        body = "# Heading\n\nSome **bold** text.\n\n- one\n- two",
        items = {}, truncated = false, fetched_at = os.time(),
    }
    local view = { app = app, hitboxes = {} }
    local bb = new_bb()
    local okp, err = pcall(function()
        Pages.release_notes(view, bb, 0, 0, VW, VH - Theme.metrics().nav_h, 0)
    end)
    ok(okp, "release notes: the page renders (" .. tostring(err) .. ")")
    ok(ink_ratio(bb) > 50, "release notes: the page paints text")
    dump(bb, "release_notes")

    local app2 = fake_app({ page = "release_notes" })
    app2.state.settings.update_notes_cache = {
        channel = "commits", target = "new", title = "Commits", items = {
            { sha = "abc1234", message = "a commit", date = "2026-11-20" },
        }, body = "", truncated = false,
    }
    local bb2 = new_bb()
    local okp2, err2 = pcall(function()
        Pages.release_notes({ app = app2, hitboxes = {} }, bb2, 0, 0, VW, VH - Theme.metrics().nav_h, 0)
    end)
    ok(okp2, "release notes: the commits channel renders (" .. tostring(err2) .. ")")
end
```

- [ ] **Step 2: Run the harness to verify the checks fail**

Expected: FAIL on "release notes: the page renders" (`Pages.release_notes` is nil) and exit non-zero.

- [ ] **Step 3: Implement `Pages.release_notes` in `ktui/pages.lua`**

- Read the cache: `local cache = app.state.settings.update_notes_cache or {}`.
- If the cache is empty, paint an empty state (`Widgets.empty_state`) with the text `_("No release notes yet.")` and an action button `_("Check for updates")` that calls `app:check_updates_now()`.
- Otherwise paint, inside the content area:
  - a header line: the cache title plus the version/commit, and a label that says whether these are the NEW notes (`_("New in %1")` with the version) or the installed ones (`_("Installed version")`) — driven by `cache.target`;
  - for `channel == "commits"`: one row per item in `cache.items`, each `sha .. " · " .. message` (the message is the FIRST line of the commit message; the body is not shown), using `Widgets.row` (it truncates long subjects safely). When `cache.items` is empty, paint the empty state `_("You are up to date.")` with the action `_("Check for updates")`;
  - for the stable channel: parse `cache.body` with `Md.parse(cache.body)` and paint each block with `P.scrollable_paragraph` (headings bold, list items prefixed with "• ", quotes with a left bar, code blocks in a monospace face if one is available in `Theme`; otherwise the default face).
- Return the scroll extent so the page scrolls.

- [ ] **Step 4: Add the rows to `Pages.settings_updates`**

Add two rows to the existing `rows` table:

```lua
        { text = _("What's new"), icon = "info-circle",
            value = function()
                -- When something newer exists the row says so: the page then
                -- shows the NEW notes (that is what "what's new" means).
                local entry = app.state.settings.update_last_entry
                if type(entry) == "table" and entry.tag then
                    local installed = Update.installed_build(app.state.settings.installed_build)
                    if Update.is_newer({ channel = entry.channel, version = entry.version,
                        commit = entry.commit }, installed) then
                        return _("Update available")
                    end
                end
                local installed = Update.installed_build(app.state.settings.installed_build)
                return Update.about_title(installed)
            end,
            callback = function() app:show_release_notes() end },
        { text = _("Check for updates automatically"), icon = "refresh", toggle = true,
            value = function() return app.state.settings.update_auto_check ~= false end,
            callback = function()
                app:save_setting("update_auto_check",
                    app.state.settings.update_auto_check == false)
            end },
```

- [ ] **Step 5: Wire the page in `ktui/app_view.lua` and `ktui/header.lua`**

- `app_view.lua`: add `elseif page == "release_notes" then max_scroll = Pages.release_notes(self, bb, x, y, w, h, scroll)` next to the other page branches.
- `header.lua`: in `page_title`, add a branch returning `_("What's new")` for `page == "release_notes"`, and add `settings_updates = _("Updates")` to the settings name table (today that page falls back to "Settings").

- [ ] **Step 6: Implement the cache in `kt_app.lua`**

- `App:show_release_notes()`: `self:navigate("release_notes")`; when the cache is empty or stale (the cached version/commit no longer matches `Update.installed_build(settings.installed_build)`), call `self:refresh_release_notes()` first.
- `App:refresh_release_notes()`: `Modals.status(_("Fetching release notes…"))`, `UIManager:forceRePaint()`, `Update.notes({ repo = ..., channel = ... }, Update.installed_build(s.installed_build))`, `Modals.close_status()`; on success store the result in `s.update_notes_cache` (plus `fetched_at = os.time()`) and save; on failure show the error via `InfoMessage` and keep the old cache.
- In `App:check_updates_now()`, after a successful check, also store `s.update_last_entry` and refresh the notes cache (call `App:refresh_release_notes()` only when the cache is empty).

- [ ] **Step 7: Run the harness to verify the checks pass**

Expected: the new checks print `ok`; exit 0.

- [ ] **Step 8: Commit**

```bash
git add ktui/pages.lua ktui/app_view.lua ktui/header.lua kt_app.lua tools/ui_smoke.lua
git commit -m "feat(update): what's new page for stable and artifact channels"
```

---

### Task 5: Translations and the full gate

**Files:**
- Modify: `locales/pt_BR.po`
- Modify: `locales/es.po`

**Interfaces:**
- Consumes: the msgids introduced by Tasks 1–4.
- Produces: the localized catalogs.

- [ ] **Step 1: Collect the new msgids**

Run: `python3 tools/check_i18n.py`
Expected: a list of the missing msgids (the checker names every untranslated or missing id).

- [ ] **Step 2: Translate every new msgid in both catalogs**

Add each msgid with a non-empty `msgstr` to `locales/pt_BR.po` (Portuguese) and `locales/es.po` (Spanish), keeping the files sorted as the checker expects. The new ids include at least: "Update available", "Update now", "Remind me later", "What's new", "Check for updates automatically", "Fetching release notes…", "No release notes yet.", "Commits".

- [ ] **Step 3: Run the i18n gate**

Run: `python3 tools/check_i18n.py`
Expected: exit 0, no missing or empty msgstr.

- [ ] **Step 4: Run the syntax gate on every touched file**

Run: `for f in kt_update.lua kt_app.lua ktui/modals.lua ktui/pages.lua ktui/app_view.lua ktui/header.lua; do luajit -bl "$f" > /dev/null || echo "FAIL $f"; done`
Expected: no output.

- [ ] **Step 5: Run the full harness**

Run: `cd /usr/lib/koreader && KO_HOME=/tmp/kotavern_ko SDL_VIDEODRIVER=dummy ./luajit <repo>/tools/ui_smoke.lua`
Expected: exit 0; the final check count is higher than before Task 1.

- [ ] **Step 6: Commit**

```bash
git add locales/pt_BR.po locales/es.po
git commit -m "i18n: update prompt and release notes strings"
```

---

### Manual device checklist (not a code step)

- Open the plugin on the device with an update available: the native prompt appears within a few seconds and the first paint is not delayed.
- "Remind me later": no prompt for 24 h; reopen the app after 24 h and the prompt is back.
- "Cancel": no prompt for that version; publish a newer version and the prompt appears again.
- Open the plugin in airplane mode: no prompt, no error dialog, the app paints normally.
- Open a book (native reader) and let the check land: the prompt appears over the reader and the reader stays put.
- Settings → Updates → "What's new": the release body renders on both channels; with the network off it shows the cached text.
