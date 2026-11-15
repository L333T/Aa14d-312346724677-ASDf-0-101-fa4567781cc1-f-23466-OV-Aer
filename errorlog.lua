-- ============================================================================
-- Master Farmer - Forever Questing
-- Error log, written to scripts_log/MASTER_FARMER_ERRORS
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.0
-- Folder: Forever_Questing
-- ============================================================================
-- One JSON Lines file per session, with bounded rollover. Each event includes
-- schema/version/session/sequence, timestamps, component, message, source hint
-- and a cached context snapshot. Context is sampled only on the update tick;
-- writing a log never queries game objects from render/menu/error callbacks.
-- The single GUI logging preference controls all file writers. Heartbeats are
-- capped at one per two seconds; full snapshots are emitted every ten seconds.
-- Lua tracebacks remain one escaped JSON string, so every physical line parses.

-- Schema 2 (2026-11): `context` (the large state snapshot) is written only on
-- STATE/WARN/ERROR lines; every other line carries `pos` instead. ERROR and
-- loop WARN records carry `details.recent`, the last RECENT_N trail lines.
-- `errorlog.event` writes structured trails (details.name / details.fields).
-- A session closes with a `session_end` record and an empty "<session>.end"
-- marker; start() warns when the previous session has no marker and keeps only
-- the newest KEEP_SESSIONS sessions (core.read_log_dir / core.delete_log_file).

local errorlog = {}

local unpack = table.unpack or unpack

local FOLDER = "MASTER_FARMER_ERRORS"
-- Lines per FILE (2.65.0). At the cap the session rolls over into
-- "<session>_part2.log", "_part3" ... instead of going quiet: the 20000-line
-- cap used to stop the log after about half an hour of heartbeats, so a
-- crash later in a long session left no trail at all.
local MAX_LINES = 20000
local REPEAT_NOTE = 50        -- re-log a repeating error every N occurrences

local path = nil              -- this session's file, relative to scripts_log
local base_path = nil         -- the first file's name without ".log"
local part = 1
local opened = false
local disabled = false
local lines = 0
local seen = {}               -- error key -> count
local seen_n = 0
local last_trail = {}         -- tag -> last text
local context_fn = nil
-- Heartbeat state (see HEARTBEAT below). Declared up here because
-- errorlog.probe reads it and is defined first: declared below, these were
-- globals inside probe - always nil - and no BEAT ever listed a stage.
local beat_on = false
local BEAT_SAME = 2.0         -- seconds an unchanged BEAT line is held back
local beat_last_body = nil
local beat_last_t = 0
local beat_same = 0
local beat_tags = {}
local beat_n = 0

local SCHEMA = 2
local KEEP_SESSIONS = 30
local RECENT_N = 20
local FULL_CONTEXT = { STATE = true, WARN = true, ERROR = true }
local recent, recent_i = {}, 0      -- ring of the last RECENT_N trail/warn lines
local loops = {}                    -- shape -> {n, t0, tl, warned}
local loops_n = 0
local LOOP_MIN, LOOP_SECS, LOOP_GAP, LOOP_RENOTE = 20, 30, 15, 300
local env_fn, env_written = nil, false
local cached_pos = nil
local counts = { error = 0, warn = 0 }
local stopped = false
local session_version, sequence = "unknown", 0
local cached_context, context_at, snapshot_next = {}, 0, 0
local context_busy = false
local ui_seq = nil
local sources = {nav="movement/nav.lua",combat="movement/combat.lua",move="movement.lua",
    height="movement.lua",rotation="smart.lua",loot="loot.lua",death="death.lua",
    deathzone="deathzones.lua",vendor="vendor.lua",equip="equip.lua",rest="resting.lua",
    live_waypoint="quest/guide.lua",waypoint="quest/guide.lua",quest="quest/engine.lua",npc="quest/npc.lua",autoload="gui.lua",ui="events.lua"}

