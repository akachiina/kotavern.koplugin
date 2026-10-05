-- World Info / Lorebook engine (SillyTavern-compatible subset, complete
-- activation mechanics). Pure Lua - no UI dependencies, unit-testable.
--
-- WI.parse_entry(raw)  → normalized entry (defaults filled)
-- WI.scan(entries, opts) → { before, after, injections = { {content, depth, role} },
--                            activated = { uid... } }
--   opts.text        - the scan text (recent chat history)
--   opts.extra_text  - persona/description text (also scanned)
--   opts.scan_depth  - default messages scanned (chat_metadata.world_info.depth)
--   opts.budget      - token budget for activated content (0/nil = unlimited)
--   opts.msg_count   - messages since chat start (timed effects)
--   opts.state       - persistent table for sticky/cooldown (chat_metadata)
--   opts.max_recursion - recursion steps (default 3)

local WI = {}

local SELECTIVE_LOGIC = { AND_ANY = 0, NOT_ALL = 1, NOT_ANY = 2, AND_ALL = 3 }
WI.SELECTIVE_LOGIC = SELECTIVE_LOGIC

local POSITION = {
    BEFORE = 0, AFTER = 1, AN_TOP = 2, AN_BOTTOM = 3,
    AT_DEPTH = 4, EM_TOP = 5, EM_BOTTOM = 6, OUTLET = 7,
}
WI.POSITION = POSITION

