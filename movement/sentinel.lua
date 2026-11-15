-- ============================================================================
-- Master Farmer - Forever Questing
-- movement/sentinel.lua - the Sentinel Navigation adapter (1.1.0)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Product version: see version.lua
-- Folder: Forever_Questing
-- ============================================================================
-- 1.1.0 SENTINEL PORT (docs/SENTINEL_PORT_GUIDE.md; the reference adapter is
-- restedXP_questing 4.7.0 movement/sentinel.lua, its self-test left out).
-- The ONE module that talks to Sentinel Navigation (_G.SentinelNavClient, a
-- Sylvanas library; the player installs and enables it, the launcher points
-- its shared client at the Master Farmer server and this game's map set).
-- A library update is fixed here and nowhere else.
--
--   * the client is looked up lazily at run time, never in header.lua:
--     rawget(_G, "SentinelNavClient"), then its `client` (a live getter, may
--     be nil);
--   * the game / server come from the launcher (MASTER_FARMER.nav: kind
--     "sentinel", game "forever" for this product, base_url, supported) -
--     this product never writes the server address, never calls
--     update_config / update;
--   * on a client without maps there navigation is unavailable:
--     S.unavailable() says why, and nothing moves.
--
-- Calls and answers as documented (restedXP_questing_sentinel/docs/
-- SENTINEL_API.md, the official v0.0.8 page) and as recorded on v0.24
-- (SENTINEL_V024.md). Every call is pcall-guarded; callbacks are wrapped so
-- the bot sees one fixed shape.
-- ============================================================================

local S = {}

-- ----------------------------------------------------------------------------
-- the library and the launcher's word on it
-- ----------------------------------------------------------------------------
---_G.SentinelNavClient (or nil).
function S.library()
    local g = rawget(_G, "SentinelNavClient")
    return type(g) == "table" and g or nil
end

---The shared client (or nil): looked up every time - the library may reload.
function S.client()
    local g = S.library()
    if not g then return nil end
    local ok, c = pcall(function() return g.client end)
    if ok and type(c) == "table" then return c end
    return nil
end

---The library's VERSION string ("" when unknown).
function S.version()
    local g = S.library()
    local ok, v = pcall(function() return g and g.VERSION end)
    return (ok and v ~= nil) and tostring(v) or ""
end

---The launcher's MASTER_FARMER table, or nil. It lives in this product's
---environment (the launcher's loader env.MASTER_FARMER), NOT in the real _G:
---read as a plain global, never rawget(_G, ...).
function S.master_farmer()
    local mf = MASTER_FARMER
    return type(mf) == "table" and mf or nil
end

---MASTER_FARMER.nav from the launcher, or a table saying it is missing.
function S.info()
    local mf = S.master_farmer()
    local n = type(mf) == "table" and mf.nav or nil
    if type(n) == "table" and n.kind == "sentinel" then return n end
    return { kind = "none", game = nil, supported = false }
end

---Why Sentinel navigation cannot be used now, or nil when it can.
function S.unavailable()
    local n = S.info()
    if n.kind ~= "sentinel" then return "not loaded through Master Farmer's Sentinel entry" end
    if not n.supported then return "Sentinel navigation has no maps for this game version" end
    local c = S.client()
    if not c then return "the Sentinel Navigation library is not loaded" end
    local ok, up = pcall(function() return c:is_server_available() end)
    if not ok or up ~= true then return "the navigation server is not answering" end
    return nil
end

-- ----------------------------------------------------------------------------
-- runtime calls - the only Sentinel calls the bot makes
-- ----------------------------------------------------------------------------
-- Replies from a replaced library or another world cannot affect this walk.
local reply_generation = 0
function S.invalidate() reply_generation = reply_generation + 1 end
local function reply_guard(c)
    local issued_generation = reply_generation
    local map_ok, map = pcall(core.get_map_id)
    local instance_ok, instance = pcall(core.get_instance_id)
    local answered = false
    return function()
        if answered or issued_generation ~= reply_generation or S.client() ~= c then return false end
        local km, current_map = pcall(core.get_map_id)
        local ki, current_instance = pcall(core.get_instance_id)
        if (map_ok and (not km or current_map ~= map))
            or (instance_ok and (not ki or current_instance ~= instance)) then return false end
        answered = true
        return true
    end
end

local function m(c, name, ...)
    local got, f = pcall(function() return c and c[name] end)
    if not got or type(f) ~= "function" then return false end
    return pcall(f, c, ...)
end

local function pt(p)
    return { x = p.x, y = p.y, z = p.z }
end

---move_to: cb(success, reason) - reason "unreachable" | "server_timeout" |
---"max_stuck_exceeded" | "max_repath_exceeded" (doc). A walk replaced by a
---newer move_to, or stopped, gets NO callback (recorded on v0.24). A second
---move_to while walking re-plans without stopping (0.12 s, recorded).
function S.move_to(c, p, cb)
    local accept = reply_guard(c)
    local ok, result = m(c, "move_to", pt(p), function(success, reason)
        if not accept() then return end
        if cb then pcall(cb, success == true, reason ~= nil and tostring(reason) or nil) end
    end)
    return ok and result ~= false
end

---move_direct: one waypoint, no pathfinding; cb(success, reason) (doc, not
---run on v0.24). Used only for the last yards into a portal (N.step_into).
function S.move_direct(c, p, cb)
    local accept = reply_guard(c)
    local ok, result = m(c, "move_direct", pt(p), function(success, reason)
        if not accept() then return end
        if cb then pcall(cb, success == true, reason ~= nil and tostring(reason) or nil) end
    end)
    return ok and result ~= false
end

---follow_path: precomputed waypoints in order; cb(success, reason) (doc).
function S.follow_path(c, points, cb)
    local accept = reply_guard(c)
    local list = {}
    for i = 1, #points do list[i] = pt(points[i]) end
    local ok, result = m(c, "follow_path", list, function(success, reason)
        if not accept() then return end
        if cb then pcall(cb, success == true, reason ~= nil and tostring(reason) or nil) end
    end)
    return ok and result ~= false
end

---stop(): stops all movement (doc); no callback for the stopped walk (v0.24).
function S.stop(c)
    local ok, result = m(c, "stop")
    -- The live client can report idle while a recovery input remains held.
    -- Release inputs only after an explicit stop; never steer a running path.
    for _,name in ipairs({"move_forward_stop","move_backward_stop","strafe_left_stop",
        "strafe_right_stop","turn_left_stop","turn_right_stop"}) do
        local input=core and core.input
        if input and type(input[name])=="function" then pcall(input[name]) end
    end
    return ok and result ~= false
end

---is_moving(): true only while the top-level state is navigating (doc).
function S.moving(c)
    local ok, v = m(c, "is_moving")
    return ok and v == true
end

---get_state(): "idle" | "navigating" | "arrived" | "failed" (doc), or nil.
function S.state(c)
    local ok, v = m(c, "get_state")
    return ok and type(v) == "string" and v or nil
end

---get_full_state(): dotted ("navigating.awaiting_path", ...) or nil.
function S.full_state(c)
    local ok, v = m(c, "get_full_state")
    return ok and type(v) == "string" and v or nil
end

---The walk is still waiting for (or re-requesting) its path.
function S.path_pending(c)
    local f = S.full_state(c) or ""
    return f:find("awaiting_path", 1, true) ~= nil or f:find("repathing", 1, true) ~= nil
        or f:find("deferred", 1, true) ~= nil
end

function S.server_up(c)
    local ok, v = m(c, "is_server_available")
    return ok and v == true
end

---get_current_path() -> vec3[] | nil, get_path_index() -> number (doc).
function S.current_path(c)
    local ok, v = m(c, "get_current_path")
    return (ok and type(v) == "table") and v or nil
end
function S.path_index(c)
    local ok, v = m(c, "get_path_index")
    return (ok and type(v) == "number") and v or nil
end

---Every navmesh floor at (x, y): cb(list of heights, nearest `p.z` first).
---v0.24 answers (true, { count, heights = { { height, flags }, ... } }, nil).
---False when the query could not be sent (cb is not called then).
function S.floors(c, p, cb)
    local accept = reply_guard(c)
    local done = false
    local ok, result = m(c, "get_all_heights", pt(p), function(okh, data)
        if not accept() then return end
        if done then return end
        done = true
        local out = {}
        local hs = (okh == true and type(data) == "table") and data.heights or nil
        for i = 1, #(type(hs) == "table" and hs or {}) do
            local h = hs[i]
            local v = type(h) == "table" and tonumber(h.height) or tonumber(h)
            if v and v == v and math.abs(v) < 20000 then out[#out + 1] = v end
        end
        local z = tonumber(p.z) or 0
        table.sort(out, function(a, b) return math.abs(a - z) < math.abs(b - z) end)
        pcall(cb, out)
    end)
    return ok == true and result ~= false
end

---validate_destination: cb(reachable, reason, distance) (doc, recorded).
function S.validate(c, p, cb)
    local accept = reply_guard(c)
    local ok, result = m(c, "validate_destination", pt(p), function(reachable, reason, distance)
        if not accept() then return end
        pcall(cb, reachable == true, reason, distance)
    end)
    return ok == true and result ~= false
end

--- Public planning-only route probe. The caller verifies endpoint order and
--- terrain before executing any movement; no private path service is used.
function S.plan_probe(c, a, b, cb)
    local accept = reply_guard(c)
    local ok, result = m(c, "plan_route", {pt(a),pt(b)}, function(success, data)
        if not accept() then return end
        local points = success == true and type(data)=="table" and data.waypoints or nil
        pcall(cb, type(points)=="table" and points or nil)
    end)
    return ok == true and result ~= false
end

---One path query, no movement (advanced: client.nav_client:find_path).
---v0.24 answers (true, { waypoints, distance, partial, computation_time_ms }, nil).
---cb(points or nil, ok, info) where info.partial says the path stops short.
function S.find_path(c, a, b, cb)
    local accept = reply_guard(c)
    local okn, nc = pcall(function() return c.nav_client end)
    if not okn or type(nc) ~= "table" or type(nc.find_path) ~= "function" then return false end
    local ok = pcall(nc.find_path, nc, pt(a), pt(b), function(okp, data)
        if not accept() then return end
        local pts = (type(data) == "table" and type(data.waypoints) == "table") and data.waypoints or nil
        local info = { partial = type(data) == "table" and data.partial == true or false }
        pcall(cb, (pts and #pts >= 2) and pts or nil, okp == true, info)
    end)
    return ok == true
end

-- AVOIDANCE ZONE + SOFT RE-PATH (verified on v0.24 by the MF API Dump,
-- 2026-10-24: obstacle:add_zone(pos, radius) 3 args, replan(reason, opts) 3).
-- Every path request after add_zone avoids the zone (Sentinel's path-avoid,
-- cost 100, the zone ages out after its TTL - 120 s in the Sentinel UI);
-- replan with soft = true blends the new path in without stopping.
function S.add_zone(c, p, radius)
    local oko, ob = pcall(function() return c.obstacle end)
    if not oko or type(ob) ~= "table" or type(ob.add_zone) ~= "function" then return false end
    return pcall(ob.add_zone, ob, pt(p), radius) == true
end

function S.soft_replan(c, reason)
    local ok, r = pcall(function() return c:replan(reason) end)
    return ok and r ~= false
end

-- KITE (nav_client:kite, present on v0.24 with 5 args - MF API Dump
-- 2026-10-24; its answer read from the readable v0.0.6 source, the same
-- (true, { waypoints, ... }, nil) shape as find_path, which v0.24 confirmed):
--   kite(player_pos, target_pos, cb(ok, { waypoints, waypoint_count }, err), { kite_radius })
-- cb(points | nil, ok, info): info.shape_bad = an answer of another shape
-- (the caller switches kiting off), info.error = the library's error text.
function S.kite(c, from, target, radius, cb)
    local accept = reply_guard(c)
    local okn, nc = pcall(function() return c.nav_client end)
    if not okn or type(nc) ~= "table" or type(nc.kite) ~= "function" then return false end
    local ok = pcall(nc.kite, nc, pt(from), pt(target), function(okp, data, err)
        if not accept() then return end
        local pts = (type(data) == "table" and type(data.waypoints) == "table") and data.waypoints or nil
        local info = { error = err ~= nil and tostring(err) or nil,
            shape_bad = okp == true and pts == nil, got = type(data) }
        pcall(cb, (pts and #pts >= 1) and pts or nil, okp == true, info)
    end, { kite_radius = radius })
    return ok == true
end

-- 1.7.0 FLEE (restedXP 4.14.0; nav_client:flee, present on v0.24 - MF API
-- Dump 2026-10-24; argument order from the official page:
-- flee(player_pos, threats, cb, opts)):
--   flee(player_pos, { threat_pos, ... }, cb(ok, { waypoints, ... }, err), { flee_distance })
-- The answer is expected in find_path's shape and checked live like kite's:
-- cb(points | nil, ok, info) - info.shape_bad = another shape (the caller
-- switches fleeing off), info.error = the library's error text.
function S.flee(c, from, threats, distance, cb)
    local accept = reply_guard(c)
    local okn, nc = pcall(function() return c.nav_client end)
    if not okn or type(nc) ~= "table" or type(nc.flee) ~= "function" then return false end
    local list = {}
    for i = 1, #threats do list[i] = pt(threats[i]) end
    local ok = pcall(nc.flee, nc, pt(from), list, function(okp, data, err)
        if not accept() then return end
        local pts = (type(data) == "table" and type(data.waypoints) == "table") and data.waypoints or nil
        local info = { error = err ~= nil and tostring(err) or nil,
            shape_bad = okp == true and pts == nil, got = type(data) }
        pcall(cb, (pts and #pts >= 1) and pts or nil, okp == true, info)
    end, { flee_distance = distance })
    return ok == true
end

-- 1.7.0 LIVE STATUS for the GUI and the route progress (restedXP 4.14.0,
-- improvements 5 and 11 of the API-dump review). Shapes recorded on v0.24 by
-- the MF Start Dump:
--   get_progress()        { current_index, percent, total_waypoints, waypoints_remaining }
--   get_route_progress()  nothing while no recorded route runs (its shape when
--                         one runs is not recorded: a number or a table with
--                         percent / index / total is read, anything else ignored)
--   get_destination()     vec3 | nothing
--   obstacle:get_zone_count()             number
--   nav_client:get_consecutive_failures() number
-- Read on the update tick only (never on the render path).
local function num(v) v = tonumber(v) if v and v == v then return v end return nil end
function S.progress(c)
    local ok, v = m(c, "get_progress")
    if not ok or type(v) ~= "table" then return nil end
    local pc = num(v.percent)
    if pc and pc <= 1 then pc = pc * 100 end
    return { index = num(v.current_index), percent = pc,
        total = num(v.total_waypoints), left = num(v.waypoints_remaining) }
end
function S.route_progress(c)
    local ok, v = m(c, "get_route_progress")
    if not ok then return nil end
    if type(v) == "number" then return { percent = (v <= 1 and v * 100) or v } end
    if type(v) ~= "table" then return nil end
    local pc = num(v.percent)
    local fr = num(v.progress)
    if not pc and fr then pc = (fr <= 1 and fr * 100) or fr end
    local i = num(v.current_index) or num(v.index) or num(v.current)
    local n = num(v.total) or num(v.total_waypoints) or num(v.count)
    if not pc and i and n and n > 0 then pc = i / n * 100 end
    if not pc then return nil end
    return { percent = pc, index = i, total = n }
end
---get_corridor_widths() -> number[] | nil (declared on the live stub: widths
---per waypoint of the current path). Units are not documented, so callers use
---it RELATIVELY (a stretch much narrower than the rest of the path).
function S.corridor_widths(c)
    local ok, v = m(c, "get_corridor_widths")
    if not ok or type(v) ~= "table" then return nil end
    local out = {}
    for i = 1, #v do out[i] = num(v[i]) or false end
    return out
end
function S.destination(c)
    local ok, v = m(c, "get_destination")
    if ok and type(v) == "table" and type(v.x) == "number" then return v end
    return nil
end
function S.zone_count(c)
    local oko, ob = pcall(function() return c.obstacle end)
    if not oko or type(ob) ~= "table" or type(ob.get_zone_count) ~= "function" then return nil end
    local ok, v = pcall(ob.get_zone_count, ob)
    return ok and num(v) or nil
end
function S.failures(c)
    local okn, nc = pcall(function() return c.nav_client end)
    if not okn or type(nc) ~= "table" or type(nc.get_consecutive_failures) ~= "function" then return nil end
    local ok, v = pcall(nc.get_consecutive_failures, nc)
    return ok and num(v) or nil
end


-- Running-path recovery belongs to Sentinel. Its private nav_client check_path
-- has no declared live signature; do not infer verdicts or restart healthy walks.

return S
