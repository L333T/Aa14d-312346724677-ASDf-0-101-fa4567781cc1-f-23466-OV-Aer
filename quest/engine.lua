-- ============================================================================
-- Master Farmer - Forever Questing
-- Quest engine - driven by RestedXP Guides (quest/guide.lua)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Product version: see version.lua
-- ============================================================================
-- main.lua runs the owners first (death, stuck recovery, loot, rest, buffs,
-- vendor, equip); this is the guide step, ONE action per tick: a tick that
-- turns in, loots, fights or skips does not also walk.
--
-- Step rules (quest/guide.lua decision):
--   no addon / no step              wait
--   inactive, requires_step ~= 0    1.0.25: the sticky it requires (requires_step
--                                   / its label) is WORKED; skipped only when that
--                                   sticky is gone from get_current_stickies or
--                                   every goal on it is done; else wait
--   inactive, requires_step 0       skipped (user, 2026-10-20: a step no API
--                                   handles may be skipped) - its turn-ins do
--                                   not count
--   level below step.level          its kills wait (logged)
--   a goal to work                  its handler
--   nothing workable left           skip_current_step, when RestedXP has not
--                                   marked the step complete; every unhandled
--                                   goal is logged with action, quest id, text
--
-- Handlers (the documented field table only):
--   complete   walk the arrow (map_id ~= 0, not wrong_continent), fight the
--              step's units; done by goal.is_complete or get_objectives
--   kill       .target / .mob / .unitscan: the closest matching unit in sight;
--              out of reach the nav client walks closer, then the rotation casts
--   accept     (1.0.4) the same NPC lookup as a turn-in; npc.accept
--   turnin     the NPC named by the waypoint title, else the quest givers at
--              the waypoint in turn; reward when not 0; nobody takes it ->
--              deferred, never a pause (1.0.1)
-- .money / .itemcount are conditions (quest/guide.lua): met = done, not met =
-- no handler.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

local gui = require("gui")
local state = require("state")
local npc = require("quest/npc")
local rotation = require("rotation")
local targeting = require("targeting")
local movement = require("movement")
local healing = require("healing")
local geometry = require("geometry")
local guide = require("quest/guide")

local loot = nil
do
    local ok, mod = pcall(require, "loot")
    if ok and type(mod) == "table" then loot = mod end
end
-- 1.0.24: ground pickups (a cRXP_PICK_ step): ESP + walk + use_object
local pickup = nil
do
    local ok, mod = pcall(require, "quest/pickup")
    if ok and type(mod) == "table" then pickup = mod end
end
-- 1.0.5: the imported RXPGuides Forever guide data (empty without the import)
local rxpdata = nil
do
    local ok, mod = pcall(require, "data/rxp_forever")
    if ok and type(mod) == "table" then rxpdata = mod end
end

local quest = {}

local KILL_TIMEOUT = 60.0     -- give up on one mob after this
local SCAN_GAP = 0.8          -- seconds between target scans
local NEAR_SCAN = 60          -- yd: mobs fought on the way to the arrow
local MOB_RANGE = 300         -- yd: mobs fought once at the arrow
local ARRIVE = 4.0            -- yd: standing on a waypoint
local ARRIVE_DZ = 12          -- yd: a waypoint height is a terrain estimate
local TALK_REACH = 2.5        -- yd: match movement's interaction gate
local TALK_SEARCH = 40.0      -- yd around the waypoint the NPC is looked for
local SKIP_SETTLE = 2.0       -- s the same step must read "nothing workable" before a skip
local SKIP_GAP = 5.0          -- s between two skips
local NOT_READY_HOLD = 6.0    -- s a turn-in the NPC says is not ready waits (1.0.6: was 10)

local g = {
    key = nil, scan_until = 0, kill_until = 0, cur_kind = nil,
    in_dialog = false, in_travel = false, loot_wait = false, label = "questing",
    skip_step = nil, skip_since = 0, skip_t = -1e9, logged = {},
    hold_until = 0, dumped = nil, unhandled = {}, tried = {},
}
local g_appr = { guid = nil, since = 0, off = false, released = false, seen = nil }
local APPROACH_BAND = 15
local APPROACH_WAIT = 3.0

local function safe(fn)
    local ok, r = pcall(fn)
    if ok then return r end
    return nil
end

local errorlog = nil
do
    local ok, mod = pcall(require, "errorlog")
    if ok and type(mod) == "table" then errorlog = mod end
end
local function trail(tag, fmt, ...)
    if errorlog then errorlog.trail(tag, fmt, ...) end
end
local function probe(tag)
    if errorlog then errorlog.probe(tag) end
end
local function note(text) state.set_note("Quest", text) end

local function release_combat()
    if type(movement.nav_stop) == "function" then movement.nav_stop() end
    if type(movement.combat_release) == "function" then movement.combat_release() end
    state.reset_target()
end

local function combat_yards(player)
    local yards = type(rotation.combat_range) == "function" and rotation.combat_range(player) or 30
    if type(yards) ~= "number" or yards < 1 then yards = 30 end
    return yards
end

