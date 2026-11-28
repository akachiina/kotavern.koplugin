-- Self-update from GitHub: stable Releases + repo snapshot (commits).
-- ZenPM updater parity (trust validation, digest check, staged install with
-- rollback), adapted: curl transport (no LuaSec on device), no daemon.
--
-- Channels: "stable" (latest non-prerelease, asset kotavern.koplugin-<ver>.zip
-- with sha256 digest) and "commits" (zipball of the default branch -
-- https://github.com/{repo}/archive/refs/heads/main.zip - public, no token;
-- SHA from the commits API). No GitHub token is used anywhere.
-- Pure selection helpers are exposed for the headless harness.

local JSON = require("json")

local Constants = require("kt_constants")
local Util = require("kotaven_util")

local Update = {}

Update.DEFAULT_REPO = "akachiina/kotavern.koplugin"
Update.RELEASE_ROOT = "kotavern.koplugin"
Update.BRANCH = "main"

local ok_logger, logger = pcall(require, "logger")

local function log_info(...)
    if ok_logger and logger and logger.info then
        logger.info("kotavern update:", ...)
    end
end

local function log_warn(...)
    if ok_logger and logger and logger.warn then
        logger.warn("kotavern update:", ...)
    end
end

local function shell_quote(value)
    return "'" .. tostring(value or ""):gsub("'", "'\"'\"'") .. "'"
end

-- === Versions (semver port, Lua 5.1-safe) =====================================

local function semver_parts(version)
    local value = (tostring(version or ""):match("^v?(.+)$") or "")
    local base = value:match("^([%d%.]+)") or ""
    local major, minor, patch = base:match("^(%d+)%.(%d+)%.?(%d*)$")
    return tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0
end

-- True when left is strictly newer than right ("v" prefix tolerated).
function Update.version_gt(left, right)
    local lmaj, lmin, lpatch = semver_parts(left)
    local rmaj, rmin, rpatch = semver_parts(right)
    if lmaj ~= rmaj then return lmaj > rmaj end
    if lmin ~= rmin then return lmin > rmin end
    return lpatch > rpatch
end

function Update.asset_name_for(version)
    local v = tostring(version or ""):gsub("^v", "")
    if v == "" then return nil end
    return "kotavern.koplugin-" .. v .. ".zip"
end

function Update.default_repo()
    return Update.DEFAULT_REPO
end

-- Channel normalization (legacy "dev" value reads as "commits").
function Update.normalize_channel(channel)
    if channel == "commits" or channel == "dev" then
        return "commits"
    end
    return "stable"
end

-- The identity of an update candidate: "v0.3.0" for a release, "commits:<sha>"
-- for a repo snapshot. It is the key of the "Cancel" (skip this version)
-- state and the label of the update prompt.
function Update.entry_tag(entry)
    if type(entry) ~= "table" then return nil end
    if entry.channel == "commits" then
        local commit = entry.commit
        if type(commit) == "string" and commit ~= "" then
            return "commits:" .. commit
        end
        return nil
    end
    local version = entry.version
    if type(version) == "string" and version ~= "" then
        return "v" .. version
    end
    return nil
end

