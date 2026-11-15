-- ============================================================================
-- Master Farmer - Forever Questing
-- Death run — release, path graveyard to corpse, retrieve
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.0
-- Folder: Forever_Questing
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type vec3
local vec3 = require("common/geometry/vector_3")

---@type unit_helper
local unit_helper = require("common/utility/unit_helper")

local gui = require("gui")
local movement = require("movement")
local state = require("state")
local geometry = require("geometry")

local death = {}

local RELEASE_GAP = 3.0
-- CLOSE ENOUGH TO REVIVE (2.256.0). The walk stopped 32 yd from the "safe
-- spot" - up to ~14 yd beside the corpse when mobs stand on it - so the ghost
-- could stand ~46 yd from the corpse, out of reach, on "Retrieving corpse"
-- for good. The distance is now to the CORPSE; the ghost walks to within
-- RETRIEVE_STEPS[1] yd, and every RETRIEVE_TRIES refused revives it walks
-- closer (10 yd, then onto the corpse).
-- 1.7.32 (user: "stop as soon as the player is within range of the corpse
-- and resurrect"): the game revives from about 39 yd; the run now stops at
-- RETRIEVE_STEPS[1] = 35 yd (flat - the corpse z is approximate), or at once
-- when the game says the corpse is in range (CORPSE_IN_RANGE, events.lua).
local RETRIEVE_RANGE = 35.0
local RETRIEVE_STEPS = { 35.0, 20.0, 10.0, 4.0 }
local RETRIEVE_TRIES = 3
local HOSTILE_RANGE = 25.0
local LEVEL_GAP = 6          -- mobs this far below the player are not a threat
local RETRIEVE_GAP = 1.5

local function safe(fn)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return nil
end
--- safe(), without the closure: the same "first result, or nil on error", but
--- using pcall's own argument passing.
---
---     safe(function() return u:is_valid() end)   ->   call(u.is_valid, u)
---
--- Identical behaviour, no allocation. Used for the calls inside loops over
--- the visible object list, where the closure form allocated one per object
--- per predicate.
---
--- THE RECEIVER MUST BE NON-NIL: the index u.is_valid happens OUTSIDE the
--- pcall, so a nil receiver throws here where the closure form swallowed it.
--- Every call site keeps its `if u and ...` guard for that reason. A receiver
--- that exists but lacks the method is still fine - pcall catches calling a
--- nil value.
--- Is this value something call() may index?
---
--- call() does the index OUTSIDE the pcall, so a receiver that is not a table
--- or userdata throws before pcall can catch it. The closure form tolerated
--- any junk in a list - a boolean, a number, a leftover - and this keeps that
--- tolerance rather than narrowing it to "not nil".
local function indexable(v)
    local t = type(v)
    return t == "table" or t == "userdata"
end

local function call(fn, a, b)
    local ok, result = pcall(fn, a, b)
    if ok then
        return result
    end
    return nil
end


local function pause_path()
    local ok, path_runner = pcall(require, "path_runner")
    if ok and path_runner and type(path_runner.pause) == "function" then
        path_runner.pause()
    end
end

local function resume_path()
    local ok, path_runner = pcall(require, "path_runner")
    if ok and path_runner and type(path_runner.resume) == "function" then
        path_runner.resume()
    end
end

local function as_vec3(pos)
    -- 2.305.0: a vec3 may be userdata, not a table - read the fields guarded
    local tp = type(pos)
    if tp ~= "table" and tp ~= "userdata" then
        return nil
    end
    local okf, x, y, z = pcall(function() return pos.x, pos.y, pos.z end)
    if not okf then return nil end
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    if x == 0 and y == 0 and z == 0 then
        return nil
    end
    -- NaN or infinity (2.201.0): the corpse position read "inf" right after
    -- the release on WoW Forever, and the corpse run (Sentinel Navigation) was
    -- sent toward it.
    if x ~= x or y ~= y or z ~= z
        or math.abs(x) > 1e7 or math.abs(y) > 1e7 or math.abs(z) > 1e7 then
        return nil
    end
    return vec3.new(x, y, z)
end

-- CORPSE POSITION (2.304.0): core.game_ui.get_corpse_position() -> vec3.
-- (0, 0, z) is "no corpse" - the API's own test is x == 0 and y == 0.
-- Since the 2026-10-10 core update it reads the world map's corpse marker
-- where the direct read fails (WoW Forever used to answer inf): x, y are
-- right, z is the ground below the corpse or - terrain not loaded yet - our
-- own height. So distances to the corpse are measured flat (dist_corpse)
-- and the position is read again every tick, z settling on the way in.
-- 2.305.0: the raw answer, logged every RAW_LOG s while the corpse is not
-- known - the 13:42 daaa22 ghost waited "for corpse position" with no clue
-- what the call returned.
local RAW_LOG = 10
local raw_logged = -1e9

-- 2.305.0: WHERE THE BODY FELL survives a reload (saved with the settings).
-- A ghost after a reload had no died-at position: nothing to run to.
local saved_died = nil
do
    local ok_s, settings = pcall(require, "settings")
    if ok_s and type(settings) == "table" and type(settings.register) == "function" then
        settings.register("died_at", function()
            local d = saved_died
            return d and string.format("%.1f:%.1f:%.1f", d.x, d.y, d.z) or nil
        end, function(v)
            if type(v) ~= "string" then return end
            local x, y, z = v:match("([%-%d%.]+):([%-%d%.]+):([%-%d%.]+)")
            if x then saved_died = { x = tonumber(x), y = tonumber(y), z = tonumber(z) } end
        end)
    end
end
local function save_died(p)
    saved_died = p and { x = p.x, y = p.y, z = p.z } or nil
    local ok_s, settings = pcall(require, "settings")
    if ok_s and type(settings) == "table" and type(settings.mark_dirty) == "function" then
        pcall(settings.mark_dirty)
    end
end

local function corpse_position()
    local raw = safe(function()
        return core.game_ui.get_corpse_position()
    end)
    local okz, zero = pcall(function() return raw.x == 0 and raw.y == 0 end)
    local got = raw
    if okz and zero then
        got = nil                          -- no corpse (the API's zero vector)
    end
    local vec = as_vec3(got)
    if vec then
        local died = as_vec3(state.dead.died_pos) or as_vec3(saved_died)
        state.dead.corpse_exact = false
        if died and (died.x-vec.x)^2 + (died.y-vec.y)^2 <= 20^2 then
            -- Map-marker Z can be the surface above a cave. The observed
            -- death position is authoritative when its XY matches this body.
            vec = died
            state.dead.corpse_exact = true
        end
        state.dead.corpse = vec
        return vec
    end
    local now = izi.now()
    if now - raw_logged >= RAW_LOG then
        raw_logged = now
        local okr, rx, ry, rz = pcall(function() return raw.x, raw.y, raw.z end)
        local el_ok, el = pcall(require, "errorlog")
        if el_ok and type(el) == "table" and type(el.trail) == "function" then
            pcall(el.trail, "death", "get_corpse_position: %s (%s, %s, %s) - %s", type(raw),
                tostring(okr and rx), tostring(okr and ry), tostring(okr and rz),
                (state.dead.corpse or state.dead.died_pos or saved_died) and "using the last known / died-at position"
                    or "no fallback position")
        end
    end
    -- The client gave nothing usable (inf, 0,0,0): the last known corpse,
    -- else where the character died (2.201.0) - the body stays where it fell.
    local died = as_vec3(state.dead.died_pos) or as_vec3(saved_died)
    local fb = died or as_vec3(state.dead.corpse)
    if died then state.dead.corpse_exact = true end
    -- 1.7.31 (log 2026-10-18 20:25:44: no path to the died-at (-949, 2140, 20)
    -- after get_corpse_position answered (0, 0, 0)): the height movement/nav
    -- found a path at there (its no-path height search) replaces the guess
    if fb and not state.dead.corpse_exact and type(movement.reach_z) == "function" then
        local zf = safe(function() return movement.reach_z(fb) end)
        if type(zf) == "number" and zf == zf and math.abs(zf - fb.z) > 1 then
            fb = vec3.new(fb.x, fb.y, zf)
        end
    end
    return fb
end

local function dist_to(pos)
    local here = state.cached_pos
    if not here or not pos then
        return nil
    end
    -- vec3:dist_to, not sqrt of the squares by hand.
    local d = geometry.distance(here, pos)
    if type(d) == "number" then
        return d
    end
    -- A position the vector helper could not read. Say "far" rather than
    -- "here": a corpse run must not think it has arrived because a
    -- coordinate was missing.
    return math.huge
end

--- Is anything near `pos` that would actually threaten a resurrection?
---
--- `player_level` is optional. When supplied, mobs more than LEVEL_GAP levels
--- below the player are ignored: a grey mob next to the corpse is not a threat,
--- and treating it as one forces a pointless relocation every single death in
--- a low-level zone.
local function hostiles_near(pos, yards, player_level)
    if not pos then
        return false
    end
    local list = safe(function()
        return unit_helper:get_enemy_list_around(pos, math.max(yards,35), true, true, false, false)
    end)
    if type(list) ~= "table" then
        return false
    end
    for i = 1, #list do
        local u = list[i]
        if indexable(u) and call(u.is_valid, u) == true then
            if call(u.is_dead_or_ghost, u) ~= true then
                if call(u.is_player, u) ~= true then
                    if call(u.is_dummy, u) ~= true then
                        local ignore = false
                        local classification=call(u.get_classification,u)
                        local elite=classification==1 or classification==2 or classification==3
                        local clearance=elite and math.max(yards,35) or yards
                        local up=call(u.get_position,u)
                        if up and type(up.x)=="number" and type(up.y)=="number" and type(up.z)=="number" then
                            ignore=math.abs(up.z-(pos.z or up.z))>8
                                or (up.x-pos.x)^2+(up.y-pos.y)^2>clearance^2
                        end
                        if type(player_level) == "number" then
                            local lvl = call(u.get_level, u)
                            if type(lvl) == "number" and (player_level - lvl) > LEVEL_GAP then
                                ignore = true
                            end
                        end
                        if not ignore then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

--- Snap a candidate onto the ground. Offsetting x/y while keeping the corpse's
--- z puts the point inside terrain on any slope, which then fails to path to.
local function snapped(x, y, hint_z)
    local z
    if type(movement.ground_z) == "function" then
        local got = safe(function() return movement.ground_z(x, y, hint_z) end)
        if type(got) == "number" and got == got and math.abs(got-hint_z)<=8 then
            z = got
        end
    end
    return z and vec3.new(x, y, z) or nil
end

local function safe_retrieve_pos(corpse, player_level)
    if not corpse then
        return nil
    end
    if not hostiles_near(corpse, HOSTILE_RANGE, player_level) then
        return corpse
    end
    -- Four diagonal points missed clear corridor ends and could snap onto
    -- the roof of a cave. Search two rings on the corpse's local floor.
    local best, best_distance
    for _, radius in ipairs({32,16}) do
        for i=0,7 do
            local angle=i*math.pi/4
            local candidate=snapped(corpse.x+radius*math.cos(angle),corpse.y+radius*math.sin(angle),corpse.z)
            if candidate and geometry.distance(candidate,corpse)<RETRIEVE_RANGE
                and not hostiles_near(candidate,HOSTILE_RANGE,player_level) then
                local distance=state.cached_pos and geometry.distance(state.cached_pos,candidate) or radius
                if not best_distance or distance<best_distance then best,best_distance=candidate,distance end
            end
        end
    end
    return best or corpse
end

local function dtrail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then
        pcall(el.trail, "death", fmt, ...)
    end
end

local function dist2d(a, b)
    if not a or not b or type(a.x) ~= "number" or type(b.x) ~= "number" then return nil end
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

local function run_to(dest)
    if not dest then
        return
    end
    local now=izi.now()
    local mode=state.dead.corpse_exact and "corpse" or nil
    if type(movement.recovery_pending)=="function" and movement.recovery_pending() then return end
    local distance=dist2d(state.cached_pos,dest)
    local w=state.dead.route_watch
    if not w or dist2d(w.goal,dest)>5 then
        w={goal={x=dest.x,y=dest.y},best=distance or math.huge,since=now,attempts=0}
        state.dead.route_watch=w
    end
    if distance and distance<w.best-2 then w.best,w.since=distance,now end
    if now-w.since>=12 and now-(w.retry_at or -1e9)>=12 then
        w.retry_at,w.since=now,now
        w.attempts=w.attempts+1
        local recovered=type(movement.recover_path)=="function"
            and movement.recover_path({x=dest.x,y=dest.y,z=dest.z,mode=mode,z_guess=not state.dead.corpse_exact},w.attempts%2==1 and 1 or -1,nil,w.attempts>=3 and w.attempts or false)
        dtrail("corpse route stalled: alternate approach %d, accepted=%s, distance=%.1f",
            w.attempts,tostring(recovered),distance or -1)
        if recovered then return end
    end
    if movement.last_fail_offmesh() then
        movement.nav_to(dest, true, mode)
        movement.clear_fail()
        return
    end
    movement.nav_to(dest, nil, mode)
end

function death.is_down(player)
    if not player then
        return false
    end
    if safe(function() return player:is_dead_or_ghost() end) == true then
        return true
    end
    if safe(function() return player:is_dead() end) == true then
        return true
    end
    if safe(function() return player:is_ghost() end) == true then
        return true
    end
    return false
end

--- Blacklist whatever we were fighting when we died.
---
--- The reference bot does this so the target selector stops handing back the
--- exact mob that just killed us - otherwise the bot corpse-runs, res-es, walks
--- straight back into the same pull and dies again in a loop. state already has
--- the mechanism; movement/combat.lua uses it for unreachable mobs.
local function blacklist_killer()
    if type(state.mark_unreachable) ~= "function" then
        return
    end
    local unit = safe(function() return movement.combat_unit() end)
    if not unit then
        return
    end
    local guid = safe(function() return unit:get_guid() end)
    if guid == nil then
        return
    end
    state.mark_unreachable(guid)
    core.log("[Master Farmer - Forever Questing] Blacklisted the mob that killed us: " .. tostring(guid))
end

local function begin_death()
    if state.dead.waiting then
        return
    end
    -- 2.247.0: the killer, read before blacklist_killer / reset_target
    local killer = safe(function() return movement.combat_unit() end)
    blacklist_killer()
    state.dead.waiting = true
    state.dead.route_watch = nil
    state.dead.corpse = nil
    state.dead.corpse_exact = false
    -- Where the body fell (2.201.0), recorded before the release: the corpse
    -- position fallback when get_corpse_position answers inf. Not as a ghost
    -- (a reload mid corpse run): the ghost stands at the graveyard.
    state.dead.died_pos = nil
    local me = safe(function() return izi.me() end)
    if me and safe(function() return me:is_ghost() end) ~= true then
        local p = safe(function() return me:get_position() end)
        if as_vec3(p) then
            state.dead.died_pos = { x = p.x, y = p.y, z = p.z }
            save_died(state.dead.died_pos)          -- 2.305.0: kept across a reload
        end
    end
    -- DEATH ZONES (2.247.0): 3 deaths to the same enemy in one area -> that
    -- area is avoided for 10+ minutes (deathzones.lua). Only a real death
    -- spot: a ghost after a reload stands at the graveyard.
    if state.dead.died_pos then
        local ok_dz, dz = pcall(require, "deathzones")
        if ok_dz and type(dz) == "table" and type(dz.record_death) == "function" then
            pcall(dz.record_death, killer, state.dead.died_pos)
        end
    end
    state.dead.retrieve_at = 0
    state.dead.retrieve_tries = 0
    state.dead.step_logged = nil
    pcall(function() require("managems").reset() end)   -- audit N8: no "conjure" pause survives death
    state.grind.step = 1
    state.reset_target()
    if type(movement.set_resting) == "function" then
        movement.set_resting(false)
    end
    pause_path()
    movement.nav_stop()
end

local function end_death()
    if not state.dead.waiting then
        return
    end
    state.dead.waiting = false
    state.dead.route_watch = nil
    state.dead.corpse = nil
    state.dead.died_pos = nil
    save_died(nil)                                  -- 2.305.0: alive again
    resume_path()
end

function death.tick(player)
    if not gui.is_started() then
        return false
    end
    if not death.is_down(player) then
        end_death()
        return false
    end

    begin_death()

    local now = izi.now()
    local is_ghost = safe(function() return player:is_ghost() end) == true
    if not is_ghost then
        if (now - (state.dead.released_at or 0)) >= RELEASE_GAP then
            state.dead.released_at = now
            pcall(function()
                core.input.release_spirit()
            end)
            -- audit F6/F7: record the corpse run next to the guide reads around
            -- it. This module never reads the guide: the body comes from
            -- core.game_ui.get_corpse_position. Logging only.
            do
                local dg = package.loaded["quest/diag"]
                if type(dg) == "table" and type(dg.corpse_run) == "function" then
                    pcall(dg.corpse_run, "spirit released")
                end
            end
        end
        state.set_note("Death", "Releasing spirit")
        return true
    end

    local corpse = corpse_position()
    if not corpse then
        state.set_note("Death", "Waiting for corpse position")
        return true
    end

    local my_level = safe(function() return player:get_level() end)
    -- 2.306.0 (audit PERF-1): the safe-revive-spot search scans enemies up
    -- to 5 times; measured 0.72 ms/frame for a ghost 273 yd out. Only within
    -- SAFE_SEARCH yd of the corpse - before that the corpse is the goal.
    local d0 = dist2d(state.cached_pos, corpse)
    local dest = (d0 == nil or d0 <= 60) and safe_retrieve_pos(corpse, my_level) or corpse
    -- 2.304.0: flat - the corpse z is approximate until the area is loaded
    local d = (state.dead.corpse_exact and dist_to(corpse)) or d0 or dist_to(corpse) or dist_to(dest)
    if now - (state.dead.coord_logged or -1e9) >= 10 then
        state.dead.coord_logged = now
        local here = state.cached_pos
        dtrail("corpse XYZ %.2f, %.2f, %.2f (%s); player Z %s; distance %.1f", corpse.x, corpse.y, corpse.z,
            state.dead.corpse_exact and "recorded death" or "map estimate", tostring(here and here.z), d or -1)
    end
    if type(d) ~= "number" then
        run_to(dest)
        state.set_note("Death", "Running to corpse")
        return true
    end

    local step = math.min(#RETRIEVE_STEPS, 1 + math.floor((state.dead.retrieve_tries or 0) / RETRIEVE_TRIES))
    local reach = RETRIEVE_STEPS[step] or RETRIEVE_RANGE
    local ev = package.loaded["events"]
    local in_range = type(ev) == "table" and type(ev.navflags) == "table" and ev.navflags.corpse_in_range == true
    if d > reach and not (in_range and step == 1) then
        -- the safe spot while it is inside the reach, else straight to the corpse
        local dd = dist_to(dest)
        local go = (step == 1 and dest and (dist2d(dest, corpse) or 0) < reach) and dest or corpse
        run_to(go)
        state.set_note("Death", string.format("Corpse  %.0f yd", d))
        if dd and step > 1 and state.dead.step_logged ~= step then
            state.dead.step_logged = step
            dtrail("revive refused %d times at %.0f yd - walking to %.0f yd of the corpse",
                state.dead.retrieve_tries or 0, d, reach)
        end
        return true
    end

    -- Being in corpse range does not make this position safe. Finish the
    -- selected nearby safe approach before reviving beside a hostile mob.
    local safe_distance = dist2d(state.cached_pos, dest)
    if step == 1 and dest and safe_distance and safe_distance > 3
        and (dist2d(dest,corpse) or math.huge) < reach
        and hostiles_near(state.cached_pos, HOSTILE_RANGE, my_level)
        and not hostiles_near(dest, HOSTILE_RANGE, my_level) then
        run_to(dest)
        state.set_note("Death", "Moving clear of enemies before reviving")
        return true
    end
    -- All candidate approaches may still be occupied. Never fall through
    -- to resurrection merely because the corpse is within reach.
    if hostiles_near(state.cached_pos, HOSTILE_RANGE, my_level) then
        movement.nav_stop()
        state.set_note("Death", "Waiting for a safe resurrection position")
        if now-(state.dead.unsafe_logged or -1e9)>=10 then
            state.dead.unsafe_logged=now
            dtrail("resurrection held: hostile enemies at player position; corpse distance %.1f",d)
        end
        return true
    end
    movement.nav_stop()
    local delay = safe(function()
        return core.game_ui.get_resurrect_corpse_delay()
    end) or 0
    if type(delay) == "number" and delay > 0 then
        state.set_note("Death", string.format("Retrieve in %.0fs", delay))
        return true
    end
    if (now - (state.dead.retrieve_at or 0)) >= RETRIEVE_GAP then
        state.dead.retrieve_at = now
        state.dead.retrieve_tries = (state.dead.retrieve_tries or 0) + 1
        dtrail("revive at %.0f yd of the corpse (try %d)%s", d, state.dead.retrieve_tries,
            in_range and " - the game says it is in range" or "")
        pcall(function()
            core.input.resurrect_corpse()
        end)
    end
    state.set_note("Death", "Retrieving corpse")
    return true
end

return death
