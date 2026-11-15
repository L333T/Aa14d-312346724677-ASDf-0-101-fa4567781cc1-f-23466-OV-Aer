-- ============================================================================
-- Master Farmer - Forever Questing
-- movement/combat.lua - closing on a target and standing in range
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.0
-- ============================================================================
-- combat_engage(player, unit, yards) is called every tick of a fight.
--   * OWNERSHIP: each call holds travel off for COMBAT_HOLD s
--     (R.combat_until); combat_release() hands the player back at once.
--   * IN POSITION: in sight and within the band - melee (yards <= 5): the
--     GUI melee distance, held to +1 yd; ranged: CHASE_BAND inside the range,
--     held to the full range. The walk stops, the player faces the target,
--     and true is returned (the caller attacks).
--   * CLOSING: Sentinel walks to the target (seamless re-paths as it
--     moves; a unit standing on the goal is never an obstacle there), and
--     false is returned. Out of sight closes in until it is in sight.
--   * NO WAY CLOSER: no CHASE_GAIN yd of progress for CHASE_STALL s while
--     out of position - the target is marked unreachable
--     (state.mark_unreachable), which grind / quest check to drop it.
--   * RETREAT: a class profile's should_retreat(ctx) (mage, priest) sends
--     the player to Sentinel's kite point (client:kite) for RETREAT_TIME s.
--     1.7.0: ctx.approaching (izi is_moving_towards_me) and ctx.slowed /
--     ctx.casting go to the profile too, for an earlier back-off.
--   * FLEE (1.7.0, restedXP 4.14.0, improvement 3 of the API-dump review):
--     FLEE_HP % health or less with FLEE_N+ enemies inside FLEE_YD yd ->
--     Sentinel's flee path (movement/nav N.flee - away from all of them) for
--     FLEE_TIME s, at most once per FLEE_GAP s; nothing is attacked while it
--     runs.
-- ============================================================================

local R = require("movement/core")
local N = require("movement/nav")
local Rg = require("movement/range")

local C = {}
local fled = {}
function C.fled_recently(unit)
    local guid=R.guid(unit)
    return guid~=nil and (fled[guid] or 0)>R.now()
end

local COMBAT_HOLD = 1.0
local MELEE_YARDS = 5
local CHASE_BAND = 3
local CHASE_GAIN, CHASE_STALL = 2.0, 10.0
-- 3.0.0.1: the chase re-paths only when the target moved CHASE_REPATH yd
-- from the walk's goal, at most every CHASE_GAP s. Sentinel's walker
-- driver restarts on every new path, and a re-path every 0.25 s made the
-- chase stutter and fall behind (log 01:44, 48 -> 53 yd while "Closing").
local CHASE_REPATH, CHASE_GAP = 4.0, 0.75
local RETREAT_TIME = 2.5
local FLEE_HP, FLEE_N, FLEE_YD, FLEE_TIME, FLEE_GAP = 100, 3, 60, 5.0, 8.0
C.FLEE_HP, C.FLEE_N = FLEE_HP, FLEE_N
local DEFAULT_MELEE_DANGER = 8
local QUERY_TIMEOUT = 3
local FLEE_RETRY = 1

local st = {
    guid = nil, unit = nil, yards = nil,
    latched = false,
    best = nil, best_t = 0,
    retreat_until = 0, kite_pending = false,
    flee_until = 0, flee_t = -1e9, flee_pending = false,
    profile = nil,
}

local function gate(reason, detail)
    local t = R.now()
    if st.gate ~= reason or t - (st.gate_t or 0) >= 5 then
        R.trail("combat", "movement gate: %s%s", reason, detail and ("; " .. detail) or "")
        st.gate, st.gate_t = reason, t
    end
    return false
end

local function expire_query(kind, t)
    local pending = st[kind .. "_pending"]
    if pending and t >= pending.deadline then
        st[kind .. "_pending"] = false
        if kind == "flee" then st.flee_t = t - FLEE_GAP + FLEE_RETRY end
        R.trail("combat", "%s query timed out; combat may resume", kind)
    end