-- ----------------------------------------------------------------------------
-- FIGHTING (from the Zygor engine: valid first, path approach, then combat
-- movement and the rotation - one cast per tick is the rotation's own rule)
-- ----------------------------------------------------------------------------
local function fight_unit(player, unit, label)
    local now = izi.now()
    if not unit or safe(function() return unit:is_valid() end) ~= true then
        -- Streaming loss or a despawn is not evidence of death. A phantom
        -- corpse here sends loot back toward an enemy we may have escaped.
        if state.target.guid then
            trail("act", "target unavailable: %s; released without confirmed kill", tostring(state.target.guid))
        end
        release_combat()
        return false
    end
    if safe(function() return unit:is_dead() end) == true or safe(function() return unit:is_dead_or_ghost() end) == true then
        state.mark_killed(state.target.guid or safe(function() return unit:get_guid() end))
        trail("act", "killed %s", tostring(safe(function() return unit:get_name() end)))
        if loot and type(loot.note_kill) == "function" then loot.note_kill(unit) end
        release_combat()
        return false
    end
    if type(movement.fled_recently)=="function" and movement.fled_recently(unit)
        and safe(function() return player:is_in_combat() end)~=true
        and not (type(targeting.attackers)=="function" and targeting.attackers(player)>0) then
        trail("act","escaped target released: %s; no chase after combat ended",tostring(safe(function() return unit:get_name() end)))
        release_combat()
        return false
    end
    -- 1.0.18: never while the player is in combat and the unit is still being
    -- fought (the lock stays on it until it dies)
    if g.kill_until > 0 and now > g.kill_until and state.target.kind == "kill"
        and not (safe(function() return player:is_in_combat() end) == true and targeting.engaged(unit)) then
        state.mark_killed(state.target.guid)
        release_combat()
        return false
    end
    local dist = safe(function() return player:distance_to(unit) end) or 99
    if dist > (targeting.MAX_RANGE or 300) then
        release_combat()
        return false
    end
    targeting.ensure_target(player, unit)
    local yards = combat_yards(player)
    if type(targeting.approach_stuck) == "function" and targeting.approach_stuck(player, unit, yards) then
        release_combat()
        note("Skip unreachable")
        return false
    end
    -- far: walk in on a path until inside engage distance + APPROACH_BAND
    local guid = safe(function() return unit:get_guid() end)
    if g_appr.guid ~= guid then g_appr.guid, g_appr.since, g_appr.off, g_appr.released = guid, now, false, false end
    if (now - (g_appr.seen or now)) > 1.0 then g_appr.since, g_appr.off = now, false end
    g_appr.seen = now
    if not g_appr.off and dist > (yards + APPROACH_BAND) and safe(function() return player:is_in_combat() end) ~= true then
        local up = safe(function() return unit:get_position() end)
        if up then
            if not g_appr.released and movement.in_combat_movement() then movement.combat_release() end
            g_appr.released = true
            local walking = movement.is_moving() and not movement.in_combat_movement()
                and (type(movement.headed_to) ~= "function" or movement.headed_to(up, 15))
            if walking or movement.nav_to(up) then
                g_appr.since = now
                note(string.format("%s (approaching %d yd)", label, math.floor(dist / 5) * 5))
                return true
            end
            if (now - g_appr.since) < APPROACH_WAIT then
                note(string.format("%s (approaching %d yd)", label, math.floor(dist / 5) * 5))
                return true
            end
            g_appr.off = true
        end
    end
    if type(movement.set_approach_target) == "function" then movement.set_approach_target(nil) end
    if not movement.combat_engage(player, unit, yards) then
        if state.is_unreachable and state.is_unreachable(state.target.guid) then
            release_combat()
            note("Skip unreachable")
            return false
        end
        movement.face(unit)
        note(label .. " (closing)")
        return true
    end
    targeting.start_auto_attack(player, unit)
    movement.face(unit)
    note(label)
    local pack = targeting.combat_scan(player, yards)
    rotation.tick(player, unit, { enemies = pack, no_move = true })
    return true
end

local function engage(player, unit, label)
    trail("act", "engage %s (%s)", tostring(safe(function() return unit:get_name() end)), tostring(label))
    targeting.set_current(unit, "kill")
    g.kill_until = izi.now() + KILL_TIMEOUT
    fight_unit(player, unit, label)
end

--- Anything fighting us first, then the kill under way.
--- 1.0.18 (user: "If the player is in combat, the bot fights"): while the
--- player is in combat and an attacker, the kill being fought or a wounded
--- runner is alive this returns true - travel, loot and the next pull wait;
--- in combat with nothing in view, combat_hold stops and waits. Several
--- enemies: the lowest remaining health, locked until it dies
--- (targeting.attacker_to_switch).
local function fight_back(player)
    local range = targeting.THREAT_RANGE or 40
    local cur_guid = (state.target.kind == "kill") and state.target.guid or nil
    local in_combat = safe(function() return player:is_in_combat() end) == true
    local attacked = type(targeting.attackers) == "function" and targeting.attackers(player) > 0
    local attacker = targeting.attacker_to_switch(player, cur_guid, range)
    if attacker then
        targeting.combat_active()
        engage(player, attacker, "Guide: defending")
        return true
    end
    local unit = state.target.unit
    if unit and state.target.kind == "kill" and fight_unit(player, unit, "Guide: " .. g.label) then
        targeting.combat_active()
        return true
    end
    if not in_combat and not attacked then
        targeting.combat_hold(player)
        return false
    end
    -- 1.0.18: the lowest remaining health of the fight's pack (one unit: that one)
    local pick = type(targeting.combat_pack) == "function"
        and targeting.lowest_health(player, targeting.combat_pack(player, range))
        or targeting.nearest(player, targeting.threats(player, range))
    if pick then
        targeting.combat_active()
        engage(player, pick, "Guide: defending")
        return true
    end
    -- 1.0.18: in combat, a wounded mob that dropped its target and ran is still the fight
    local runner = in_combat and type(targeting.fight_unfinished) == "function" and targeting.fight_unfinished(player, range)
    if runner then
        targeting.combat_active()
        engage(player, runner, "Guide: finishing the fight")
        return true
    end
    if targeting.combat_hold(player) then
        movement.nav_stop()
        note("Guide: holding - combat not over")
        return true
    end
    return false
end

-- ----------------------------------------------------------------------------
-- WALKING - Zygor style (1.0.7, user: "use Zygor's style navigation movement,
-- waypoint handling, stuck handling"). From products_src/zygor_questing
-- quest/engine.lua: walk_to (one waypoint walk per key, the exact server path
-- for NPC approaches, a forced fresh path after a stall), the route through
-- the step's waypoints (resume at the nearest, next point on a failed path,
-- reachability / death-zone skips, flip-flop guard), the standing-still watch,
-- clearing a weak mob off the path, and for NPC goals the 30 s no-progress
-- ladder, the giver re-route, close-in after a refused interact and the
-- behind-a-counter interact. The outdoor unstick ladder, the 5 min long stuck
-- and the sharp-turn pivot are the movement layer's (movement.lua, pivot.lua).
-- ----------------------------------------------------------------------------
local TALK_ARRIVE = 8.0       -- yd: at the NPC's door is close enough to stop walking
local EXACT_DZ = 2.5          -- yd: an NPC / object height is real - the same floor
local CLOSE_REACH = 1.5       -- yd: after a refused interact
local CHAIN_WP = 12           -- yd: standing on a route point = it is done
local STALL_AFTER, STALL_MAX, STALL_GAIN = 30.0, 3, 2.0
local BLACK_FOR = 1800        -- s an NPC that never answered is left alone
-- 1.0.14: 50 yd of the path ahead (about 7 s of running) - the threat check
local PATH_AHEAD, PATH_GAP = 50, 0.5
local IS_AVOID_SAID = {}       -- 1.2.0: "walked round" logged once per mob

local W = {
    move = 1, force_path = false, last_x = nil, last_y = nil, rt_t = 0,
    still = { x = nil, y = nil, t = 0, seen = 0, S = 6.0, YD = 2.0 },
    flip = { last = nil, prev = nil, t = 0, n = 0, lock = nil, lock_until = 0 },
    path_t = -1e9, giver_walk = nil, close_in = false, black = {}, unreach = {},
    stall = { t = 0, seen = 0, best = nil, reach = false, seq = nil, recoveries = 0 },
}
quest._W = W

local function walk_reset()
    W.move, W.force_path, W.giver_walk, W.close_in = 1, false, nil, false
    W.stall.t, W.stall.seen, W.stall.best, W.stall.reach, W.stall.seq, W.stall.recoveries = 0, 0, nil, false, nil, 0
end

--- Standing within `yards` of `pos`, flat; `exact` (an NPC) needs the same
--- floor; a guide point's height is a terrain estimate (ARRIVE_DZ).
local function near(pos, yards, exact)
    local me = safe(function() return izi.me():get_position() end)
    if not me or not pos then return false end
    local d = geometry.distance_flat(me, pos)
    if type(d) ~= "number" or d > yards then return false end
    if exact and type(me.z) == "number" and type(pos.z) == "number" then
        return math.abs(me.z - pos.z) <= EXACT_DZ
    end
    if type(me.z) ~= "number" or type(pos.z) ~= "number" or math.abs(me.z - pos.z) <= ARRIVE_DZ then return true end
    return not movement.is_moving()
end

--- Walk toward `pos`. A guide point (`key`) is ONE waypoint walk per key
--- (movement.waypoint_walk: find_path + follow_path, rechecked every 5 s);
--- anything else (an NPC) is the exact server path (movement.guide_to), one
--- retarget (nudge) when it moves. True while walking.
local path_threat
local function walk_to(pos, label, arrive, exact, key)
    arrive = arrive or ARRIVE
    if near(pos, arrive, exact) then return false end
    if path_threat and path_threat(izi.me(), true) then return true end
    if key then
        if movement.is_quiet() or movement.in_combat_movement() then
            note("Nav settle")
            return true
        end
        if W.force_path then
            W.force_path = false
            movement.nav_stop()
        end
        note("Guide: " .. label)
        g.in_travel = true
        movement.waypoint_walk(pos, key)
        return true
    end
    if arrive >= TALK_ARRIVE then
        local me = safe(function() return izi.me():get_position() end)
        local d = me and geometry.distance_flat(me, pos)
        if type(d) == "number" and d <= TALK_ARRIVE
            and not (exact and type(me.z) == "number" and type(pos.z) == "number" and math.abs(me.z - pos.z) > EXACT_DZ) then
            return false
        end
    end
    if W.force_path then
        W.force_path = false
        movement.nav_stop()
        W.last_x, W.last_y = nil, nil
    end
    local wx, wy = math.floor(pos.x), math.floor(pos.y)
    local moved = wx ~= W.last_x or wy ~= W.last_y
    if moved then
        W.last_x, W.last_y = wx, wy
        local me = safe(function() return izi.me():get_position() end)
        trail("walk", "to (%.0f, %.0f, %.0f) %.0fy away for %s", pos.x, pos.y, pos.z or 0,
            me and geometry.distance(me, pos) or -1, tostring(label))
    end
    if movement.is_blocked(pos) or movement.last_fail_offmesh() then
        movement.clear_fail()
        local me = safe(function() return izi.me():get_position() end)
        local d = me and geometry.distance_flat(me, pos)
        if type(d) == "number" and d <= TALK_SEARCH then return false end
        note("Guide: cannot reach " .. label)
        return true
    end
    if movement.is_quiet() or movement.in_combat_movement() then
        note("Nav settle")
        return true
    end
    note("Guide: " .. label)
    g.in_travel = true
    if type(movement.keep_path) == "function" then movement.keep_path(true) end
    if type(movement.set_approach) == "function" then
        local k = g.cur_kind
        -- Exact destinations here come from a visible interaction target,
        -- including vendors serving collect/buy goals on another floor.
        movement.set_approach((exact or k == "accept" or k == "turnin") and "npc" or ((k == "kill" or k == "complete") and "enemy" or nil))
    end
    if exact then
        movement.nav_to(pos, true, "npc")
    elseif movement.is_moving() then
        if moved and type(movement.nudge) == "function" then movement.nudge(pos) end
    elseif type(movement.guide_to) == "function" then
        movement.guide_to(pos)
    else
        movement.nav_to(pos, true)
    end
    return true
end

local function wp_key(goal, pos)
    return string.format("%d|%d|%s|%.0f|%.0f", guide.step_num(), goal.index or 0, tostring(goal.sticky or 0), pos.x, pos.y)
end

--- NEXT-WAYPOINT HINT for a walk to RestedXP's live arrow: the arrow only moves
--- on once the player has reached it, so the point after it is read from the
--- step's own waypoint list (the entry at the arrow, then the one after it).
--- Nothing is hinted when the arrow is the last point or not in the list.
local function hint_after_arrow(goal, pos)
    if type(movement.hint_next) ~= "function" or type(guide.raw_step_waypoints) ~= "function" then return end
    local num = goal.sticky_step or guide.step_num()
    local list = {}
    for _, wp in ipairs(guide.raw_step_waypoints() or {}) do
        if tonumber(wp.goal_num) == num then
            local p = guide.to_world(wp)
            if p then list[#list + 1] = p end
        end
    end
    for i = 1, #list - 1 do
        local d = geometry.distance_flat(list[i], pos)
        if type(d) == "number" and d <= 3 then
            local nxt = list[i + 1]
            if geometry.distance_flat(nxt, pos) < 3 or movement.is_blocked(nxt) then return end
            local ok_dz, dz = pcall(require, "deathzones")
            if ok_dz and type(dz) == "table" and type(dz.zone_at_pos) == "function" and dz.zone_at_pos(nxt) then return end
            pcall(movement.hint_next, nxt, wp_key(goal, nxt))
            return
        end
    end
end

local function next_wp(n)
    W.move = W.move + 1
    if W.move > n then W.move = 1 end
end

--- Standing still on a walk (indoors only - outdoors the movement layer's
--- unstick ladder owns it): a fresh path, and the next route point.
local function watch_still(pts, must_do, label)
    local now = izi.now()
    local me = safe(function() return izi.me():get_position() end)
    local w = W.still
    if not me then return end
    if not w.x or (now - w.seen) > 2.0 or geometry.distance_flat(me, { x = w.x, y = w.y, z = me.z }) > w.YD then
        w.x, w.y, w.t = me.x, me.y, now
    end
    w.seen = now
    local inside=safe(function() return izi.me():is_indoors() end)==true
    local target = pts[math.min(W.move, #pts)].pos
    local d = geometry.distance_flat(me, target)
    if type(d) ~= "number" or d <= (must_do and TALK_ARRIVE or ARRIVE) + 2 then
        w.t = now
        return
    end
    if not inside then
        if now-w.t<12 then return end
        if type(movement.recovery_pending)=="function" and movement.recovery_pending() then return end
        if w.goal~=g.key then w.goal,w.recoveries=g.key,0 end
        w.t=now
        w.recoveries=(w.recoveries or 0)+1
        local accepted=type(movement.recover_path)=="function" and movement.recover_path(
            {x=target.x,y=target.y,z=target.z,mode="guide"},w.recoveries%2==1 and 1 or -1,
            "quest progress watchdog",w.recoveries+2)
        trail("route","outdoor quest stalled: prechecked detour attempt %d, accepted=%s, %.0f yd to %s",w.recoveries,tostring(accepted),d,tostring(label))
        return
    end
    if (now - w.t) < w.S then return end
    w.t = now
    trail("route", "no movement for %.0f s toward point %d of %d (%.0f yd) for %s - fresh path%s", w.S, W.move, #pts, d,
        tostring(label), (#pts > 1 and not must_do) and ", next point" or "")
    movement.clear_fail()
    W.force_path = true
    if #pts > 1 and not must_do then next_wp(#pts) end
end

--- A hostile mob whose threat range the walk runs into (targeting.path_threats
--- on the path ahead or within 45 yd, level difference -2 .. +2): killed first.
path_threat = function(player, starting_travel, earning)
    if type(targeting.path_threats) ~= "function" or type(movement.path_ahead) ~= "function" then return false end
    if not player then return false end
    if not starting_travel and not (type(movement.is_navigating) == "function" and movement.is_navigating()) then return false end
    if healing and type(healing.is_resting) == "function" and healing.is_resting() then return false end
    if safe(function() return player:is_in_combat() end) == true then return false end
    -- Loot completion can reach this branch before rest has started. Do not
    -- chain optional pulls on depleted health; fight_back owns self-defense.
    local health = safe(function() return player:get_health_percentage() end)
    if type(movement.npc_holding) == "function" and movement.npc_holding() then return false end
    local now = izi.now()
    if now - W.path_t < PATH_GAP then return false end
    W.path_t = now
    local ok_vendor, vendor = pcall(require, "vendor")
    -- 1.2.0: mobs 3+ levels above the player and elites on the path ahead are
    -- not pulled: each gets a Sentinel avoidance zone of its aggro range (+6
    -- yd) and the walk is re-planned round it (soft, no stop) - once per mob
    -- while its zone stands (movement/nav AV)
    local ahead = movement.path_ahead(PATH_AHEAD)
    if type(ahead) ~= "table" or #ahead == 0 then
        local pp = safe(function() return player:get_position() end)
        ahead = pp and { pp } or {}
    end
    if type(targeting.path_dangers) == "function" and type(movement.avoid_area) == "function" then
        local dangers = targeting.path_dangers(player, ahead) or {}
        for i = 1, #dangers do
            local d = dangers[i]
            local nm = tostring(safe(function() return d.unit:get_name() end))
            local why = string.format("%s (level %s%s), aggro %.0f yd", nm, tostring(d.level),
                d.elite and ", elite" or "", d.r)
            if movement.avoid_area({ x = d.x, y = d.y, z = d.z }, d.r + 6, why) and not IS_AVOID_SAID[nm .. d.x] then
                IS_AVOID_SAID[nm .. d.x] = true
                trail("act", "%s is on the path: walked round (Sentinel avoidance zone)", why)
            end
        end
    end
    -- Avoidance still runs during recovery trips and at low health. These
    -- guards suppress optional fights, not the scan that keeps travel safe.
    if state.vendor and state.vendor.active and (state.vendor.reason == "supplies" or state.vendor.reason == "repair") then return false end
    if type(health) ~= "number" or health < 80 then return false end
    if not earning and ok_vendor and type(vendor.needs_gear_recovery) == "function"
        and safe(vendor.needs_gear_recovery) == true then return false end
    local list = targeting.path_threats(player, ahead)
    local u
    for _, candidate in ipairs(list or {}) do
        local candidate_level = safe(function() return candidate:get_level() end)
        local player_level = safe(function() return player:get_level() end)
        local manageable = not earning or (type(candidate_level) == "number" and type(player_level) == "number" and candidate_level <= player_level)
        -- Optional travel combat must be a single pull. Allowing two nearby
        -- enemies caused a fatal wolf pack pull during live waypoint travel.
        -- Already engaged enemies remain handled by self-defense.
        if manageable and not (type(movement.fled_recently)=="function" and movement.fled_recently(candidate))
            and (type(targeting.travel_pull_safe) ~= "function" or targeting.travel_pull_safe(player, candidate, 1)) then
            u = candidate
            break
        end
    end
    if not u then return false end
    local ml, pl = safe(function() return u:get_level() end), safe(function() return player:get_level() end)
    trail("act", "%s (level %s, diff %s) - nearby or threatening the path: kill it first",
        tostring(safe(function() return u:get_name() end)), tostring(ml),
        (type(ml) == "number" and type(pl) == "number") and string.format("%+d", ml - pl) or "?")
    targeting.combat_active()
    engage(player, u, "Guide: clearing the path")
    return true
end
quest.path_threat = path_threat

function quest.earn_tick(player)
    if not player or not gui.is_on("use_quest") then return false end
    local hp = safe(function() return player:get_health_percentage() end)
    if type(hp) ~= "number" or hp < 70 then return false end
    if safe(function() return player:is_casting_spell() or player:is_channelling_spell() or player:is_dead_or_ghost() end) == true then return false end
    local ok, vendor = pcall(require, "vendor")
    if not ok or type(vendor.income_needed) ~= "function" then return false end
    local needed, budget, available = vendor.income_needed(player)
    if not needed then return false end
    if state.vendor and (state.vendor.active or state.vendor.returning) then return false end
    if state.target.unit and state.target.kind == "kill" then return false end -- normal combat owns existing targets
    if path_threat(player, true, true) then
        note(string.format("Earning for supplies / repairs / training (%d/%d copper including sellable loot)", available, budget))
        return true
    end
    return false
end

--- 1.0.14: the same check on the walks the quest engine does not run - a
--- vendor trip and the walk back (main.lua, before vendor.tick): a kill under
--- way is carried on, else a mob whose threat range the walk runs into is
--- engaged.
function quest.path_clear(player)
    if not player then return false end
    local unit = state.target.unit
    if unit and state.target.kind == "kill" and safe(function() return unit:is_dead() end) ~= true
        and fight_unit(player, unit, "Guide: clearing the path") then
        targeting.combat_active()
        return true
    end
    return path_threat(player)
end

--- Walk a kill / complete goal's route: the step's waypoints in order (one
--- walked at a time, the next once there), resumed at the nearest after a
--- fight. True while walking / handled.
local function walk_route(player, goal, pts, label)
    if #pts == 0 then return false end
    if W.move > #pts then W.move = 1 end
    local now = izi.now()
    -- back on the route after a fight / loot / rest: the nearest point
    if #pts > 1 and now - W.rt_t > 1.0 then
        local me = safe(function() return izi.me():get_position() end)
        if me then
            local best, best_d = W.move, nil
            for i = 1, #pts do
                local d = geometry.distance_flat(me, pts[i].pos)
                if type(d) == "number" and (not best_d or d < best_d) then best, best_d = i, d end
            end
            if best_d and best_d <= CHAIN_WP then best = best % #pts + 1 end
            if best ~= W.move then
                trail("route", "resume at point %d of %d (%.0f yd) for %s", best, #pts, best_d or -1, tostring(label))
            end
            W.move = best
        end
    end
    W.rt_t = now
    -- reachability: a point the nav client reports unreachable is skipped;
    -- every one unreachable - the walk itself is tried (the answers were for
    -- guessed heights) for 180 s, then the goal is set aside
    if type(movement.reachable) == "function" then
        local tried = 0
        while tried < #pts and movement.reachable(pts[W.move].pos) == false do
            next_wp(#pts)
            tried = tried + 1
        end
        if tried >= #pts then
            local key = tostring(guide.step_num()) .. "|" .. tostring(goal.index)
            W.unreach[key] = W.unreach[key] or now
            if (now - W.unreach[key]) < 180 then
                if type(movement.reach_forget) == "function" then
                    for i = 1, #pts do pcall(movement.reach_forget, pts[i].pos) end
                end
            else
                W.unreach[key] = nil
                trail("quest", "every waypoint of %s is unreachable - set aside", tostring(label))
                guide.defer(goal, 60, "every waypoint unreachable")
                return true
            end
        end
    end
    -- death zones: route points in an area the player died in repeatedly are skipped
    do
        local ok_dz, dz = pcall(require, "deathzones")
        if ok_dz and type(dz) == "table" and type(dz.zone_at_pos) == "function" then
            local tried = 0
            while tried < #pts and dz.zone_at_pos(pts[W.move].pos) do
                next_wp(#pts)
                tried = tried + 1
            end
            if tried >= #pts then
                local zn = dz.zone_at_pos(pts[W.move].pos)
                note(string.format("Guide: avoiding the %s area (died there %d times)", tostring(zn and zn.name or "?"),
                    zn and zn.deaths or 3))
                return true
            end
        end
    end
    -- a route point the path could not reach: the next one
    if #pts > 1 then
        local why = movement.last_fail_reason()
        if movement.is_blocked(pts[W.move].pos) or why then
            movement.clear_fail()
            trail("route", "point %d of %d unreachable (%s) - next point", W.move, #pts, tostring(why or "blocked"))
            next_wp(#pts)
        end
    end
    -- flip-flop guard: three swaps back and forth within 4 s hold a point 10 s
    do
        local fl = W.flip
        if fl.lock and now < fl.lock_until and fl.lock <= #pts then
            W.move = fl.lock
        elseif W.move ~= fl.last then
            if W.move == fl.prev and (now - fl.t) < 4 then fl.n = fl.n + 1 else fl.n = 0 end
            fl.prev, fl.last, fl.t = fl.last, W.move, now
            if fl.n >= 3 then
                fl.lock, fl.lock_until, fl.n = W.move, now + 10, 0
                trail("route", "points %s / %d flip-flopping - holding point %d for 10 s", tostring(fl.prev), W.move, W.move)
            end
        end
    end
    local function key(i)
        local p = pts[i] and pts[i].pos
        return string.format("%s|%s|%d|%d|%d", tostring(guide.step_num()), tostring(goal.index), i,
            math.floor((p and p.x) or 0), math.floor((p and p.y) or 0))
    end
    -- NEXT-WAYPOINT HINT: tell the movement layer which point follows this one
    -- (the one the loop below would pick) so its floors / path are prepared
    -- ahead and the walk rolls on without a stop. Points this loop would skip
    -- (blocked, unreachable, a death area) are never hinted.
    if #pts > 1 and type(movement.hint_next) == "function" then
        local nx = W.move % #pts + 1
        local np = pts[nx] and pts[nx].pos
        if np and nx ~= W.move and not movement.is_blocked(np)
            and not (type(movement.reachable) == "function" and movement.reachable(np) == false) then
            local ok_dz, dz = pcall(require, "deathzones")
            if not (ok_dz and type(dz) == "table" and type(dz.zone_at_pos) == "function" and dz.zone_at_pos(np)) then
                pcall(movement.hint_next, np, key(nx))
            end
        end
    end
    if walk_to(pts[W.move].pos, label, ARRIVE, pts[W.move].floor_verified, key(W.move)) then
        watch_still(pts, false, label)
        return true
    end
    if #pts > 1 then
        next_wp(#pts)
        walk_to(pts[W.move].pos, label, ARRIVE, pts[W.move].floor_verified, key(W.move))
        return true
    end
    return false
end

-- NO-PROGRESS LADDER for an NPC goal (Zygor 2.134.0 / 2.297.0): no yard
-- gained on the NPC (or the waypoint), no dialog stage, for STALL_AFTER s ->
-- frames closed, the guide read again, a fresh path; the 3rd time the NPC is
-- left alone for BLACK_FOR s and the goal set aside.
local function stalled(now, d)
    local st = W.stall
    if (now - st.seen) > 1.0 then st.t = now end       -- fights / rests are not this goal's time
    st.seen = now
    local moved = false
    if type(d) == "number" then
        local was_far = st.best == nil or st.best > TALK_ARRIVE
        if st.best == nil or d < st.best - STALL_GAIN then
            if was_far or d <= TALK_REACH then
                st.best = d
                moved = true
            elseif d < st.best then
                st.best = d
            end
        end
        local in_reach = d <= TALK_REACH
        if in_reach and not st.reach then moved = true end
        st.reach = in_reach
    end
    local ns = type(npc.progress_seq) == "function" and npc.progress_seq() or nil
    if ns ~= st.seq then
        st.seq = ns
        moved = true
    end
    if moved then
        st.t = now
        return false
    end
    return (now - st.t) >= STALL_AFTER
end

local function recover_stall(now, goal, label, unit)
    local st = W.stall
    local reached = st.reach == true
    st.recoveries = st.recoveries + 1
    trail("act", "%s: no progress for %.0f s - recovery %d of %d", tostring(label), STALL_AFTER, st.recoveries, STALL_MAX)
    npc.close()
    movement.nav_stop()
    guide.invalidate()
    W.giver_walk, W.close_in, W.force_path = nil, false, true
    st.t, st.best, st.reach = now, nil, false
    if st.recoveries >= STALL_MAX then
        st.recoveries = 0
        local gu = unit and safe(function() return unit:get_guid() end)
        if gu and reached then
            W.black[gu] = now + BLACK_FOR
            trail("act", "%s: %s never answered - left alone for %d min", tostring(label),
                tostring(safe(function() return unit:get_name() end)), BLACK_FOR / 60)
        end
        guide.defer(goal, 60, "no progress after " .. STALL_MAX .. " recoveries")
        return true
    end
    return false
end

--- The guids not to talk to on this goal: tried ones and blacklisted ones.
local function excluded()
    local now, set = izi.now(), {}
    for k, v in pairs(g.tried) do set[k] = v end
    for k, t in pairs(W.black) do
        if t > now then set[k] = true else W.black[k] = nil end
    end
    return set
end

-- ----------------------------------------------------------------------------
-- HANDLERS
-- ----------------------------------------------------------------------------
local function label_of(goal)
    return tostring(goal.text or (goal.kind .. " " .. tostring(goal.quest_id or "")))
end

--- kill / complete: fight the closest wanted unit; else walk the step's
--- route (1.0.7, Zygor style), else the arrow / the guides' point.
local try_skip
local function fight_goal(player, goal, label, recovery_route)
    local now = izi.now()
    local pts = recovery_route or guide.step_route(goal)
    local wp = nil
    if #pts == 0 then
        wp = guide.goal_waypoint(goal, goal.kind == "complete")       -- 1.0.3
        -- 1.0.5: no waypoint: the Forever guides' .goto of this quest's .complete step
        if not wp and rxpdata and goal.quest_id then
            local p = rxpdata.quest_point("complete", goal.quest_id)
            local pos = p and guide.point_world(p) or nil
            if pos then wp = { pos = pos } end
        end
        if wp then pts = { wp } end
    end
    local at_wp = #pts == 0
    for i = 1, #pts do if near(pts[i].pos, 30) then at_wp = true end end
    if now >= g.scan_until then
        g.scan_until = now + SCAN_GAP
        local unit, d, unsafe_pull, unsafe_elite = guide.find_mob(player, at_wp and MOB_RANGE or NEAR_SCAN, goal)
        g.unsafe_quest_pull = unsafe_pull and not unit
        g.unsafe_quest_elite = unsafe_elite and not unit
        if unit then
            trail("act", "closest %s at %.0f yd for %s", tostring(safe(function() return unit:get_name() end)), d or -1, label)
            engage(player, unit, "Guide: " .. label)
            return
        end
    end
    if g.unsafe_quest_pull then
        movement.nav_stop()
        if g.unsafe_quest_elite and not goal.sticky then
            try_skip("unsafe elite target; quest remains unfinished")
            return
        end
        note("Guide: " .. label .. " - waiting for a safe target; elite or nearby pack is unsafe")
        return
    end
    if #pts == 0 then
        local why = guide.waypoint_refusal() or "no waypoint"
        movement.nav_stop()
        note(string.format("Guide: %s - no walkable waypoint (%s)", label, why))
        return
    end
    if walk_route(player, goal, pts, label) then return end
    note("Guide: " .. label .. " - at the waypoint, looking for targets")
end

local function log_title(quest_id)
    local n = tonumber(safe(function() return core.quests.get_num_quest_log_entries() end)) or 0
    for i = 1, math.min(n, 80) do
        local e = safe(function() return core.quests.get_quest_log_title(i) end)
        if type(e) == "table" and e.is_header ~= true and tonumber(e.quest_id) == quest_id
            and type(e.title) == "string" and e.title ~= "" then
            return e.title
        end
    end
    return nil
end

--- The quest a turn-in goal is about: quest_id, else the first of ids not
--- handed in yet.
local function turnin_quest(goal)
    if goal.quest_id and not npc.was_turned_in(goal.quest_id) then return goal.quest_id end
    for _, id in ipairs(goal.ids or {}) do
        if not npc.was_turned_in(id) then return id end
    end
    return goal.quest_id
end

--- 1.0.4: the quest an accept goal is about: quest_id, else the first of ids
--- not in the quest log yet.
local function accept_quest(goal)
    local function on(id) return safe(function() return core.quests.is_on_quest(id) end) == true end
    if goal.quest_id and not on(goal.quest_id) then return goal.quest_id end
    for _, id in ipairs(goal.ids or {}) do
        if not on(id) then return id end
    end
    return goal.quest_id
end

--- The title the NPC's frames list: the quest log's (a turn-in), else the
--- goal's text without its "Accept " / "Turn in " verb.
local function frame_title(goal, qid, kind)
    local t = kind == "turnin" and log_title(qid) or nil
    if t then return t end
    local txt = type(goal.text) == "string" and goal.text or nil
    if txt then
        txt = txt:gsub("^[Aa]ccept%s+", ""):gsub("^[Tt]urn in%s+", "")
        if txt ~= "" then return txt end
    end
    return nil
end

local DEFER_S = 60             -- s a turn-in no NPC here takes is set aside

--- Set the goal aside (never a pause): the next goal / sticky / skip goes on.
local function defer(goal, label, why)
    trail("quest", "%s (quest %s): %s - set aside %ds, moving on", label, tostring(goal.quest_id), why, DEFER_S)
    note(string.format("Guide: %s - %s, moving on", label, why))
    movement.nav_stop()
    guide.defer(goal, DEFER_S, why)
end

-- 1.0.1 (user): a turn-in never pauses. The NPC is the waypoint title's (the
-- documented name source); with no title, the quest givers (npc flag 0x2) at
-- the waypoint are tried in turn - the dialog says whether the quest is there
-- (npc.turn_in: done / not_offered / not_ready). Nobody takes it: deferred.
-- 1.0.4 (user): an ACCEPT goal uses the same NPC lookup and the same flow
-- (npc.accept: done / not_offered / gave_up / skipped / bags_full).
-- 1.0.8 (log 17:47, step 8 ".collect 247834,1,91741 / .use 247834 / .accept
-- 91741"): a quest STARTED BY AN ITEM is accepted from the item - used from
-- the bags (bags.use_id), then Accept on its quest panel once that panel is
-- this quest (npc.open_panel). One action per tick.
local ITEM_ACCEPT_GAP = 3.0
local function item_accept(goal, qid, label, now)
    local item = rxpdata and rxpdata.accept_item(qid) or nil
    if not item then return quest.bag_start(goal, qid, label) end
    local okb, bags = pcall(require, "bags")
    if not okb or type(bags) ~= "table" then return false end
    if (bags.count(item) or 0) <= 0 then
        defer(goal, label, "the item that starts it (" .. tostring(item) .. ") is not in the bags")
        return true
    end
    movement.nav_stop()
    g.in_dialog = true
    local panel = type(npc.open_panel) == "function" and npc.open_panel() or nil
    if panel and tonumber(panel.quest_id) == qid then
        pcall(function() core.quests.accept_quest() end)
        trail("quest", "accept %s (quest %d) from item %d", label, qid, item)
        note("Guide: accepting " .. label)
        guide.invalidate()
        return true
    end
    if (now - (g.item_used_t or -1e9)) >= ITEM_ACCEPT_GAP then
        g.item_used_t = now
        bags.use_id(item)
        trail("quest", "%s: using item %d to start quest %d", label, item, qid)
    end
    note("Guide: " .. label .. " - using the item that starts it")
    return true
end

-- 1.13.0 (user: "completes the steps that require using items from inventory
-- for completing quest tasks OR starting quests"): no guide data names the
-- item that starts the quest - with a ".use" goal in the step (or a step item
-- in the bags) the quest is started from the bags (quest/bagstart: the step's
-- items first, then any quest item with no use spell) and its panel accepted.
-- nil from bagstart (nothing left to try): the NPC lookup carries on.
function quest.bag_start(goal, qid, label)
    local okb, bs = pcall(require, "quest/bagstart")
    if not okb or type(bs) ~= "table" or type(guide.step_item_ids) ~= "function" then return false end
    local step = guide.step()
    local uses = false
    for _, gl in ipairs((step or {}).goals or {}) do
        if guide.classify(gl) == "item" then uses = true break end
    end
    local prefer = guide.step_item_ids(step)
    local own = false
    for i = 1, #prefer do if bs.has(prefer[i]) then own = true break end end
    if not uses and not own then return false end
    local r = bs.start(qid, prefer)
    if r == "accepted" then
        guide.invalidate()
        note("Guide: " .. label .. " - accepted from the item")
        return true
    end
    if r == "using" then
        movement.nav_stop()
        g.in_dialog = true
        note("Guide: " .. label .. " - starting it from the item")
        return true
    end
    return false
end

-- 1.13.0: ".use <item>" - the item is used from the bags at the goal's
-- waypoint (30 yd), on the current target when there is a live one. A panel
-- it opens for a quest the step accepts is accepted. quest.USE_MAX uses with
-- the goal still open: set aside (the step's next goal goes on).
quest.USE_MAX, quest.USE_GAP = 6, 1.6
function quest.item_goal(player, goal, label)
    local okb, bs = pcall(require, "quest/bagstart")
    if okb and type(bs) == "table" and bs.accept_open(guide.step_open_accepts()) then
        guide.invalidate()
        note("Guide: " .. label .. " - quest accepted")
        return
    end
    local item = guide.item_for(goal)
    if not item then return end
    local wp = guide.goal_waypoint(goal, false)
    if wp and wp.pos and not near(wp.pos, 30) then
        if walk_route(player, goal, { wp }, label) then return end
    end
    if safe(function() return player:is_channeling_or_casting() end) == true then
        note("Guide: use " .. label)
        return
    end
    local now = izi.now()
    if now - (g.use_t or -1e9) < quest.USE_GAP then return end
    g.use_n = g.use_n or {}
    local key = string.format("%d|%d|%d", guide.step_num() or 0, goal.index or 0, item)
    if (g.use_n[key] or 0) >= quest.USE_MAX then
        g.use_n[key] = nil
        defer(goal, label, "item " .. item .. " used " .. quest.USE_MAX .. " times, the goal still open")
        return
    end
    movement.nav_stop()
    g.use_t = now
    local on = state.target.unit
    if on and (safe(function() return on:is_valid() end) ~= true or safe(function() return on:is_dead() end) == true) then
        on = nil
    end
    local ok
    if on then
        ok = safe(function() return core.input.use_item_target(item, on) end)
    else
        ok = safe(function() return core.input.use_item(item) end)
    end
    g.use_n[key] = (g.use_n[key] or 0) + 1
    trail("act", "use item %d for %s (use %d)%s", item, label, g.use_n[key], ok == false and " - refused" or "")
    note("Guide: use " .. label)
end

-- Collect goals accompanied by an explicit Buy instruction are vendor tasks.
-- Buy one unit at a time and wait for the bag count, since vendor lots differ.
local purchase = {}
function quest.buy_goal(player, goal, label)
    if goal.sticky_step and goal.sticky_step ~= guide.step_num() then return false end
    local buy = false
    for _, line in ipairs(type(guide.goals) == "function" and guide.goals() or {}) do
        if type(line.text) == "string" and line.text:lower():match("^buy%s") then buy = true break end
    end
    if not buy then return false end
    local name = guide.talk_to_name(goal)
    local item, need = guide.collect_item(goal)
    local item_name = type(goal.text) == "string" and goal.text:match("^(.-):%s*%d+%s*/%s*%d+") or nil
    if not name or (not item and not item_name) then
        note("Guide: purchase needs an identifiable NPC and item")
        return true
    end
    local key = tostring(guide.step_num()) .. ":" .. tostring(goal.index)
    if purchase.key ~= key then purchase = { key = key, tries = 0, next = 0 } end
    local now = izi.now()
    local wp = guide.goal_waypoint(goal)
    local unit = guide.find_named_npc(player, name, 200, nil)
    if not unit or safe(function() return unit:is_valid() end) ~= true then
        if wp and wp.pos then walk_to(wp.pos, "to " .. name, TALK_ARRIVE) end
        note("Guide: looking for vendor " .. name)
        return true
    end
    local pos = safe(function() return unit:get_position() end)
    local me = safe(function() return player:get_position() end)
    if not pos or not me then return true end
    if geometry.distance(me, pos) > TALK_REACH then
        walk_to(pos, "to " .. name, TALK_REACH - 1, true)
        return true
    end
    movement.nav_stop()
    g.in_dialog = true
    if now < purchase.next then return true end
    local target = safe(function() return player:get_target() end)
    local correct = target and safe(function() return target:is_valid() end) == true
        and safe(function() return target:get_guid() end) == safe(function() return unit:get_guid() end)
    local count = tonumber(safe(function() return core.game_ui.get_vendor_item_count() end)) or 0
    if not correct or count == 0 then
        purchase.next = now + 1.5
        if correct then
            local ok, gossip = pcall(require, "gossip")
            if ok and gossip.select({ icon = "VENDOR", type = "vendor", words = { "browse", "goods" } }) then return true end
        end
        if count > 0 then pcall(function() core.input.close_merchant() end) end
        targeting.ensure_target(player, unit)
        movement.interact(unit)
        trail("quest", "purchase: opening %s for %s", name, item_name or tostring(item))
        return true
    end
    for index = 1, math.min(count, 200) do
        local row = safe(function() return core.game_ui.get_vendor_item_info(index) end)
        if type(row) == "table" and ((item and row.item_id == item) or (not item and row.item_name == item_name)) then
            local bags = require("bags")
            local id = tonumber(row.item_id)
            local have = id and bags.count(id)
            if not id or id <= 0 or type(have) ~= "number" then
                note("Guide: vendor item or bag count unavailable")
                return true
            end
            if have >= need then
                pcall(function() core.input.close_merchant() end)
                guide.invalidate()
                note("Guide: purchase complete - " .. (item_name or tostring(item)))
                return true
            end
            if purchase.have and have > purchase.have then purchase.tries = 0 end
            if purchase.tries >= 3 then
                note("Guide: purchase not confirmed - " .. (item_name or tostring(item)))
                return true
            end
            local gold = tonumber(safe(function() return core.inventory.get_gold() end))
            if row.is_usable == false or type(row.cost) ~= "number" or not gold or gold < row.cost then
                note("Guide: cannot afford or use " .. (item_name or tostring(item)))
                return true
            end
            purchase.have, purchase.tries, purchase.next = have, purchase.tries + 1, now + 2
            pcall(function() core.input.buy_item(index, 1) end)
            bags.invalidate()
            trail("quest", "purchase: %s at %s, slot %d, have %d/%d, attempt %d", row.item_name, name, index, have, need, purchase.tries)
            return true
        end
    end
    note("Guide: " .. name .. " does not stock " .. (item_name or tostring(item)))
    return true
end

local function npc_goal(player, goal, label, kind)
    local qid = (kind == "accept") and accept_quest(goal) or turnin_quest(goal)
    if not qid then return defer(goal, label, "the goal names no quest id") end
    if kind == "turnin" then
        local rows = safe(function() return core.quests.get_quest_objectives(qid) end)
        for index, objective in ipairs(type(rows) == "table" and rows or {}) do
            if objective.finished ~= true and type(objective.required) == "number"
                and type(objective.fulfilled) == "number" and objective.fulfilled < objective.required then
                npc.close()
                g.in_dialog = false
                local best, best_route, best_d
                local me = safe(function() return player:get_position() end)
                local sources = rxpdata and type(rxpdata.quest_rows) == "function" and rxpdata.quest_rows("complete", qid) or {}
                for _, row in ipairs(sources) do
                    if row.objective == index and not row.pick and #(row.mobs or {}) > 0 then
                        local route = {}
                        for _, point in ipairs(row.gotos or {}) do
                            local pos = guide.point_world(point)
                            if pos then route[#route + 1] = {pos=pos} end
                        end
                        local d = me and route[1] and geometry.distance_flat(me, route[1].pos)
                        if d and (not best_d or d < best_d) then best, best_route, best_d = row, route, d end
                    end
                end
                local text = "Recover missing objective: " .. tostring(objective.text or label)
                if best then
                    fight_goal(player, {index=goal.index, action="mob", kind="kill", quest_id=qid, units=best.mobs}, text, best_route)
                else
                    local object_goal={index=goal.index, action="complete", kind="complete", quest_id=qid,
                        objective=index, text=objective.text}
                    if pickup and pickup.goal(player,object_goal,text,{
                        recovery=true,
                        rxpdata=rxpdata, guide=guide, walk_to=walk_to, note=note,
                        nav_stop=function() movement.nav_stop() end,
                        in_combat=safe(function() return player:is_in_combat() end)==true,
                    }) then return end
                    movement.nav_stop()
                    note(text .. " - no verified collection route")
                end
                return
            end
        end
    end
    local now = izi.now()
    if kind == "accept" and item_accept(goal, qid, label, now) then return end
    if now < g.hold_until then
        note(string.format("Guide: turn in %s - the NPC said not ready, waiting", label))
        return
    end
    -- RestedXP may keep a preceding travel-only sticky active to route us
    -- through a dirt path or entrance before the NPC step. Its live arrow
    -- is an approach, not a different quest giver's destination.
    local approach = not goal.recovery_npc and type(guide.step_route)=="function" and guide.step_route(goal) or {}
    local first = approach[1]
    if first and first.approach and first.pos then
        hint_after_arrow(goal, first.pos)
        if walk_to(first.pos, "following guide approach for " .. label, ARRIVE, nil, wp_key(goal,first.pos)) then
            watch_still({first},true,label)
            return
        end
    end
    local wp = goal.recovery_npc and {pos=goal.recovery_pos, title=goal.recovery_npc} or guide.goal_waypoint(goal)
    local center = wp and wp.pos or nil
    -- The current step's explicit NPC wins over a stale arrow title.
    local name = goal.recovery_npc or guide.talk_to_name(goal)
        or (wp and type(wp.title) == "string" and wp.title ~= "" and wp.title or nil)
    -- 1.0.5: the Forever guides' own .target line and .goto for this quest
    if rxpdata and (not name or not wp) then
        local gname, gpt = rxpdata.quest_npc(kind, qid)
        name = name or gname
        if not wp then
            local pos = gpt and guide.point_world(gpt) or nil
            if not pos then
                local p2 = rxpdata.quest_point(kind, qid)
                pos = p2 and guide.point_world(p2) or nil
            end
            if pos then
                wp = { pos = pos, title = name, own = false }
                center = pos
            end
        end
    end
    local ex = excluded()
    local unit = nil
    if name then unit = guide.find_named_npc(player, name, TALK_SEARCH, center, ex) end
    -- A stale guide waypoint must not hide the correctly named nearby NPC.
    if not unit and name then unit = guide.find_named_npc(player, name, 200, nil, ex) end
    -- 1.8.0: no NPC by that name - it may be an OBJECT that gives / takes the
    -- quest (the Scourge Cauldron for Target: Dalson's Tears), opened with
    -- use_object (movement.interact)
    if not unit and name and type(guide.find_named_object) == "function" then unit = guide.find_named_object(player, name, center and TALK_SEARCH or 100, center, ex) end
    if not unit and not name then unit = guide.nearest_quest_giver(player, center, TALK_SEARCH, ex) end
    -- Include height: climbing toward an upstairs NPC is real progress even
    -- when horizontal distance barely changes along the hillside or stairs.
    local me = safe(function() return player:get_position() end)
    local track_d = nil
    if unit then
        local up = safe(function() return unit:get_position() end)
        track_d = me and up and geometry.distance(me, up) or nil
    elseif wp then
        track_d = me and geometry.distance(me, wp.pos) or nil
    end
    if stalled(now, track_d) then
        recover_stall(now, goal, label, unit)
        return
    end
    if not unit then
        if wp then hint_after_arrow(goal, wp.pos) end
        if wp and walk_to(wp.pos, "to " .. (name or "the quest NPC") .. " (" .. label .. ")", TALK_ARRIVE, nil,
            wp_key(goal, wp.pos)) then
            watch_still({{pos=wp.pos}},false,label)
            return
        end
        -- A missing named NPC is not permission to try unrelated quest givers.
        if not name then unit = guide.nearest_quest_giver(player, nil, TALK_SEARCH, ex) end
        if not unit then
            trail("quest", "NPC lookup failed: quest %d, name [%s], waypoint [%s], player scan 200 yd", qid, tostring(name), tostring(wp and wp.title))
            if type(guide.dump_step) == "function" then
                for _, line in ipairs(guide.dump_step()) do trail("quest", "%s", line) end
            end
            return defer(goal, label, wp and "no NPC here takes it" or "no waypoint and no quest giver in sight")
        end
    end
    local uname = tostring(safe(function() return unit:get_name() end))
    -- an interact the NPC refused (out of range, a UI error): the next from closer
    if type(npc.take_refused) == "function" and npc.take_refused() and not W.close_in then
        W.close_in = true
        trail("act", "%s: %s refused the interaction - closing in", tostring(label), uname)
    end
    local reach = W.close_in and CLOSE_REACH or TALK_REACH
    -- 3D reach (an NPC one floor up is not in reach), the larger of the two reads
    local d = 99
    do
        local up = safe(function() return unit:get_position() end)
        local d3 = me and up and geometry.distance(me, up)
        if type(d3) == "number" then d = d3 end
        local dt = safe(function() return player:distance_to(unit) end)
        if type(dt) == "number" and dt > d then d = dt end
    end
    if d > reach then
        local p = safe(function() return unit:get_position() end)
        if p then
            -- re-route when the NPC is not where the walk heads (a patrol)
            if W.giver_walk == nil or geometry.distance(W.giver_walk, p) > 5 then
                W.giver_walk = { x = p.x, y = p.y, z = p.z, best = d, t = now }
                movement.nav_stop()
                trail("act", "%s: walking to %s (%.1f yd, via %s)", kind, uname, d, name and "its name" or "a quest giver")
            end
            if d < (W.giver_walk.best or 1e9) - 0.3 then W.giver_walk.best, W.giver_walk.t = d, now end
            walk_to(p, label, math.max(reach - 1.0, 1.5), true)
            watch_still({{pos=p}},false,label)
        end
        return
    end
    W.giver_walk = nil
    movement.nav_stop()
    g.in_dialog = true
    local title = frame_title(goal, qid, kind) or label
    if goal.recovery_npc then title = nil end -- identify the offered quest by ID, not objective text
    local r
    if kind == "accept" then
        r = npc.accept(player, qid, title, nil, unit)
    else
        r = npc.turn_in(player, qid, title, nil, unit, (goal.reward or 0) ~= 0 and goal.reward or nil)
    end
    local verb = kind == "accept" and "accept" or "turn in"
    if r == nil then
        note(string.format("Guide: %s %s at %s", kind == "accept" and "accepting" or "turning in", title, uname))
        return
    end
    trail("quest", "%s %s (quest %d) at %s: %s", verb, title, qid, uname, tostring(r))
    npc.close()
    -- 1.0.6: the dialog is over - the NPC walk hold (up to 10 s) ends now
    if type(movement.npc_release) == "function" then movement.npc_release() end
    guide.invalidate()
    if r == "skipped" then
        -- a grey quest npc.accept put in the skip bag: the goal is done for the bot
        return
    elseif r == "bags_full" then
        pcall(function()
            local v = require("vendor")
            if type(v) == "table" and type(v.request_loot_trip) == "function" then
                v.request_loot_trip(player)
            end
        end)
        return defer(goal, label, "bags full - the quest item does not fit")
    elseif r == "not_ready" then
        return defer(goal, label, "NPC reports quest not ready; recheck objectives before retry")
    elseif r ~= "done" then
        -- this NPC does not take it: the next candidate on the next tick
        local gu = safe(function() return unit:get_guid() end)
        if gu then g.tried[gu] = true end
    end
end

-- Recover an absent prerequisite only from the imported guide's exact giver.
-- Collection-before-accept steps are intentionally excluded.
function quest.recover_missing(player, goal, label)
    local qid = tonumber(goal.quest_id)
    if (goal.kind ~= "complete" and goal.kind ~= "turnin") or not qid or type(npc.in_log) ~= "function"
        or npc.in_log(qid) ~= false then
        if g.recover_qid then g.recover_qid=nil; npc.close(); walk_reset() end
        return false
    end
    if (type(guide.skipped)=="function" and guide.skipped(qid))
        or require("quest/done").done(qid) then return false end
    local name, point
    if rxpdata then name, point = rxpdata.quest_npc("accept", qid) end
    local pos = point and guide.point_world(point)
    if not name or not pos then return false end
    if g.recover_qid ~= qid then
        g.recover_qid=qid; walk_reset(); g.tried={}; g.hold_until=0
        if pickup then pickup.clear() end
        trail("quest", "recover missing quest %d: accept from %s before objective %s", qid, name, label)
    end
    local accept = {}
    for k,v in pairs(goal) do accept[k]=v end
    accept.kind, accept.action, accept.text = "accept", "accept", nil
    accept.recovery_npc, accept.recovery_pos = name, pos
    g.cur_kind="accept"
    npc_goal(player, accept, "missing quest " .. qid, "accept")
    return true
end

-- ----------------------------------------------------------------------------
-- SKIP
-- ----------------------------------------------------------------------------
local function log_unhandled(d)
    for _, u in ipairs(d.unhandled or {}) do
        local gl = u.goal
        local k = string.format("%d|%d|%s", guide.step_num(), gl.index or 0, tostring(gl.action))
        if not g.logged[k] then
            g.logged[k] = true
            g.unhandled[gl.action ~= "" and gl.action or "(empty)"] = true
            trail("quest", "UNHANDLED RestedXP goal step %d goal %d: action '%s' quest %s text '%s' - %s",
                guide.step_num(), gl.index or 0, tostring(gl.action), tostring(gl.quest_id), tostring(gl.text), u.why)
        end
    end
end

-- 1.0.3 (log 2026-10-20 17:05-17:10: step 3 skipped at 17:05:54, 17:06:13 and
-- 17:10:10 - RestedXP came back to it each time, its accept of quest 307
-- still open): a step RestedXP returns to after a skip is not skipped again
-- for SKIP_AGAIN s - the bot holds there and says what the step needs.
local SKIP_AGAIN = 600
local skipped_at = {}          -- step num -> time of the last skip
try_skip = function(why)
    local now = izi.now()
    local num = guide.step_num()
    if skipped_at[num] and (now - skipped_at[num]) < SKIP_AGAIN then
        movement.nav_stop()
        local k = "back|" .. num
        if not g.logged[k] then
            g.logged[k] = true
            trail("quest", "step %d came back after a skip - RestedXP needs it done (%s); not skipped again for %ds",
                num, why, SKIP_AGAIN)
        end
        note(string.format("Guide: step %d needs %s - RestedXP returns to it after a skip", num, why))
        return
    end
    if g.skip_step ~= num then g.skip_step, g.skip_since = num, now end
    if (now - g.skip_since) < SKIP_SETTLE or (now - g.skip_t) < SKIP_GAP then
        note(string.format("Guide: step %d - %s", num, why))
        return
    end
    g.skip_t = now
    movement.nav_stop()
    local moved = guide.skip_current()
    skipped_at[num] = now
    trail("quest", "skip_current_step on step %d (%s): %s", num, why, moved and "RestedXP moved on" or "refused")
    note(string.format("Guide: skipped step %d - %s", num, why))
end

-- ----------------------------------------------------------------------------
-- TICK
-- ----------------------------------------------------------------------------
local function tick_inner(player)
    g.in_dialog, g.in_travel = false, false
    if type(movement.keep_path) == "function" then movement.keep_path(false) end     -- 1.0.7: walk_to re-arms it
    -- a corpse to loot before the next pull (loot owns the walk)
    do
        local u = state.target.unit
        local live = u and state.target.kind == "kill" and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_dead() end) ~= true
        local attacked = type(targeting.attackers) == "function" and targeting.attackers(player) > 0
        -- 1.0.18: never while the player is in combat - fight_back owns the tick
        local fighting = safe(function() return player:is_in_combat() end) == true
        if not live and not attacked and not fighting and loot and type(loot.has_work) == "function"
            and loot.has_work(player) then
            if not g.loot_wait then
                g.loot_wait = true
                movement.nav_stop()
                movement.combat_release()
            end
            note("Guide: looting before the next pull")
            return
        end
        g.loot_wait = false
    end
    probe("q:fight_back")
    if fight_back(player) then return end
    -- 1.0.7 (Zygor style): a weak mob the walk runs into is killed first
    probe("q:path_threat")
    if path_threat(player) then return end
    if healing and type(healing.is_resting) == "function" and healing.is_resting() then
        movement.nav_stop()
        return
    end

    local d = guide.decision()
    if not d then return end
    if guide.step_num() ~= g.dumped and guide.step_num() > 0 then
        g.dumped = guide.step_num()
        for _, line in ipairs(guide.dump_step()) do trail("rxp", "%s", line) end
    end
    if d.state == "no_addon" then
        release_combat()
        note("RestedXP Guides is not loaded - enable the RestedXP addon (waiting)")
        return
    end
    if d.state == "no_step" then
        release_combat()
        note("RestedXP: no current step - pick a guide in RestedXP (waiting)")
        return
    end
    if d.state == "wait_requires" or d.state == "wait_level" or d.state == "wait_complete" or d.state == "wait_deferred" then
        movement.nav_stop()
        local k = "w|" .. guide.step_num() .. "|" .. d.state
        if not g.logged[k] then
            g.logged[k] = true
            trail("quest", "step %d: waiting - %s", guide.step_num(), tostring(d.why))
        end
        note("Guide: waiting - " .. tostring(d.why))
        return
    end
    if d.state == "inactive" then
        try_skip(d.why)
        return
    end
    if d.state == "skip" then
        log_unhandled(d)
        try_skip(d.why)
        return
    end

    local goal = d.goal
    local kind = goal.kind
    local label = label_of(goal)
    local key = string.format("%d|%d|%s|%s", guide.step_num(), goal.index or 0, tostring(goal.sticky or 0), kind)
    if key ~= g.key then
        if g.key and (g.cur_kind == "accept" or g.cur_kind == "turnin") then
            npc.close()
            if type(movement.npc_release) == "function" then movement.npc_release() end
        end
        g.key = key
        g.scan_until, g.kill_until, g.hold_until, g.tried = 0, 0, 0, {}
        g.unsafe_quest_pull, g.unsafe_quest_elite = false, false
        walk_reset()                                                    -- 1.0.7
        if safe(function() return player:is_in_combat() end) ~= true then state.reset_target() end
        trail("quest", "step %d goal %d%s: %s [%s] %s (quest %s)", guide.step_num(), goal.index or 0,
            goal.sticky and (" (sticky step " .. tostring(goal.sticky_step) .. ")") or "", goal.action, kind, label,
            tostring(goal.quest_id))
    end
    g.label = label
    g.cur_kind = kind
    probe("q:act " .. kind)
    if quest.recover_missing(player, goal, label) then return end
    -- 1.0.24: a ground pickup (the guide names the object: cRXP_PICK_) is
    -- walked to and used; any other complete / collect stays a fight
    if kind == "collect" and quest.buy_goal(player, goal, label) then return end
    if (kind == "complete" or kind == "collect") and pickup then
        local handled = pickup.goal(player, goal, label, {
            rxpdata = rxpdata, guide = guide, walk_to = walk_to, note = note,
            nav_stop = function() movement.nav_stop() end,
            in_combat = safe(function() return player:is_in_combat() end) == true,
        })
        if handled then return end
    elseif pickup and kind ~= "turnin" then
        pickup.clear()
    end
    if kind == "turnin" or kind == "accept" then
        npc_goal(player, goal, label, kind)
    elseif kind == "complete" or kind == "kill" or kind == "collect" then     -- 1.0.8: collect
        fight_goal(player, goal, label)
    elseif kind == "item" then                                              -- 1.13.0
        quest.item_goal(player, goal, label)
    end
end

function quest.tick(player)
    tick_inner(player)
end

-- ----------------------------------------------------------------------------
-- STATUS (read by main, gui, trainer, watchdog)
-- ----------------------------------------------------------------------------
function quest.in_travel() return g.in_travel == true end
function quest.current_kind() return g.cur_kind end
function quest.in_npc_interaction() return g.in_dialog == true end
function quest.skip_current_goal()
    -- the watchdog's way out of an NPC: the hold makes the next tick wait
    g.hold_until = izi.now() + NOT_READY_HOLD
    npc.close()
end
function quest.is_ready(player) return player ~= nil end
function quest.status_text() return guide.describe() end
--- Action strings seen on live steps that have no handler (GUI / reply list).
function quest.unhandled_actions()
    local out = {}
    for a in pairs(g.unhandled) do out[#out + 1] = a end
    table.sort(out)
    return out
end

local last_snap = { loaded = false, ready = false, step = 0, stickies = 0 }
local last_snap_t = -1
function quest.refresh_snapshot()
    local now = izi.now()
    if last_snap_t >= 0 and now >= last_snap_t and (now - last_snap_t) < 0.25 then return end
    last_snap_t = now
    local ok, snap = pcall(guide.snapshot)
    if ok and type(snap) == "table" then last_snap = snap end
end
function quest.snapshot()
    last_snap.note = state.note or ""
    last_snap.unhandled = quest.unhandled_actions()
    return last_snap
end

quest._test = { g = g }

return quest
