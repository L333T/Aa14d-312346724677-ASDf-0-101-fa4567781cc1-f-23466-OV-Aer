-- ============================================================================
-- Master Farmer - Forever Questing
-- Movement - public facade
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Product version: see version.lua
-- Folder: Forever_Questing
-- ============================================================================
-- 1.1.0 SENTINEL PORT (docs/SENTINEL_PORT_GUIDE.md). Sentinel Navigation does
-- every walk (movement/nav.lua over movement/sentinel.lua, the only Sentinel
-- caller): navmesh paths, steering, its own stuck recovery. Nothing here
-- presses movement keys while a Sentinel walk runs (guide rule 4): the
-- outdoor unstick below is a NO-PROGRESS WATCHDOG on Sentinel (a fresh path,
-- then the detour fan - OU.KEYS false); its key ladder stays in the code for
-- a walker that needs it, off.
-- This layer decides where to go and when to stand still:
--
--   travel   nav_to / follow_route / nav_stop      movement/nav
--   combat   combat_engage / combat_release        movement/combat
--   holds    rest, cast, channel, loot, backpedal  movement/locks
--   sight    facing, line of sight, arrival        movement/range, sight
--   corridor recorded-path leash (path_runner)      movement/leash
--   areas    blacklisted areas                     movement/zones
--
-- The surface below is the one the rest of the bot calls (every name has
-- callers; the 2.x helpers nobody called are gone). Reading a name that does
-- not exist is logged once and answers nil.
-- ============================================================================

local R  = require("movement/core")
local Z  = require("movement/zones")
local N  = require("movement/nav")
local AS = require("movement/astar")   -- local A* + ray fallback for off-mesh targets (alongside Sentinel)
local TR = require("movement/trace")   -- 2026-10-25: the ray walk assistant (trace_tick, halt)
local Lk = require("movement/locks")
local Rg = require("movement/range")
local C  = require("movement/combat")
local L  = require("movement/leash")
local Pv = require("movement/pivot")   -- 3.2.0: stop and turn on sharp waypoint turns
local Mt = require("movement/mount")   -- 3.8.0: mount for travel (the 1-60 way)

-- 3.8.0: Gathering uses its own "Use Mount" box; questing / grinding the
-- General tab one
Mt.enabled_fn = function()
    local ok, gui = pcall(require, "gui")
    if not ok or type(gui) ~= "table" or type(gui.is_on) ~= "function" then return true end
    return gui.is_on("fq_mount") ~= false
end

-- the General tab box "Local A* Fallback" (on by default); AS.ON is the code kill switch
AS.enabled_fn = function()
    local ok, gui = pcall(require, "gui")
    if not ok or type(gui) ~= "table" or type(gui.is_on) ~= "function" then return false end
    return gui.is_on("fq_astar") ~= false
end

-- 3.2.0: the GUI switch (Path tab, "Stop and Turn on Sharp Turns", on by default)
Pv.set_enabled_fn(function()
    local ok, gui = pcall(require, "gui")
    if not ok or type(gui) ~= "table" or type(gui.is_on) ~= "function" then return true end
    local v = gui.is_on("sharp_turn_stop")
    return v ~= false
end)

local movement = {}

-- GUI snapshot state (built in movement.pulse, read by debug_snapshot)
local SNAP_EVERY = 0.5
local snap = { state = "idle", owner = "none", quiet = false }
local snap_t = -1e9
local build_snapshot
local height_log_t = -1e9

-- ============================================================================
-- TRAVEL
-- ============================================================================
movement.nav_to       = function(dest, direct, mode) return N.nav_to(dest, direct, mode) end
movement.nudge        = function(dest) return N.nav_to(dest) end
-- 3.5.0: RestedXP waypoints / movement instructions: 3-yard, object-checked walks
movement.guide_to     = function(dest) return N.nav_to(dest, true, "guide") end
-- 1.4.0: a guide waypoint - one Sentinel walk per waypoint key
movement.waypoint_walk = function(dest, key) return N.waypoint_walk(dest, key) end
movement.hint_next    = function(pos, key) return N.hint_next(pos, key) end   -- the waypoint AFTER the current one (quest engine)
movement.follow_route = N.follow_route
movement.want_input_driver = N.want_input_driver      -- 1.7.4 (gui Start / Stop)
movement.step_into = N.step_into                      -- 1.7.7: the last yards into a portal (move_direct)
movement.avoid_area = N.avoid_area                  -- 1.2.0: Sentinel avoidance zone + soft re-path
movement.path_ahead = N.path_ahead                    -- 1.7.9: the walk's path ahead (threat check; Sentinel's path)
movement.nav_path     = function(points) return N.follow_route(points) end
movement.recover_path = N.recover_path
movement.recovery_pending = N.recovery_pending
-- 3.0.4: callers stop every tick once "near" an NPC (4-5 yd); an approach
-- movement.interact started (to NPC_REACH) is not cancelled by that
local npc_walk = { until_t = 0 }
movement.nav_stop     = function()
    if R.now() < npc_walk.until_t and N.mode() == "npc" then return end
    -- 1.8.7: a stopped walk ends a running unstick try (its keys let go, the
    -- "mf_unstick" pause resumed) - it must not carry on into the next walk
    if movement.unstick_stop then pcall(movement.unstick_stop, "the walk stopped") end
    N.stop("Master Farmer")
end
movement.is_moving    = function() return N.busy() or R.backpedal_until ~= nil end
movement.is_navigating = function() return N.busy() and not C.in_combat_movement() end
movement.sentinel_active = N.busy
movement.is_quiet     = function() return R.now() < (R.quiet_until or 0) end

--- The running walk's destination is within `yards` (2D) of `pos`.
function movement.headed_to(pos, yards)
    local dx, dy = N.destination()
    local x, y = R.xyz(pos)
    if not dx or not x then return false end
    return R.dist2(dx, dy, x, y) <= (tonumber(yards) or 15)