function errorlog.enabled()
    local gui=package.loaded["gui"]
    if type(gui)=="table" and type(gui.is_on)=="function" then
        local ok,on=pcall(gui.is_on,"fq_logging")
        if ok then return on~=false end
    end
    return true -- capture module-load failures before the GUI exists
end

local function quote(v)
    return '"'..tostring(v):gsub('[%z\1-\31\\"]',function(c)
        if c=='"' then return '\\"' end
        if c=='\\' then return '\\\\' end
        return string.format('\\u%04x',string.byte(c))
    end)..'"'
end
local function json(v,depth,seen)
    local kind=type(v)
    if kind=="string" then return quote(v) end
    if kind=="boolean" then return tostring(v) end
    if kind=="number" then return v==v and math.abs(v)<math.huge and tostring(v) or "null" end
    if kind~="table" then return "null" end
    depth,seen=depth or 0,seen or {}
    if depth>=5 or seen[v] then return quote("[bounded]") end
    seen[v]=true
    local n=#v
    if n>0 then
        local cnt=0
        for _ in pairs(v) do cnt=cnt+1 end
        if cnt==n then -- a plain array: keep its order
            local arr={}
            for i=1,math.min(64,n) do arr[i]=json(v[i],depth+1,seen) end
            seen[v]=nil
            return "["..table.concat(arr,",").."]"
        end
    end
    local keys,out={},{}
    for k in pairs(v) do if type(k)=="string" or type(k)=="number" then keys[#keys+1]=k end end
    table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
    for i=1,math.min(64,#keys) do
        local k=keys[i];out[#out+1]=quote(k)..":"..json(v[k],depth+1,seen)
    end
    seen[v]=nil
    return "{"..table.concat(out,",").."}"
end

local function stamp()
    local ok, t = pcall(function() return core.get_local_time() end)
    if ok and type(t) == "table" then
        return string.format("%04d-%02d-%02d %02d:%02d:%02d",
            tonumber(t.year) or 0, tonumber(t.month) or 0, tonumber(t.day) or 0,
            tonumber(t.hour) or 0, tonumber(t.minute) or 0, tonumber(t.second) or 0)
    end
    return "????-??-?? ??:??:??"
end

--- Seconds since the game started. core.time() already reports seconds; the
--- 2.20.0 log divided it by 1000 and every line read "t=0.69".
local function game_time()
    local ok, t = pcall(function() return core.time() end)
    if ok and type(t) == "number" then
        return string.format("%.2f", t)
    end
    return "-"
end

local function now_s()
    local ok, t = pcall(function() return core.time() end)
    if ok and type(t) == "number" then
        return t
    end
    return 0
end

local function open()
    if opened then
        return path ~= nil
    end
    opened = true
    if type(core) ~= "table" or type(core.write_log_file) ~= "function" then
        disabled = true
        return false
    end
    pcall(function() core.create_log_folder(FOLDER) end)
    local name = stamp():gsub("[: ]", function(c) return c == " " and "_" or "-" end)
    base_path = FOLDER .. "/session_" .. name
    path = base_path .. ".jsonl"
    pcall(function() core.create_log_file(path) end)
    return true
end

--- Continue the session in the next part file.
local function roll_over()
    part = part + 1
    local next_path = base_path .. "_part" .. part .. ".jsonl"
    local ok = pcall(function() core.create_log_file(next_path) end)
    if not ok then
        return false
    end
    pcall(core.write_log_file, path, json({schema=1,event="rollover",next_file=next_path,version=session_version}).."\n")
    path = next_path
    lines = 0
    return true
end

local function recent_copy()
    local out = {}
    for i = 1, math.min(recent_i, RECENT_N) do
        out[i] = recent[(recent_i - math.min(recent_i, RECENT_N) + i - 1) % RECENT_N + 1]
    end
    return out
end

local function write(kind, text, details)
    if disabled or not errorlog.enabled() or not open() then
        return
    end
    if lines >= MAX_LINES and not roll_over() and kind ~= "ERROR" then
        return
    end
    lines = lines + 1
    sequence=sequence+1
    local component = (kind=="TRAIL" and tostring(text):match("^([^:]+):")) or kind:lower()
    if kind == "ERROR" then counts.error = counts.error + 1 elseif kind == "WARN" then counts.warn = counts.warn + 1 end
    if kind == "TRAIL" or kind == "WARN" then
        recent_i = recent_i + 1
        recent[(recent_i - 1) % RECENT_N + 1] = string.format("#%d t=%s %s", sequence, game_time(), tostring(text))
    end
    local rec = {schema=SCHEMA,session=base_path,version=session_version,seq=sequence,
        timestamp=stamp(),game_time=tonumber(game_time()),level=kind=="ERROR" and "error" or (kind=="WARN" and "warning" or "info"),
        event=kind:lower(),component=component,source_hint=sources[component],message=text,
        context_at=context_at,details=details}
    if FULL_CONTEXT[kind] then rec.context = cached_context else rec.pos = cached_pos end
    local line = json(rec).."\n"
    local ok,result = pcall(core.write_log_file, path, line)
    if not ok or result==false then
        disabled = true
    end
end

local function traceback(err)
    local dbg = rawget(_G, "debug")
    if type(dbg) == "table" and type(dbg.traceback) == "function" then
        local ok, tb = pcall(dbg.traceback, tostring(err), 2)
        if ok and type(tb) == "string" then
            return tb
        end
    end
    return tostring(err)
end

-- ----------------------------------------------------------------------------
-- PUBLIC
-- ----------------------------------------------------------------------------

-- Keep the newest KEEP_SESSIONS sessions, delete the rest (jsonl parts, .end
-- markers and the legacy .log files), and say if the session before this one
-- never wrote its end marker (crash, game exit or forced unload).
local SESSION_PAT = "^(session_%d%d%d%d%-%d%d%-%d%d_%d%d%-%d%d%-%d%d)"
local function housekeeping()
    local ok, entries = pcall(function() return core.read_log_dir(FOLDER) end)
    if not ok or type(entries) ~= "table" then return end
    local groups, order = {}, {}
    for _, name in ipairs(entries) do
        local base = type(name) == "string" and name:match(SESSION_PAT)
        if base then
            local g = groups[base]
            if not g then g = { files = {}, ended = false }; groups[base] = g; order[#order + 1] = base end
            g.files[#g.files + 1] = name
            if name == base .. ".end" then g.ended = true end
        end
    end
    table.sort(order)
    local current = base_path and base_path:match(SESSION_PAT)
    local prev = nil
    for i = #order, 1, -1 do
        if order[i] ~= current then prev = order[i]; break end
    end
    local removed = 0
    for i = 1, #order - KEEP_SESSIONS do
        if order[i] ~= current and removed < 400 then
            for _, name in ipairs(groups[order[i]].files) do
                pcall(function() core.delete_log_file(FOLDER .. "/" .. name) end)
                removed = removed + 1
            end
        end
    end
    if removed > 0 then
        write("INFO", string.format("retention: removed %d old log files, keeping the newest %d sessions", removed, KEEP_SESSIONS))
    end
    if prev and not groups[prev].ended then
        write("WARN", "previous session " .. prev .. " has no end marker: it crashed, the game closed, or it predates end markers",
            {previous_session = prev})
    end
end

--- Start the session file and write its header.
function errorlog.start(version)
    session_version=tostring(version)
    if not errorlog.enabled() then return end
    if not open() then
        return
    end
    write("INFO", "JSONL schema 2: sort by session/seq; `context` only on state/warn/error lines (others carry `pos`); details.recent on errors; source_hint is a starting point, not a stack trace.")
    write("INFO", "Master Farmer - Forever Questing v" .. tostring(version) .. " session start")
    write("INFO", "Logging enabled; snapshots every 10 seconds, context sampled every 2 seconds; repeated trails suppressed.")
    pcall(housekeeping)
end

--- Close the session: a session_end record and the empty "<session>.end"
--- marker. Safe to call twice.
function errorlog.stop(reason)
    if stopped or not opened or not path or disabled then return end
    stopped = true
    if not errorlog.enabled() then return end
    write("INFO", "session_end: " .. tostring(reason or "unload"),
        {session_end = true, reason = tostring(reason or "unload"), lines_in_part = lines, part = part,
         seq = sequence, errors = counts.error, warnings = counts.warn})
    pcall(function() core.create_log_file(base_path .. ".end") end)
end

--- A function returning a table describing the environment (game build,
--- Sentinel version, class, race, faction, level, map). Sampled once, on the
--- first update tick, never from a render or error callback.
function errorlog.set_env(fn)
    env_fn = fn
end

--- A function returning a table of what the bot is doing, for error snapshots.
function errorlog.set_context(fn)
    context_fn = fn
end

--- Record a Lua error. `where` names the call that threw.
function errorlog.error(where, err, tb)
    if not errorlog.enabled() then return end
    local key = tostring(where) .. "|" .. tostring(err)
    -- 3.0.0: bounded - errors that embed numbers make new keys forever
    if seen[key] == nil then
        seen_n = seen_n + 1
        if seen_n > 500 then
            for k in pairs(seen) do seen[k] = nil end
            seen_n = 1
        end
    end
    local n = (seen[key] or 0) + 1
    seen[key] = n
    if n > 1 and n % REPEAT_NOTE ~= 0 then
        return
    end
    if n > 1 then
        write("ERROR", string.format("%s: repeated %d times: %s", tostring(where), n, tostring(err)))
        return
    end
    write("ERROR", tostring(where)..": "..tostring(err),
        {where=tostring(where),traceback=tostring(tb or err),occurrences=n,recent=recent_copy()})
    pcall(function()
        core.log_error("[Master Farmer - Forever Questing] " .. tostring(where) .. ": " .. tostring(err)
            .. "  (details: scripts_log/" .. tostring(path) .. ")")
    end)
end

function errorlog.warn(fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    write("WARN", ok and text or tostring(fmt))
end

function errorlog.info(fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    write("INFO", ok and text or tostring(fmt))
end

local function loop_check(tag, text)
    local shape = (tag .. ":" .. text):gsub("%-?%d+%.?%d*", "#"):sub(1, 120)
    local t = now_s()
    local e = loops[shape]
    if not e then
        loops_n = loops_n + 1
        if loops_n > 300 then loops, loops_n = {}, 1 end
        loops[shape] = { n = 1, t0 = t, tl = t, warned = -1e9 }
        return
    end
    if t - e.tl > LOOP_GAP then e.n, e.t0 = 1, t else e.n = e.n + 1 end
    e.tl = t
    if e.n >= LOOP_MIN and (t - e.t0) >= LOOP_SECS and (t - e.warned) >= LOOP_RENOTE then
        e.warned = t
        write("WARN", string.format("loop: %s repeated %d times in %.0f s", shape, e.n, t - e.t0),
            {loop = true, shape = shape, count = e.n, seconds = t - e.t0, recent = recent_copy()})
    end
end

local function trail_text(tag, text, details)
    if last_trail[tag] == text then
        return
    end
    last_trail[tag] = text
    write("TRAIL", tostring(tag) .. ": " .. text, details)
    loop_check(tostring(tag), text)
end

--- A breadcrumb. Written only when it differs from the previous one with the
--- same tag, so calling this every frame with an unchanged value is free.
function errorlog.trail(tag, fmt, ...)
    if not errorlog.enabled() then return end
    local ok, text = pcall(string.format, fmt, ...)
    trail_text(tag, ok and text or tostring(fmt))
end

--- A structured breadcrumb: errorlog.event("nav", "span_rejected",
--- {grade = 1.2, limit = 0.9, decision = "reject"}). The text is "name k=v ..."
--- (keys sorted) and details.name / details.fields carry the same data, so a
--- reader can aggregate without parsing sentences.
function errorlog.event(tag, name, fields)
    if not errorlog.enabled() then return end
    local keys, parts = {}, {}
    if type(fields) == "table" then
        for k in pairs(fields) do if type(k) == "string" then keys[#keys + 1] = k end end
        table.sort(keys)
        for i = 1, math.min(16, #keys) do
            local v = fields[keys[i]]
            if type(v) == "number" then v = string.format("%.2f", v):gsub("%.?0+$", "") end
            parts[#parts + 1] = keys[i] .. "=" .. tostring(v)
        end
    end
    local text = tostring(name) .. (#parts > 0 and (" " .. table.concat(parts, " ")) or "")
    trail_text(tag, text, {name = tostring(name), fields = fields})
end

--- Run fn(...) and record anything it throws. Returns ok, first result.
function errorlog.guard(where, fn, ...)
    local args = { n = select("#", ...), ... }
    local tb = nil
    local ok, res = xpcall(function()
        return fn(unpack(args, 1, args.n))
    end, function(e)
        tb = traceback(e)
        return e
    end)
    if not ok then
        errorlog.error(where, res, tb)
    end
    return ok, res
end

-- ----------------------------------------------------------------------------
-- FLIGHT RECORDER
-- ----------------------------------------------------------------------------
-- TRAIL lines only record changes, and a game crash happens INSIDE a native
-- call - between two TRAIL lines that look perfectly ordinary. So for a short
-- burst after something risky starts (questing begins, a mob is engaged),
-- every probe point writes a PROBE line straight to disk, unfiltered. The
-- last PROBE line in a crashed session names the call the game died in.
--
-- Bounded by a line budget rather than time, so a burst costs a fixed amount
-- of disk however fast frames run, and re-arming only tops the budget up.
-- TIME-BASED (2.27.0). A 2,500-line burst lasted ten seconds at the frame
-- rate the recorder itself costs, and the 20:25 crash came about fifteen
-- seconds after it ran out. The recorder now runs for PROBE_WINDOW seconds
-- from the last arm, bounded only by the session's MAX_LINES.
local PROBE_WINDOW = 90
local probe_until = -1
local probe_on = false

-- ----------------------------------------------------------------------------
-- LIGHT CAPTURE (2.87.0)
-- ----------------------------------------------------------------------------
-- Every game shutdown traced on 2026-09-27 came 0.6-1 s after the bot began
-- closing on a target (a new engage / pull, or a rest ending) - and the full
-- recorder, being opt-in and heavy, was never on. The light capture is armed
-- for a short window at exactly those moments. It writes every bot-decision
-- probe, but not the per-frame window drawing, and each per-frame movement
-- probe at most every LIGHT_FRAME_GAP s - a short hitch per pull rather than
-- a game at a fraction of its frame rate. The last PROBE line before a
-- shutdown names the call it happened in.
local light_until = -1
local light_last = {}          -- per-frame tag -> last write time
local LIGHT_FRAME_GAP = 0.05

-- Per-frame stages: written at most every LIGHT_FRAME_GAP. u:izi.on_update is
-- one of them and is NOT skipped (2.88.0) - it runs izi's spell queue, which
-- finishes casts, and the 16:40 shutdown came at the end of a Fireball.
local PER_FRAME = {
    ["u:begin"] = true, ["u:izi.on_update"] = true, ["u:keybinds"] = true,
    ["u:movement.pulse"] = true, ["on_render"] = true,
}

local function light_skip(tag)
    if tag == "-" or tag == "gui.draw" or tag:find("^gui:") then
        return true
    end
    if tag:find("^mv:") or PER_FRAME[tag] then
        local t = now_s()
        if (t - (light_last[tag] or -1)) < LIGHT_FRAME_GAP then
            return true
        end
        light_last[tag] = t
    end
    return false
end

--- Arm the light capture for `seconds` (extends, never shortens).
function errorlog.arm_light(seconds, why)
    local until_t = now_s() + (tonumber(seconds) or 1.5)
    if until_t > light_until then
        if light_until < now_s() then
            write("INFO", "light capture: " .. tostring(why))
        end
        light_until = until_t
    end
end

--- Arm (or extend) the recorder for another PROBE_WINDOW seconds.
function errorlog.arm(why)
    local until_t = now_s() + PROBE_WINDOW
    if until_t > probe_until then
        local was_on = probe_on
        probe_until = until_t
        probe_on = true
        -- Said once per window, not on every extension (a fight re-arms every tick).
        if not was_on then
            write("INFO", string.format("flight recorder armed for %ds: %s", PROBE_WINDOW, tostring(why)))
        end
    end
end

-- ----------------------------------------------------------------------------
-- PROFILER (2.28.0)
-- ----------------------------------------------------------------------------
-- The Plugin Monitor showed Master Farmer at 93 ms of Lua time a frame, 99% of
-- all plugins. core.time() only advances once a frame, so the recorder's
-- timestamps could not say where inside the frame that went. core.cpu_time()
-- is a nanosecond CPU clock: every probe point now adds the time since the
-- previous one to that stage's tally, in memory - no disk, one native call.
-- A PERF line every PERF_GAP seconds reports the plugin's CPU per frame and
-- the stages that cost the most.
--
-- errorlog.probe("-") marks the end of a callback: time from there to the
-- next probe belongs to the game and other plugins, not to a stage.
local cpu = nil
do
    local ok, fn = pcall(function() return core.cpu_time end)
    if ok and type(fn) == "function" then
        local ok2, v = pcall(fn)
        if ok2 and type(v) == "number" then
            cpu = fn
        end
    end
end
local PERF_GAP = 10
local perf = {}               -- tag -> { ns, n }
local perf_tag, perf_ns = nil, 0
local perf_frames = 0
local perf_next = 0

local function perf_mark(tag)
    local now = cpu()
    if perf_tag ~= nil and perf_tag ~= "-" then
        local e = perf[perf_tag]
        if e == nil then
            e = { 0, 0 }
            perf[perf_tag] = e
        end
        e[1] = e[1] + (now - perf_ns)
        e[2] = e[2] + 1
    end
    perf_tag, perf_ns = tag, now
end

local function perf_report()
    if perf_frames <= 0 then
        return
    end
    local list, total = {}, 0
    for tag, e in pairs(perf) do
        list[#list + 1] = { tag, e[1] }
        total = total + e[1]
    end
    table.sort(list, function(x, y) return x[2] > y[2] end)
    local parts = {}
    for i = 1, math.min(8, #list) do
        parts[#parts + 1] = string.format("%s %.2f", list[i][1], list[i][2] / 1e6 / perf_frames)
    end
    write("PERF", string.format("%.2f ms/frame over %d frames | %s",
        total / 1e6 / perf_frames, perf_frames, table.concat(parts, ", ")))
    perf = {}
    perf_frames = 0
end

--- Count a frame for the profiler. Called once per on_update.
function errorlog.frame()
    perf_frames = perf_frames + 1
end

-- SPIKE RECORDER (2.193.0), defined with the MEM code below.
local spike = nil
local spike_mark

--- A probe point: a profiler mark always, and a PROBE line while the
--- recorder is armed.
function errorlog.probe(tag)
    if cpu then
        perf_mark(tag)
        if spike then spike_mark(tag) end
    end
    if beat_on and beat_n < 48 and tag ~= "-" then
        beat_n = beat_n + 1
        beat_tags[beat_n] = (tag:gsub("^u:", ""))
    end
    if not probe_on then
        if light_until > 0 and now_s() <= light_until and not light_skip(tag) then
            write("PROBE", tag)
        end
        return
    end
    if now_s() > probe_until then
        probe_on = false
        write("INFO", "flight recorder window finished")
        return
    end
    -- The heap at each probe: a jump between two lines is what the stage in
    -- between allocated (less whatever the collector freed meanwhile).
    local ok, kb = pcall(collectgarbage, "count")
    if ok and type(kb) == "number" then
        write("PROBE", string.format("%-40s heap %.0f KB", tostring(tag), kb))
    else
        write("PROBE", tag)
    end
end

-- ----------------------------------------------------------------------------
-- HEARTBEAT (2.31.0)
-- ----------------------------------------------------------------------------
-- The full recorder writes ~25 lines a frame and slows the game enough that
-- the crash stops happening. The heartbeat writes ONE line per bot tick
-- (10 a second): the stages that tick ran through, and a short snapshot of
-- what the bot was doing. The last BEAT before a crash is the last complete
-- tick. Probe tags are only collected while a bot tick is open.
local beat_count = 0
local beat_extra = nil

--- A function returning a short status string for each BEAT line.
function errorlog.set_beat_extra(fn)
    beat_extra = fn
end

--- Open a bot tick: probe tags from here on are collected for its BEAT line.
function errorlog.tick_begin()
    beat_on = true
    beat_n = 0
end

--- Close the bot tick and write its BEAT line. No-op when none is open.
function errorlog.tick_end()
    if not beat_on then
        return
    end
    beat_on = false
    beat_count = beat_count + 1
    if not errorlog.enabled() then return end
    local now=tonumber(game_time()) or 0
    if now-beat_last_t<2 then beat_same=beat_same+1;return end
    local extra = ""
    if type(beat_extra) == "function" then
        local ok, s = pcall(beat_extra)
        if ok and type(s) == "string" then
            extra = s
        end
    end
    local body = table.concat(beat_tags, ">", 1, beat_n) .. " | " .. extra
    local same = beat_same > 0 and string.format(" (+%d same)", beat_same) or ""
    beat_last_body, beat_last_t, beat_same = body, now, 0
    write("BEAT", string.format("#%d %s%s", beat_count, body, same))
end

-- ----------------------------------------------------------------------------
-- MEMORY
-- ----------------------------------------------------------------------------
-- A MEM line every MEM_GAP seconds: the Lua heap now, and the peak since the
-- session began. A heap that climbs from line to line is a leak; one that
-- saws up and down is churn the collector is keeping up with.
local MEM_GAP = 30
local mem_next = 0
local mem_peak = 0
local mem_extra = nil

--- A function returning extra text for each MEM line (e.g. request counts).
function errorlog.set_mem_extra(fn)
    mem_extra = fn
end

local function heap_kb()
    local ok, kb = pcall(collectgarbage, "count")
    if ok and type(kb) == "number" then
        return kb
    end
    return nil
end

-- SPIKE LINE (2.193.0). One stage call (u:healing) timed with its probe
-- marks inside, CPU and heap per segment. A call over SPIKE_MS or one that
-- grew the heap by SPIKE_KB writes one line naming the segments that cost
-- the most, e.g.
--   SPIKE u:healing 1.52 ms, heap +2048 KB | rest:food_ids 1.20 ms +1900 KB; ...
-- The heap is counted at each mark only while such a call is open.
local SPIKE_MS, SPIKE_KB, SPIKE_GAP = 1.0, 512, 2.0
local spike_last = -1e9

spike_mark = function(tag)
    local s = spike
    if not s or s.n >= 32 then return end
    local t, kb = cpu(), heap_kb() or s.last_kb
    s.n = s.n + 1
    s.seg[s.n] = { s.last_tag, t - s.last_t, kb - s.last_kb }
    s.last_tag, s.last_t, s.last_kb = tag, t, kb
end

--- Open a timed call (main.lua, around healing.tick).
function errorlog.spike_begin(group)
    if not cpu then return end
    local t, kb = cpu(), heap_kb() or 0
    spike = { group = group, t0 = t, kb0 = kb, n = 0, seg = {}, last_tag = group, last_t = t, last_kb = kb }
end

--- Close it; write a SPIKE line when it was slow or allocated a lot.
function errorlog.spike_end()
    local s = spike
    spike = nil
    if not s or not cpu then return end
    local t, kb = cpu(), heap_kb() or s.last_kb
    s.n = s.n + 1
    s.seg[s.n] = { s.last_tag, t - s.last_t, kb - s.last_kb }
    if kb > mem_peak then mem_peak = kb end
    local ms, dkb = (t - s.t0) / 1e6, kb - s.kb0
    if ms < SPIKE_MS and dkb < SPIKE_KB then return end
    local wall = now_s()
    if (wall - spike_last) < SPIKE_GAP then return end
    spike_last = wall
    table.sort(s.seg, function(a, b) return a[2] > b[2] end)
    local parts = {}
    for i = 1, math.min(6, #s.seg) do
        local g = s.seg[i]
        parts[#parts + 1] = string.format("%s %.2f ms %+.0f KB", tostring(g[1]), g[2] / 1e6, g[3])
    end
    write("SPIKE", string.format("%s %.2f ms, heap %+.0f KB (%.0f -> %.0f) | %s",
        tostring(s.group), ms, dkb, s.kb0, kb, table.concat(parts, "; ")))
end

-- HEAP PEAK ONCE A SECOND (2.193.0): collectgarbage("count") ran every frame
-- only to keep the peak; a spike call (above) also updates it.
local PEAK_GAP = 1.0
local peak_next = 0

--- Called every frame from main.lua. Cheap when it is not time to write.
function errorlog.tick(now)
    if not errorlog.enabled() then return end
    local ev=package.loaded["events"]
    local ui=type(ev)=="table" and ev.ui
    if type(ui)=="table" and ui.UI_ERROR_MESSAGE~=ui_seq and ui.error_text then
        ui_seq=ui.UI_ERROR_MESSAGE
        write("TRAIL","ui: "..tostring(ui.error_id or "unknown").." - "..tostring(ui.error_text),
            {code=ui.error_id,text=ui.error_text,observed_at=ui.UI_ERROR_MESSAGE})
    end
    if type(now)=="number" and (now-context_at>=2 or context_at==0 or now<context_at) and not context_busy then
        context_busy=true
        local ok,value=pcall(function() return context_fn and context_fn() or {} end)
        cached_context=ok and type(value)=="table" and value or {snapshot_error=tostring(value)}
        local cp = cached_context.position
        cached_pos = type(cp)=="table" and type(cp.x)=="number"
            and string.format("%.1f,%.1f,%.1f", cp.x, cp.y or 0, cp.z or 0) or nil
        context_at=now
        if env_fn and not env_written then
            env_written = true
            local okE, env = pcall(env_fn)
            write("INFO", "environment", {environment = okE and type(env) == "table" and env or {error = tostring(env)}})
        end
        context_busy=false
        if now>=snapshot_next then
            snapshot_next=now+10
            write("STATE","Periodic diagnostic snapshot")
        end
    end
    local kb = nil
    if type(now) ~= "number" or now >= peak_next or now < peak_next - PEAK_GAP * 2 then
        peak_next = (type(now) == "number" and now or 0) + PEAK_GAP
        kb = heap_kb()
        if kb and kb > mem_peak then
            mem_peak = kb
        end
    end
    if cpu and type(now) == "number" and now >= perf_next then
        if perf_next > 0 then
            perf_report()
        end
        perf_next = now + PERF_GAP
    end
    if type(now) ~= "number" or now < mem_next then
        return
    end
    mem_next = now + MEM_GAP
    kb = kb or heap_kb()
    if kb then
        local extra = ""
        if type(mem_extra) == "function" then
            local ok, s = pcall(mem_extra)
            if ok and type(s) == "string" and s ~= "" then
                extra = "  " .. s
            end
        end
        write("MEM", string.format("lua heap %.0f KB  (peak %.0f KB)%s", kb, mem_peak, extra))
    end
end

--- Where this session's file is, for a status line.
function errorlog.path()
    return path and ("scripts_log/" .. path) or nil
end

return errorlog
