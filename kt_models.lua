-- Data models and message processing utilities.

local _ = require("gettext")

local Models = {}

-- Approximate token count for a string (chars/4 heuristic, same as WI budget).
local function approx_tokens(s)
    return math.ceil(#tostring(s or "") / 4)
end

-- Extract reasoning wrapped in configurable tags (ST auto-parse): returns
-- clean_content, reasoning_or_nil. Unterminated tags (mid-stream) put the
-- whole tail into reasoning so the live view stays correct while streaming.
function Models.extract_reasoning(content, prefix, suffix)
    content = tostring(content or "")
    prefix = tostring(prefix or "<think>")
    suffix = tostring(suffix or "</think>")
    if prefix == "" or suffix == "" or not content:find(prefix, 1, true) then
        return content, nil
    end
    local s = content:find(prefix, 1, true)
    local cs = s + #prefix
    local ce = content:find(suffix, cs, true)
    local reasoning
    if ce then
        reasoning = tostring(content:sub(cs, ce - 1)):match("^%s*(.-)%s*$")
        content = content:sub(1, s - 1) .. content:sub(ce + #suffix)
    else
        reasoning = tostring(content:sub(cs)):match("^%s*(.-)%s*$")
        content = content:sub(1, s - 1)
    end
    return content, (reasoning ~= "" and reasoning or nil)
end

-- === Macros (SillyTavern core subset) ===
-- Supported: {{char}} {{user}} {{persona}} <BOT> <USER> <CHAR>,
-- {{time}} {{date}} {{weekday}} {{idle_duration}}? no - time family only,
-- {{random: a::b::c}}, {{pick: a::b}} (deterministic per seed),
-- {{roll: 1d20}} / {{roll: d6}}.
function Models.expand_macros(text, mctx)
    text = tostring(text or "")
    if not text:find("{{") and not text:find("<USER>") and not text:find("<BOT>") then
        -- fast path: nothing to expand
        if not text:find("{{") then return text end
    end
    mctx = mctx or {}
    local char = mctx.char or ""
    local user = mctx.user or ""

    local function split_list(argstr)
        local out = {}
        for raw_part in tostring(argstr or ""):gmatch("[^:]+") do
            local part = raw_part:match("^%s*(.-)%s*$")
            if part ~= "" then table.insert(out, part) end
        end
        return out
    end

    -- {{random: a::b::c}} - re-rolled every expansion
    text = text:gsub("{{%s*random%s*:%s*([^}]*)}}", function(args)
        local list = split_list(args)
        if #list == 0 then return "" end
        return list[math.random(1, #list)]
    end)

    -- {{pick: a::b}} - deterministic per pick_seed + args
    text = text:gsub("{{%s*pick%s*:%s*([^}]*)}}", function(args)
        local list = split_list(args)
        if #list == 0 then return "" end
        local seed = tostring(mctx.pick_seed or "") .. "|" .. args
        local h = 5381
        for i = 1, #seed do
            h = (h * 33 + seed:byte(i)) % 2147483647
        end
        return list[(h % #list) + 1]
    end)

    -- {{roll: 1d20}} / {{roll: d6}}
    text = text:gsub("{{%s*roll%s*:%s*([^}]*)}}", function(expr)
        local count, sides = tostring(expr):match("(%d*)%s*[dD]%s*(%d+)")
        count = tonumber(count) or 1
        sides = tonumber(sides)
        if not sides or sides <= 0 or count <= 0 or count > 100 then return "" end
        local total = 0
        for _ = 1, count do
            total = total + math.random(1, sides)
        end
        return tostring(total)
    end)

    -- Static substitutions
    local now = os.time()
    text = text:gsub("{{%s*char%s*}}", char)
        :gsub("{{%s*user%s*}}", user)
        :gsub("{{%s*persona%s*}}", mctx.persona or "")
        :gsub("<BOT>", char)
        :gsub("<USER>", user)
        :gsub("<CHAR>", char)
        :gsub("<CHARIFNOTGROUP>", char)
        :gsub("{{%s*time%s*}}", os.date("%H:%M", now))
        :gsub("{{%s*isotime%s*}}", os.date("%H:%M:%S", now))
        :gsub("{{%s*date%s*}}", os.date("%Y-%m-%d", now))
        :gsub("{{%s*weekday%s*}}", os.date("%A", now))
        :gsub("{{%s*model%s*}}", mctx.model or "")
    return text
end

-- Enforce the model context window: drop OLDEST history entries until the
-- estimated prompt fits (max_context - max_tokens). Leading system messages
-- are protected; trimming stops before eating into the last exchanges.
-- Returns messages, trimmed_flag.
function Models.enforce_context_budget(messages, ctx)
    ctx = ctx or {}
    local max_ctx = tonumber(ctx.openai_max_context)
    if not max_ctx or max_ctx <= 0 or #messages == 0 then
        return messages, false
    end
    local budget = max_ctx - (tonumber(ctx.openai_max_tokens) or 0)
    if budget <= 0 then
        return messages, false
    end
    local total = 0
    for _, m in ipairs(messages) do
        total = total + approx_tokens(m.content)
    end
    if total <= budget then
        return messages, false
    end
    -- Protect the preamble: everything up to (and including) the first
    -- non-system message stays.
    local head = 1
    while head <= #messages and messages[head].role == "system" do
        head = head + 1
    end
    -- Never trim below preamble + last 2 entries.
    local floor = math.min(#messages - 2, head)
    while total > budget and head < #messages and #messages > floor do
        local removed = table.remove(messages, head)
        total = total - approx_tokens(removed.content)
    end
    return messages, true
end

-- Build the system prompt for a character (story_string style, ST-compatible)
function Models.build_system_prompt(character, persona_desc)
    local parts = {}

    -- 1. System prompt do personagem
    local sys = character.system_prompt or ""
    if sys ~= "" then
        table.insert(parts, sys)
    end

    -- 2. Descrição do personagem
    if character.description and character.description ~= "" then
        table.insert(parts, character.description)
    end

    -- 3. Personalidade
    if character.personality and character.personality ~= "" then
        table.insert(parts, character.personality)
    end

    -- 4. Cenário
    if character.scenario and character.scenario ~= "" then
        table.insert(parts, character.scenario)
    end

    -- 5. Persona do usuário
    if persona_desc and persona_desc ~= "" then
        table.insert(parts, "[User Persona: " .. persona_desc .. "]")
    end

    -- 6. Post-history instructions
    if character.post_history_instructions and character.post_history_instructions ~= "" then
        table.insert(parts, character.post_history_instructions)
    end

    return table.concat(parts, "\n\n")
end

-- Build messages array for the API call.
-- ctx (all optional):
--   note_prompt/note_depth/note_interval/note_position/note_role - Author's Note
--     (SillyTavern chat_metadata keys; position: 0 in-prompt, 1 in-chat @ depth,
--      2 before scenario; role: 0 system, 1 user, 2 assistant)
--   depth_prompt/depth_prompt_depth/depth_prompt_role - character note @ depth
--   lorebook_entries - world info entries to activate (see world_info.lua)
-- === Prompt Manager (ST prompts/prompt_order in presets) ===

local MARKER_CONTENT = {
    chatHistory = true,
    charDescription = function(character) return character and character.description or "" end,
    charPersonality = function(character) return character and character.personality or "" end,
    scenario = function(character) return character and character.scenario or "" end,
    dialogueExamples = function(character) return character and character.mes_example or "" end,
    personaDescription = function(character, persona_desc) return persona_desc or "" end,
    worldInfoBefore = function(character, persona_desc, ctx) return (ctx and ctx.wi_before) or "" end,
    worldInfoAfter = function(character, persona_desc, ctx) return (ctx and ctx.wi_after) or "" end,
}
Models.MARKERS = MARKER_CONTENT

-- Resolve the preset's prompt_order into a message sequence.
-- Returns sequence = { {role, content} | {marker="chatHistory"} }, injections.
function Models.resolve_prompt_order(preset, character, persona_desc, ctx)
    if type(preset) ~= "table" or type(preset.prompts) ~= "table" then
        return nil
    end
    local order_list
    if type(preset.prompt_order) == "table" then
        for _, po in ipairs(preset.prompt_order) do
            if tonumber(po.character_id) == 100001 and type(po.order) == "table" then
                order_list = po.order
                break
            end
        end
        if not order_list then
            for _, po in ipairs(preset.prompt_order) do
                if tonumber(po.character_id) == 100000 and type(po.order) == "table" then
                    order_list = po.order
                    break
                end
            end
        end
    end
    if not order_list then
        return nil
    end

    local by_id = {}
    for _, p in ipairs(preset.prompts) do
        if type(p) == "table" and type(p.identifier) == "string" then
            by_id[p.identifier] = p
        end
    end

    local sequence = {}
    local injections = {}
    for _, item in ipairs(order_list) do
        if item.enabled ~= false then
            local p = by_id[item.identifier]
            if p then
                if p.marker and MARKER_CONTENT[item.identifier] then
                    if item.identifier == "chatHistory" then
                        table.insert(sequence, { marker = "chatHistory" })
                    else
                        local fn = MARKER_CONTENT[item.identifier]
                        local content = Models.expand_macros(fn(character, persona_desc, ctx), mctx)
                        if content and content ~= "" then
                            table.insert(sequence, { role = p.role or "system", content = content })
                        end
                    end
                elseif type(p.content) == "string" and p.content ~= "" then
                    if tonumber(p.injection_position) == 1 then
                        table.insert(injections, {
                            content = Models.expand_macros(p.content, mctx),
                            depth = tonumber(p.injection_depth) or 4,
                            role = p.role or "system",
                        })
                    else
                        table.insert(sequence, { role = p.role or "system", content = Models.expand_macros(p.content, mctx) })
                    end
                end
            end
        end
    end
    return sequence, injections
end

function Models.build_messages(character, persona_desc, chat_messages, ctx)
    ctx = ctx or {}
    local messages = {}

    -- Macro expansion context ({{char}}/{{user}}/{{random}}...). Applied to
    -- prompt scaffolding only - never to the user's own history.
    local mctx = {
        char = (type(character) == "table" and character.name) or "",
        user = ctx.user_name or "",
        persona = persona_desc or "",
        model = (ctx.preset and ctx.preset.model_id) or "",
        pick_seed = tostring(ctx.pick_seed or ""),
    }

    -- Accept ST numeric roles (0/1/2) or plain strings
    local function norm_role(r, default)
        if r == "user" or r == "assistant" or r == "system" then return r end
        if r == 1 then return "user" end
        if r == 2 then return "assistant" end
        return default or "system"
    end

    -- Prompt Manager path: the preset's prompts/prompt_order defines the layout
    if ctx.preset then
        local sequence, prompt_injections = Models.resolve_prompt_order(ctx.preset, character, persona_desc, ctx)
        if sequence then
            -- Prompt-side regex scripts must apply on this path too (parity
            -- with the legacy path below).
            local RE = ctx.regex_scripts and require("kt_regex_engine") or nil
            local history = {}
            for _, msg in ipairs(chat_messages or {}) do
                if msg.role ~= "system" and msg.hidden ~= true then
                    local content = msg.content or ""
                    if RE then
                        content = RE.apply(content, ctx.regex_scripts, "prompt")
                    end
                    table.insert(history, {
                        role = msg.role or "user",
                        content = content,
                        name = type(msg.name) == "string" and msg.name ~= "" and msg.name or nil,
                    })
                end
            end
            if ctx.new_chat_starter then
                table.insert(history, { role = "user", content = "[Start a new Chat]" })
            end

            -- @depth injections: prompt manager + Author's Note + depth prompt + WI
            local injections = {}
            for _, inj in ipairs(prompt_injections or {}) do
                table.insert(injections, inj)
            end
            local note_in_chat = ctx.note_prompt and ctx.note_prompt ~= ""
                and (tonumber(ctx.note_position) or 1) == 1
            if note_in_chat then
                local interval = tonumber(ctx.note_interval) or 1
                if interval <= 1 or (#history % interval) == 0 then
                    table.insert(injections, {
                        content = ctx.note_prompt,
                        depth = tonumber(ctx.note_depth) or 4,
                        role = norm_role(tonumber(ctx.note_role), "system"),
                    })
                end
            end
            if ctx.depth_prompt and ctx.depth_prompt ~= "" then
                table.insert(injections, {
                    content = ctx.depth_prompt,
                    depth = tonumber(ctx.depth_prompt_depth) or 4,
                    role = norm_role(ctx.depth_prompt_role, "system"),
                })
            end
            for i, inj in ipairs(type(ctx.wi_injections) == "table" and ctx.wi_injections or {}) do
                if type(inj.content) == "string" and inj.content ~= "" then
                    table.insert(injections, {
                        content = inj.content,
                        depth = tonumber(inj.depth) or 4,
                        role = norm_role(inj.role, "system"),
                        _ord = i,
                    })
                end
            end

            local history_done = false
            for _, item in ipairs(sequence) do
                if item.marker == "chatHistory" and not history_done then
                    history_done = true
                    -- deeper injections first so earlier insertions keep positions
                    for i = 1, #injections do injections[i]._i = i end
                    table.sort(injections, function(a, b)
                        local da, db = a.depth or 4, b.depth or 4
                        if da ~= db then return da > db end
                        return (a._i or 0) < (b._i or 0)
                    end)
                    for _, inj in ipairs(injections) do
                        local pos = math.max(0, #history - math.max(0, inj.depth))
                        table.insert(history, pos + 1, { role = inj.role, content = inj.content })
                    end
                    for _, h in ipairs(history) do
                        table.insert(messages, h)
                    end
                else
                    table.insert(messages, { role = item.role, content = item.content })
                end
            end
            -- Presets without a chatHistory marker still get the history
            if not history_done and #history > 0 then
                for _, h in ipairs(history) do
                    table.insert(messages, h)
                end
            end
            return Models.enforce_context_budget(messages, ctx)
        end
    end

    -- System prompt (story_string style, ST-compatible)
    local sys_prompt = Models.expand_macros(Models.build_system_prompt(character, persona_desc), mctx)

    -- Author's Note with position "in prompt" (0) / "before scenario" (2):
    -- folded into the system message. Position 1 (default) is injected in-chat.
    local note_in_chat = true
    local note_text = Models.expand_macros(ctx.note_prompt, mctx)
    if note_text and note_text ~= "" then
        local pos = tonumber(ctx.note_position) or 1
        if pos == 0 then
            sys_prompt = sys_prompt ~= "" and (sys_prompt .. "\n\n" .. note_text) or note_text
            note_in_chat = false
        elseif pos == 2 then
            local prefix = "[Author's Note: " .. note_text .. "]"
            sys_prompt = sys_prompt ~= "" and (prefix .. "\n\n" .. sys_prompt) or prefix
            note_in_chat = false
        end
    end

    if sys_prompt ~= "" then
        table.insert(messages, { role = "system", content = sys_prompt })
    end

    -- In-chat injections (@ depth from the end of history)
    local injections = {}
    if note_in_chat and note_text and note_text ~= "" then
        table.insert(injections, {
            depth = tonumber(ctx.note_depth) or 4,
            role = norm_role(tonumber(ctx.note_role), "system"),
            content = note_text,
        })
    end
    if ctx.depth_prompt and ctx.depth_prompt ~= "" then
        table.insert(injections, {
            depth = tonumber(ctx.depth_prompt_depth) or 4,
            role = norm_role(ctx.depth_prompt_role, "system"),
            content = Models.expand_macros(ctx.depth_prompt, mctx),
        })
    end
    -- World Info @depth injections (already scanned by world_info.lua)
    for _, inj in ipairs(type(ctx.wi_injections) == "table" and ctx.wi_injections or {}) do
        if type(inj.content) == "string" and inj.content ~= "" then
            table.insert(injections, {
                depth = tonumber(inj.depth) or 4,
                role = norm_role(inj.role, "system"),
                content = inj.content,
            })
        end
    end

    -- World Info entries (activated by world_info.scan) - before/after the
    -- system prompt and @depth injections are already resolved by the scanner.
    if type(ctx.wi_before) == "string" and ctx.wi_before ~= "" then
        table.insert(messages, { role = "system", content = Models.expand_macros(ctx.wi_before, mctx) })
    end
    if type(ctx.wi_after) == "string" and ctx.wi_after ~= "" then
        table.insert(messages, { role = "system", content = Models.expand_macros(ctx.wi_after, mctx) })
    end

    -- Chat history (hidden/system messages are skipped - SillyTavern is_system)
    local RE = ctx.regex_scripts and require("kt_regex_engine") or nil
    local history = {}
    for _, msg in ipairs(chat_messages or {}) do
        if msg.role == "system" or msg.hidden == true then
            goto continue
        end
        local entry = {
            role = msg.role or "user",
            content = RE and RE.apply(msg.content or "", ctx.regex_scripts, "prompt") or (msg.content or ""),
        }
        if type(msg.name) == "string" and msg.name ~= "" then
            entry.name = msg.name
        end
        table.insert(history, entry)
        ::continue::
    end
    if ctx.new_chat_starter then
        table.insert(history, { role = "user", content = "[Start a new Chat]" })
    end

    -- Apply @depth injections (depth = messages from the end)
    for _, inj in ipairs(injections) do
        local pos = math.max(0, #history - math.max(0, inj.depth))
        table.insert(history, pos + 1, { role = inj.role, content = inj.content })
    end

    for _, entry in ipairs(history) do
        table.insert(messages, entry)
    end

    return Models.enforce_context_budget(messages, ctx)
end

-- === Prompt Post-Processing (SillyTavern "Custom OAI-compatible" parity) ===
-- Shape the message array for endpoints that restrict incoming prompts.
-- Modes (connection.post_processing; nil/"none" skips the call):
--   merge        consecutive same-role messages merged (blank-line separated)
--   semi_strict  merge + only the first system message survives, pinned top
--   strict       semi_strict + first non-system message must be user
--                ("[Start a new chat]" placeholder inserted otherwise)
--   single_user  everything merged into ONE user message
-- Returns a NEW table; the input is never mutated.
function Models.post_process_messages(messages, mode)
    messages = messages or {}
    if mode == "single_user" then
        local parts = {}
        for _, m in ipairs(messages) do
            if type(m.content) == "string" and m.content ~= "" then
                table.insert(parts, m.content)
            end
        end
        return { { role = "user", content = table.concat(parts, "\n\n") } }
    end
    if mode ~= "merge" and mode ~= "semi_strict" and mode ~= "strict" then
        return messages
    end

    -- Pass 1: merge consecutive same-role messages.
    local merged = {}
    for _, m in ipairs(messages) do
        local role = m.role or "user"
        local last = merged[#merged]
        if last and last.role == role and type(last.content) == "string"
            and type(m.content) == "string" and last.content ~= "" then
            last.content = last.content .. "\n\n" .. m.content
        else
            table.insert(merged, { role = role, content = m.content })
        end
    end

    if mode == "semi_strict" or mode == "strict" then
        -- Pass 2: at most one system message (the first), pinned to the top.
        local sys, rest = nil, {}
        for _, m in ipairs(merged) do
            if m.role == "system" then
                if sys == nil then sys = m end
            else
                table.insert(rest, m)
            end
        end
        merged = {}
        if sys then table.insert(merged, sys) end
        for _, m in ipairs(rest) do table.insert(merged, m) end
    end

    if mode == "strict" then
        -- Pass 3: the first non-system message must be a user message.
        local first_idx
        for i, m in ipairs(merged) do
            if m.role ~= "system" then first_idx = i break end
        end
        if first_idx and merged[first_idx].role ~= "user" then
            table.insert(merged, first_idx,
                { role = "user", content = "[Start a new chat]" })
        elseif not first_idx then
            table.insert(merged, { role = "user", content = "[Start a new chat]" })
        end
    end

    return merged
end

-- Normalize a message for the swipes data model (SillyTavern-compatible).
-- Assistant messages carry:
--   swipes[]  → all alternate responses (including the active one)
--   swipe_id  → 1-based index of the active response
-- Legacy messages (no swipes) are upgraded in place.
function Models.normalize_message(msg)
    if type(msg) ~= "table" then
        return msg
    end
    -- SillyTavern schema detection (mes/is_user present) → convert
    if msg.mes ~= nil or msg.is_user ~= nil then
        return Models.from_st_message(msg)
    end
    if msg.role ~= "assistant" then
        return msg
    end
    if type(msg.swipes) ~= "table" then
        msg.swipes = {}
    end
    if #msg.swipes == 0 and type(msg.content) == "string" and msg.content ~= "" then
        msg.swipes = { msg.content }
    end
    if not msg.swipe_id or msg.swipe_id < 1 or msg.swipe_id > #msg.swipes then
        msg.swipe_id = #msg.swipes > 0 and 1 or 0
    end
    if #msg.swipes > 0 then
        msg.content = msg.swipes[msg.swipe_id] or msg.swipes[1]
    end
    return msg
end

-- === SillyTavern on-disk schema (chats) ===
--
-- The .jsonl files we write are byte-compatible with SillyTavern:
--   line 1  → header: { chat_metadata: {...}, user_name: "unused", character_name: "unused" }
--   lines 2+ → messages: { name, mes, is_user, is_system, send_date, swipes[],
--              swipe_id (0-based), swipe_info[], extra, gen_started/gen_finished }
-- This lets chats be exchanged 1:1 with SillyTavern (export = raw file copy).

-- Convert an internal message to the ST on-disk schema. Only ST fields are
-- emitted (never role/content). Unknown ST fields from an imported message are
-- preserved via the `_st` snapshot.
function Models.to_st_message(msg)
    if type(msg) ~= "table" then
        return msg
    end
    local st = {}
    if type(msg._st) == "table" then
        for k, v in pairs(msg._st) do
            st[k] = v
        end
    end

    -- Canonical fields are always recomputed from the internal model.
    -- ST uses is_system as the hidden flag, so is_user must keep reflecting
    -- the REAL role even while hidden; kt_orig_role (private, tolerated by
    -- ST as an unknown key) preserves the exact pre-hide role losslessly.
    st.mes = msg.content or ""
    if msg.hidden == true then
        st.is_user = (msg.role == "user")
        st.is_system = true
        st.kt_orig_role = (msg.role == "system") and nil or msg.role
    else
        st.is_user = (msg.role == "user")
        st.is_system = (msg.role == "system")
        st.kt_orig_role = nil
    end
    if type(msg.name) == "string" and msg.name ~= "" then
        st.name = msg.name
    end
    if type(msg.send_date) == "number" then
        st.send_date = msg.send_date
    end

    -- Persist internal reasoning into ST's extra.reasoning (merged over any
    -- snapshot extra so round-trips stay lossless in both directions).
    if type(msg.reasoning) == "string" and msg.reasoning ~= "" then
        local extra = (type(st.extra) == "table" and st.extra) or {}
        extra.reasoning = msg.reasoning
        st.extra = extra
    end

    if type(msg.swipes) == "table" and #msg.swipes > 0 then
        st.swipes = msg.swipes
        st.swipe_id = (tonumber(msg.swipe_id) or 1) - 1
        if st.swipe_id < 0 then
            st.swipe_id = 0
        end
    else
        st.swipes = nil
        st.swipe_id = nil
    end

    -- Keep swipe_info aligned with the swipe count WITHOUT discarding the
    -- existing per-swipe metadata (gen_started/gen_finished snapshots from ST).
    -- Sources, in order: the disk snapshot, then a live msg.swipe_info field.
    if type(st.swipes) == "table" then
        local src
        if type(st.swipe_info) == "table" then
            src = st.swipe_info
        elseif type(msg.swipe_info) == "table" then
            src = msg.swipe_info
        end
        local info = type(src) == "table" and src or {}
        for i = #info + 1, #st.swipes do
            info[i] = { send_date = st.send_date or os.time() }
        end
        for i = #st.swipes + 1, #info do
            info[i] = nil
        end
        st.swipe_info = info
    end

    return st
end

-- Convert an ST message to the internal model (role/content, 1-based swipe_id).
-- A `_st` snapshot keeps the original ST fields so unknown keys survive a round-trip.
function Models.from_st_message(st)
    if type(st) ~= "table" then
        return st
    end
    -- Internal/legacy message (no ST markers) → just normalize
    if st.mes == nil and st.is_user == nil then
        return Models.normalize_message(st)
    end

    local swipes = {}
    if type(st.swipes) == "table" then
        for _, s in ipairs(st.swipes) do
            if type(s) == "string" then
                table.insert(swipes, s)
            end
        end
    end
    local content = st.mes or ""
    if #swipes == 0 and content ~= "" then
        swipes = { content }
    end

    local hidden = st.is_system == true
    local role
    if hidden and type(st.kt_orig_role) == "string" then
        -- Our own marker: exact pre-hide role.
        role = st.kt_orig_role
    elseif st.is_user == true then
        role = "user"
    elseif hidden then
        -- Imported ST file (no kt_orig_role): a hidden assistant/user keeps
        -- its character name; genuine system/narrator lines have none or
        -- "System". Legacy KOTavern files masked is_user on hidden messages,
        -- so the name heuristic is the best available signal.
        role = (type(st.name) == "string" and st.name ~= "" and st.name ~= "System") and "assistant" or "system"
    else
        role = "assistant"
    end
    local swipe_id = (tonumber(st.swipe_id) or 0) + 1
    if swipe_id < 1 or swipe_id > #swipes then
        swipe_id = #swipes > 0 and 1 or 0
    end

    local msg = {
        role = role,
        content = (#swipes > 0 and (swipes[swipe_id] or swipes[1])) or content,
        name = type(st.name) == "string" and st.name or nil,
        send_date = type(st.send_date) == "number" and st.send_date or nil,
        swipes = swipes,
        swipe_id = swipe_id,
    }
    if hidden then
        msg.hidden = true
    end

    -- Snapshot for round-trip: everything except the canonical ST fields
    local _st = {}
    for k, v in pairs(st) do
        if k ~= "mes" and k ~= "is_user" and k ~= "is_system"
            and k ~= "swipes" and k ~= "swipe_id" then
            _st[k] = v
        end
    end
    msg._st = _st
    -- Surface ST-imported reasoning so the collapsible line can render it.
    local snap_extra = type(_st.extra) == "table" and _st.extra or nil
    if not (type(msg.reasoning) == "string" and msg.reasoning ~= "") then
        if snap_extra and type(snap_extra.reasoning) == "string" and snap_extra.reasoning ~= "" then
            msg.reasoning = snap_extra.reasoning
        end
    end
    return msg
end

-- Wrap chat metadata into the ST header line. ST writes user_name/character_name
-- as fixed "unused" for backward compatibility.
function Models.to_st_header(chat_metadata)
    return {
        chat_metadata = chat_metadata or {},
        user_name = "unused",
        character_name = "unused",
    }
end

-- Extract chat metadata from a header (ST or legacy).
function Models.from_st_header(header)
    if type(header) ~= "table" then
        return {}
    end
    if type(header.chat_metadata) == "table" then
        return header.chat_metadata
    end
    return header
end

-- Normalize a character object from parsed data
function Models.normalize_character(char_data, png_path)
    local data = char_data.data or char_data
    if type(data) ~= "table" then
        data = {}
    end

    local function str(v)
        return type(v) == "string" and v or ""
    end

    local function arr(v)
        return type(v) == "table" and v or {}
    end

    return {
        id = png_path and png_path:match("([^/]+)%.png$") or "unknown",
        name = str(data.name or char_data.name) ~= "" and str(data.name or char_data.name) or "Unknown",
        description = str(data.description),
        personality = str(data.personality),
        scenario = str(data.scenario),
        first_mes = str(data.first_mes),
        alternate_greetings = arr(data.alternate_greetings),
        mes_example = str(data.mes_example),
        system_prompt = str(data.system_prompt),
        post_history_instructions = str(data.post_history_instructions),
        creator_notes = str(data.creator_notes),
        tags = arr(data.tags),
        creator = str(data.creator),
        character_version = str(data.character_version) ~= "" and str(data.character_version) or "1.0",
        extensions = arr(data.extensions),
        -- ccv3 embedded lorebook (kept raw; world_info.lua imports it)
        character_book = type(data.character_book) == "table" and data.character_book or nil,
        png_path = png_path,
        created_at = os.time(),
        updated_at = os.time(),
    }
end

-- Convert markdown-style text to plain text for e-ink display
function Models.markdown_to_text(text)
    if not text or text == "" then return "" end

    -- Strip markdown formatting for e-ink readability
    local result = text
    -- Bold/italic: **text** or __text__ or *text*
    result = result:gsub("%*%*(.-)%*%*", "%1")
    result = result:gsub("__(.-)__", "%1")
    result = result:gsub("%*(.-)%*", "%1")
    result = result:gsub("_(.-)_", "%1")
    -- Inline code
    result = result:gsub("`(.-)`", "%1")
    -- Links: [text](url) → text
    result = result:gsub("%[(.-)%]%([^)]*%)", "%1")
    -- Images: ![alt](url) → [img]
    result = result:gsub("!%[(.-)%]%([^)]*%)", "[img: %1]")
    -- Headers: ## text → text
    result = result:gsub("^#+%s*", "")
    -- Horizontal rules
    result = result:gsub("^[-*_]{3,}$", "---")

    return result
end

return Models