end

-- "long travel" / approach hints: Sentinel needs neither (one path to the
-- real destination); kept so the callers' bookkeeping stays simple.
local hints = { keep = false, approach = nil, target = nil }
movement.keep_path           = function(on) hints.keep = on == true end
movement.set_approach        = function(kind) hints.approach = kind end
movement.set_approach_target = function(guid) hints.target = guid end

--- Everything stops: walk, fight, holds, backpedal.
local ou_end                                             -- 1.7.16 (defined with the outdoor unstick)
local OU_probe_stop                                      -- audit S2 (defined with the outdoor unstick)
function movement.halt()
    TR.reset()                                           -- 2026-10-25
    if ou_end then pcall(ou_end, "halt") end             -- 1.7.16
    if OU_probe_stop then pcall(OU_probe_stop) end       -- audit S2: a probe pause is lifted
    pcall(function() require("managems").reset() end)   -- audit N8: a "conjure" pause too
    Pv.release("halt")
    C.combat_release()
    Lk.clear()
    N.stop("halt", true)                                 -- 1.24.0: Stop / close / unload, not a deferred pulse
    pcall(function() require("movement/memory").flush(true) end)   -- 1.9.0: the nav memory is written
    N.release_driver_now()                               -- 1.7.4: unload puts the driver back
    pcall(function() core.input.stop_attack() end)
end

-- ============================================================================
-- FAILURES
-- ============================================================================
movement.last_fail_reason  = N.last_fail_reason
movement.last_fail_offmesh = N.last_fail_offmesh
movement.clear_fail        = N.clear_fail

-- ============================================================================
-- COMBAT
-- ============================================================================
movement.combat_engage        = C.combat_engage
movement.combat_release       = C.combat_release
movement.fled_recently        = C.fled_recently
movement.in_combat_movement   = C.in_combat_movement
movement.combat_unit          = C.combat_unit
movement.combat_in_position   = C.in_position
movement.set_combat_profile   = C.set_combat_profile
movement.clear_combat_profile = C.clear_combat_profile

-- ============================================================================
-- FACING / SIGHT / RANGE
-- ============================================================================
movement.face           = Rg.face
movement.has_los        = Rg.has_los
movement.in_fight_range = Rg.in_fight_range
movement.arrived        = Rg.arrived
movement.line_blocked   = Rg.line_blocked
movement.can_reach      = Rg.can_reach
--- Measured local floor for resurrection candidates. A hint is not evidence:
--- unknown ground must remain nil so death.lua cannot select phantom floors.
movement.ground_z = function(x, y, hint_z)
    if not R.finite(x) or not R.finite(y) or not R.finite(hint_z) then return nil end
    return TR.player_ground({x=x,y=y,z=hint_z},1.5)
end

-- ============================================================================
-- AREAS
-- ============================================================================
movement.is_blocked     = Z.is_blocked
movement.blacklist_area = Z.blacklist_area

-- ============================================================================
-- HOLDS
-- ============================================================================
movement.set_resting     = Lk.set_resting
movement.release         = Lk.release
movement.cast_cancelled  = Lk.cast_cancelled
movement.prepare_cast    = Lk.prepare_cast
movement.prepare_channel = Lk.prepare_channel
movement.prepare_ground  = Lk.prepare_ground
movement.pause_for_loot  = Lk.pause_for_loot
movement.backpedal       = Lk.backpedal
movement.backpedaling    = Lk.backpedaling
movement.blink_away      = Lk.blink_away             -- 1.7.15
movement.blinking        = Lk.blinking

-- 3.0.2: AT AN NPC. Every NPC interaction goes through movement.interact:
-- the walk stops and travel is held NPC_HOLD s from the LAST interaction,
-- so a window, gossip, purchase, repair or turn-in completes before the
-- bot walks off (walking away closed trainer / merchant windows). Fights
-- are not held (combat_engage walks regardless).
-- 3.0.4: the player walks to within NPC_REACH yd of the NPC first (the
-- callers stopped at 4-5 yd and the game answered "too far away"), and the
-- fallback hold is 3 s; confirmed dialog completion releases it immediately.
local NPC_HOLD = 3.0
local NPC_REACH = 2.5
movement.NPC_REACH = NPC_REACH
local function event_clock()
    -- events.lua stamps UI errors with izi.now(); the too-far check compares
    -- against that clock
    local ok, izi = pcall(require, "common/izi_sdk")
    if ok and type(izi) == "table" and type(izi.now) == "function" then
        local okn, t = pcall(izi.now)
        if okn and type(t) == "number" then return t end
    end
    return nil
end

function movement.npc_hold(seconds)
    R.npc_until = R.now() + (tonumber(seconds) or NPC_HOLD)
    R.npc_ev_t = event_clock()
    if N.busy() then N.stop("at an NPC") end
end

--- Forever Questing 1.0.6: the quest dialog finished - walking may go on at
--- once (NPC_HOLD stays the cap for a dialog that never reports an end).
function movement.npc_release()
    R.npc_until, R.npc_ev_t = nil, nil
end

function movement.npc_holding()
    return (R.npc_until or 0) > R.now()
end