end

function C.set_combat_profile(p)
    st.profile = type(p) == "table" and p or nil
end

function C.clear_combat_profile()
    st.profile = nil
end

local function state_mod()
    local ok, s = pcall(require, "state")
    if ok and type(s) == "table" then return s end
    return nil
end

local function want_retreat(player, unit, range)
    local p = st.profile
    if not p or type(p.should_retreat) ~= "function" then return false end
    local enemies = {}
    local oke, list = pcall(player.get_enemies_in_range, player, tonumber(p.melee_danger) or DEFAULT_MELEE_DANGER, false)
    if oke and type(list) == "table" then enemies = list end
    local ck = nil
    do
        local okc, m = pcall(require, "combatcheck")
        if okc and type(m) == "table" then ck = m end
    end
    local ctx = {
        player = player, target = unit, distance = range, melee_count = #enemies, enemies = enemies,
        approaching = ck and ck.approaching(unit, player) == true or false,
        slowed = ck and (ck.slowed(unit) == true or ck.held(unit) == true) or false,
        casting = select(2, pcall(player.is_channeling_or_casting, player)) == true,
        last_spell_id = R.last_spell_id, last_spell_target = R.last_spell_target,
        last_spell_age = R.now() - (R.last_spell_t or 0),
    }
    local ok, v = pcall(p.should_retreat, ctx)
    return ok and v == true
end

local function start_retreat(player, unit)
    if st.kite_pending then return end
    -- 1.3.0: Sentinel's kite path (movement/nav N.kite - nav_client:kite, its last
    -- point; the answer's shape is checked live, a wrong one switches kiting off)
    local okp, pp = pcall(player.get_position, player)
    local oku, up = pcall(unit.get_position, unit)
    if not okp or not oku or not pp or not up then return end
    local request = { deadline = R.now() + QUERY_TIMEOUT }
    st.kite_pending = request
    local ok = N.kite(R.point(pp), R.point(up), function(point)
        if st.kite_pending ~= request or R.now() >= request.deadline then return end
        st.kite_pending = false
        if point and N.nav_to(point, true, "combat") then
            st.retreat_until = R.now() + RETREAT_TIME
            R.trail("move", "retreat to the kite point (%.0f, %.0f)", point.x or 0, point.y or 0)
        end
    end)
    if not ok then st.kite_pending = false end
end