-- The commits newer than the installed one, newest first. The anchor may be
-- a short or a full SHA; the matching commit itself is NOT part of the list.
-- truncated = true when the anchor is not in the window (the list is only
-- the newest N commits, so the installed build may be older than that).
function Update.commit_notes(commits, installed_commit)
    local items = {}
    local anchor = tostring(installed_commit or "")
    anchor = anchor:gsub("^%s+", ""):gsub("%s+$", "")
    local found = false
    for _ci, c in ipairs(commits or {}) do
        if type(c) == "table" then
            local sha = tostring(c.sha or "")
            if anchor ~= "" and sha ~= ""
                and (sha:sub(1, #anchor) == anchor or anchor:sub(1, #sha) == sha) then
                found = true
                break
            end
            local commit = type(c.commit) == "table" and c.commit or {}
            local author = type(commit.author) == "table" and commit.author or {}
            local message = tostring(commit.message or "")
            message = message:match("^[^\n]*") or ""
            items[#items + 1] = {
                sha = sha:sub(1, 7),
                message = message,
                date = tostring(author.date or ""),
            }
        end
    end
    return {
        truncated = (anchor ~= "" and not found),
        items = items,
    }
end

-- === Trust validation =========================================================

local trusted_download_hosts = {
    ["github.com"] = true,
    ["codeload.github.com"] = true,
    ["objects.githubusercontent.com"] = true,
    ["release-assets.githubusercontent.com"] = true,
    ["github-releases.githubusercontent.com"] = true,
}

-- Only https URLs on trusted hosts. No token is ever sent.
function Update.trusted_url(url)
    local scheme, host = tostring(url or ""):match("^(https?)://([^/%?#]+)")
    if scheme ~= "https" or not host then return false end
    return trusted_download_hosts[host:lower()] == true
end

local function valid_digest(digest)
    if type(digest) ~= "string" then return false end
    local value = digest:match("^sha256:([0-9a-fA-F]+)$")
    return type(value) == "string" and #value == 64
end

-- === Release / commit selection (pure; fixtures in the harness) ================

-- Latest non-prerelease with a matching, digest-bearing asset.
function Update.pick_stable_release(releases)
    local entries = {}
    for i, r in ipairs(releases or {}) do
        if type(r) == "table" and r.prerelease ~= true then
            local version = tostring(r.tag_name or ""):gsub("^v", "")
            local want = Update.asset_name_for(version)
            if version ~= "" and want then
                for _, a in ipairs(r.assets or {}) do
                    if type(a) == "table" and a.name == want
                        and Update.trusted_url(a.browser_download_url)
                        and valid_digest(a.digest) then
                        entries[#entries + 1] = {
                            version = version, tag = r.tag_name,
                            published_at = r.published_at or r.created_at or "",
                            asset = a, index = i,
                            -- The release text: the "What's new" page shows it.
                            body = type(r.body) == "string" and r.body or "",
                            name = type(r.name) == "string" and r.name or "",
                            html_url = type(r.html_url) == "string" and r.html_url or "",
                        }
                        break
                    end
                end
            end
        end
    end
    table.sort(entries, function(l, r)
        if l.published_at ~= r.published_at then return l.published_at > r.published_at end
        return l.index < r.index
    end)
    return entries[1]
end

-- Newest commit in a commits-API list (per_page=1 in production).
function Update.pick_latest_commit(commits)
    if type(commits) ~= "table" then return nil end
    local c = commits[1]
    if type(c) ~= "table" or type(c.sha) ~= "string" or c.sha == "" then
        return nil
    end
    return tostring(c.sha):sub(1, 7)
end

-- Unsafe zip member (absolute path or .. escape).
function Update.unsafe_entry(path)
    if path == "" or path:sub(1, 1) == "/" or path:sub(1, 1) == "\\" then return true end
    for part in path:gmatch("[^/\\]+") do
        if part == ".." then return true end
    end
    return false
end

-- === Network (curl; no LuaSec on device) =======================================

local function api_headers()
    return { ["User-Agent"] = "kotavern.koplugin", ["Accept"] = "application/vnd.github+json" }
end

-- Build the curl command for a GitHub API GET (exposed for the harness:
-- asserts headers without touching the network). Never any Authorization.
function Update.api_cmd(url)
    local cmd = "curl -s --max-time 30 --connect-timeout 15"
    for k, v in pairs(api_headers()) do
        cmd = cmd .. " -H " .. shell_quote(k .. ": " .. v)
    end
    return cmd .. " " .. shell_quote(url)
end

-- The same GET, detached: the body lands in body_file, the HTTP code in
-- status_file. The trailing "&" is what makes it non-blocking - the caller
-- runs it in the background and polls the status file.
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

local function api_get(url)
    local cmd = Update.api_cmd(url)
    local p = io.popen(cmd .. " 2>/dev/null", "r")
    if not p then
        return nil, "Could not spawn curl."
    end
    local body = p:read("*a") or ""
    p:close()
    if body == "" then
        return nil, "Empty response from GitHub."
    end
    local ok, decoded = pcall(JSON.decode, body)
    if not ok or decoded == nil then
        return nil, "Could not read the GitHub response."
    end
    return Util.clean_json(decoded)
end

local function sha256_file(path)
    local ok_sha, sha2 = pcall(require, "ffi/sha2")
    if not ok_sha or not sha2 or not sha2.sha256 then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local append = sha2.sha256()
    while true do
        local chunk = f:read(64 * 1024)
        if not chunk then break end
        append(chunk)
    end
    f:close()
    local ok, digest = pcall(append)
    return (ok and type(digest) == "string") and digest:lower() or nil
end

-- Download with redirect following; the EFFECTIVE host must stay trusted
-- (fail closed). Returns true, or false + error.
local function download(url, path, digest)
    if not Update.trusted_url(url) then
        return false, "Untrusted download URL."
    end
    local cmd = "curl -sL --max-redirs 5 --max-time 300 --connect-timeout 20"
        .. ' -w "%{url_effective}"'
    for k, v in pairs(api_headers()) do
        cmd = cmd .. " -H " .. shell_quote(k .. ": " .. v)
    end
    cmd = cmd .. " " .. shell_quote(url) .. " -o " .. shell_quote(path)
    local p = io.popen(cmd .. " 2>/dev/null", "r")
    if not p then
        return false, "Could not spawn curl."
    end
    local effective = p:read("*a") or ""
    p:close()
    effective = effective:match("^%s*(.-)%s*$")
    if not Update.trusted_url(effective) then
        os.remove(path)
        log_warn("download landed on an untrusted host")
        return false, "Download redirected to an untrusted host."
    end
    local f = io.open(path, "rb")
    if not f then
        return false, "Download produced no file."
    end
    f:close()
    if valid_digest(digest) then
        local actual = sha256_file(path)
        if not actual then
            os.remove(path)
            return false, "Could not verify the update download."
        end
        if actual ~= digest:sub(8):lower() then
            os.remove(path)
            log_warn("update checksum did not match")
            return false, "Downloaded update checksum did not match."
        end
    end
    log_info("downloaded and verified", path)
    return true
end

-- === Extract / install ==========================================================

local function is_dir(path)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local attrs = ok_lfs and lfs.attributes(path)
    return attrs and attrs.mode == "directory"
end

local function remove_tree(path)
    os.execute("rm -rf " .. shell_quote(path))
end

local function has_file(path)
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
end

-- Unpack into stage_dir; returns ok, plugin_subdir-or-err. Accepts two
-- layouts: release assets rooted at kotavern.koplugin/, and repo zipballs
-- (single top-level dir holding main.lua + _meta.lua).
local function extract(zip_path, stage_dir)
    local ok_arch, Archiver = pcall(require, "ffi/archiver")
    if not ok_arch or not Archiver then
        return false, "Archive support is unavailable in this KOReader build."
    end
    local root = Update.RELEASE_ROOT
    local archive = Archiver.Reader:new()
    if not archive:open(zip_path) then
        return false, archive.err or "Could not open update archive."
    end
    local entries = 0
    local top_dirs = {}
    for entry in archive:iterate() do
        if Update.unsafe_entry(entry.path)
            or (entry.mode ~= "file" and entry.mode ~= "directory") then
            archive:close()
            return false, "Update archive has an invalid layout."
        end
        local top = entry.path:match("^([^/\\]+)")
        if top then top_dirs[top] = true end
        if not archive:extractToPath(entry.path, stage_dir .. "/" .. entry.path) then
            local err = archive.err or "Could not unpack update archive."
            archive:close()
            return false, err
        end
        entries = entries + 1
    end
    local err = archive.err
    archive:close()
    if err or entries == 0 then return false, err or "Update archive is empty." end
    if is_dir(stage_dir .. "/" .. root)
        and has_file(stage_dir .. "/" .. root .. "/_meta.lua")
        and has_file(stage_dir .. "/" .. root .. "/main.lua")
        and has_file(stage_dir .. "/" .. root .. "/kt_app.lua") then
        return true, root
    end
    -- Repo zipball: exactly one top-level dir that IS the plugin.
    local tops = {}
    for d in pairs(top_dirs) do tops[#tops + 1] = d end
    if #tops == 1 and is_dir(stage_dir .. "/" .. tops[1])
        and has_file(stage_dir .. "/" .. tops[1] .. "/_meta.lua")
        and has_file(stage_dir .. "/" .. tops[1] .. "/main.lua")
        and has_file(stage_dir .. "/" .. tops[1] .. "/kt_app.lua") then
        return true, tops[1]
    end
    return false, "Update archive does not contain a KOTavern plugin."
end

local function plugins_dir()
    local plugin_dir = Constants.PLUGIN_DIR
    local dir = plugin_dir:match("^(.*)/[^/]+$")
    local name = plugin_dir:match("([^/]+)$")
    if not dir or not name or not is_dir(dir) then return nil, nil end
    return dir, name
end

local function install_staged(stage_dir, staged_subdir, version)
    local dir, name = plugins_dir()
    if not dir then
        return false, "Could not find KOReader's plugins directory."
    end
    local plugin_dir = Constants.PLUGIN_DIR
    local staged = stage_dir .. "/" .. staged_subdir
    local backup_dir = dir .. "/." .. name .. ".backup"
    local probe = io.open(dir .. "/.kotavern-update-write-probe", "wb")
    if not probe then
        return false, "KOReader's plugins directory is not writable."
    end
    probe:close()
    os.remove(dir .. "/.kotavern-update-write-probe")
    remove_tree(backup_dir)
    local had_plugin = is_dir(plugin_dir)
    if had_plugin and not os.rename(plugin_dir, backup_dir) then
        return false, "Could not move the old KOTavern plugin."
    end
    if not os.rename(staged, plugin_dir) then
        if had_plugin then os.rename(backup_dir, plugin_dir) end
        log_warn("could not install staged plugin; restored previous version")
        return false, "Could not install the updated plugin."
    end
    remove_tree(stage_dir)
    remove_tree(backup_dir)
    log_info("update installed", version)
    return true, version
end

-- === Public flow ==================================================================

local function repo_api(repo)
    return "https://api.github.com/repos/" .. tostring(repo or "")
end

local function zipball_url(repo)
    return "https://github.com/" .. tostring(repo or "")
        .. "/archive/refs/heads/" .. Update.BRANCH .. ".zip"
end

-- Check for updates. opts = { repo, channel ("stable"|"commits") }.
-- Returns ok, "up_to_date" | entry { channel, version, tag, commit,
-- asset_name, download_url, digest } | err string. No token anywhere.
function Update.check(opts)
    opts = opts or {}
    local repo = tostring(opts.repo or ""):match("^%s*(.-)%s*$")
    if repo == "" then
        repo = Update.DEFAULT_REPO
    end
    if not repo:match("^[%w%.%-]+/[%w%.%-]+$") then
        return false, "Repository must look like owner/name."
    end
    local channel = Update.normalize_channel(opts.channel)
    if channel == "stable" then
        local releases, err = api_get(repo_api(repo) .. "/releases?per_page=100")
        if not releases then return false, err end
        if type(releases) ~= "table" then
            return false, "Could not read release information."
        end
        local entry = Update.pick_stable_release(releases)
        if not entry then
            return false, "No stable KOTavern release found."
        end
        entry.channel = "stable"
        entry.download_url = entry.asset.browser_download_url
        entry.digest = entry.asset.digest
        entry.asset_name = entry.asset.name
        return true, entry
    end
    local commits, err = api_get(repo_api(repo) .. "/commits?per_page=1&sha=" .. Update.BRANCH)
    if not commits then return false, err end
    local commit = Update.pick_latest_commit(commits)
    if not commit then
        return false, "Could not read the latest commit."
    end
    local url = zipball_url(repo)
    if not Update.trusted_url(url) then
        return false, "Untrusted download URL."
    end
    return true, {
        channel = "commits",
        version = nil,
        tag = nil,
        commit = commit,
        asset_name = "repo snapshot " .. commit,
        download_url = url,
        digest = nil, -- no digest for zipballs: layout check only
    }
end

-- === Background check (never blocks the UI) =================================
--
-- The automatic check runs when the plugin opens: it must not freeze the
-- first paint, so curl is spawned DETACHED and the result is polled from the
-- UI timer. Only one check may be in flight; cancel_bg() kills the poll.

local bg_state = {
    active = false,
    token = 0,
    body_file = nil,
    status_file = nil,
}

function Update.cancel_bg()
    bg_state.token = bg_state.token + 1
    bg_state.active = false
    if bg_state.body_file then os.remove(bg_state.body_file) end
    if bg_state.status_file then os.remove(bg_state.status_file) end
    bg_state.body_file = nil
    bg_state.status_file = nil
end

-- Check for updates without blocking. opts = { repo, channel };
-- callback(ok, entry_or_err). deps = { cmd, sched, now } are injection points
-- for the headless harness (a fake command and a fake scheduler).
function Update.check_bg(opts, callback, deps)
    if bg_state.active then return false end
    opts = opts or {}
    deps = deps or {}
    local repo = tostring(opts.repo or ""):match("^%s*(.-)%s*$")
    if repo == "" then
        repo = Update.default_repo()
    end
    local channel = Update.normalize_channel(opts.channel)
    local url = (channel == "stable")
        and (repo_api(repo) .. "/releases?per_page=100")
        or (repo_api(repo) .. "/commits?per_page=1&sha=" .. Update.BRANCH)

    local body_file = os.tmpname()
    local status_file = os.tmpname()
    local cmd_for = deps.cmd or function(b, s)
        return Update.api_bg_cmd(url, b, s)
    end
    local sched = deps.sched or function(fn, delay)
        return require("ui/uimanager"):scheduleIn(delay, fn)
    end
    local now = deps.now or function()
        return require("socket").gettime()
    end

    bg_state.active = true
    bg_state.token = bg_state.token + 1
    bg_state.body_file = body_file
    bg_state.status_file = status_file
    local token = bg_state.token
    local started_at = now()

    os.execute("(" .. cmd_for(body_file, status_file) .. ") >/dev/null 2>&1 &")

    local function finish(okc, res)
        os.remove(body_file)
        os.remove(status_file)
        if bg_state.token ~= token then return end
        bg_state.active = false
        bg_state.body_file = nil
        bg_state.status_file = nil
        if callback then callback(okc, res) end
    end

    local poll
    poll = function()
        if bg_state.token ~= token then return end
        local fs = io.open(status_file, "r")
        local content = fs and (fs:read("*a") or "") or ""
        if fs then fs:close() end
        if content:match("%d%d%d") then
            local body = ""
            local bf = io.open(body_file, "r")
            if bf then
                body = bf:read("*a") or ""
                bf:close()
            end
            local ok_decode, decoded = pcall(JSON.decode, body)
            if not ok_decode or decoded == nil then
                finish(false, "Could not read the GitHub response.")
                return
            end
            local parsed = Util.clean_json(decoded)
            if channel == "stable" then
                if type(parsed) ~= "table" then
                    finish(false, "Could not read release information.")
                    return
                end
                local entry = Update.pick_stable_release(parsed)
                if not entry then
                    finish(false, "No stable KOTavern release found.")
                    return
                end
                entry.channel = "stable"
                entry.download_url = entry.asset.browser_download_url
                entry.digest = entry.asset.digest
                entry.asset_name = entry.asset.name
                finish(true, entry)
                return
            end
            if type(parsed) ~= "table" then
                finish(false, "Could not read the latest commit.")
                return
            end
            local commit = Update.pick_latest_commit(parsed)
            if not commit then
                finish(false, "Could not read the latest commit.")
                return
            end
            finish(true, {
                channel = "commits",
                version = nil,
                tag = nil,
                commit = commit,
                asset_name = "repo snapshot " .. commit,
                download_url = zipball_url(repo),
                digest = nil,
            })
            return
        end
        if now() - started_at > 45 then
            finish(false, "The update check timed out.")
            return
        end
        sched(poll, 0.5)
    end
    sched(poll, 0.5)
    return true
end

-- Should the automatic check open the update prompt for this entry?
-- Returns true + "ok", or false + the reason it stays quiet
-- ("up_to_date" / "skipped").
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

-- Is entry newer than the installed build? installed = { channel, version,
-- commit } (settings.installed_build; legacy = stable VERSION).
function Update.is_newer(entry, installed)
    installed = installed or {}
    if not entry or type(entry) ~= "table" then return false end
    if entry.channel == "commits" then
        if installed.channel == "commits" and installed.commit then
            return tostring(entry.commit) ~= tostring(installed.commit)
        end
        return true -- switching channels always offers the build
    end
    return Update.version_gt(entry.version, installed.version or "0")
end

-- The release notes for the "What's new" page.
-- opts = { repo, channel }; installed = { channel, version, commit }.
-- Returns { channel, target, title, version, commit, body, items, truncated }
-- where target is "new" (something newer than the installed build exists) or
-- "installed" (the user is up to date and wants the notes of what they run).
function Update.notes(opts, installed)
    opts = opts or {}
    installed = installed or {}
    local _ = require("gettext")
    local repo = tostring(opts.repo or ""):match("^%s*(.-)%s*$")
    if repo == "" then
        repo = Update.default_repo()
    end
    local channel = Update.normalize_channel(opts.channel)

    if channel == "commits" then
        local commits, err = api_get(repo_api(repo) .. "/commits?per_page=30&sha=" .. Update.BRANCH)
        if not commits then return nil, err end
        if type(commits) ~= "table" then
            return nil, "Could not read the commit list."
        end
        local list = Update.commit_notes(commits, installed.commit or "")
        return {
            channel = "commits",
            target = (#list.items > 0) and "new" or "installed",
            title = _("Commits"),
            version = nil,
            commit = installed.commit,
            body = "",
            items = list.items,
            truncated = list.truncated,
        }
    end

    local releases, err = api_get(repo_api(repo) .. "/releases?per_page=100")
    if not releases then return nil, err end
    if type(releases) ~= "table" then
        return nil, "Could not read release information."
    end

    local function release_by_tag(tag)
        for _ri, r in ipairs(releases) do
            if type(r) == "table" and tostring(r.tag_name or "") == tostring(tag or "") then
                return r
            end
        end
        return nil
    end

    local newest = Update.pick_stable_release(releases)
    local installed_version = tostring(installed.version or ""):gsub("^v", "")
    local installed_release = nil
    if installed_version ~= "" then
        installed_release = release_by_tag("v" .. installed_version)
    end

    local target = "installed"
    local release = installed_release
    if newest and (installed_version == ""
        or Update.version_gt(newest.version, installed_version)) then
        -- There IS something newer: the notes the user wants are the ones
        -- of the release they would get.
        target = "new"
        release = release_by_tag(newest.tag) or installed_release
    end
    if not release then release = installed_release end
    if not release then
        return nil, "Could not find the release notes."
    end

    local title = type(release.name) == "string" and release.name or ""
    if title == "" then title = tostring(release.tag_name or "") end
    return {
        channel = "stable",
        target = target,
        title = title,
        version = tostring(release.tag_name or ""):gsub("^v", ""),
        commit = nil,
        body = type(release.body) == "string" and release.body or "",
        items = {},
        truncated = false,
    }
end

-- Full install: download + verify + extract + swap. Returns ok, version/err.
function Update.install(entry)
    if not entry or not entry.download_url then
        return false, "Nothing to install."
    end
    local dir = plugins_dir()
    if not dir then
        return false, "Could not find KOReader's plugins directory."
    end
    local zip_path = dir .. "/.kotavern-update.zip"
    local stage_dir = dir .. "/.kotavern-update-stage"
    remove_tree(stage_dir)
    os.remove(zip_path)
    local ok, err = download(entry.download_url, zip_path, entry.digest)
    if not ok then return false, err end
    local unpacked, staged_or_err = extract(zip_path, stage_dir)
    os.remove(zip_path)
    if not unpacked then
        remove_tree(stage_dir)
        return false, staged_or_err
    end
    local SHOW_VERSION = entry.version or (entry.commit and ("commits-" .. entry.commit)) or "commits"
    local installed, install_err = install_staged(stage_dir, staged_or_err, SHOW_VERSION)
    remove_tree(stage_dir)
    if not installed then return false, install_err end
    return true, SHOW_VERSION
end

-- Installed build descriptor for the About screen.
function Update.installed_build(settings_build)
    if type(settings_build) == "table" and settings_build.version then
        return settings_build
    end
    return { channel = "stable", version = Constants.VERSION }
end

-- About title line: "KOTavern v0.2.0 Stable" | "KOTavern v0.2.0 (a1b2c3d)".
-- Both words are msgids in the locales: the prefix and "Stable" translate
-- (the version never does).
function Update.about_title(build)
    build = build or {}
    local _ = require("gettext")
    local v = tostring(build.version or Constants.VERSION)
    if build.channel == "commits" and build.commit then
        return _("KOTavern v") .. v .. " (" .. tostring(build.commit) .. ")"
    end
    return _("KOTavern v") .. v .. " " .. _("Stable")
end

return Update