--- Interact with an NPC and hold travel NPC_HOLD s. True when sent.
--- Farther than NPC_REACH: walks up to the NPC instead and answers false
--- (the caller's next attempt interacts from there).
function movement.interact(unit)
    if not unit then return false end
    local valid, live = pcall(unit.is_valid, unit)
    if not valid or live ~= true then return false end
    local me = R.me()
    local d = nil
    if me then
        local okd, v = pcall(me.distance_to, me, unit)
        if okd and type(v) == "number" and v == v and v >= 0 and v < math.huge then d = v end
    end
    if d and d > NPC_REACH then
        local okp, pos = pcall(unit.get_position, unit)
        if okp and pos then
            R.npc_until, R.npc_ev_t = nil, nil
            if N.nav_to(pos, true, "npc") then
                npc_walk.until_t = R.now() + 3.0
                R.trail("move", "NPC %.1f yd away - walking within %.0f yd before interacting", d, NPC_REACH)
                return false
            end
        end
        return false
    end
    if not d then return false end
    npc_walk.until_t = 0
    movement.npc_hold()
    -- 1.8.0 (restedXP 4.5.0): a game object that gives / takes a quest (a
    -- cauldron, a diary) is opened with use_object - interact_with_object
    -- does not cover every object
    local okq, is_unit = pcall(unit.is_unit, unit)
    if okq and is_unit == false then
        -- 1.9.0 (restedXP 4.27.0): use_object ONLY - interact_with_object on a world
        -- object crashed the game (Joseph Redpath's Monument, the Pamela's Doll pieces)
        local oku, used = pcall(function() return core.input.use_object(unit) end)
        return oku and used == true
    end
    local ok = pcall(function() core.input.interact_with_object(unit) end)
    return ok
end

-- ============================================================================
-- RECORDED-PATH CORRIDOR (path_runner)
-- ============================================================================
movement.set_path_leash    = L.set_path_leash
movement.clear_path_leash  = L.clear_path_leash
movement.needs_rejoin      = L.needs_rejoin
movement.rejoin_path       = L.rejoin_path
movement.path_anchor_index = L.path_anchor_index

-- ============================================================================
-- NAVMESH QUERIES
-- ============================================================================
movement.reachable         = N.reachable
movement.node_reachable    = N.node_reachable
movement.reach_z           = N.reach_z
movement.reach_forget      = N.reach_forget
movement.nav_stats         = function() return N.stats end

-- ============================================================================
-- SPELLS (spellcheck.lua records each cast sent; class retreat rules read it)
-- ============================================================================
function movement.note_spell(id, target)
    R.last_spell_id, R.last_spell_target, R.last_spell_t = id, target, R.now()
end

function movement.last_player_spell()
    return R.last_spell_id, R.last_spell_target, R.last_spell_t
end

-- ============================================================================
-- PER FRAME / DEBUG
-- ============================================================================
-- 1.7.8 INDOOR JUMP (user: "add a jump on indoor pathing when the player's
-- position stays on a waypoint for more than 3 seconds, to help with sharp
-- turns indoors"). While a Sentinel Navigation walk runs indoors and the player has
-- moved less than STILL_YD for STILL_S, one jump (jump = JumpOrAscendStart, so
-- ascend_stop right after, as quest/engine does); then the window starts again.
-- Not while the walk is held on purpose: a sharp-turn pivot, a cast / loot
-- hold, casting, resting, a backpedal, standing at an NPC, or a portal step.
-- The user's rule; an exception to CLAUDE_MASTERARTHASNAV_RULES R3.1 / R6.2.
local IJ = { STILL_S = 3.0, STILL_YD = 0.5, x = nil, y = nil, since = 0, jumps = 0 }
movement.IJ = IJ

-- 1.7.16 OUTDOOR UNSTICK (user: "during navigation stuck try moving to the
-- left and jump 3 times while moving forward; if still stuck after trying to
-- path, moving right and jumping 3 times; repeat until the player is moving
-- along the route"). Outdoors (indoors has the 1.7.8 jump), while a
-- Sentinel Navigation walk runs and the player has moved less than STILL_YD for
-- STILL_S: the walk is PAUSED (Sentinel Navigation lets go of its keys), forward +
-- strafe toward OU.side is held for LEN s with a jump at each of JUMPS, then
-- the keys are released and the walk RESUMED (it paths on from there). Still
-- stuck STILL_S later: the other side. Moving again: the next try starts left.
-- Not during a pivot, a hold, casting, swimming, resting, a backpedal (Blink
-- Away too), at an NPC or on a portal step. A user rule: an exception to
-- CLAUDE_MASTERARTHASNAV_RULES R3.1 / R6.2 (keys during a PAUSED walk only).
-- 1.7.21 (log 17:00-17:04, the ghost's corpse run, 579 yd from the corpse for
-- 4 minutes): "stuck" is NO PROGRESS ALONG THE ROUTE - the distance to the
-- walk's destination not PROGRESS_YD shorter for STILL_S - not "under 0.5 yd
-- of movement": Sentinel Navigation's own detour recovery wiggled the ghost in
-- place for 4 minutes (more than 0.5 yd every 3 s) and no try was ever made.
-- The window is not reset by a sharp-turn pivot (ended for the try) or by a
-- short idle moment of a restarting walk (IDLE_OK s); only progress resets it,
-- and only progress sends the next try back to the left side.
-- Progress is also MOVE_YD of real movement from where progress was last
-- seen (a route bending round a hill moves away from its goal for a while).
-- 1.7.23 (log 18:03-18:05: 162-169 yd from the goal for minutes - the walk
-- back to the path after each try read as "moving again", and a sideways
-- shuffle never gets past a wall): STUCK EPISODES. The spot where the walk got
-- stuck is remembered; while the player is within EP_RADIUS of it and not
-- EP_GAIN yd closer to the goal than the episode's best, every stuck window
-- takes the NEXT rung of OU.LADDER:
--   left, right            forward + strafe with 3 jumps (the user's rule)
--   repath                 a fresh path from here (N.replan_fresh)
--   detour <side> <yd>     a point beside the blocked stretch (left / right of
--                          the path's direction, or back), checked with
--                          Sentinel Navigation's find_path (a path to it no longer
--                          than DETOUR_STRAIGHT x the straight line), walked to,
--                          then a fresh path to the goal (N.detour)
-- and round again. The episode ends on real progress (EP_GAIN closer) or
-- EP_RADIUS away from the spot and closer to the goal.
-- 1.1.0 SENTINEL PORT: Sentinel recovers from being stuck by itself, and keys
-- pressed (or a pause = a stop on Sentinel) during its walk cut that recovery
-- short. OU.KEYS = false: no nudge, no turn / back-up / strafe rung, no pause
-- while the fan's path queries run. What is left is a watchdog: no progress
-- for WATCH_S s (Sentinel's own tries come first) -> OU.LADDER_SENTINEL, a
-- fresh path (the destination handed to Sentinel again, N.replan_fresh), then
-- the detour fan (each point checked with Sentinel find_path and its floors,
-- walked with N.detour). The stuck episode and its nav-memory confirm stay.
local OU = { KEYS = false, WATCH_S = 10.0, LADDER_SENTINEL = { { "repath" }, { "fan" } },
    STILL_S = 3.0, PROGRESS_YD = 2.0, MOVE_YD = 4.0, IDLE_OK = 1.5, ARRIVED_YD = 4.0,
    EP_RADIUS = 15, EP_GAIN = 8, DETOUR_STRAIGHT = 3.5, ep = nil, probing = false,   -- 1.7.30: 3.5 (was 2.5) - a longer way round is fine
    -- 1.7.24: after left / right / a fresh path, the FAN - new points (x, y, z)
    -- and new paths until the player is past the stuck spot
    -- 1.8.7 (user: "when stuck, turn in slight angles to the right 5 times; if
    -- still stuck back the player up 1 yard and do the same to the left" -
    -- indoors and out): 5 slight right turns (each a short turn on the turn key,
    -- then forward), a 1 yd back-up, 5 slight left turns, then the fresh path
    -- and the detour fan as before
    LADDER = { { "turn", "right" }, { "turn", "right" }, { "turn", "right" }, { "turn", "right" }, { "turn", "right" },
        { "backup" },
        { "turn", "left" }, { "turn", "left" }, { "turn", "left" }, { "turn", "left" }, { "turn", "left" },
        { "repath" }, { "fan" } },
    -- 1.0.11 (log 2026-10-20 18:17, Northshire Abbey: five slight right turns
    -- in a row at a door, 44 yd to go): INDOORS (game_object:is_indoors at
    -- the start of the episode) the ladder is short and mixed - back up 1 yd,
    -- a fresh path, one slight turn each way, back up, a fresh path, the fan
    LADDER_INDOOR = { { "backup" }, { "repath" }, { "turn", "right" }, { "turn", "left" }, { "backup" },
        { "repath" }, { "fan" } },
    TURN_S = 0.1,       -- s on the turn key: about 18 degrees (the turn rate is about 180 deg / s)
    FWD_S = 0.9,        -- s forward after the turn
    BACK_S = 0.25,      -- s backward: about 1 yd (the back-pedal speed is about 4.5 yd / s)
    FAN_ANGLES = { 45, -45, 90, -90, 135, -135, 180 }, FAN_RADII = { 15, 30, 50 }, FAN_KEEP_OFF = 6, FAN_DZ = 20, PROBE_MAX_S = 4,   -- 1.7.30: radii further out
    JUMPS = { 0.3, 0.9, 1.5 }, LEN = 1.8,
    -- 1.0.13 (user: "When Player is outside and navigating forward but player
    -- position not changing and or not advancing through waypoints then player
    -- should ALWAYS 1. jump if not moving for more than 1.5 s, 2. strafe right
    -- 0.5 s if not moving forward for 2 s, 3. strafe left 0.5 s if not moving
    -- forward for 2.5 s"): the OUTDOOR NUDGE - every stuck window outdoors,
    -- before the ladder's rung at STILL_S (3 s). The walk is paused
    -- ("mf_unstick"), forward held, a jump at 1.5 s, strafe right 2.0-2.5 s,
    -- strafe left 2.5-3.0 s, then released and resumed; MOVE_YD gained ends it.
    -- 1.0.21 (user): each strafe is held 2 s - right 2.0-4.0 s, left 4.0-6.0 s
    -- (right is released on the tick left starts; never both). The ladder waits
    -- for ou_end("nudged") although that is now after STILL_S.
    NUDGE = { JUMP_AT = 1.5, RIGHT_AT = 2.0, LEFT_AT = 4.0, STRAFE_S = 2.0 },
    nudge_window = nil,
    side = "left", best = nil, best_t = 0, dest = nil, idle_since = nil, run = nil, tries = 0 }
movement.OU = OU
local function ou_key(name)
    pcall(function() core.input[name]() end)
end
ou_end = function(why)
    local r = OU.run
    if not r then return end
    if r.kind == "turn" then
        if not r.fwd then ou_key(r.side == "left" and "turn_left_stop" or "turn_right_stop") end
        if r.fwd then ou_key("move_forward_stop") end
    elseif r.kind == "backup" then
        ou_key("move_backward_stop")
    elseif r.kind == "nudge" then
        if r.right and not r.right_off then ou_key("strafe_right_stop") end
        if r.left and not r.left_off then ou_key("strafe_left_stop") end
        ou_key("move_forward_stop")
    else
        ou_key(r.side == "left" and "strafe_left_stop" or "strafe_right_stop")
        ou_key("move_forward_stop")
    end
    N.resume("mf_unstick")
    OU.run, R.unsticking = nil, false
    -- 1.7.22: the walk goes on from the waypoint nearest the player, not from
    -- the one it was heading for before the try (often behind the player now)
    if why == "tried" or why == "nudged" then pcall(N.rejoin, "after the unstick try") end
    if r.kind == "nudge" then
        -- 1.0.13: the nudge is inside the stuck window - the window keeps its
        -- start (the ladder's rung follows at STILL_S if still stuck); the
        -- nudge's own sideways steps are not progress
        local nx, ny = R.here()
        OU.ax, OU.ay = nx, ny
        R.trail("move", "outdoor nudge: %s - walk resumed", tostring(why))
        return
    end
    OU.side = (r.side == "left") and "right" or "left"     -- still stuck next time: the other side
    -- the next window counts from the end of this try, from where it ended:
    -- the try's own strafe is not progress along the route
    OU.best_t, OU.best, OU.ax, OU.ay = R.now(), nil, nil, nil
    R.trail("move", "unstick (%s %s): %s - walk resumed", tostring(r.kind or "strafe"), tostring(r.side or ""), tostring(why))
end
movement.unstick_stop = ou_end
-- audit S2: while the fan's path queries run the walk is paused ("mf_unstick",
-- once), so the library's own ladder does not fire meanwhile; every way out
-- of the probe (next_point, the detour, the PROBE_MAX_S timeout, halt) resumes
-- that reason exactly once.
local function probe_start(t)
    OU.probing, OU.probe_t = true, t
    if OU.KEYS and not OU.probe_paused then              -- 1.1.0: no pause (= a stop) on Sentinel
        OU.probe_paused = true
        N.pause("mf_unstick")
    end
end
local function probe_stop()
    OU.probing = false
    if OU.probe_paused then
        OU.probe_paused = false
        N.resume("mf_unstick")
    end
end
OU_probe_stop = probe_stop
-- 1.0.14: the stuck-episode side of the nav memory (movement/memory): the
-- episode token (a cell is confirmed once per episode) and the confirm of the
-- episode's origin, mirrored to the session's zones as record_fail's are.
-- Bookkeeping only: the ladder below stays the only recovery.
local function ou_mem(fn, ...)
    local ok, MEM = pcall(require, "movement/memory")
    if ok and type(MEM) == "table" and type(MEM[fn]) == "function" then
        local okc, r = pcall(MEM[fn], ...)
        if okc then return r end
    end
    return nil
end
local function ou_confirm(ep, why)
    if not (R.finite(ep.x) and R.finite(ep.y) and R.finite(ep.z)) then return end
    local rec = ou_mem("confirm_episode", ep.x, ep.y, ep.z, why)
    if rec and type(N.mem_black) == "function" then pcall(N.mem_black, rec, why) end
end

--- 1.1.0: the stuck window - STILL_S with the key ladder, WATCH_S on Sentinel.
local function still_s() return OU.KEYS and OU.STILL_S or OU.WATCH_S end

local function outdoor_unstick(t)
    -- audit S2: the probe timeout first, before any early return below
    if OU.probing and t - (OU.probe_t or t) > OU.PROBE_MAX_S then probe_stop() end
    local r = OU.run
    if r and r.kind == "nudge" then
        -- 1.0.13: the outdoor nudge's timeline, from the stuck window's start
        if not N.busy() then return ou_end("the walk ended") end
        local s, NU = t - r.t0, OU.NUDGE
        -- 1.0.21: real movement ends the nudge only BEFORE the strafes - a 2 s
        -- strafe moves the player well past MOVE_YD by itself
        local px, py = R.here()
        if s < NU.RIGHT_AT and px and r.x and R.dist2(r.x, r.y, px, py) >= OU.MOVE_YD then
            OU.best_t = t                                -- real movement: a new window
            return ou_end("moving again")
        end
        if s >= NU.RIGHT_AT and not r.right then
            r.right = true
            ou_key("strafe_right_start")
        end
        if r.right and not r.right_off and s >= NU.RIGHT_AT + NU.STRAFE_S then
            r.right_off = true
            ou_key("strafe_right_stop")
        end
        if s >= NU.LEFT_AT and not r.left then
            r.left = true
            ou_key("strafe_left_start")
        end
        if r.left and not r.left_off and s >= NU.LEFT_AT + NU.STRAFE_S then
            r.left_off = true
            ou_key("strafe_left_stop")
            return ou_end("nudged")
        end
        return
    end
    if r and (r.kind == "turn" or r.kind == "backup") and not N.busy() then
        return ou_end("the walk ended")                 -- 1.8.7: as the strafe tries
    end
    if r and r.kind == "turn" then
        -- 1.8.7: a slight turn on the turn key, then forward
        if not r.fwd and t - r.t0 >= OU.TURN_S then
            ou_key(r.side == "left" and "turn_left_stop" or "turn_right_stop")
            ou_key("move_forward_start")
            r.fwd = t
        end
        if r.fwd and t - r.fwd >= OU.FWD_S then ou_end("tried") end
        return
    end
    if r and r.kind == "backup" then
        if t - r.t0 >= OU.BACK_S then ou_end("tried") end      -- 1.8.7: about 1 yd back
        return
    end
    if r then
        if not N.busy() then return ou_end("the walk ended") end
        for i = 1, #OU.JUMPS do
            if not r.jumped[i] and t - r.t0 >= OU.JUMPS[i] then
                r.jumped[i] = true
                ou_key("jump")
                ou_key("ascend_stop")      -- jump is JumpOrAscendStart
            end
        end
        if t - r.t0 >= OU.LEN then ou_end("tried") end
        return
    end
    local function reset()
        OU.best, OU.dest, OU.idle_since, OU.ax, OU.ay, OU.ep = nil, nil, nil, nil, nil, nil
        ou_mem("episode", nil)                             -- 1.0.14
    end
    if R.resting or R.backpedal_until or Lk.holding() or (R.npc_until or 0) > t or N.mode() == "portal" then
        return reset()
    end
    -- a walk restarting (follow_path windows, a repath) is idle for a moment:
    -- that is not the end of the walk
    if not N.busy() then
        OU.idle_since = OU.idle_since or t
        if t - OU.idle_since > OU.IDLE_OK then reset() end
        return
    end
    OU.idle_since = nil
    local me = R.me()
    if not me then return reset() end
    local okc, casting = pcall(function() return me:is_casting_spell() == true or me:is_channelling_spell() == true end)
    if okc and casting == true then OU.best_t = t return end      -- a cast holds the walk on purpose
    -- 1.8.7: indoors too (the user's turn ladder runs indoors and out)
    local oks, swim = pcall(function() return core.character.is_swimming() == true end)
    if oks and swim == true then return reset() end
    local x, y = R.here()
    local dx, dy = N.destination()
    if not x or not dx then return reset() end
    local dkey = string.format("%d|%d", math.floor(dx / 8), math.floor(dy / 8))
    if OU.dest ~= dkey then                                -- a new destination: a new count
        if N.detour_active() then
            OU.dest = dkey                                 -- (the detour keeps the goal; not new)
        else
            OU.dest, OU.best, OU.best_t, OU.ax, OU.ay, OU.ep = dkey, nil, t, nil, nil, nil
            ou_mem("episode", nil)                         -- 1.0.14
        end
    end
    -- 1.7.23: a detour leg is walking somewhere on purpose - not a stuck window
    -- 1.7.24: a path query that never answers does not hold the window for ever
    -- (audit S2: that timeout runs at the top of this function)
    if N.detour_active() or OU.probing then OU.best_t = t return end
    -- 1.1.0: Sentinel's own stuck recovery / re-path runs - the watchdog waits
    -- for it (never cuts it short)
    if not OU.KEYS then
        local fs = N.full_state() or ""
        if fs:find("recovering", 1, true) or fs:find("repathing", 1, true) or fs:find("awaiting_path", 1, true) then
            OU.best_t = t
            return
        end
    end
    local d = R.dist2(x, y, dx, dy)
    if d <= OU.ARRIVED_YD then OU.best, OU.best_t = d, t return end
    local moved = OU.ax and R.dist2(OU.ax, OU.ay, x, y) >= OU.MOVE_YD
    -- 1.7.23: the episode ends only on REAL progress past the stuck spot
    local ep = OU.ep
    if ep and (d < ep.best - OU.EP_GAIN or (R.dist2(ep.x, ep.y, x, y) > OU.EP_RADIUS and d < ep.best)) then
        R.trail("move", "stuck re-navigation: past the stuck spot after %d step(s) (%.0f yd to go)", ep.step, d)
        OU.ep, ep = nil, nil
        ou_mem("episode", nil)                             -- 1.0.14
        OU.side, OU.tries = "left", 0
    end
    if not OU.best or d < OU.best - OU.PROGRESS_YD or moved then
        OU.best, OU.best_t, OU.ax, OU.ay = d, t, x, y
        return
    end
    -- 1.0.13: the OUTDOOR NUDGE at JUMP_AT s of no progress, once per window
    if OU.KEYS and t - OU.best_t >= OU.NUDGE.JUMP_AT and t - OU.best_t < OU.STILL_S and OU.nudge_window ~= OU.best_t then
        local oki, ind = pcall(function() return me:is_indoors() == true end)
        if not (oki and ind == true) then
            OU.nudge_window = OU.best_t
            if R.turning then Pv.release("unstick") end
            N.pause("mf_unstick")
            ou_key("move_forward_start")
            ou_key("jump")
            ou_key("ascend_stop")                           -- jump is JumpOrAscendStart
            OU.run, R.unsticking = { kind = "nudge", t0 = OU.best_t, x = x, y = y }, true
            R.trail("move", "outdoors: no progress for %.1f s (%.0f yd to go) - jump, then strafe right / left",
                t - OU.best_t, d)
            return
        end
    end
    if t - OU.best_t < still_s() then return end
    if R.turning then Pv.release("unstick") end            -- a pivot loop is no reason to wait
    -- 1.7.23: the stuck episode and its next rung
    if not ep then
        local oki, ind = pcall(function() return me:is_indoors() == true end)
        local _, _, hz = R.here()
        -- 1.0.14: z and d0 for the stuck-area confirm (the player's own height)
        ep = { x = x, y = y, z = hz, d0 = d, best = d, step = 0, t0 = t, indoors = oki and ind == true }
        OU.ep = ep
        ou_mem("episode", t)
    end
    if d < ep.best then ep.best = d end
    ep.step = ep.step + 1
    local ladder = ep.indoors and OU.LADDER_INDOOR or OU.LADDER            -- 1.0.11
    if not OU.KEYS then ladder = OU.LADDER_SENTINEL end                   -- 1.1.0: no key rungs
    local rung = ladder[math.min(ep.step, #ladder)]     -- 1.7.24: the fan rung repeats
    OU.best_t = t                                          -- the next window counts from now
    if rung[1] == "repath" then
        -- 1.0.14: the first fresh-path rung CONFIRMS the episode's origin as a
        -- stuck area - still within EP_RADIUS of it, not EP_GAIN nearer the goal
        if not ep.recorded and R.dist2(ep.x, ep.y, x, y) <= OU.EP_RADIUS and d > ep.d0 - OU.EP_GAIN then
            ep.recorded = true
            ou_confirm(ep, "stuck episode: the fresh-path rung")
        end
        R.trail("move", "stuck re-navigation step %d: a fresh path from here (%.0f yd to go)", ep.step, d)
        N.replan_fresh("stuck " .. ep.step)
        return
    end
    if rung[1] == "fan" then
        -- 1.7.24 (user: "repathing should calculate the x, y and z and generate
        -- new paths until the player is un-stuck"): the next point of the
        -- episode's FAN round the stuck spot - angles either side of the path's
        -- direction, at growing radii - each made a full x, y, z and checked
        -- before it is walked:
        --   z     the mesh floor nearest the player's height (get_all_heights),
        --         else ours (1.1.0: no game ground probe);
        --   leg 1 a path from here to it, no longer than DETOUR_STRAIGHT x the
        --         straight line;
        --   leg 2 a path from it to the goal that does not run back through the
        --         stuck spot (none of its first points within FAN_KEEP_OFF yd);
        -- a point that fails is skipped at once; a passing one is walked
        -- (N.detour), then a fresh path to the goal. Every point tried is a new
        -- path; the fan used up, it widens and the ladder starts over.
        local fx, fy = dx - x, dy - y
        local ahead = type(N.path_ahead) == "function" and N.path_ahead(20) or {}
        for i = 2, #ahead do
            local p = ahead[i]
            if R.dist2(x, y, p.x, p.y) >= 3 then fx, fy = p.x - x, p.y - y break end
        end
        local l = math.sqrt(fx * fx + fy * fy)
        if l < 0.1 then return end
        fx, fy = fx / l, fy / l
        ep.fan_i = (ep.fan_i or 0) + 1
        local n_fan = #OU.FAN_ANGLES * #OU.FAN_RADII
        if ep.fan_i > n_fan then
            ep.fan_i, ep.step = 1, 0
            ep.round = (ep.round or 0) + 1
            -- audit S1: after two full rounds the fan stops (longstuck is the backstop)
            if ep.round >= 2 then
                R.trail("move", "stuck re-navigation: the fan is exhausted after %d rounds - walk stopped", ep.round)
                if not ep.recorded then                    -- 1.0.14: the origin, once
                    ep.recorded = true
                    ou_confirm(ep, "stuck episode: the fan gave up")
                end
                OU.ep = nil
                ou_mem("episode", nil)
                N.stop("stuck: fan exhausted")
                return
            end
            R.trail("move", "stuck re-navigation: every fan point tried - a wider fan (round %d), ladder again", ep.round + 1)
            OU.best_t = t - still_s()
            return
        end
        local ai = ((ep.fan_i - 1) % #OU.FAN_ANGLES) + 1
        local ri = math.floor((ep.fan_i - 1) / #OU.FAN_ANGLES) + 1
        local ang = math.rad(OU.FAN_ANGLES[ai])
        local yd = OU.FAN_RADII[ri] * (1 + 0.6 * (ep.round or 0))
        yd = math.min(yd, 35)                          -- audit N2: the detour is a plain move_to
        local ca, sa = math.cos(ang), math.sin(ang)
        local vx, vy = fx * ca - fy * sa, fx * sa + fy * ca            -- the direction turned by `ang`
        local _, _, pz = R.here()
        pz = pz or 0
        local cand = { x = x + vx * yd, y = y + vy * yd, z = pz }
        local label = string.format("step %d: %+d deg, %.0f yd", ep.step, OU.FAN_ANGLES[ai], yd)
        local function next_point(why)
            R.trail("move", "stuck re-navigation %s - %s, next point", label, tostring(why))
            probe_stop()                                         -- audit S2
            OU.best_t = R.now() - still_s()                      -- the next point at once
            ep.step = ep.step - 1                                -- still the fan rung
        end
        local function leg2()
            local sent2 = N.path_probe(cand, { x = dx, y = dy, z = select(3, N.destination()) or cand.z },
                function(points, ok)
                    if type(points) ~= "table" or #points < 2 or ok == false then return next_point("no path from it to the goal") end
                    if type(N.steep_at) == "function" and N.steep_at(points) then
                        return next_point("its path to the goal climbs steep ground")
                    end
                    for i = 1, math.min(#points, 12) do
                        if R.dist2(points[i].x, points[i].y, ep.x, ep.y) <= OU.FAN_KEEP_OFF then
                            return next_point("its path to the goal runs back through the stuck spot")
                        end
                    end
                    probe_stop()                                 -- audit S2
                    -- audit N2: a refused detour (too far, a cast...) is the next point
                    if not N.detour(cand, "stuck " .. label .. string.format(" (z %.1f)", cand.z)) then
                        next_point("the detour could not start")
                    end
                end)
            if not sent2 then next_point("the path query could not be sent") end
        end
        local function leg1()
            local sent1 = N.path_probe({ x = x, y = y, z = pz }, cand, function(points, ok)
                local len = 0
                if type(points) == "table" then
                    for i = 2, #points do len = len + R.dist2(points[i - 1].x, points[i - 1].y, points[i].x, points[i].y) end
                end
                if type(points) ~= "table" or #points < 2 or ok == false then return next_point("no path to it") end
                if len > yd * OU.DETOUR_STRAIGHT + 2 then return next_point(string.format("its path is %.0f yd long", len)) end
                -- 1.7.29: never a detour over steep ground
                if type(N.steep_at) == "function" and N.steep_at(points) then return next_point("its path climbs steep ground") end
                local e = points[#points]
                cand.x, cand.y, cand.z = e.x, e.y, e.z or cand.z         -- the mesh's own end point
                leg2()
            end)
            if not sent1 then next_point("the path query could not be sent") end
        end
        local function with_z(vals)
            local best = nil
            for i = 1, #(vals or {}) do
                local v = vals[i]
                v = tonumber(type(v) == "table" and v.z or v)
                if v and math.abs(v - pz) <= OU.FAN_DZ and (best == nil or math.abs(v - pz) < math.abs(best - pz)) then best = v end
            end
            -- 1.1.0: no game ground probe (guide rule 6) - no mesh floor near
            -- the player's height: ours, and Sentinel find_path snaps it
            cand.z = best or pz
            leg1()
        end
        probe_start(t)                                           -- audit S2
        if not (type(N.all_heights) == "function" and N.all_heights(cand, with_z)) then with_z(nil) end
        return
    end
    if rung[1] == "turn" or rung[1] == "backup" then
        -- 1.8.7: the walk paused ("mf_unstick"), a slight turn + forward, or 1 yd back
        N.pause("mf_unstick")
        OU.tries = OU.tries + 1
        if rung[1] == "turn" then
            ou_key(rung[2] == "left" and "turn_left_start" or "turn_right_start")
            OU.run = { kind = "turn", side = rung[2], t0 = t }
            R.trail("move", "no progress for %.0f s (%.0f yd to go) - step %d: a slight turn %s, then forward",
                OU.STILL_S, d, ep.step, rung[2])
        else
            ou_key("move_backward_start")
            OU.run = { kind = "backup", t0 = t }
            R.trail("move", "no progress for %.0f s (%.0f yd to go) - step %d: back up 1 yd", OU.STILL_S, d, ep.step)
        end
        R.unsticking = true
        return
    end
    OU.side = rung[2]
    N.pause("mf_unstick")
    ou_key("move_forward_start")
    ou_key(OU.side == "left" and "strafe_left_start" or "strafe_right_start")
    OU.tries = OU.tries + 1
    OU.run, R.unsticking = { side = OU.side, t0 = t, jumped = {} }, true
    R.trail("move", "outdoors: no progress for %.0f s (%.0f yd to go) - step %d: forward + %s with 3 jumps",
        OU.STILL_S, d, ep.step, OU.side)
end

-- 2026-10-25 (user: "Remove Raycast and traceline rules ... that Sentinel can use"): the
-- ray walk assistant (movement/trace.lua, Desktop\Helper trace.lua) - Sentinel walking with
-- no progress and the way ahead blocked: a low obstacle is jumped, a wall gets a Sentinel
-- avoidance zone (when this product has one); one context table reused every pulse
local TR_CTX = { avoid = N.avoid_area, jump = function() pcall(core.input.jump) end }
-- 2026-10-28 (user: "Always dismount when attempting to enter doorways"): the ray
-- helpers call this when the gap ahead admits the player but not the mounted body.
-- Mt.suppress inside Mt.dismount keeps us off the mount long enough to walk through.
TR_CTX.dismount = function() Mt.dismount(R.me(), "an entrance too low for the mount") end

-- A corridor much narrower than the rest of the path (Sentinel's corridor widths)
-- ahead of a mounted player: off the mount before it, as for a low doorway.
N.tight_hook = function(width, yards)
    local me = R.me()
    local ok, flying = pcall(function() return me:is_flying() end)
    if ok and flying == true then return end
    Mt.dismount(me, string.format("a narrow corridor %.0f yd ahead", yards or 0))
end

local function trace_tick(t)
    local mode = N.mode()
    local c = TR_CTX
    -- The legacy stall probe must not compete with Sentinel recovery, a
    -- pending path, or combat facing. Only an established travel leg owns it.
    local fs = N.full_state() or ""
    c.walking = N.busy() and mode ~= "portal" and mode ~= "combat" and mode ~= "swim"
        and not R.turning and not N.holding() and not N.leg_fresh()
        and fs == "navigating.following_path"
    if c.walking then
        c.no_jump = true -- Sentinel owns all jump/recovery input during its walk
        local me = R.me()
        c.mounted_flying = me ~= nil and select(2, pcall(me.is_flying, me)) == true
    end
    return TR.tick(t, c)
end

--- Once per frame (main.lua), before anything reads movement state.
function movement.pulse()
    local t = R.now()
    Lk.tick(t)
    N.pulse()
    AS.tick(t)                    -- local A* fallback: one ray-budgeted slice a frame
    -- 1.8.7: the indoor jump (1.7.8) is retired - the turn ladder above runs
    -- indoors too, and two of our own unsticks never act on one stuck
    outdoor_unstick(t)            -- 1.7.16
    trace_tick(t)                 -- 2026-10-25: the ray walk assistant
    Pv.tick(t)                 -- 3.2.0: sharp turn -> hold the walk, turn in place
    Z.prune(t)
    if t - snap_t >= SNAP_EVERY then build_snapshot(t) end
end

function movement.on_render() end

function movement.set_debug(on) R.debug_on = on == true end

function movement.owner()
    if C.in_combat_movement() then return "combat" end
    if N.busy() then return "nav" end
    return "none"
end

function movement.state()
    local s = N.full_state()                               -- 1.1.0: through movement/nav
    if s then return s end
    return N.busy() and "navigating" or "idle"
end

-- The GUI movement panel is drawn on the RENDER path, where no game call
-- may run (Sentinel-era docs: a game call inside the menu render crashed WoW
-- Forever). The snapshot is built on the update tick (movement.pulse, every
-- SNAP_EVERY s) and the panel only reads this cached table.
build_snapshot = function(t)
    local px, py, pz = R.here()
    local ground = px and TR.player_ground({x=px, y=py, z=pz}) or nil
    local coords = px and string.format("XYZ %.2f, %.2f, %.2f | ground Z %s | delta %s", px, py, pz,
        ground and string.format("%.2f", ground) or "unknown",
        ground and string.format("%+.2f", pz-ground) or "unknown") or "Position unavailable"
    if t - height_log_t >= 10 then
        height_log_t = t
        R.trail("height", "%s", coords)
    end
    local u = C.combat_unit()
    local d = nil
    if u then
        local me = R.me()
        if me then
            local ok, v = pcall(me.distance_to, me, u)
            if ok and type(v) == "number" then d = v end
        end
    end
    snap = {
        coordinates = coords,
        state = movement.state(),
        owner = movement.owner(),
        restriction = R.resting and "resting" or (R.backpedal_until and "backpedal" or nil),
        retreating = false,
        paused = R.resting == true,
        sentinel = N.busy(),
        -- 1.7.2 (R2.4): the server state, read here on the update tick
        nav = N.client() == nil and "missing" or (N.nav_ready() and "ready" or "down"),
        nav_why = N.unavailable(),                        -- 1.1.0: why Sentinel cannot navigate (GUI)
        nav_status = N.status_text(N.status()),           -- 1.7.0: live progress / zones / failures (GUI)
        quiet = t < (R.quiet_until or 0),
        target_dist = d,
    }
    snap_t = t
end

--- For the GUI movement panel: the cached snapshot (no game call).
function movement.debug_snapshot()
    return snap
end

-- ============================================================================
-- STRICT SURFACE
-- ============================================================================
local missing_reported = {}
setmetatable(movement, {
    __index = function(_, key)
        if type(key) == "string" and not missing_reported[key] then
            missing_reported[key] = true
            pcall(core.log_error, R.TAG .. " movement." .. key .. " does not exist (stale call site)")
        end
        return nil
    end,
})

return movement