--- FLEE: three confirmed attackers at any health - walk
--- Sentinel's flee path away from all of them. True while fleeing.
local function flee_check(player, t)
    expire_query("flee", t)
    if t < st.flee_until or st.flee_pending then return true end
    -- Reassess danger before returning to chase after an escape leg.
    -- The request cooldown must not force a three-second re-engage.
    local continuing = st.flee_until > 0
    st.flee_until = 0
    if not continuing and (t - st.flee_t) < FLEE_GAP then return false end
    local okh, hp = pcall(player.get_health_percentage, player)
    hp = (okh and tonumber(hp)) or 0
    local okt, targeting = pcall(require, "targeting")
    if not okt or type(targeting.threats) ~= "function" then return false end
    local oke, list = pcall(targeting.threats, player, FLEE_YD,
        { player_only = true, include_unreachable = true, include_cc = true })
    -- Start before two attackers consume the health needed to escape.
    local needed = hp > 0 and hp <= 70 and 2 or FLEE_N
    if oke and type(list)=="table" and type(targeting.too_strong)=="function" then
        for _,u in ipairs(list) do
            if R.alive(u) then
                local ok,strong=pcall(targeting.too_strong,player,u)
                if ok and strong then needed=1 break end
            end
        end
    end
    if not oke or type(list) ~= "table" or #list < needed then return false end
    local threats = {}
    local seen = {}
    for i = 1, #list do
        local u = list[i]
        if R.alive(u) then
            local guid = R.guid(u)
            local okp, p = pcall(u.get_position, u)
            local point = okp and R.point(p) or nil
            if guid and not seen[guid] and point then
                seen[guid] = true
                threats[#threats + 1] = point
            end
        end
    end
    local okp, pp = pcall(player.get_position, player)
    if not okp or not pp or #threats < needed then return false end
    local ambient={}
    if type(targeting.scan_enemies)=="function" then
        local oks,attack,avoid=pcall(targeting.scan_enemies,player)
        local okl,level=pcall(function() return player:get_level() end)
        if oks then
            for _,units in ipairs({attack or {},avoid or {}}) do
                for _,u in ipairs(units) do
                    local guid=R.guid(u)
                    if guid and not seen[guid] and R.alive(u) then
                        seen[guid]=true
                        local okpos,p=pcall(u.get_position,u)
                        local point=okpos and R.point(p) or nil
                        local oke,enemy=pcall(function() return u:is_enemy_with(player) end)
                        if point and oke and enemy==true and math.abs(point.z-pp.z)<=8 then
                            local okn,n=pcall(function() return u:get_level() end)
                            point.radius=20
                            if okl and okn and type(level)=="number" and type(n)=="number" and type(targeting.aggro_radius)=="function" then
                                point.radius=targeting.aggro_radius(level,n)
                            end
                            ambient[#ambient+1]=point
                        end
                    end
                end
            end
        end
    end
    local request = { deadline = t + QUERY_TIMEOUT, continuing = continuing }
    st.flee_t, st.flee_pending = t, request
    R.trail("combat", "escape requested: %d attackers within %d yd, %.0f%% health, %d additional enemy hazards", #threats, FLEE_YD, hp,#ambient)
    local asked = N.flee(R.point(pp), threats, function(point)
        if st.flee_pending ~= request or R.now() >= request.deadline then return end
        st.flee_pending = false
        if point and N.nav_to(point, true, "combat") then
            local now=R.now()
            for guid,until_t in pairs(fled) do if until_t<=now then fled[guid]=nil end end
            for _,enemy in ipairs(list) do
                local guid=R.alive(enemy) and R.guid(enemy) or nil
                if guid then fled[guid]=now+60 end
            end
            st.flee_until = R.now() + FLEE_TIME
            R.trail("move", "flee: %.0f%% health, %d enemies within %d yd - to (%.0f, %.0f)", hp, #threats, FLEE_YD,
                point.x or 0, point.y or 0)
        else
            -- A failed query never bought any separation. Do not charge the
            -- full successful-escape cooldown while enemies are still hitting.
            st.flee_t = R.now() - FLEE_GAP + FLEE_RETRY
            R.trail("combat", "escape unavailable; reassess threats in %.1f s", FLEE_RETRY)
        end
    end,nil,ambient)
    if not asked then
        st.flee_pending = false
        st.flee_t = R.now() - FLEE_GAP + FLEE_RETRY
        return false
    end
    return true
end
C._flee_check = flee_check

--- True when in position to attack `unit` from `yards`; false while closing.
function C.combat_engage(player, unit, yards)
    if not player or not unit then return gate("missing player or target") end
    if R.resting then return gate("rest lock") end
    if R.backpedal_until then return gate("backpedal lock") end
    if not R.alive(unit) then return gate("target invalid or dead") end
    yards = tonumber(yards) or 20
    if yards < 1 then yards = MELEE_YARDS end
    local t = R.now()
    expire_query("kite", t)
    R.combat_until = t + COMBAT_HOLD

    local guid = R.guid(unit)
    if guid == nil or guid ~= st.guid then
        st.guid, st.latched, st.best, st.best_t = guid, false, nil, t
        -- 2026-10-28 (user: "Sentinel Kiting is not being used in combat", found in
        -- Zygor Questing 1.42.0 and ported here - this file is shared): the retreat
        -- used to be thrown away here with the rest of the per-target state. It is not
        -- per-target. The zygor 10-27 21:27 log: the kite walk starts at t=2124.20, an
        -- attacker switch lands at t=2124.45, retreat_until goes to 0, and the
        -- "range <= reach" branch below stops the walk at t=2125.20 - one second in,
        -- every time, which in a multi-mob fight is continuously. A retreat is about
        -- where the PLAYER needs to be, not about which unit is being hit, so it now
        -- outlives the switch and ends on its own RETREAT_TIME. The band state resets.
    end
    st.unit, st.yards = unit, yards

    local okd, range = pcall(player.distance_to, player, unit)
    if not okd or type(range) ~= "number" or range ~= range or range < 0 or range == math.huge then return gate("invalid target distance") end
    local los = Rg.has_los(player, unit)
    local melee = yards <= MELEE_YARDS
    local reach = melee and yards or math.max(MELEE_YARDS, yards - CHASE_BAND)
    local hold = melee and (yards + 1) or yards
    local ready = los and range <= hold

    -- 1.7.0: fleeing - the flee walk runs, nothing is attacked
    if flee_check(player, t) then
        gate(st.flee_pending and "waiting for flee path" or "fleeing")
        -- Planning alone must not suppress attacks against enemies already
        -- in reach. Do not stop navigation here: that invalidates the reply.
        if st.flee_pending and not st.flee_pending.continuing and ready then Rg.face(unit) return true end
        return false
    end
    -- retreating: the kite walk runs, the caller casts what it can
    if t < st.retreat_until then return ready end
    if want_retreat(player, unit, range) then
        start_retreat(player, unit)
        if t < st.retreat_until or st.kite_pending then return ready end
    end

    if los and (range <= reach or (st.latched and range <= hold)) then
        -- 3.0.0.1: ANY running walk stops here, not only the chase - the
        -- route walk kept going through a fight and carried the player out
        -- of range, unable to face the target (log 01:44, 14 -> 48 yd)
        if N.busy() then N.stop("in range") end
        st.latched = true
        st.best, st.best_t = range, t
        Rg.face(unit)
        if st.gate then R.trail("combat", "movement ready: %.1f yd; rotation released", range) end
        st.gate = nil
        return true
    end
    st.latched = false

    -- closing
    if st.best == nil or range < st.best - CHASE_GAIN then
        st.best, st.best_t = range, t
    elseif (t - st.best_t) >= CHASE_STALL then
        local s = state_mod()
        if s and guid and type(s.mark_unreachable) == "function" then s.mark_unreachable(guid) end
        R.trail("move", "no way closer to %s for %.0f s (%.0f yd%s) - marked unreachable",
            tostring(select(2, pcall(unit.get_name, unit))), t - st.best_t, range, los and "" or ", out of sight")
        st.best, st.best_t = range, t
        return false
    end
    local okp, pos = pcall(unit.get_position, unit)
    if okp and pos then
        local tx, ty = R.xyz(pos)
        local gx, gy = N.destination()
        local chasing = N.mode() == "combat" and N.busy()
        local moved = (not gx or not tx) or R.dist2(gx, gy, tx, ty) > CHASE_REPATH
        if not chasing or (moved and (t - (st.chase_t or 0)) >= CHASE_GAP) then
            st.chase_t = t
            N.nav_to(pos, true, "combat")
        end
    end
    return gate("closing", string.format("%.1f yd, reach %.1f, los %s", range, reach, tostring(los)))
end

function C.in_combat_movement()
    return (R.combat_until or 0) > R.now()
end

--- The unit being fought, never a freed one.
function C.combat_unit()
    if st.unit and R.alive(st.unit) then return st.unit end
    return nil
end

--- Latched in position against a live target while combat is asked for.
function C.in_position()
    if not st.latched or not C.in_combat_movement() then return false end
    if R.resting or R.backpedal_until or R.now() < st.retreat_until or R.now() < st.flee_until then return false end
    return C.combat_unit() ~= nil
end

--- Give the player back (loot, quest approach, fight over).
function C.combat_release()
    R.combat_until = 0
    st.latched = false
    st.kite_pending, st.flee_pending = false, false
    st.guid, st.unit, st.best = nil, nil, nil
    st.retreat_until, st.flee_until = 0, 0
    if N.mode() == "combat" then N.stop("combat over") end
end

return C