-- Normalize a raw ST entry into a full entry with defaults.
function WI.parse_entry(raw)
    raw = raw or {}
    local function str(v) return type(v) == "string" and v or nil end
    local function num(v, d) return tonumber(v) or d end
    local function bool(v) return v == true end

    local function keylist(v)
        local out = {}
        if type(v) == "table" then
            for _, k in ipairs(v) do
                if type(k) == "string" and k ~= "" then
                    table.insert(out, k)
                end
            end
        elseif type(v) == "string" and v ~= "" then
            -- tolerate comma-separated strings
            for k in v:gmatch("[^,]+") do
                table.insert(out, k:match("^%s*(.-)%s*$"))
            end
        end
        return out
    end

    local entry = {
        uid = raw.uid,
        key = keylist(raw.key),
        keysecondary = keylist(raw.keysecondary),
        selective = raw.selective == true or (#keylist(raw.keysecondary) > 0),
        selectiveLogic = num(raw.selectiveLogic, SELECTIVE_LOGIC.AND_ANY),
        content = str(raw.content) or "",
        comment = str(raw.comment) or "",
        order = num(raw.order, 100),
        position = num(raw.position, POSITION.BEFORE),
        depth = num(raw.depth, 4),
        role = num(raw.role, 0),
        constant = bool(raw.constant),
        disable = bool(raw.disable),
        probability = num(raw.probability, 100),
        useProbability = raw.useProbability == true or num(raw.probability, 100) < 100,
        excludeRecursion = bool(raw.excludeRecursion),
        preventRecursion = bool(raw.preventRecursion),
        delayUntilRecursion = bool(raw.delayUntilRecursion),
        scanDepth = raw.scanDepth and num(raw.scanDepth) or nil,
        caseSensitive = bool(raw.caseSensitive),
        matchWholeWords = bool(raw.matchWholeWords),
        sticky = num(raw.sticky, 0),
        cooldown = num(raw.cooldown, 0),
        delay = num(raw.delay, 0),
    }
    if entry.uid == nil then
        entry.uid = tostring(math.random(100000, 999999))
    end
    return entry
end

-- Normalize a whole world file: { entries = { "0": {...} } } → array
function WI.parse_world(data)
    local out = {}
    if type(data) ~= "table" then return out end
    local entries = data.entries or data
    if type(entries) ~= "table" then return out end
    for uid, raw in pairs(entries) do
        if type(raw) == "table" then
            local e = WI.parse_entry(raw)
            if e.uid == nil then e.uid = tostring(uid) end
            table.insert(out, e)
        end
    end
    table.sort(out, function(a, b)
        return tostring(a.uid) < tostring(b.uid)
    end)
    return out
end

-- Convert a ccv3 character_book (card-embedded) into ST world entries.
function WI.from_character_book(book)
    local out = {}
    if type(book) ~= "table" then return out end
    local entries = book.entries
    if type(entries) == "table" then
        for i, raw in ipairs(entries) do
            if type(raw) == "table" then
                -- ccv3 spec: keys[], secondary_keys[], insertion_order,
                -- position: 'before_char'|'after_char', enabled
                local position = POSITION.BEFORE
                if raw.position == "after_char" then position = POSITION.AFTER end
                table.insert(out, WI.parse_entry({
                    uid = raw.id or tostring(i),
                    key = raw.keys or raw.key,
                    keysecondary = raw.secondary_keys or raw.keysecondary,
                    selective = raw.selective or (raw.secondary_keys and #raw.secondary_keys > 0),
                    selectiveLogic = raw.selective_logic,
                    content = raw.content,
                    comment = raw.comment or raw.name,
                    order = raw.insertion_order or raw.order,
                    position = position,
                    depth = raw.extensions and raw.extensions.depth,
                    constant = raw.constant,
                    disable = raw.enabled == false,
                    probability = raw.probability,
                }))
            end
        end
    end
    return out
end

-- Convert entries back to a ST world file body.
function WI.to_world_file(entries)
    local out = { entries = {} }
    for i, e in ipairs(entries or {}) do
        local uid = tostring(e.uid or i)
        out.entries[uid] = {
            uid = uid,
            key = e.key,
            keysecondary = e.keysecondary,
            selective = e.selective,
            selectiveLogic = e.selectiveLogic,
            content = e.content,
            comment = e.comment,
            order = e.order,
            position = e.position,
            depth = e.depth,
            role = e.role,
            constant = e.constant,
            disable = e.disable,
            probability = e.probability,
            useProbability = e.useProbability,
            excludeRecursion = e.excludeRecursion,
            preventRecursion = e.preventRecursion,
            delayUntilRecursion = e.delayUntilRecursion,
            scanDepth = e.scanDepth,
            caseSensitive = e.caseSensitive,
            matchWholeWords = e.matchWholeWords,
            sticky = e.sticky,
            cooldown = e.cooldown,
            delay = e.delay,
        }
    end
    return out
end

-- === Key matching ===
-- `text` must already be in the right case for the entry (see WI.scan).

local function match_key(key, text, entry)
    if key == "" then return false end
    local k = entry.caseSensitive and key or key:lower()
    if entry.matchWholeWords then
        return text:find("%f[%w]" .. k:gsub("(%W)", "%%%1") .. "%f[%W]") ~= nil
    end
    return text:find(k, 1, true) ~= nil
end

local function secondary_ok(entry, text)
    local secs = entry.keysecondary
    if not entry.selective or #secs == 0 then
        return true
    end
    local any, all = false, true
    for _, k in ipairs(secs) do
        local hit = match_key(k, text, entry)
        any = any or hit
        all = all and hit
    end
    local logic = entry.selectiveLogic
    if logic == SELECTIVE_LOGIC.NOT_ALL then return not all end
    if logic == SELECTIVE_LOGIC.NOT_ANY then return not any end
    if logic == SELECTIVE_LOGIC.AND_ALL then return all end
    return any -- AND_ANY
end

-- === Scan ===

-- entries: array of parsed entries; opts see header.
function WI.scan(entries, opts)
    opts = opts or {}
    local state = opts.state or {}
    local msg_count = tonumber(opts.msg_count) or 0
    local max_recursion = tonumber(opts.max_recursion) or 3

    -- Timed effects bookkeeping (persisted by the caller)
    state.sticky = state.sticky or {}
    state.cooldown = state.cooldown or {}
    state.last_active = state.last_active or {}

    -- Raw + lowered copies of the scan text (per-entry case sensitivity)
    local raw_text = opts.text or ""
    if opts.extra_text and opts.extra_text ~= "" then
        raw_text = raw_text .. "\n" .. opts.extra_text
    end
    local lower_text = raw_text:lower()
    local buffer_raw, buffer_lower = "", ""

    -- Per-entry scan text: respects entry.scanDepth (via opts.last_n) and
    -- entry.caseSensitive (raw vs lowered copy).
    local function text_for(e)
        local depth = e.scanDepth or opts.scan_depth
        if depth and opts.last_n then
            local raw = opts.last_n(depth)
            if opts.extra_text and opts.extra_text ~= "" then
                raw = raw .. "\n" .. opts.extra_text
            end
            if e.caseSensitive then return raw end
            return raw:lower()
        end
        if e.caseSensitive then
            return raw_text .. buffer_raw
        end
        return lower_text .. buffer_lower
    end

    -- Recursion loop
    local activated_map = {}   -- uid → entry
    local activated_order = {}
    local pending = {}
    local rolled = {}          -- uid → probability outcome (rolled once per
                               -- scan: retrying per recursion step would turn
                               -- p=50% into ~87% over 4 steps)
    for _, e in ipairs(entries or {}) do
        if not e.disable then table.insert(pending, e) end
    end

    for step = 0, max_recursion do
        local new_hits = {}
        for _, e in ipairs(pending) do
            local uid = tostring(e.uid)
            if not activated_map[uid] then
                local ok = false
                -- delayUntilRecursion only fires from recursion step 2 on
                if not (e.delayUntilRecursion and step < 1) then
                    -- Timed effects
                    local in_cooldown = (state.cooldown[uid] or 0) > msg_count
                    local in_delay = msg_count < (e.delay or 0)
                    if not in_cooldown and not in_delay then
                        if e.constant then
                            ok = true
                        else
                            local text = text_for(e)
                            for _, k in ipairs(e.key) do
                                if match_key(k, text, e) then
                                    ok = true
                                    break
                                end
                            end
                            if ok then
                                ok = secondary_ok(e, text)
                            end
                        end
                    end
                end
                if ok and e.useProbability and (e.probability or 100) < 100 then
                    if rolled[uid] == nil then
                        rolled[uid] = math.random(1, 100) <= e.probability
                    end
                    ok = rolled[uid]
                end
                if ok then
                    new_hits[uid] = e
                end
            end
        end
        if next(new_hits) == nil then break end
        for uid, e in pairs(new_hits) do
            activated_map[uid] = e
            table.insert(activated_order, e)
            -- timed effects update
            if (e.sticky or 0) > 0 then
                state.sticky[uid] = msg_count + e.sticky
            end
            state.last_active[uid] = msg_count
            -- recursion buffer (both cases)
            if not e.excludeRecursion and e.content ~= "" then
                buffer_raw = buffer_raw .. "\n" .. e.content
                buffer_lower = buffer_lower .. "\n" .. e.content:lower()
            end
        end
    end

    -- Sticky: keep entries active whose sticky window hasn't expired
    for uid, until_msg in pairs(state.sticky or {}) do
        if msg_count <= until_msg and not activated_map[uid] then
            for _, e in ipairs(entries or {}) do
                if tostring(e.uid) == uid and not e.disable then
                    activated_map[uid] = e
                    table.insert(activated_order, e)
                    -- Stamp last_active so the cooldown arms when the sticky
                    -- window finally expires (otherwise sticky+cooldown never
                    -- combines, which is the whole point of the combo).
                    state.last_active[uid] = msg_count
                end
            end
        end
    end

    -- Cooldown: mark entries that just deactivated
    for _, e in ipairs(entries or {}) do
        local uid = tostring(e.uid)
        local was = state.last_active[uid]
        if was and was == msg_count - 1 and (e.cooldown or 0) > 0 then
            state.cooldown[uid] = msg_count + e.cooldown
        end
    end

    -- Sort by order (higher order first, like ST's b.order - a.order),
    -- stable by uid for determinism.
    table.sort(activated_order, function(a, b)
        if a.order ~= b.order then return a.order > b.order end
        return tostring(a.uid) < tostring(b.uid)
    end)

    -- Prune bookkeeping for uids that no longer exist in this lorebook:
    -- without this the persisted state grows forever and inflates every
    -- header read of the chat file.
    local known = {}
    for _, e in ipairs(entries or {}) do
        known[tostring(e.uid)] = true
    end
    for _, key in ipairs({ "sticky", "cooldown", "last_active" }) do
        local t = state[key]
        if type(t) == "table" then
            for uid in pairs(t) do
                if not known[uid] then
                    t[uid] = nil
                end
            end
        end
    end

    -- Budget (approximate: 1 token ≈ 4 chars). Entries beyond the budget are
    -- not emitted (and not reported as activated) - except constant entries,
    -- which are mandatory lore and match ST's behavior.
    local budget = tonumber(opts.budget) or 0
    local used = 0
    local emitted = {}

    local before_parts, after_parts, injections = {}, {}, {}
    for _, e in ipairs(activated_order) do
        if e.content ~= "" then
            local size = math.ceil(#e.content / 4)
            if budget <= 0 or e.constant or used + size <= budget then
                used = used + size
                table.insert(emitted, e)
                local pos = tonumber(e.position) or POSITION.BEFORE
                if pos == POSITION.AT_DEPTH then
                    table.insert(injections, {
                        content = e.content,
                        depth = e.depth,
                        role = (e.role == 1 and "user") or (e.role == 2 and "assistant") or "system",
                    })
                elseif pos == POSITION.AFTER or pos == POSITION.AN_BOTTOM or pos == POSITION.EM_BOTTOM or pos == POSITION.OUTLET then
                    table.insert(after_parts, e.content)
                else
                    table.insert(before_parts, e.content)
                end
            end
        end
    end

    return {
        before = table.concat(before_parts, "\n"),
        after = table.concat(after_parts, "\n"),
        injections = injections,
        activated = emitted,
        state = state,
    }
end

-- Chat activation: read the chat's lorebook config, scan the recent history
-- and return { before, after, injections } for Models.build_messages.
-- app needs: state.current_chat_path, state.messages, _active_persona_description().
function WI.active_context(app, character)
    local path = app.state.current_chat_path
    if not path then return nil end
    local Storage = require("kt_storage")
    local chat_data = Storage.load_chat(path)
    local meta = chat_data and chat_data.header and chat_data.header.chat_metadata
    local cfg = meta and meta.world_info
    if type(cfg) ~= "table" or type(cfg.selected) ~= "string" or cfg.selected == "" then
        return nil
    end

    local entries
    local world = Storage.load_world(cfg.selected)
    if world then
        entries = WI.parse_world(world)
    elseif type(character) == "table" and character.character_book then
        entries = WI.from_character_book(character.character_book)
    end
    if not entries or #entries == 0 then
        return nil
    end

    -- Scan text: the last `depth` non-hidden messages
    local depth = tonumber(cfg.depth) or 2
    local msgs = app.state.messages or {}
    local parts = {}
    local count = 0
    for i = #msgs, 1, -1 do
        local mm = msgs[i]
        if mm.role ~= "system" and mm.hidden ~= true then
            count = count + 1
            table.insert(parts, 1, tostring(mm.content or ""))
            if count >= depth then break end
        end
    end

    local ok_persona, persona = pcall(function() return app:_active_persona_description() end)

    local result = WI.scan(entries, {
        text = table.concat(parts, "\n"),
        extra_text = ok_persona and persona or nil,
        scan_depth = depth,
        budget = tonumber(cfg.budget) or 0,
        msg_count = #msgs,
        state = (type(cfg.state) == "table" and cfg.state) or {},
    })

    -- Persist timed-effects state (sticky/cooldown counters)
    cfg.state = result.state
    meta.world_info = cfg
    Storage.save_chat(path, chat_data.header, chat_data.messages)

    return {
        before = result.before,
        after = result.after,
        injections = result.injections,
        activated = result.activated,
    }
end

return WI
