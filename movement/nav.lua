-- ============================================================================
-- Master Farmer - Forever Questing
-- movement/nav.lua - travel through Sentinel Navigation
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Product version: see version.lua
-- ============================================================================
-- 1.1.0 SENTINEL PORT (docs/SENTINEL_PORT_GUIDE.md; the reference travel layer
-- is restedXP_questing 4.7.0 movement/nav.lua - SENTINEL_API.md = the official
-- v0.0.8 page, SENTINEL_V024.md = what the installed v0.24 really does).
-- Every Sentinel call goes through movement/sentinel.lua (S.*). Sentinel plans
-- and walks its own path: this layer hands it destinations and reads how they
-- end. Sentinel Navigation / Sentinel are gone from this file: no find_path +
-- follow_path exact walk (movement/guide_path is retired), no 15 yd windows,
-- no input driver, no the Sentinel UI, no game height probes.
--
-- WALK = move_to(target, cb(success, reason)). A new destination while a walk
-- runs is another move_to - Sentinel re-plans without stopping (0.12 s,
-- recorded) - at most every RETARGET_GAP s (combat COMBAT_GAP s): one path
-- request a second, never per frame. The same destination (within SAME_DEST
-- yd) while walking is a no-op, so callers can ask every tick.
--
-- WALKS ARE OURS TO TRACK: a walk replaced by a newer move_to, or stopped,
-- gets NO callback (recorded). Each walk carries a token (cur.id); a newer
-- walk or a stop retires it and its callback, should one ever come, is
-- ignored. A walk the Sentinel UI ended (no callback) is closed by the pulse
-- from get_state().
--
-- HEIGHTS (RestedXP waypoints are x, y with a guessed z): an off-mesh target
-- costs ~6 s of library retries before Sentinel snaps it (recorded), so an
-- out-of-combat walk of FLOOR_FIRST yd or more asks the navmesh floors there
-- first (get_all_heights, one request per spot, nearest the guess) and walks
-- at that height. A walk that still ends "unreachable" tries another floor
-- there (retry_at_ground; 1.0.22 kept: floors near the player's own height
-- first - a cave floor at a cave mouth). The height found is kept (N.reach_z).
--
-- HOLDS: Sentinel has no pause / resume. A hold (a cast, a loot, a conjure)
-- stops the walk and remembers where it went; when the last hold lifts the
-- same destination is walked again. Destinations asked for during a hold
-- replace the remembered one. Sentinel steers its own corners and recovers
-- from being stuck by itself: the sharp-turn pivot holds no walk (Pv.HOLD
-- false) and movement.lua presses no unstick keys while a walk runs.
--
-- STOPS: never on a walk still waiting for its path or younger than
-- FRESH_LEG s (the 2.181.0 / 3.7.1 crash pattern: stopping a fresh leg came
-- right before game crashes). Such a stop is deferred to the pulse until the path is ready; a new walk meanwhile replaces it instead.
--
-- FAILURES: the reason of the last failed walk is kept (last_fail_reason /
-- last_fail_offmesh). "unreachable" twice at one spot in FAIL_WINDOW s
-- blacklists it (movement/zones); "server_timeout" backs off SERVER_BACKOFF s
-- and asks is_server_available() again.
--
-- NAV MEMORY (movement/memory, 1.9.0 / 1.0.14 bookkeeping kept): a walk that
-- Sentinel gave up stuck (max_stuck_exceeded) marks the player's spot a black
-- point, a twice re-planned corridor too; black points go to this session's
-- zones (N.mem_black) and a goal inside one is refused. The memory reads the
-- walk Sentinel follows (N.path_points / N.path_index) for its valid paths.
--
-- THE FOREVER SURFACE (movement.lua, quest/engine): waypoint_walk (one walk
-- per guide waypoint key), step_into (move_direct into a portal), path_ahead
-- (Sentinel's own path from its index), replan_fresh / rejoin (the current
-- destination walked again), detour (a point, then the destination),
-- all_heights (get_all_heights), steep_at (a client-side check of a point
-- list - Sentinel has no slope data), mem_black.
--
-- NO SENTINEL (library missing, no maps for this game version - only the WoW
-- Forever map set exists for this product): no movement at all, and the
-- reason is logged (once per reason). There is no straight-line fallback.
-- ============================================================================

local R = require("movement/core")
local Z = require("movement/zones")
local MT = require("movement/mount")         -- 3.8.0: mount for travel (the 1-60 way)
local MEM = require("movement/memory")       -- 1.9.0: black points (bookkeeping)
local S = require("movement/sentinel")       -- 1.1.0: the only Sentinel caller
local AS = require("movement/astar")         -- local A* + ray fallback for off-mesh targets (alongside Sentinel)

local N = {}

local SAME_DEST = 2.0          -- yd: the same destination
local RETARGET_GAP = 1.0       -- s between two travel retargets (one path request a second)
local COMBAT_GAP = 0.5         -- s between two combat retargets (a moving target)
local UNDERFOOT = 1.0          -- yd: a destination this close is reached
local QUIET_STOP = 0.3         -- s callers wait after a real stop (is_quiet)
local FLOOR_FIRST = 40         -- yd: farther travel walks ask the floors there first
local HEIGHT_SAME = 2.0        -- yd: a height this close to a tried one is the same
local HEIGHT_SCAN_HOLD = 10.0  -- s: a floor query with no answer holds new walks there no longer
local FAIL_WINDOW, FAIL_BLACKLIST = 120, 2
local REACH_TTL, REACH_TTL_BAD, REACH_GAP = 120, 45, 0.25
local REACH_TRUST_FAR = 150    -- yd: farther answers are guesses, never "unreachable"
local FRESH_LEG = 1.0          -- s: a leg younger than this is never stopped (3.7.1)
local LOST_WALK = 2.0          -- s: an idle client this long after our walk began = it ended
local WP_RECHECK = 5.0         -- s: an idle waypoint walk short of its point is sent again
local DETOUR_MAX_S = 15        -- s: a detour leg that takes longer is given up
local DETOUR_FAR = 40          -- yd: a detour point farther than this is refused
local CAVE_NEAR = 6            -- yd of the player's z: a floor at a cave mouth (1.0.22)

-- Sentinel failure reasons (doc): unreachable, server_timeout,
-- max_stuck_exceeded, max_repath_exceeded
local OFFMESH = { unreachable = true }
local SERVER_CODES = { server_timeout = true, server_down = true, map_not_loaded = true }
local SERVER_BACKOFF = 3.5
local GIVE_UP_CODES = { max_stuck_exceeded = true, max_repath_exceeded = true }
local HEIGHT_RETRY = { unreachable = true }
-- the nav memory: Sentinel's own stuck give-up is a black point at the player
-- ("unreachable" is a planning answer about the goal, not a stuck spot)
local STUCK_CODES = { max_stuck_exceeded = true }

-- the walk this layer asked for
local cur = { id = 0, x = nil, y = nil, z = nil, mode = nil, t = 0, route = nil, done = false }
local fail = { reason = nil, offmesh = false, t = 0 }
local fails_at = {}            -- dest key -> { n, t }
local zfix = {}                -- dest key -> corrected z
local zscan = {}               -- dest key -> { tried = { z, ... }, t, list, asking }
local terrain_guard = { next_t = 0, key = nil, tries = 0, blocked_until = 0 }
local blocked_terrain, orbit = {}, {}
local escape_poll = nil
local stats = { issued = 0, refused = 0, floors = 0, deferred_stops = 0 }
N.stats = stats
local stop_req = nil           -- { t, reason } a stop waiting for a safe moment
local held = { reasons = {}, dest = nil }
local wp_walk = { key = nil, t = -1e9, failed = nil }   -- 1.4.0: one walk per guide waypoint key
-- 2026-11-15 NEXT-WAYPOINT HINT (see N.hint_next): the quest engine says which
-- waypoint it walks AFTER the current one; `hint` is that word, `hand` the
-- hand-over once the walk to it was started before the current waypoint ended.
local hint, hand = nil, nil
local det = nil                -- 1.7.23: { x, y, z, dest = { x, y, z, mode, route }, id, until_t }

-- fails_at / zfix / zscan are keyed per destination and would grow for a whole
-- session; past CACHE_MAX keys each is emptied (all are re-learnt).
local CACHE_MAX = 256
local cache_n = { fails = 0, zfix = 0, zscan = 0 }
local function cache_put(tbl, which, k, v)
    if tbl[k] == nil then
        cache_n[which] = cache_n[which] + 1
        if cache_n[which] > CACHE_MAX then
            for key in pairs(tbl) do tbl[key] = nil end
            cache_n[which] = 1
        end
    end
    tbl[k] = v
end

-- ----------------------------------------------------------------------------
-- the client
-- ----------------------------------------------------------------------------
local warned = nil             -- the last "no navigation" reason logged

--- Sentinel's shared client, or nil: the library is missing, or this game
--- version has no maps on the server (the launcher says so in MASTER_FARMER.nav).
function N.client()
    local info = S.info()
    local why = nil
    if info.kind ~= "sentinel" then
        why = "not loaded through Master Farmer's Sentinel entry - the bot will not move"
    elseif not info.supported then
        why = "Sentinel navigation has no maps for this game version - the bot will not move"
    end
    local c = nil
    if not why then
        c = S.client()
        if not c then why = "the Sentinel Navigation library is not loaded - enable it and reload" end
    end
    if why then
        if warned ~= why then
            warned = why
            R.log(why)
        end
        return nil
    end
    warned = nil
    return c
end

--- Why the bot cannot navigate now (for the GUI), or nil.
function N.unavailable() return S.unavailable() end

-- 1.7.4 Sentinel Navigation driver claim: Sentinel has no driver setting and its
-- UI owns the tuning - kept as no-ops so the callers (gui Start / Stop,
-- mapwalk, unload) stay as they are.
function N.want_input_driver(_) end
function N.driver_claimed() return false end
function N.release_driver_now() end

local function key_of(x, y)
    return string.format("%d|%d", math.floor(x / 4), math.floor(y / 4))
end

-- Temporary hazards belong to a world, and goal holds to a specific floor.
local function guard_context()
    local map, instance = MEM.ctx()
    local world = tostring(map) .. "|" .. tostring(instance)
    if terrain_guard.world ~= world then
        terrain_guard = {world=world,next_t=0,blocked_until=0}
        blocked_terrain, orbit = {}, {}
        fails_at, zfix, zscan = {}, {}, {}
        cache_n = {fails=0,zfix=0,zscan=0}
    end
    return world
end
local function guard_blocked(x,y,z)
    guard_context()
    return terrain_guard.key == key_of(x,y)
        and type(z)=="number" and type(terrain_guard.goal_z)=="number"
        and math.abs(z-terrain_guard.goal_z)<2
        and R.now()<terrain_guard.blocked_until
end

-- Collapse only straight, level/constant-grade runs. Preserve every bend and
-- height change; cap each ray span at two yards. Dense server points therefore
-- do not consume the entire ray budget in the first few feet.
local function guard_points(points)
    local out = {}
    for _,p in ipairs(points) do
        local a,b=out[#out-1],out[#out]
        local merge=false
        if a and b then
            local dx,dy,dz=p.x-a.x,p.y-a.y,p.z-a.z
            local length2=dx*dx+dy*dy+dz*dz
            if length2>0 and length2<=4 then
                local u=((b.x-a.x)*dx+(b.y-a.y)*dy+(b.z-a.z)*dz)/length2
                local ex,ey,ez=b.x-a.x-u*dx,b.y-a.y-u*dy,b.z-a.z-u*dz
                merge=u>=0 and u<=1 and ex*ex+ey*ey+ez*ez<0.000001
            end
        end
        if merge then out[#out]=p else out[#out+1]=p end
    end
    return out
end
N._guard_points = guard_points

local function corrected_z(x, y, hint)
    local e = zfix[key_of(x, y)]
    if e and (math.abs(hint - e.hint) <= 2 or math.abs(hint - e.z) <= 2) then return e.z end
end


-- ----------------------------------------------------------------------------
-- gates: who may start a walk now
-- ----------------------------------------------------------------------------
--- Why travel is refused now, or nil. Combat owns the player while a fight
--- asks for it every tick (movement/combat sets R.combat_until); a rest or a
--- backpedal holds everything.
function N.refusal()
    if R.resting then return "resting" end
    if R.backpedal_until then return "backpedal" end
    if (R.combat_until or 0) > R.now() then return "combat" end
    -- 3.0.2: standing at an NPC (movement.interact) - its window / gossip /
    -- purchase gets NPC_HOLD s before any walk starts again
    if (R.npc_until or 0) > R.now() then
        -- the game answered "too far away": nothing opened, the caller walks
        -- up to the NPC - the hold is lifted for that walk
        local ev = package.loaded["events"]
        if R.npc_ev_t and type(ev) == "table" and type(ev.too_far_since) == "function"
            and ev.too_far_since(R.npc_ev_t) == true then
            R.npc_until, R.npc_ev_t = nil, nil
            return nil
        end
        return "npc"
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- state
-- ----------------------------------------------------------------------------
--- Sentinel is navigating (is_moving: true only while "navigating").
function N.busy()
    local c = N.client()
    return c ~= nil and S.moving(c)
end

function N.destination()
    if cur.x and N.busy() then return cur.x, cur.y, cur.z end
    return nil
end

function N.mode() return N.busy() and cur.mode or nil end

--- Sentinel's dotted state, or nil.
function N.full_state()
    local c = N.client()
    return c and S.full_state(c) or nil
end

--- The path Sentinel follows (vec3[]) and the index being walked to, or nil.
function N.path_points()
    local c = N.client()
    return c and S.current_path(c) or nil
end
function N.path_index()
    local c = N.client()
    return c and S.path_index(c) or nil
end

-- 1.9.0: a black point (movement/memory) also goes to this session's zones at
-- its radius, so the walk refuses the spot at once; the file is the copy that
-- survives a reload
-- 2026-11-15 (nav audit 11): the same spot is also queued as a Sentinel
-- avoidance zone, applied by N.pulse once the player is clear of it (a zone
-- on the player's own feet could only confuse the next path).
local stuck_zone = {}
local function mem_black(rec, why)
    if rec and MEM.active(rec) then
        Z.blacklist_area({ x = rec.cx, y = rec.cy, z = rec.cz }, rec.radius, "stuck here (" .. tostring(why) .. ")")
        stuck_zone[#stuck_zone + 1] = { x = rec.cx, y = rec.cy, z = rec.cz, r = math.max(2, math.min(rec.radius or 2, 6)), t = R.now() }
        if #stuck_zone > 8 then table.remove(stuck_zone, 1) end
    end
    return rec
end
N.mem_black = mem_black                  -- 1.0.14: movement.lua's stuck-episode confirm

--- `walked`: a walk ENDED with `code` (a move_to / follow_path callback), not a
--- planning answer - only then can the player's spot be a black point.
local function record_fail(code, x, y, z, walked)
    if walked then
        local px, py, pz = R.here()
        if px and STUCK_CODES[code] then
            mem_black(MEM.confirm_stuck(px, py, pz, code), code)   -- 1.0.14: once per cell per episode
        elseif px and code == "max_repath_exceeded" and (x or cur.x) then
            mem_black(MEM.note_replan(px, py, pz, x or cur.x, y or cur.y), code)
        end
    end
    fail.reason, fail.offmesh, fail.t = tostring(code or "failed"), OFFMESH[code] == true, R.now()
    if SERVER_CODES[code] then fail.server_until = R.now() + SERVER_BACKOFF end
    fail.give_up = GIVE_UP_CODES[code] == true
    if not x then return end
    local k = key_of(x, y)
    local e = fails_at[k]
    local t = R.now()
    if not e or (t - e.t) > FAIL_WINDOW or not e.z or not z or math.abs(e.z-z)>=2 then e = { n = 0, t = t, z = z } cache_put(fails_at, "fails", k, e) end
    e.n, e.t = e.n + 1, t
    if e.n >= FAIL_BLACKLIST and fail.offmesh then
        Z.blacklist_area({ x = x, y = y, z = z }, 6, "no path there (" .. fail.reason .. ")")
        fails_at[k] = nil
    end
end

-- ----------------------------------------------------------------------------
-- fresh legs (3.7.1, crash logs 2026-10-16 17:30 - 18:06)
-- ----------------------------------------------------------------------------
local FALSE_ARRIVAL = 5.0      -- yd: an "arrived" farther from the goal is not one

--- Seconds since the running leg started (huge when none runs).
function N.leg_age()
    if not cur.leg_t or not N.busy() then return 1e9 end
    return R.now() - cur.leg_t
end
function N.leg_fresh() return N.leg_age() < FRESH_LEG end

local function indoors()
    local me = R.me()
    local ok, inside = pcall(function() return me and me:is_indoors() end)
    return ok and inside == true
end

local function same_destination(x, y, z)
    return cur.x and R.dist2(cur.x, cur.y, x, y) <= (indoors() and 1 or SAME_DEST)
        and math.abs((cur.z or z) - z) < 2
end

--- An "arrived" far from the goal is not counted (logged once per leg).
function N.false_arrival(x, y, z)
    local hx, hy, hz = R.here()
    if not hx or not x then return false end
    local d = R.dist2(hx, hy, x, y)
    local dz = z and hz and math.abs(hz - z) or 0
    if d <= (indoors() and 2.5 or FALSE_ARRIVAL) and dz <= 3 then return false end
    R.trail("nav", "arrival rejected: %.1f yd horizontal, %.1f yd vertical from (%.1f, %.1f, %.1f); player z %.1f",
        d, dz, x, y, z or hz or 0, hz or 0)
    return true
end

-- ----------------------------------------------------------------------------
-- route helpers (pure: a point list and the player's x, y)
-- ----------------------------------------------------------------------------
-- 1.7.22 PICK UP THE PATH WHERE THE PLAYER IS: the point nearest the player
-- within [lo, hi]; when the player is already past it (nearer the next point
-- than it is), the next one. Used for a recorded route (follow_route).
local function pickup_index(pts, lo, hi)
    if type(pts) ~= "table" or #pts == 0 then return 1 end
    lo = math.max(1, math.floor(lo or 1))
    hi = math.min(#pts, math.floor(hi or #pts))
    local x, y = R.here()
    if not x or lo > hi then return lo end
    local best, bd = nil, nil
    for i = lo, hi do
        local p = pts[i]
        if type(p) == "table" and p.x then
            local d = R.dist2(x, y, p.x, p.y)
            if bd == nil or d < bd then best, bd = i, d end
        end
    end
    if not best then return lo end
    local p, n = pts[best], pts[best + 1]
    if n and R.dist2(x, y, n.x, n.y) < R.dist2(p.x, p.y, n.x, n.y) then best = best + 1 end
    return best
end
N._pickup_index = pickup_index

-- 1.0.21 THE WAYPOINT IN FRONT: the nearest SEGMENT (i, i+1) in [lo, hi] (the
-- player projected onto it) and its END, i + 1 - the point still ahead; point
-- i itself only when the projection is ON i. Used by N.rejoin on a recorded
-- route (never the point behind).
local function front_index(pts, lo, hi)
    if type(pts) ~= "table" or #pts == 0 then return 1 end
    lo = math.max(1, math.floor(lo or 1))
    hi = math.min(#pts, math.floor(hi or #pts))
    if lo >= hi then return math.max(1, math.min(lo, #pts)) end
    local x, y = R.here()
    if not x then return lo end
    local best, bd, bt = nil, nil, nil
    for i = lo, hi - 1 do
        local a, b = pts[i], pts[i + 1]
        if type(a) == "table" and type(b) == "table" and a.x and b.x then
            local vx, vy = b.x - a.x, b.y - a.y
            local L = vx * vx + vy * vy
            local t = L > 0 and (((x - a.x) * vx + (y - a.y) * vy) / L) or 0
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
            local d = R.dist2(x, y, a.x + t * vx, a.y + t * vy)
            if bd == nil or d < bd then best, bd, bt = i, d, t end
        end
    end
    if not best then return lo end
    if bt <= 0 then return best end
    return best + 1
end
N._front_index = front_index

--- 1.0.23: is the player at (px, py) CLEAR of stuck disk r on the way to (gx, gy)
--- - radius + VALID_CLEAR yd from it and nearer the goal than it is?
local function clear_of(r, px, py, gx, gy)
    if not (r and px and gx) then return true end
    return R.dist2(px, py, r.cx, r.cy) >= r.radius + MEM.VALID_CLEAR
        and R.dist2(px, py, gx, gy) < R.dist2(r.cx, r.cy, gx, gy)
end
N._clear_of = clear_of

-- 1.7.29 STEEP GROUND: Sentinel gives no slope data, so this is a client-side
-- check of a point list with heights (a Sentinel find_path answer): more than
-- about 42 deg up (rise / run > UP), about 45 deg down (DOWN), or a STEP_DZ
-- climb in under a yard. The stuck fan (movement.lua) refuses a detour over
-- steep ground with it (N.steep_at). Nothing re-plans a Sentinel walk round
-- steep ground: Sentinel's own path is walked.
-- Kharanos shop stairs measure about 0.84 rise/run on the mesh. A 0.7
-- threshold rejected walkable steps and created a permanent retry loop.
local TM = R.TERRAIN                      -- the shared terrain model (movement/core)
local ST = { UP = R.TERRAIN.UP, UP_IN = R.TERRAIN.UP_IN, DOWN = R.TERRAIN.DOWN, MIN_RUN = R.TERRAIN.MIN_RUN,
    STEP_DZ = R.TERRAIN.STEP_DZ }
N.STEEP = ST

-- 1.28.146 GHOSTS FALL FOR FREE. A dead player takes no fall damage, so a
-- steep descent or a drop is no hazard on a corpse run (log 2026-11-06: 7 of
-- 38 slope vetoes were descents, each costing a recovery cycle). Every ASCENT
-- limit stays: a ghost cannot climb a wall. Read at most twice a second -
-- ST.grade / ST.first_steep run over whole point lists.
local ghost_cache = { t = -1e9, v = false }
local function ghost_now()
    local t = R.now()
    if t - ghost_cache.t >= 0.5 or t < ghost_cache.t then
        ghost_cache.t = t
        local ok, v = pcall(function() return R.me():is_ghost() end)
        ghost_cache.v = ok and v == true
    end
    return ghost_cache.v
end
N.ghost_now = ghost_now

function ST.grade(a, b, inside)
    if inside == nil then inside = indoors() end
    local up = inside and ST.UP_IN or ST.UP
    local run = R.dist2(a.x, a.y, b.x, b.y)
    local dz = (b.z or 0) - (a.z or 0)
    if run >= ST.MIN_RUN then
        local g = dz >= 0 and dz / run or (-dz / run) * (ST.UP / ST.DOWN)
        return g, dz >= 0 and dz/run > up
            or (dz < -ST.STEP_DZ and -dz/run > ST.DOWN and not ghost_now())
    end
    if dz > ST.STEP_DZ or (dz < -ST.STEP_DZ and not ghost_now()) then return 99, true end   -- a wall to climb, not a step
    return 0, false
end
--- The first steep stretch of `points`: its index (points[i] -> points[i+1]), or nil.
function ST.first_steep(points, inside, progress_check)
    if type(points) ~= "table" then return nil end
    if inside == nil then inside = indoors() end
    -- Indoor risers are judged across three yards of stair treads. Keep
    -- immediate vertical-wall and downhill checks; never relax cliff drops.
    -- Keep enough dense nodes to detect a sustained descent after allowing
    -- an isolated <=2 yard step; a one-yard window could hide that descent.
    local window,up = 3, inside and ST.UP_IN or ST.UP
    local ghost = ghost_now()
    local function must_reject(a,b,run)
        local rise=b.z-a.z
        -- Preflight may approach a short moderate ascent that the live
        -- guard already permits ONLY while travel makes progress.
        -- It does not grant a descent, long-rise, or stalled-walk exemption.
        return not (progress_check and run>=1 and rise>0 and rise<=6 and rise/run<=ST.UP_IN)
    end
    local first,run = 1,0
    for i=1,#points-1 do
        local a,b=points[i],points[i+1]
        if type(a)=="table" and type(b)=="table" and a.z and b.z then
            local edge=R.dist2(a.x,a.y,b.x,b.y)
            local dz=b.z-a.z
            local _,steep=ST.grade(a,b,inside)
            if steep and (not inside or dz<=0 or edge>=window
                or (edge<ST.MIN_RUN and dz>ST.STEP_DZ)) and must_reject(a,b,edge) then return i,i+1 end
            run=run+edge
            while first<i do
                local p,q=points[first],points[first+1]
                local n=R.dist2(p.x,p.y,q.x,q.y)
                if run-n<window then break end
                run,first=run-n,first+1
            end
            local rise=b.z-points[first].z
            if ((run>=window and rise>up*run)
                or (not ghost and run>=ST.MIN_RUN and -rise>ST.STEP_DZ and -rise>ST.DOWN*run)
                or (run<ST.MIN_RUN and (rise>ST.STEP_DZ or (not ghost and -rise>ST.STEP_DZ)))
                or (i==#points-1 and run>=ST.MIN_RUN and rise>up*run))
                and must_reject(points[first],b,run) then return first,i+1 end
        else first,run=i+1,0 end
    end
    return nil
end
N.steep_at = ST.first_steep

-- Mesh clearance varies between nodes. Before rejecting a short span,
-- sample its actual floor while preserving every bend in the original path.
-- Only nearby surfaces qualify: never snap a cave path to another level.
function ST.measured_span(points,first,last,inside)
    local a,b=points[first],points[last]
    if not a or not b or math.abs(b.z-a.z)>6 then return nil end
    local trace=require("movement/trace")
    local samples,walked={},0
    for n=first,last-1 do
        local p,q=points[n],points[n+1]
        local run=R.dist2(p.x,p.y,q.x,q.y)
        walked=walked+run
        if walked>8 then return nil end
        local count=math.max(1,math.ceil(run))
        for j=n==first and 0 or 1,count do
            if #samples>=24 then return nil end
            local u=j/count
            local s={x=p.x+(q.x-p.x)*u,y=p.y+(q.y-p.y)*u,z=p.z+(q.z-p.z)*u}
            local floor=trace.player_ground(s,1.5)
            if not R.finite(floor) or math.abs(floor-s.z)>1.5 then return nil end
            s.z=floor;samples[#samples+1]=s
        end
    end
    if ST.first_steep(samples,inside,true) then return nil end
    local corrected={}
    for n=1,first-1 do corrected[#corrected+1]=points[n] end
    for _,p in ipairs(samples) do corrected[#corrected+1]=p end
    for n=last+1,#points do corrected[#corrected+1]=points[n] end
    return corrected
end

function ST.preflight_path(points)
    for attempt=1,8 do
        local first,last=ST.first_steep(points,nil,true)
        if not first then return points end
        local measured=ST.measured_span(points,first,last)
        if not measured then return points end
        points=measured
    end
    return points
end

-- ----------------------------------------------------------------------------
-- heights: the navmesh floors at a spot
-- ----------------------------------------------------------------------------
local function swimming()
    local ok, v = pcall(function() return core.character.is_swimming() end)
    return ok and v == true
end

--- 1.0.22: the heights to try at a spot other than the failed `z`:
--- floors within CAVE_NEAR yd of the player's own height first (a cave floor
--- at its mouth, not the hill over it), then the rest nearest `z`. Floors
--- within 1 yd of `z` or of each other are one. (1.1.0: mesh floors only - no
--- game ground probe.)
local function order_floors(vals, z)
    local _, _, hz = R.here()
    local floors, list = {}, {}
    for i = 1, #(vals or {}) do
        local v = vals[i]
        if type(v) == "table" then v = v.z or v.height end
        v = tonumber(v)
        if R.finite(v) and math.abs(v) < 20000 then floors[#floors + 1] = v end
    end
    table.sort(floors, function(a, b) return math.abs(a - z) < math.abs(b - z) end)
    local function add(v)
        if math.abs(v - z) <= 1.0 then return end
        for i = 1, #list do if math.abs(list[i] - v) <= 1.0 then return end end
        list[#list + 1] = v
    end
    if hz then
        for i = 1, #floors do if math.abs(floors[i] - hz) <= CAVE_NEAR then add(floors[i]) end end
    end
    for i = 1, #floors do add(floors[i]) end
    return list
end

--- The floors at (x, y), asked once per spot per FAIL_WINDOW s: cb(list, st).
--- True when the list is known or the query went out.
local function floors_for(c, k, x, y, z, cb)
    local st = zscan[k]
    if st and (R.now() - st.t) > FAIL_WINDOW then st = nil end
    if not st then
        st = { tried = {}, t = R.now(), list = nil, asking = false, waiting = {} }
        cache_put(zscan, "zscan", k, st)
    end
    if st.list then cb(st.list, st) return true end
    st.waiting[#st.waiting + 1] = cb
    if st.asking then return true end
    st.asking = true
    stats.floors = stats.floors + 1
    local sent = S.floors(c, { x = x, y = y, z = z }, function(list)
        st.asking, st.list = false, list
        local w = st.waiting
        st.waiting = {}
        for i = 1, #w do pcall(w[i], list, st) end
    end)
    if not sent then
        st.asking, st.list, st.waiting = false, {}, {}
        cb(st.list, st)
    end
    return true
end

--- The first floor of `cands` not tried at this spot yet, or nil.
local function untried(st, cands)
    for i = 1, #cands do
        local v, fresh = cands[i], true
        for j = 1, #st.tried do
            if math.abs(v - st.tried[j]) <= HEIGHT_SAME then fresh = false break end
        end
        if fresh then return v end
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- issuing walks
-- ----------------------------------------------------------------------------
local issue_walk

-- LOCAL A* FALLBACK (movement/astar, alongside Sentinel): a walk Sentinel ends
-- "arrived" short of its goal or "unreachable", with the goal within AS.MAX_YD
-- of the player, is handed to the local grid search; its path is walked leg by
-- leg (N.astar_leg, Sentinel move_direct). On A* failure the old outcome is
-- recorded (the place is marked unreachable), so the engine carries on.
local function astar_try(x, y, z, mode, code)
    if mode == "combat" or mode == "astar" or mode == "swim" or mode == "portal" then return false end
    local rec = (code == "arrived_short") and "unreachable" or code
    return AS.start({ x = x, y = y, z = z }, function(ok, why)
        if ok then
            fail.reason, fail.offmesh = nil, false
            return
        end
        record_fail(rec, x, y, z, mode ~= "combat")
    end)
end

--- "unreachable" at (x, y, z): walk again at another floor found there.
--- True when a retry is under way (it reports the failure itself).
local function retry_at_ground(c, id, x, y, z, code, mode)
    if mode == "npc" or mode == "corpse" then return false end -- Observed destination floors are authoritative.
    if swimming() then return false end          -- R9.2 (the floor query answers the bed)
    local k = key_of(x, y)
    cur.scanning, cur.scan_t = id, R.now()
    floors_for(c, k, x, y, z, function(list, st)
        if cur.scanning == id then cur.scanning = nil end
        st.tried[#st.tried + 1] = z
        if cur.id ~= id then return end           -- superseded meanwhile (the list is kept)
        local hz = untried(st, order_floors(list, z))
        if hz then
            cache_put(zfix, "zfix", k, { z = hz, hint = z })
            R.trail("nav", "(%.0f, %.0f): %s at z %.1f - walking again at a floor there, z %.1f (%d found)",
                x, y, tostring(code), z, hz, #list)
            issue_walk(c, x, y, hz, mode)
        else
            if not st.spent then
                st.spent = true
                R.trail("nav", "(%.0f, %.0f): no floor with a path found (%d found) - %s", x, y, #list, tostring(code))
            end
            if astar_try(x, y, z, mode, code) then return end                  -- local A* fallback
            record_fail(code, x, y, z, mode ~= "combat")
            if wp_walk.id == id then wp_walk.failed = tostring(code) end
        end
    end)
    return true
end

-- PRECOMPUTED PATHS (user, 2026-11-15: "use follow_path with precomputed paths
-- instead of move_to"; session log 2026-11-15 11:48, v1.28.147: 68 path
-- segments, 59 "walking again", every 2.6 s). A move_to makes Sentinel go
-- awaiting_path and ask its server AFTER the walk is issued; here the path is
-- planned FIRST (plan_route - planning only, nothing walks, the player keeps
-- running the old walk meanwhile), audited for steep ground (a steep span becomes
-- an avoidance zone and the path is planned again), and only then handed to
-- Sentinel as follow_path(waypoints) - a path it already has, no server wait.
--   * re-generation (a zone, a hazard, the loop breaker): N.regen plans a fresh
--     path from where the player is NOW and swaps it in (follow_path again) while
--     the old one is still being walked;
--   * a path that ends short of the goal (a partial plan): the horizon (LA) plans
--     the continuation from the path's END and swaps in old-remainder + new;
--   * anything the plan cannot answer (no path, an error, 3 s with no reply, no
--     plan_route in the library): the walk is a plain move_to, exactly as before.
-- Walks of 15+ yd in the "move" and "guide" modes only; short hops, combat, NPC,
-- corpse, portal, swim, A* and recorded-route walks are not touched.
N.PRECOMPUTE = true
local PRE = { MIN_YD = 15, WAIT_S = 3.0, TRIES = 2, REGEN_GAP = 1.5, EXTEND_MIN = 3.0, MODES = { move = true, guide = true } }
N.PRE = PRE

--- The planned points from the one nearest the player on (the point the player
--- already stands on is dropped), as plain {x, y, z}.
local function pre_trim(points)
    local hx, hy = R.here()
    local first = 1
    if hx then
        local best, bd = 1, math.huge
        for i = 1, #points do
            local d = R.dist2(hx, hy, points[i].x, points[i].y)
            if d < bd then best, bd = i, d end
        end
        first = (bd < 2 and best < #points) and best + 1 or best
    end
    local out = {}
    for i = first, #points do out[#out + 1] = { x = points[i].x, y = points[i].y, z = points[i].z } end
    return out
end

--- Start walk `id` to (x, y, z) as plan -> audit -> follow_path. True when the
--- plan request went out (the reply starts the walk, or falls back to move_to);
--- false when this walk is not eligible (the caller issues the move_to).
local function pre_start(c, id, x, y, z, finished)
    if not N.PRECOMPUTE or not PRE.MODES[cur.mode or "move"] or swimming() then return false end
    local hx, hy = R.here()
    if not hx or R.dist2(hx, hy, x, y) < PRE.MIN_YD then return false end
    local goal = { x = x, y = y, z = z }
    local st = { id = id, done = false, started = false, planning = false, tries = 0, t0 = R.now(), regen_t = -1e9 }
    local request
    local function fallback(why)
        if st.done or cur.id ~= id then return end
        st.done = true
        if cur.scanning == id then cur.scanning = nil end
        stats.pre_fallbacks = (stats.pre_fallbacks or 0) + 1
        R.trail("nav", "precomputed path unavailable (%s) - Sentinel plans this walk itself", tostring(why))
        local sent = S.move_to(c, goal, finished)
        if not sent then cur.done = true end
    end
    st.fallback = fallback
    local function launch(points)
        local list = pre_trim(points)
        if #list == 0 then return fallback("empty plan") end
        if not S.follow_path(c, list, finished) then return fallback("follow_path refused") end
        local first = not st.started
        st.started = true
        cur.leg_t = R.now()
        if first then
            stats.pre_walks = (stats.pre_walks or 0) + 1
            R.trail("nav", "precomputed path: %d points planned in %.2f s, walked with follow_path", #list, R.now() - st.t0)
        else
            stats.pre_regens = (stats.pre_regens or 0) + 1
        end
    end
    request = function(initial)
        st.tries = st.tries + 1
        local fx, fy, fz = R.here()
        if not fx then return fallback("no position") end
        st.planning, st.plan_t = true, R.now()
        local sent = S.plan_probe(c, { x = fx, y = fy, z = fz }, goal, function(points)
            if cur.id ~= id or st.done then return end
            st.planning = false
            if initial and cur.scanning == id then cur.scanning = nil end
            if type(points) ~= "table" or #points < 2 then
                if st.started then return end            -- a swap that found nothing: the old path runs on
                return fallback("no plan")
            end
            st.in_reply = true
            local pts = guard_points(points)
            local i, e = ST.first_steep(pts, indoors(), true)
            local zoned = false
            if i and st.tries <= PRE.TRIES then
                zoned = N.zone_span(pts[i], pts[e or i + 1], "unsafe slope") == "new"
                if zoned then
                    R.trail("nav", "plan audit: steep span (rise %.1f / run %.1f) - zone, planning again",
                        pts[(e or i + 1)].z - pts[i].z, R.dist2(pts[i].x, pts[i].y, pts[e or i + 1].x, pts[e or i + 1].y))
                end
            end
            st.in_reply = false
            if zoned then return request(initial) end
            launch(points)
        end)
        if not sent then st.planning = false return fallback("plan not sent") end
        if initial then cur.scanning, cur.scan_t = id, R.now() end
    end
    --- re-generation: a fresh path from where the player stands, swapped in
    st.again = function(why)
        if st.done or not st.started or st.in_reply or cur.id ~= id then return false end
        if st.planning and R.now() - (st.plan_t or 0) < PRE.WAIT_S then return false end
        if R.now() - st.regen_t < PRE.REGEN_GAP then return false end
        st.regen_t, st.tries = R.now(), 0
        R.trail("nav", "path re-generated while walking (%s)", tostring(why))
        request(false)
        return true
    end
    --- the continuation of a path that ends short of the goal, from its END
    st.extend = function()
        if st.done or not st.started or st.in_reply or cur.id ~= id or st.no_extend then return false end
        if st.planning and R.now() - (st.plan_t or 0) < PRE.WAIT_S then return false end
        local ahead = N.path_ahead(300)
        if #ahead < 2 then return false end
        local last = ahead[#ahead]
        st.planning, st.plan_t = true, R.now()
        local sent = S.plan_probe(c, last, goal, function(points)
            st.planning = false
            if cur.id ~= id or st.done then return end
            if type(points) ~= "table" or #points < 2 then st.no_extend = true return end
            local nl = points[#points]
            if R.dist2(nl.x, nl.y, last.x, last.y) < PRE.EXTEND_MIN then st.no_extend = true return end
            local now_ahead = N.path_ahead(300)
            local list = {}
            for k = 2, #now_ahead do list[#list + 1] = { x = now_ahead[k].x, y = now_ahead[k].y, z = now_ahead[k].z } end
            for k = 2, #points do list[#list + 1] = { x = points[k].x, y = points[k].y, z = points[k].z } end
            if S.follow_path(c, list, finished) then
                stats.pre_extends = (stats.pre_extends or 0) + 1
                R.trail("nav", "path extended by %d points from its end (%.0f yd from the goal)", #points - 1,
                    R.dist2(nl.x, nl.y, x, y))
            end
        end)
        if not sent then st.planning = false return false end
        return true
    end
    cur.pre = st
    request(true)
    return true            -- the plan, or its move_to fallback, is on its way: the caller sends nothing
end

issue_walk = function(c, x, y, z, mode)
    cur.start_x,cur.start_y = R.here()
    cur.id = cur.id + 1
    local id = cur.id
    cur.x, cur.y, cur.z, cur.t, cur.mode, cur.route, cur.done = x, y, z, R.now(), mode or "move", nil, false
    cur.leg_t = R.now()
    stop_req = nil                                -- a new walk replaces a pending stop
    stats.issued = stats.issued + 1
    if mode == "guide" then wp_walk.id = id end
    cur.pre = nil
    local finished = function(success, reason)
        if cur.id ~= id then return end
        cur.done = true
        if success then
            if N.false_arrival(x, y, z) then
                -- audit N10: an "arrived" short of the goal is a failure (no black
                -- point: nothing got stuck), or the waypoint recheck walks it for ever
                MEM.walk_ended(false)
                if astar_try(x, y, z, mode, "arrived_short") then return end   -- local A* finishes the last yards
                record_fail("unreachable", x, y, z, false)
                if wp_walk.id == id then wp_walk.failed = "unreachable" end
                return
            end
            MEM.walk_ended(true)
            fail.reason, fail.offmesh = nil, false
            return
        end
        local code = reason or "failed"
        if HEIGHT_RETRY[code] and retry_at_ground(c, id, x, y, z, code, mode) then return end
        MEM.walk_ended(false)
        R.trail("nav", "walk to (%.0f, %.0f, %.0f) ended: %s", x, y, z, tostring(code))
        if OFFMESH[code] and astar_try(x, y, z, mode, code) then return end     -- local A* for an off-mesh goal
        record_fail(code, x, y, z, mode ~= "combat")   -- 1.9.0: a short combat step is no black point
        if wp_walk.id == id then wp_walk.failed = tostring(code) end
    end
    if pre_start(c, id, x, y, z, finished) then return true end
    local sent = S.move_to(c, { x = x, y = y, z = z }, finished)
    if not sent then cur.done = true end
    return sent
end

--- Out of combat and FLOOR_FIRST yd or more away with an unchecked height:
--- the floors there first, then the walk at the nearest one. True while it runs.
local FLOOR_ASKS = 3                       -- stacked floors asked about at most
local function walk_at_floor(c, x, y, z, mode)
    local k = key_of(x, y)
    cur.id = cur.id + 1
    local id = cur.id
    cur.x, cur.y, cur.z, cur.t, cur.mode, cur.route, cur.done = x, y, z, R.now(), mode or "move", nil, false
    cur.scanning, cur.scan_t = id, R.now()
    stop_req = nil
    return floors_for(c, k, x, y, z, function(list, st)
        if cur.scanning == id then cur.scanning = nil end
        st.checked, st.hint = true, z
        if cur.id ~= id then return end
        -- Cached lists were sorted for the original query height. Re-sort for
        -- this destination so stacked floors do not inherit that ordering.
        local candidates = {}
        for i = 1, #list do candidates[i] = list[i] end
        table.sort(candidates, function(a, b) return math.abs(a - z) < math.abs(b - z) end)
        local _, _, player_z = R.here()
        R.trail("nav", "terrain: player z %.1f, requested z %.1f, floor z %s, layers %d, indoors %s",
            player_z or 0, z, tostring(candidates[1]), #candidates, tostring(indoors()))
        local hz = candidates[1]
        if hz then
            local function go(h)
                if cur.scanning == id then cur.scanning = nil end
                cache_put(zfix, "zfix", k, { z = h, hint = z })
                R.trail("nav", "(%.0f, %.0f): walking at the floor there, z %.1f (guess %.1f, %d floor(s))", x, y, h, z, #list)
                issue_walk(c, x, y, h, mode)
            end
            -- 2026-11-15 (nav audit 10): stacked floors - ask Sentinel which of the
            -- nearest FLOOR_ASKS is reachable (nearest height first) instead of
            -- walking at the closest one and failing; none answers yes -> the
            -- nearest, as before. A superseded walk drops the answer.
            local function try(i)
                if i > math.min(FLOOR_ASKS, #candidates) then return go(candidates[1]) end
                cur.scanning, cur.scan_t = id, R.now()
                local sent = S.validate(c, { x = x, y = y, z = candidates[i] }, function(reachable)
                    if cur.id ~= id then return end
                    if reachable then go(candidates[i]) else try(i + 1) end
                end)
                if not sent then go(candidates[i]) end
            end
            if #candidates >= 2 then try(1) else go(hz) end
        else
            issue_walk(c, x, y, z, mode)
        end
    end)
end

local function event_flags()
    local ev = package.loaded["events"]
    return type(ev) == "table" and type(ev.navflags) == "table" and ev.navflags or nil
end

--- Why a NEW walk may not start now, or nil. A walk already running is a
--- retarget, not a new start. "casting": the caller walks once the cast ends
--- (moving would cancel it).
local function start_blocked(c, mode)
    -- no new travel walk in combat - only the fight's own walks (mode "combat")
    if mode ~= "combat" then
        local nf = event_flags()
        local me0 = R.me()
        local okc, fighting = pcall(function() return me0 and me0:is_in_combat() == true end)
        if (nf and nf.in_combat) or (okc and fighting == true) then return "in combat" end
    end
    local me = R.me()
    if me then
        local okc, casting = pcall(function() return me:is_casting_spell() == true or me:is_channelling_spell() == true end)
        if okc and casting == true then return "casting" end
    end
    if not S.server_up(c) then
        fail.server_until = R.now() + SERVER_BACKOFF
        return "server down"
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- holds (Sentinel has no pause / resume)
-- ----------------------------------------------------------------------------
function N.holding() return next(held.reasons) ~= nil end

--- The guide asks for `x, y` while a detour runs: the same goal - leave the
--- detour alone (true); another goal - the detour is over (false).
local function detour_owns(x, y)
    if not det then return false end
    if x and R.dist2(x, y, det.dest.x, det.dest.y) <= 8 then return true end
    det = nil
    return false
end

--- Walk to `dest`. True when a walk there is running or was started (also
--- when `dest` is underfoot, or remembered for after a hold); false when
--- refused (combat / rest / backpedal, a blacklisted area, the same spot just
--- failed, no Sentinel). Safe to call every tick.
function N.nav_to(dest, direct, mode)
    local x, y, z = R.xyz(dest)
    if not x then return false end
    if guard_blocked(x,y,z) then return false end
    if mode == "combat" then
        det = nil -- combat must not inherit a quest detour's resume destination
    elseif detour_owns(x, y) then return true end
    -- 3.5.0: a retarget (movement.nudge) of a running guide walk stays one
    if mode == nil and cur.mode == "guide" and cur.x and not cur.done then mode = "guide" end
    -- 3.7.1: a sharp turn is being made - the next leg starts after it
    if R.turning and mode ~= "combat" then
        if held.dest then held.dest = { x = x, y = y, z = z, mode = mode, direct = direct } end
        stats.refused = stats.refused + 1
        return true
    end
    local why = N.refusal()
    -- combat walks always go; an NPC approach (movement.interact) goes
    -- through its own NPC hold
    if why and mode ~= "combat" and not (mode == "npc" and why == "npc") then
        stats.refused = stats.refused + 1
        return false
    end
    local cached_floor = mode ~= "npc" and mode ~= "corpse" and corrected_z(x, y, z) or nil
    if not cached_floor and mode ~= "npc" and mode ~= "corpse" then
        local scan = zscan[key_of(x,y)]
        if scan and scan.list and #scan.list == 1 and R.now()-scan.t <= FAIL_WINDOW then
            cached_floor = scan.list[1]
        end
    end
    z = cached_floor or z
    local hx, hy, hz = R.here()
    if hx and R.dist2(hx, hy, x, y) <= UNDERFOOT and math.abs(hz - z) < 3 then
        return true
    end
    if not direct and mode ~= "combat" and Z.blocked_xy(x, y) then
        record_fail("blacklisted")
        return false
    end
    if not direct and mode ~= "combat" and MEM.goal_blocked(x, y, z) then   -- 1.9.0: a black goal cell
        record_fail("blacklisted")
        return false
    end
    local k = key_of(x, y)
    local fe = fails_at[k]
    if fe and fe.z and math.abs(fe.z-z)<2 and fe.n > 0 and (R.now() - fe.t) < 5 and (fail.offmesh or fail.give_up) then return false end
    local c = N.client()
    if not c then return false end
    -- server back-off, then is_server_available()
    if fail.server_until then
        if R.now() < fail.server_until then
            stats.refused = stats.refused + 1
            return false
        end
        if not S.server_up(c) then
            fail.server_until = R.now() + SERVER_BACKOFF
            stats.refused = stats.refused + 1
            return false
        end
        fail.server_until = nil
    end
    -- a hold (cast, loot, conjure): remembered, walked when it lifts
    if N.holding() then
        held.dest = { x = x, y = y, z = z, mode = mode, direct = direct }
        return true
    end
    local busy = S.moving(c)
    if busy and same_destination(x, y, z) and cur.mode ~= "route"
        and not (mode == "combat" and cur.mode ~= "combat") then
        return true
    end
    -- its floors are being asked for (walk_at_floor / retry_at_ground)
    if cur.scanning and cur.scanning == cur.id and (R.now() - (cur.scan_t or 0)) < HEIGHT_SCAN_HOLD
        and same_destination(x, y, z) then
        return true
    end
    if busy and not (mode == "combat" and cur.mode ~= "combat")
        and (R.now() - cur.t) < (mode == "combat" and COMBAT_GAP or RETARGET_GAP) then return true end
    if not busy then
        local blocked = start_blocked(c, mode)
        if blocked == "casting" then return true end      -- walked once the cast ends
        if blocked then stats.refused = stats.refused + 1 return false end
    end
    -- 3.8.0: before an out-of-combat walk of MIN_WALK yd or more starts, mount
    -- (or Travel Form) first - the player stands for the cast meanwhile
    if not busy and mode ~= "combat" and mode ~= "npc" and mode ~= "corpse" and hx and MT.wants(R.dist2(hx, hy, x, y)) then
        if MT.step(R.me()) then return true end
    end
    if mode ~= "combat" and mode ~= "npc" and mode ~= "corpse" and hx and (R.dist2(hx, hy, x, y) >= (indoors() and 3 or FLOOR_FIRST) or math.abs(hz - z) >= 4) and not corrected_z(x, y, z) and not swimming() then
        local st = zscan[k]
        if not (st and st.checked and st.hint == z and (R.now() - st.t) <= FAIL_WINDOW) then
            if mode == "guide" then wp_walk.id = cur.id + 1 end
            return walk_at_floor(c, x, y, z, mode)
        end
    end
    return issue_walk(c, x, y, z, mode)
end

--- 1.4.0 (Zygor spec, kept for RestedXP waypoints): ONE walk per guide
--- waypoint key (step, goal, point); another only when the key changes. The
--- same key is rechecked every WP_RECHECK s and walked again when Sentinel
--- stands idle short of the point. A stop (a fight, an NPC) lets the same key
--- go again at once.
function N.waypoint_walk(dest, key)
    local x, y, z = R.xyz(dest)
    if not x then return false end
    if guard_blocked(x,y,z) then return false end
    if detour_owns(x, y) then return true end           -- 1.7.23: a stuck detour runs
    if N.refusal() then
        stats.refused = stats.refused + 1
        return false
    end
    if not N.client() then return false end
    if MEM.goal_blocked(x, y, z) then                     -- 1.9.0: the goal cell is a black point
        record_fail("blacklisted")
        return false
    end
    local now = R.now()
    -- the walk to the NEXT waypoint was started a few yards before this one
    -- ended (N.hint_next): this waypoint's key is satisfied, do not turn back
    if hand and hand.from == key and now < hand.until_t then return true end
    if wp_walk.key == key then
        if N.pending() then return true end
        if N.busy() then
            -- the walk running is this waypoint's (a retarget refused by the
            -- retarget gap is asked again below)
            if same_destination(x, y, z) then return true end
        elseif (now - wp_walk.t) < WP_RECHECK then
            return true
        else
            R.trail("nav", "waypoint recheck: idle short of (%.0f, %.0f, %.0f) - walking again", x, y, z)
            cur.t = -1e9                                  -- not a retarget: at once
        end
    end
    -- audit S3: a give-up (max_stuck / max_repath) or a server back-off is not
    -- retried every 5 s - the same 5 s give-up window nav_to uses
    if (fail.give_up and (now - (fail.t or 0)) < 5) or (fail.server_until and now < fail.server_until) then
        return false
    end
    if wp_walk.key ~= key then
        wp_walk.key, wp_walk.failed = key, nil
        fail.reason = nil
    end
    wp_walk.t = now
    return N.nav_to(dest, true, "guide")
end
function N.waypoint_forget() wp_walk.key = nil end

--- 1.7.9: the running walk's own path from the point being walked, up to
--- `yards` along it (the player's position first): Sentinel's
--- get_current_path from get_path_index. Client reads only, on the update
--- tick. Just the player's position when idle.
function N.path_ahead(yards)
    yards = tonumber(yards) or 40
    local out = {}
    local hx, hy, hz = R.here()
    if hx then out[1] = { x = hx, y = hy, z = hz } end
    local c = N.client()
    if not c or not S.moving(c) then return out end
    local pts = S.current_path(c)
    if type(pts) ~= "table" then return out end
    local idx = S.path_index(c)
    idx = (type(idx) == "number" and idx >= 1) and math.floor(idx) or 1
    yards = math.max(0, yards)
    if yards == 0 then return out end
    local walked, px, py, pz = 0, hx, hy, hz
    for i = idx, #pts do
        local p = pts[i]
        if type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" then
            local leg = px and R.dist2(px, py, p.x, p.y) or 0
            if leg > 0 and walked + leg >= yards then
                local t = (yards - walked) / leg
                local z = (type(pz) == "number" and type(p.z) == "number") and (pz + (p.z - pz) * t) or p.z
                out[#out + 1] = { x = px + (p.x - px) * t, y = py + (p.y - py) * t, z = z }
                break
            end
            walked = walked + leg
            out[#out + 1] = { x = p.x, y = p.y, z = p.z }
            px, py, pz = p.x, p.y, p.z
        end
    end
    return out
end

--- 1.7.7: the last yards INTO a portal. The portal is not on the navmesh, so
--- this is Sentinel's move_direct - a single waypoint with no pathfinding
--- (documented, not yet recorded on v0.24). The loading screen ends it.
function N.step_into(pos)
    local x, y, z = R.xyz(pos)
    if not x then return false end
    local c = N.client()
    if not c then return false end
    if S.moving(c) then return true end          -- this step, or the walk to the entry, still runs
    if start_blocked(c, "portal") then return false end
    cur.id = cur.id + 1
    local id = cur.id
    cur.x, cur.y, cur.z, cur.t, cur.mode, cur.route, cur.done = x, y, z, R.now(), "portal", nil, false
    cur.leg_t = R.now()
    stop_req = nil
    stats.issued = stats.issued + 1
    R.trail("nav", "stepping into the portal: straight walk to (%.0f, %.0f, %.0f)", x, y, z)
    local ok = S.move_direct(c, { x = x, y = y, z = z }, function(success, reason)
        if cur.id ~= id then return end
        cur.done = true
        R.trail("nav", "portal step ended: %s", success and "arrived" or tostring(reason))
    end)
    if not ok then cur.done = true end
    return ok
end

--- One leg of the local A* path (movement/astar): Sentinel's move_direct, a
--- single off-mesh waypoint, never a key. One leg start a second at most; holds
--- are respected. Set as AS.leg_fn below.
local ASTAR_LEG_GAP = 1.0
function N.astar_leg(x, y, z)
    if R.resting or R.backpedal_until then return false end
    local c = N.client()
    if not c or N.holding() or stop_req then return false end
    if cur.leg_t and (R.now() - cur.leg_t) < ASTAR_LEG_GAP then return false end
    cur.id = cur.id + 1
    local id = cur.id
    cur.x, cur.y, cur.z, cur.t, cur.mode, cur.route, cur.done = x, y, z, R.now(), "astar", nil, false
    cur.leg_t = R.now()
    stop_req = nil
    stats.issued = stats.issued + 1
    R.trail("nav", "move_direct (astar leg) %.1f %.1f %.1f", x, y, z)
    local ok = S.move_direct(c, { x = x, y = y, z = z }, function()
        if cur.id ~= id then return end
        cur.done = true
    end)
    if not ok then cur.done = true end
    return ok
end
AS.leg_fn = N.astar_leg

--- Walk a recorded route (array of {x,y,z}) with follow_path, picked up at its
--- point nearest the player (1.7.22; `front`: the point in front, 1.0.21). The
--- same table while it runs is a no-op unless `replace`. True when accepted.
function N.follow_route(list, replace, front)
    if type(list) ~= "table" or #list < 1 then return false end
    if N.refusal() then return false end
    local c = N.client()
    if not c then return false end
    if N.holding() then
        held.dest = { route = list }
        return true
    end
    if not replace and cur.route == list and S.moving(c) then return true end
    local all = {}
    for i = 1, #list do
        local x, y, z = R.xyz(list[i])
        if not x then return false end
        all[i] = { x = x, y = y, z = z }
    end
    local from = front and front_index(all, 1, #all) or pickup_index(all, 1, #all)
    local pts = {}
    for i = from, #all do pts[#pts + 1] = all[i] end
    if from > 1 then R.trail("nav", "route picked up at point %d of %d", from, #all) end
    cur.id = cur.id + 1
    local id = cur.id
    local last = pts[#pts]
    cur.x, cur.y, cur.z, cur.t, cur.mode, cur.route, cur.done = last.x, last.y, last.z, R.now(), "route", list, false
    cur.leg_t = R.now()
    stop_req = nil
    stats.issued = stats.issued + 1
    local ok = S.follow_path(c, pts, function(success, reason)
        if cur.id ~= id then return end
        cur.done = true
        MEM.walk_ended(success == true)
        if success then return end
        R.trail("nav", "route walk ended: %s", tostring(reason))
        record_fail(reason or "failed", nil, nil, nil, true)
    end)
    if not ok then cur.done = true end
    return ok
end

-- ----------------------------------------------------------------------------
-- re-navigation (movement.lua's no-progress watchdog): the current
-- destination walked again, or a detour point first
-- ----------------------------------------------------------------------------
--- The running walk may be replaced now: it follows its path and is not fresh.
local function replaceable(c)
    if S.path_pending(c) then return false end
    return (R.now() - (cur.leg_t or 0)) >= FRESH_LEG
end

--- Walk `d` again from where the player stands (a new move_to re-plans
--- without stopping; a recorded route is picked up again).
local function walk_again(c, d, why, front)
    if d.mode == "route" and type(d.route) == "table" then
        N.follow_route(d.route, true, front)
    else
        issue_walk(c, d.x, d.y, d.z, d.mode or "move")
    end
    R.trail("nav", "re-navigation: walking to (%.0f, %.0f, %.0f) again - %s", d.x, d.y, d.z or 0, tostring(why))
end

--- A fresh path from where the player stands to the walk's own goal: the
--- same destination handed to Sentinel again. False when there is no walk,
--- a new walk may not start, or the leg is still fresh / awaiting its path.
function N.replan_fresh(why)
    local c = N.client()
    if not c or not cur.x then return false end
    if guard_blocked(cur.x,cur.y,cur.z) then return false end
    -- audit N6: no new walk during a cast / channel, in combat (out-of-combat
    -- walks) or mid-pivot
    if start_blocked(c, cur.mode) or R.turning then return false end
    if S.moving(c) and not replaceable(c) then return false end
    local d = { x = cur.x, y = cur.y, z = cur.z, mode = cur.mode, route = cur.route }
    -- 1.9.0: the second stuck re-plan of the same corridor is a black point
    if type(why) == "string" and why:find("stuck", 1, true) then
        local px, py, pz = R.here()
        if px then mem_black(MEM.note_replan(px, py, pz, d.x, d.y), "re-planned twice") end
    end
    det = nil
    walk_again(c, d, why or "stuck")
    return true
end

--- 1.7.22 / 1.0.21: the running walk picks its path up again from where the
--- player is - a recorded route at the point in front, any other walk its
--- destination handed to Sentinel again.
function N.rejoin(why)
    local c = N.client()
    if not c or not cur.x or not S.moving(c) then return false end
    if guard_blocked(cur.x,cur.y,cur.z) then return false end
    if not replaceable(c) then return false end
    walk_again(c, { x = cur.x, y = cur.y, z = cur.z, mode = cur.mode, route = cur.route },
        "rejoin" .. (why and (" - " .. tostring(why)) or ""), true)
    return true
end

local function detour_done(reason)
    local d = det
    if not d then return end
    det = nil
    local c = N.client()
    if c then walk_again(c, d.dest, "after a detour (" .. tostring(reason) .. ")") end
end

--- 1.7.23: walk to `pt` (a checked detour point), then on to the walk's own
--- goal. While it runs the walk's destination (cur.x) stays the real goal, so
--- the guide asking for the same goal every tick leaves the detour alone;
--- another goal ends it.
function N.detour(pt, why, resume_goal, recovery_radius, planned_path)
    local c = N.client()
    if not c or (not cur.x and not resume_goal) or type(pt) ~= "table" or not pt.x then return false end
    local mode = resume_goal and (resume_goal.mode or "move") or cur.mode
    if start_blocked(c, mode) or R.turning then return false end          -- audit N6
    if S.moving(c) and not replaceable(c) then return false end
    local max_distance=DETOUR_FAR
    local max_time=DETOUR_MAX_S
    if resume_goal and type(recovery_radius)=="number" then
        max_distance=math.max(DETOUR_FAR,math.min(180,recovery_radius))+0.1
        max_time=math.max(DETOUR_MAX_S,math.min(35,recovery_radius*0.5))
        if type(planned_path)=="table" then
            local route_length=0
            for n=1,#planned_path-1 do
                local a,b=planned_path[n],planned_path[n+1]
                route_length=route_length+R.dist3(a.x,a.y,a.z,b.x,b.y,b.z)
            end
            max_time=math.max(max_time,math.min(120,route_length/4+5))
        end
    end
    do
        local hx, hy = R.here()
        if not hx or R.dist2(hx, hy, pt.x, pt.y) > max_distance then return false end
    end
    local dest = resume_goal and {x=resume_goal.x,y=resume_goal.y,z=resume_goal.z,mode=mode}
        or { x = cur.x, y = cur.y, z = cur.z, mode = cur.mode, route = cur.route }
    cur.x,cur.y,cur.z,cur.mode = dest.x,dest.y,dest.z,dest.mode
    cur.id = cur.id + 1
    local id = cur.id
    cur.route, cur.done = nil, false
    cur.t, cur.leg_t = R.now(), R.now()
    stop_req = nil
    stats.issued = stats.issued + 1
    det = { x = pt.x, y = pt.y, z = pt.z, dest = dest, id = id, until_t = R.now() + max_time }
    R.trail("nav", "re-navigation: detour to (%.0f, %.0f) - %s", pt.x, pt.y, tostring(why))
    local function completed(success, reason)
        if not det or det.id ~= id then return end
        -- A server code (timeout / down / map not loaded) is not a detour that
        -- merely failed: back off (record_fail) and drop any capture instead of
        -- re-issuing the real walk at once, bypassing SERVER_BACKOFF.
        if not success and SERVER_CODES[reason] then
            MEM.walk_ended(false)
            record_fail(reason, nil, nil, nil, false)
            det = nil
            R.trail("nav", "detour ended: %s; backing off %.1f s before walking again", tostring(reason), SERVER_BACKOFF)
            return
        end
        detour_done(success and "reached" or tostring(reason))
    end
    local ok
    if type(planned_path)=="table" and #planned_path>=2 then
        R.trail("nav","recovery follows %d validated waypoints",#planned_path)
        ok=S.follow_path(c,planned_path,completed)
    else
        ok=S.move_to(c,{x=pt.x,y=pt.y,z=pt.z or dest.z},completed)
    end
    if not ok then det = nil return false end
    return true
end

function N.detour_active() return det ~= nil end

-- A corpse-run watchdog may ask for a different local approach after a
-- stalled leg. Sentinel remains the only walker; rays reject unsafe exits.
function N.recover_path(goal, side, why, wide)
    if det or N.holding() or N.leg_fresh() then return false end
    local c=N.client()
    if not c or S.path_pending(c) then return false end
    local x,y,z=R.here()
    if not x or not goal then return false end
    local dx,dy=goal.x-x,goal.y-y
    local length=math.sqrt(dx*dx+dy*dy)
    if length<1 then return false end
    local trace=require("movement/trace")
    if not trace.ready() then return false end
    local from={x=x,y=y,z=z}
    local rejected={floor=0,slope=0,body=0,budget=0,request=0}
    local first_body
    -- Sideways-only probes cannot escape a slope between trees or walls.
    -- Try stepping back around it before considering forward diagonals.
    local distances=type(wide)=="number" and wide>=3 and {} or {3,6,10}
    for _,distance in ipairs(distances) do
        for _,degrees in ipairs({90,-90,135,-135,180,45,-45}) do
            local angle=math.rad(degrees*(side or 1))
            local ux=(dx*math.cos(angle)-dy*math.sin(angle))/length
            local uy=(dx*math.sin(angle)+dy*math.cos(angle))/length
            local samples={from}
            local safe_exit=true
            for n=1,math.ceil(distance) do
                local d=math.min(distance,n)
                local previous=samples[#samples]
                local point={x=x+ux*d,y=y+uy*d,z=previous.z}
                -- The next sample may rise up to 1.1 yd over this one-yard
                -- interval. Starting only 0.5 yd above the preceding floor
                -- casts from inside an otherwise walkable uphill surface.
                local floor=trace.player_ground(point,1.5)
                if type(floor)~="number" then rejected.floor=rejected.floor+1 safe_exit=false break end
                point.z=floor
                samples[#samples+1]=point
                if ST.first_steep(samples) then rejected.slope=rejected.slope+1 safe_exit=false break end
            end
            local point=samples[#samples]
            if safe_exit then
                -- Follow the measured floor profile. A single low ray chord
                -- intersects harmless convex ground between safe endpoints.
                for n=1,#samples-1 do
                    local blocked=trace.corridor_blocked(samples[n],samples[n+1],false,true)
                    if blocked~=false then
                        if blocked and not first_body then first_body=trace.last_hit end
                        local key=blocked==nil and "budget" or "body"
                        rejected[key]=rejected[key]+1 safe_exit=false break
                    end
                end
                if safe_exit then
                    -- Keep the floor and body corridor we just measured.
                    -- Replanning only its endpoint can send a three-yard
                    -- escape back through the slope it was meant to avoid.
                    if N.detour(point,why or "corpse progress watchdog",goal,nil,samples) then return true end
                    rejected.request=rejected.request+1
                end
            end
        end
    end
    R.trail("nav","measured escape refused: floor=%d slope=%d body=%d ray_budget=%d request=%d",
        rejected.floor,rejected.slope,rejected.body,rejected.budget,rejected.request)
    if first_body then
        local a,b=first_body.a,first_body.b
        R.trail("nav","escape collision evidence: %s mask=%s (%.2f,%.2f,%.2f)->(%.2f,%.2f,%.2f), hit distance=%s",
            first_body.source,first_body.mask,a.x,a.y,a.z,b.x,b.y,b.z,tostring(first_body.distance))
    end
    if wide and not escape_poll then
        -- Short straight exits can all touch a wall even when a curved
        -- navmesh retreat exists. Validate a bounded endpoint through
        -- Sentinel; the normal path guard still checks the resulting walk.
        -- Rotate the geometric exclusion point on alternate attempts. A
        -- retreat directly away from the distant corpse rejoins the same
        -- failed corridor; a side approach can reach its entrance instead.
        -- Try opposite sides first, then rotate the pair through diagonals
        -- and forward/backward approaches instead of repeating two corridors.
        local attempt=type(wide)=="number" and wide or 3
        local pair=math.max(0,math.floor((attempt-3)/2))
        local angle=(pair%4)*math.pi/4
        local sx,sy=-dy/length*(side or 1),dx/length*(side or 1)
        local ex,ey=sx*math.cos(angle)-sy*math.sin(angle),sx*math.sin(angle)+sy*math.cos(angle)
        local exclusion={x=x+ex*5,y=y+ey*5,z=z}
        local radius=math.min(180,30+pair*15)
        R.trail("nav","corpse recovery search: attempt %d, radius %.0f yd, heading pair %d",attempt,radius,pair%4)
        -- Keep the validated origin stationary during asynchronous probes.
        -- The previous walk otherwise keeps advancing into the hazard and
        -- its terrain stop cancels the new search before it can finish.
        N.stop("planning alternate recovery route",true)
        return N.flee(from,{exclusion},function(point,path)
            local me=R.me()
            local ok,ghost=pcall(function() return me:is_dead_or_ghost() end)
            local okc,combat=pcall(function() return me:is_in_combat() end)
            local quest=goal.mode=="guide"
            if point and ok and ((quest and ghost==false and okc and combat==false) or (not quest and ghost==true)) then
                local purpose=quest and "quest" or "corpse"
                local started=N.detour(point,purpose.." retreat after local exits failed",goal,radius,path)
                R.trail("nav","%s recovery walk: radius %.0f yd, started=%s",purpose,radius,tostring(started))
            end
        end,radius,nil,goal)
    end
    return false
end

function N.recovery_pending() return escape_poll~=nil end

--- 1.7.24: every navmesh floor under `pos` (Sentinel get_all_heights through
--- the adapter) -> cb(list of heights, nearest pos.z first). False when it
--- could not be asked (cb is not called then).
function N.all_heights(pos, cb)
    local c = N.client()
    if not c or type(pos) ~= "table" or not pos.x then return false end
    return S.floors(c, { x = pos.x, y = pos.y, z = pos.z or 0 }, function(list) pcall(cb, list) end)
end

--- 1.0.22: other heights to try at (x, y) than `z` - the floors there, those
--- near the player's own height first: cb(list). (Tests; retry_at_ground
--- orders a spot's cached floors the same way.)
local function z_candidates(x, y, z, cb)
    local asked = N.all_heights({ x = x, y = y, z = z }, function(vals) cb(order_floors(vals, z)) end)
    if not asked then cb({}) end
end
N._z_candidates = z_candidates

--- A stop may go out now: the walk follows its path and is not fresh.
local function safe_to_stop(c)
    if S.path_pending(c) then return false end
    return (R.now() - (cur.leg_t or 0)) >= FRESH_LEG
end

--- Stop the walk this layer started. Cheap when idle. A walk still waiting
--- for its path or younger than FRESH_LEG s is stopped by the pulse later
--- unless `force` (Stop / GUI close / unload: callbacks will not pulse again).
function N.stop(reason, force)
    escape_poll = nil
    S.invalidate()
    det = nil                               -- 1.7.23
    if cur.mode ~= "astar" or reason ~= "astar leg" then AS.cancel(reason or "stop") end   -- end any local A* search/walk
    wp_walk.key = nil                       -- 1.4.0: a stopped waypoint walk may go again
    local c = N.client()
    local was = c ~= nil and (S.moving(c) or S.path_pending(c))
    if c and (was or cur.x or force == true) then
        if force == true or safe_to_stop(c) then
            S.stop(c)
            stop_req = nil
        else
            stop_req = { t = R.now(), reason = reason }
            stats.deferred_stops = stats.deferred_stops + 1
        end
    end
    if cur.x and not cur.done then MEM.walk_ended(false) end   -- 1.9.0
    cur.id = cur.id + 1                     -- the stopped walk's callback, if any, is ignored
    cur.x, cur.mode, cur.route, cur.done = nil, nil, nil, true
    cur.t = -1e9                            -- the next walk is not a retarget: it goes at once (and replaces a deferred stop)
    cur.scanning, cur.pre = nil, nil
    -- 3.7.1: a deliberate stop also ends a sharp turn in progress (movement/pivot
    -- only finishes a turn when the walk ended by itself)
    if R.turning then R.turn_cancel, R.turning = true, false end
    if was then R.quiet_until = R.now() + QUIET_STOP end
end

--- Hold the walk for `reason` (a cast, a loot, a conjure): stopped, its
--- destination remembered.
function N.pause(reason)
    reason = reason or "hold"
    MEM.on_pause(reason)                    -- 1.9.0: a loot / conjure / cast hold holds the memory
    local first = not N.holding()
    held.reasons[reason] = true
    if first and cur.x and N.busy() then
        held.dest = { x = cur.x, y = cur.y, z = cur.z, mode = cur.mode, route = cur.route, direct = true }
        local turning = R.turning
        N.stop("hold " .. reason)
        R.turning = turning                     -- a sharp-turn hold keeps its turn
        R.turn_cancel = false
    end
end

--- Lift `reason`; when no hold is left the remembered destination is walked again.
function N.resume(reason)
    reason = reason or "hold"
    MEM.on_resume(reason)
    held.reasons[reason] = nil
    if N.holding() then return end
    local d = held.dest
    held.dest = nil
    if not d then return end
    if d.route then
        N.follow_route(d.route, true)
    else
        N.nav_to(d, d.direct, d.mode)
    end
end

--- Per frame: event-flag stops, the deferred stop, walks ended without a
--- callback, the detour timeout, the nav memory.

-- Inspect the next few yards, not the endpoint's overall grade: a safe
-- switchback can end far above us. Replans are bounded so a bad mesh does
-- not send the character into the same cliff indefinitely.

local function guard_path(c)
    guard_context()
    local now = R.now()
    if now < terrain_guard.next_t or cur.mode == "combat" or cur.mode == "portal"
        or cur.mode == "swim" or not cur.x or cur.done or N.holding()
        or stop_req or not S.moving(c) or S.path_pending(c) or N.leg_fresh() then return end
    terrain_guard.next_t = now + 0.35
    local fs = S.full_state(c) or ""
    if fs:find("recovering", 1, true) or fs:find("repathing", 1, true) then return end
    local px,py = R.here()
    if not px then return end
    local _,_,pz = R.here()
    local goal_key = key_of(cur.x,cur.y)
    if orbit.key ~= goal_key or not orbit.t or math.abs((cur.z or pz)-orbit.goal_z)>=2 then
        orbit = {key=goal_key,t=now,x=px,y=py,lx=px,ly=py,z=pz,goal_z=cur.z or pz,distance=0,tries=0}
    end
    orbit.distance = orbit.distance + R.dist2(px,py,orbit.lx,orbit.ly)
    orbit.lx,orbit.ly = px,py
    if now-orbit.t >= 12 then
        local loop = orbit.distance >= 18 and R.dist2(px,py,orbit.x,orbit.y) < 6
            and math.abs(pz-orbit.z)<2
        orbit.t,orbit.x,orbit.y,orbit.z,orbit.distance = now,px,py,pz,0
        if loop and not det then
            orbit.tries = orbit.tries + 1
            R.trail("nav", "loop detected: returned within 6 yd after travelling 18+ yd; recovery %d", orbit.tries)
            if orbit.tries == 1 then N.regen(c,"circling without progress")
            else
                terrain_guard.key,terrain_guard.goal_z,terrain_guard.blocked_until = goal_key,cur.z,now+30
                local gx,gy,gz=cur.x,cur.y,cur.z
                N.stop("repeated navigation loop",true)
                record_fail("max_repath_exceeded",gx,gy,gz,false)
            end
            return
        elseif not loop then orbit.tries=0 end
    end
    if not terrain_guard.mx or R.dist2(px,py,terrain_guard.mx,terrain_guard.my) >= 1 then
        terrain_guard.mx,terrain_guard.my,terrain_guard.motion_t = px,py,now
    end
    local ahead=N.path_ahead(indoors() and math.max(12,(N.LA and N.LA.H) or 20) or 28)
    -- A small hop/fall puts the live player above the path's floor. Judge
    -- that entry connection from measured ground, not the airborne body.
    -- Large/unknown drops and every later mesh edge remain guarded.
    local ok_fall,falling=pcall(function() return R.me():is_falling() end)
    if ok_fall and falling==true and ahead[1] then
        local ground=require("movement/trace").player_ground({x=px,y=py,z=pz})
        if type(ground)=="number" and pz-ground>0.6 and pz-ground<=2 then
            ahead[1]={x=px,y=py,z=ground}
        end
    end
    local points = guard_points(ahead)
    -- Shop/inn entrance stairs begin outside the indoor flag boundary.
    -- A live NPC destination uses the same bounded stair-rise allowance.
    local stair_approach=indoors() or cur.mode=="npc"
    local i, steep_end = ST.first_steep(points,stair_approach)
    if i then
        local measured=ST.measured_span(points,i,steep_end or i+1,stair_approach)
        if measured then
            points=measured
            i,steep_end=ST.first_steep(points,stair_approach)
        end
    end
    -- Mesh grades near 45 degrees can describe traversable snow banks.
    -- Nearby moderate ascents get a short progress grace. A moderate descent
    -- also requires measured ground at our feet and no falling; never grant
    -- that exception to a long drop, a steep wall, or a stalled walk.
    local function progressing_grade(a,b)
        local run=R.dist2(a.x,a.y,b.x,b.y)
        local rise=b.z-a.z
        -- A short grade eligible for the near-player progress check must
        -- first be approachable. Stopping it at 17 yd otherwise prevents
        -- that check forever and sends recovery back around the same ridge.
        -- This is only an approach allowance; nearby stalled walks and all
        -- descents still take the checks below.
        if run>=1 and rise>0 and rise<=6 and rise/run<=ST.UP_IN
            and R.dist2(px,py,a.x,a.y)>=8 then return true end
        -- Descents can be validated ahead of arrival using every ground
        -- sample below; rejecting them outside eight yards prevents the
        -- player ever reaching the near-player validation window.
        if run<1 or (rise>=0 and R.dist2(px,py,a.x,a.y)>=8)
            or now-(terrain_guard.motion_t or now)>=1.2 then return false end
        if rise>=0 and rise/run<=ST.UP_IN then return true end
        if math.abs(rise)>6 or run>8 then return false end
        local ok,falling=pcall(function() return R.me():is_falling() end)
        if not ok or falling~=false then return false end
        local trace=require("movement/trace")
        local ground=trace.player_ground({x=px,y=py,z=pz})
        if type(ground)~="number" or math.abs(pz-ground)>0.6 then return false end
        -- Measure the entire short descent. Mesh interpolation can cross
        -- snow banks or cave steps at the wrong Z; feet alone prove nothing
        -- about the next drop. Unknown floors and sharp ledges stay blocked.
        local count=math.ceil(run/0.75)
        local previous
        for sample=0,count do
            local u=sample/count
            local p={x=a.x+(b.x-a.x)*u,y=a.y+(b.y-a.y)*u,z=a.z+rise*u}
            local z=trace.player_ground(p,1.5)
            if type(z)~="number" or math.abs(z-p.z)>2 then return false end
            -- A short continuous downhill grade can be steeper than an
            -- ascent. Samples remain under one yard; abrupt ledges fail.
            if previous and (previous-z>1.25*run/count or z-previous>1.1*run/count) then return false end
            previous=z
        end
        return true
    end
    if i then
        local a,b=points[i],points[steep_end or i+1]
        if progressing_grade(a,b) then
            i,steep_end=nil,nil
        end
    end
    local reason = "unsafe slope"
    local function supported_stair_ascent(a,b)
        if not stair_approach or b.z<=a.z or b.z-a.z>6 or not progressing_grade(a,b) then return false end
        local ground=require("movement/trace").player_ground({x=px,y=py,z=pz})
        return type(ground)=="number" and math.abs(pz-ground)<=0.6
    end
    local function supported_deck(a,b)
        local run=R.dist2(a.x,a.y,b.x,b.y)
        if run>8 then return false end
        local trace=require("movement/trace")
        local count=math.max(1,math.ceil(run))
        for sample=0,count do
            local u=sample/count
            local x,y,z=a.x+(b.x-a.x)*u,a.y+(b.y-a.y)*u,a.z+(b.z-a.z)*u
            if trace.hit({x=x,y=y,z=z+0.3},{x=x,y=y,z=z-0.8},"GROUND")~=true then return false end
        end
        return true
    end
    for n=#blocked_terrain,1,-1 do
        if now >= blocked_terrain[n].until_t then table.remove(blocked_terrain,n) end
    end
    if not i then
        for j=1,#points-1 do
            local a,b=points[j],points[j+1]
            local dx,dy=b.x-a.x,b.y-a.y
            local length2=dx*dx+dy*dy
            for _,hazard in ipairs(blocked_terrain) do
                local u=length2>0 and math.max(0,math.min(1,((hazard.x-a.x)*dx+(hazard.y-a.y)*dy)/length2)) or 0
                local z=a.z+(b.z-a.z)*u
                local direction_ok = not hazard.dx or dx*hazard.dx+dy*hazard.dy > 0
                local _, steep_now = ST.grade(a,b,stair_approach)
                local shape_ok = hazard.kind ~= "unsafe slope" or (not stair_approach and steep_now and not progressing_grade(a,b))
                if hazard.kind=="unsupported ground / drop"
                    and (supported_stair_ascent(a,b) or supported_deck(a,b)) then shape_ok=false end
                if direction_ok and shape_ok and R.dist2(a.x+u*dx,a.y+u*dy,hazard.x,hazard.y)<2 and math.abs(z-hazard.z)<3 then
                    i,reason=j,"remembered blocked terrain"; break
                end
            end
            if i then break end
        end
    end
    if not i then
        local trace = require("movement/trace")
        if trace.ready() then
            local count=#points-1
            local start=math.min(terrain_guard.scan_index or 1,math.max(1,count))
            local eq={n=0,max=10}          -- height queries the ledge test may use this scan
            terrain_guard.edge=terrain_guard.edge or {}
            for offset=0,math.min(15,count-1) do
                local j=1+(start-1+offset)%count
                terrain_guard.scan_index=1+j%count
                local a,b = points[j],points[j+1]
                local mid = {x=(a.x+b.x)/2,y=(a.y+b.y)/2,z=(a.z+b.z)/2}
                local ground = trace.player_ground and trace.player_ground(mid)
                -- A chord between ascending stair nodes can pass over the
                -- lower room beside the staircase. Grounded forward progress
                -- up a bounded stair is not evidence of a drop.
                -- Terrain height may lie below a solid bridge deck. Require
                -- short downward collision rays along the whole span before
                -- dismissing a drop; a missing deck sample remains unsafe.
                if type(ground) == "number" and mid.z-ground > 3 and not ghost_now()
                    and not supported_stair_ascent(a,b) and not supported_deck(a,b) then
                    i, reason = j, "unsupported ground / drop"
                    break
                end
                -- Ledge: the path itself is fine but runs along a cliff edge. Soft
                -- hazard only: a Sentinel zone + re-path, never a stop (a rail-lined
                -- bridge or a ledge trail with no other way is still walked).
                if R.dist2(px,py,a.x,a.y)>=4 and not ghost_now() then
                    local ek=key_of(mid.x,mid.y)
                    local seen=terrain_guard.edge[ek]
                    if not seen or now-seen>60 then
                        local ledge,drop,lx,ly=trace.edge_drop(a,b,eq)
                        if ledge~=nil then
                            if next(terrain_guard.edge) and (terrain_guard.edge_n or 0)>200 then
                                terrain_guard.edge,terrain_guard.edge_n={},0
                            end
                            terrain_guard.edge[ek]=now
                            terrain_guard.edge_n=(terrain_guard.edge_n or 0)+1
                            if ledge then
                                local placed=N.zone_span(a,b,"cliff edge")
                                R.trail("nav","cliff edge: ground %.1f yd lower %.1f yd beside the path near (%.0f, %.0f) - zone %s",
                                    drop,TM.EDGE_SIDE,lx,ly,tostring(placed))
                                if placed=="new" then stats.edge_zones=(stats.edge_zones or 0)+1 end
                            end
                        end
                    end
                end
                local blocked=trace.corridor_blocked(a,b,true)
                if blocked == nil then terrain_guard.scan_index=j; break end
                if blocked == true then
                    terrain_guard.scan_index=j
                    i, reason = j, "blocked body corridor"
                    break
                end
            end
        end
    end
    if not i then
        terrain_guard.suspect = nil
        terrain_guard.tries, terrain_guard.ax, terrain_guard.ay = 0, nil, nil
        return true
    end
    local a, b = points[i], points[steep_end or i+1]
    local k = key_of(cur.x, cur.y)
    if reason == "blocked body corridor" then
        -- At a doorway/step, a ray can cross geometry that Sentinel is
        -- already rounding successfully. Distant obstructions are proactive;
        -- immediate contacts need a real progress stall before intervention.
        if R.dist2(px,py,a.x,a.y)<8 and now-(terrain_guard.motion_t or now)<1.2 then return end
        local suspect=terrain_guard.suspect
        if not suspect or R.dist2(b.x,b.y,suspect.x,suspect.y)>3 or math.abs(b.z-suspect.z)>2 then
            terrain_guard.suspect={x=b.x,y=b.y,z=b.z,t=now}
            return
        end
        if now-suspect.t<0.3 then return end
    end
    local hazard
    for _,h in ipairs(blocked_terrain) do
        if R.dist2(b.x,b.y,h.x,h.y)<4 and math.abs(b.z-h.z)<3 then hazard=h break end
    end
    if not hazard then
        hazard={x=b.x,y=b.y,z=b.z,dx=b.x-a.x,dy=b.y-a.y,kind=reason,until_t=now+120,tries=0}
        blocked_terrain[#blocked_terrain+1]=hazard
        if #blocked_terrain>24 then table.remove(blocked_terrain,1) end
    end
    if now-(hazard.action_t or -1e9)<2 then
        if R.dist2(px,py,a.x,a.y)<=8 then
            terrain_guard.key,terrain_guard.goal_z,terrain_guard.blocked_until=k,cur.z,now+30
            N.stop("known terrain hazard ahead",true)
        end
        return
    end
    hazard.action_t=now
    hazard.tries=hazard.tries+1
    if terrain_guard.key ~= k or not terrain_guard.ax
        or R.dist2(b.x,b.y,terrain_guard.ax,terrain_guard.ay) > 4 then
        terrain_guard.key, terrain_guard.tries = k, 0
        terrain_guard.ax, terrain_guard.ay = b.x, b.y
    end
    terrain_guard.tries = hazard.tries
    R.trail("nav", "%s: rise %.2f / run %.2f near (%.1f, %.1f, %.1f), attempt %d",
        reason, b.z-a.z, R.dist2(a.x,a.y,b.x,b.y), a.x,a.y,a.z, terrain_guard.tries)
    if b.z<a.z then
        local ok,falling=pcall(function() return R.me():is_falling() end)
        local ground=require("movement/trace").player_ground({x=px,y=py,z=pz})
        R.trail("nav", "descent evidence: player Z %.2f, ground %s, falling %s, progress age %.2f",
            pz,tostring(ground),ok and tostring(falling) or "unknown",now-(terrain_guard.motion_t or now))
    end
    local distance = R.dist2(px,py,a.x,a.y)
    -- Tell Sentinel about the hazard (a path-avoid zone + soft re-path) so its
    -- next plan goes round it; the local measured escape waits for that answer.
    -- A body-corridor ray hit is not zoned (doorways Sentinel rounds fine).
    if reason ~= "blocked body corridor" and distance > 8
        and N.zone_span(a,b,reason) == "new" then
        return
    end
    -- A lateral waypoint changes the server's route without another movement
    -- driver. Require measured floor, a walkable grade and a clear body corridor.
    if not det and terrain_guard.tries<=2 and N.recover_path({x=cur.x,y=cur.y,z=cur.z,mode=cur.mode},
        terrain_guard.tries%2==1 and 1 or -1,reason .. " measured escape") then
        return
    end
    if distance > 8 and terrain_guard.tries <= 2 then
        if now - (terrain_guard.replan_t or -1e9) < 2 then return end
        terrain_guard.replan_t = now
        N.regen(c, reason .. " ahead")
    else
        terrain_guard.goal_z,terrain_guard.blocked_until = cur.z,now + 30
        local gx,gy,gz=cur.x,cur.y,cur.z
        N.stop(reason .. " ahead", true)
        record_fail("max_repath_exceeded", gx, gy, gz, false)
        R.trail("nav", "unsafe route stopped before hazard (%.1f yd ahead); deferred for 30 s", distance)
    end
end
N._guard_path = guard_path

-- Select intermediate destinations from the server path, never from a
-- straight line to the goal. Sentinel replans each short leg and the detour
-- lifecycle retains the original destination across holds and completion.
-- 2026-11-15 (user log: "State navigating.following_path -> arrived, arrived ->
-- navigating.awaiting_path" every ~2.5 s = every 12 yd): this split a walk into
-- 12 yd legs, each ENDING in an arrival; the next leg's path was only asked for
-- after it, so the player ran, stopped for the path, ran again. Sentinel's own
-- full path is walked instead (the path guard, the whole-path audit and the
-- rolling horizon cover what the legs were for). N.SEGMENTS = true brings the
-- legs back; they then hand over to the next walk a few yards BEFORE arrival.
N.SEGMENTS = false
local function outdoor_segment(c)
    if not N.SEGMENTS then return false end
    if indoors() or swimming() or det or N.holding() or N.leg_fresh()
        or not cur.x or cur.done or stop_req or cur.scanning
        or cur.mode=="combat" or cur.mode=="npc" or cur.mode=="portal"
        or cur.mode=="swim" or cur.mode=="astar" or cur.mode=="route"
        or S.path_pending(c) or not S.moving(c) then return false end
    local fs=S.full_state(c) or ""
    if fs:find("recovering",1,true) or fs:find("repathing",1,true) then return false end
    local px,py=R.here()
    if not px or not cur.start_x or R.dist2(px,py,cur.start_x,cur.start_y)<1 then return false end
    local points=N.path_ahead(12)
    local p,here=points[#points],points[1]
    if #points<2 or not p.z or R.dist2(here.x,here.y,p.x,p.y)<6
        or R.dist2(p.x,p.y,cur.x,cur.y)<6 or ST.first_steep(points,false) then return false end
    local started = N.detour(p,"12 yd outdoor path segment")
    if started and det then det.segment = true end
    return started
end
N._outdoor_segment = outdoor_segment

-- EARLY PATH AUDIT + CORRIDOR WIDTHS. The moment Sentinel's path for a new walk
-- is in, the WHOLE path (not just the 12/28 yd the guard looks at) is checked
-- once for steep ground with the guard's own grade rules (pure arithmetic, no
-- rays). A steep span 8+ yd away becomes a Sentinel avoidance zone and a soft
-- re-path while the walk has barely started. One audit per walk id, so a
-- re-path can never loop. get_corridor_widths (units undocumented) is read
-- relatively: a stretch under N.TIGHT_W that is also under 60 % of the path's
-- median is a real narrowing - a mounted player gets N.tight_hook (dismount).
N.TIGHT_W, N.TIGHT_LOOK, N.TIGHT_GAP = 2.0, 14, 1.0
N.tight_hook = nil                     -- set by movement.lua: function(width, yards)
local audit = { id = -1, tight_t = -1e9, tight_id = -1 }
N._audit = audit

local function tight_scan(c, log)
    local ws = S.corridor_widths(c)
    local pts = S.current_path(c)
    if not ws or not pts then return end
    local idx = S.path_index(c)
    idx = (type(idx) == "number" and idx >= 1) and math.floor(idx) or 1
    local list = {}
    for i = idx, #ws do if ws[i] then list[#list + 1] = ws[i] end end
    if #list < 3 then return end
    table.sort(list)
    local median = list[math.ceil(#list / 2)]
    local hx, hy = R.here()
    if not hx then return end
    local walked, px, py, min, at = 0, hx, hy, nil, nil
    for i = idx, #pts do
        local p = pts[i]
        if type(p) == "table" and type(p.x) == "number" then
            walked = walked + R.dist2(px, py, p.x, p.y)
            px, py = p.x, p.y
            if walked > N.TIGHT_LOOK then break end
            local w = ws[i]
            if w and (not min or w < min) then min, at = w, walked end
        end
    end
    if log then
        R.trail("nav", "corridor widths: %d points, median %.2f, narrowest within %d yd %s", #list, median,
            N.TIGHT_LOOK, min and string.format("%.2f at %.0f yd", min, at) or "n/a")
    end
    if min and min < N.TIGHT_W and min < median * 0.6 then return min, at end
end

local function audit_new_path(c)
    if not cur.x or cur.done or stop_req or N.holding() then return end
    local m = cur.mode
    if m == "combat" or m == "portal" or m == "swim" or m == "astar" or m == "route" then return end
    if not S.moving(c) or S.path_pending(c) then return end
    local fs = S.full_state(c) or ""
    if fs:find("recovering", 1, true) or fs:find("repathing", 1, true) then return end
    local now = R.now()
    if cur.id ~= audit.id then
        audit.id = cur.id
        local planned = cur.pre and cur.pre.id == cur.id        -- audited before it was walked
        local points = planned and {} or guard_points(N.path_ahead(90))
        if #points >= 2 then
            local i, e = ST.first_steep(points, indoors() or m == "npc", true)
            if i then
                local a, b = points[i], points[e or i + 1]
                local px, py = R.here()
                if px and R.dist2(px, py, a.x, a.y) >= 8 then
                    local r = N.zone_span(a, b, "unsafe slope")
                    R.trail("nav", "path audit: steep span %.1f yd away (rise %.1f / run %.1f) - zone %s",
                        R.dist2(px, py, a.x, a.y), b.z - a.z, R.dist2(a.x, a.y, b.x, b.y), tostring(r))
                    if r then stats.audit_zones = (stats.audit_zones or 0) + 1 end
                end
            end
        end
        tight_scan(c, true)
    end
    -- while mounted: a narrowing ahead -> the hook (dismount), at most once a second
    if N.tight_hook and audit.tight_id ~= cur.id and now - audit.tight_t >= N.TIGHT_GAP then
        audit.tight_t = now
        local ok, mounted = pcall(function() return R.me():is_mounted() end)
        if ok and mounted == true then
            local w, at = tight_scan(c, false)
            if w then
                audit.tight_id = cur.id
                R.trail("nav", "narrow corridor %.2f %.0f yd ahead - mounted, dismount hook", w, at)
                pcall(N.tight_hook, w, at)
            end
        end
    end
end
N._audit_new_path = audit_new_path

-- NEXT-WAYPOINT HINT (user, 2026-11-15: "add the next waypoint hint from the
-- quest engine"). The engine walks a route one waypoint at a time and only
-- looks at the next one once it stands within ARRIVE yd of the current one;
-- that late start is the run, stop, run: Sentinel arrives at the point, the
-- next point's floors are asked for, its path is asked for, the player stands.
-- With the hint (movement.hint_next(pos, key), called by the engine on every
-- route tick) the work is done AHEAD:
--   * at once, while the next point is far: its floors are asked for and cached
--     (a single floor - stacked floors keep their reachability pick), so the
--     later walk starts without a floor query;
--   * within the horizon (>= 20 yd) of the current point: the path from the
--     current point to the next is planned (planning only, nothing walks) and
--     checked for steep ground - a steep span becomes an avoidance zone;
--   * a few yards (speed * latency) before the current point ends, while the
--     player still walks: the walk to the next point is started (a second
--     move_to re-plans without stopping), under the next point's own key - the
--     engine's later request for it finds it already running. The current key
--     stays satisfied (hand) so the engine does not turn the player back.
-- A hint older than HINT_TTL s (the engine stopped walking the route) is dead.
local HINT_TTL, HAND_S = 1.5, 5.0

local function prefetch_floor(c, x, y, z)
    local k = key_of(x, y)
    if corrected_z(x, y, z) then return end
    local st = zscan[k]
    if st and st.checked and st.hint == z and (R.now() - st.t) <= FAIL_WINDOW then return end
    floors_for(c, k, x, y, z, function(list, st2)
        if #list >= 2 then return end          -- stacked floors: the normal walk picks by reachability
        st2.checked, st2.hint = true, z
        if #list == 1 then cache_put(zfix, "zfix", k, { z = list[1], hint = z }) end
    end)
end

local function probe_next(c, a, b)
    S.plan_probe(c, a, b, function(points)
        if type(points) ~= "table" or #points < 2 then return end
        local pts = guard_points(points)
        local i, e = ST.first_steep(pts, indoors(), true)
        if not i then return end
        local p, q = pts[i], pts[e or i + 1]
        local r = N.zone_span(p, q, "unsafe slope")
        R.trail("nav", "next leg audit: steep span (rise %.1f / run %.1f) on the way to the next waypoint - zone %s",
            q.z - p.z, R.dist2(p.x, p.y, q.x, q.y), tostring(r))
        if r == "new" then stats.audit_zones = (stats.audit_zones or 0) + 1 end
    end)
end

--- The engine's word on the waypoint after the current one. Cheap; called on
--- every route tick.
function N.hint_next(pos, key)
    local x, y, z = R.xyz(pos)
    if not x or not key then return false end
    local now = R.now()
    if not hint or hint.key ~= key then
        hint = { key = key, x = x, y = y, z = z, t = now, floors = false, probed = false }
    end
    hint.t = now
    return true
end

local function hint_tick(c)
    if hand and (R.now() > hand.until_t or not cur.x or cur.done) then hand = nil end
    if not hint or R.now() - hint.t > HINT_TTL then return end
    if cur.mode ~= "guide" or not cur.x or cur.done or det or stop_req or N.holding() or R.turning
        or not S.moving(c) or swimming() then return end
    local hx, hy = R.here()
    if not hx then return end
    -- the hint must be a waypoint other than the one being walked
    if R.dist2(cur.x, cur.y, hint.x, hint.y) < 3 then return end
    if wp_walk.key == hint.key then return end
    if not hint.floors and R.dist2(hx, hy, hint.x, hint.y) >= FLOOR_FIRST then
        hint.floors = true
        prefetch_floor(c, hint.x, hint.y, hint.z)
    end
    local to_a = R.dist2(hx, hy, cur.x, cur.y)
    if not hint.probed and to_a <= N.LA.horizon() and not S.path_pending(c) then
        hint.probed = true
        probe_next(c, { x = cur.x, y = cur.y, z = cur.z }, { x = hint.x, y = hint.y, z = corrected_z(hint.x, hint.y, hint.z) or hint.z })
    end
    -- hand over a few yards before this waypoint ends
    local lead = math.max(4, math.min(10, N.LA.speed * (N.LA.latency + 0.3)))
    if to_a > lead or S.path_pending(c) or not replaceable(c) then return end
    local from_key = wp_walk.key
    if not from_key then return end
    local ok = N.nav_to({ x = hint.x, y = hint.y, z = hint.z }, true, "guide")
    local z = corrected_z(hint.x, hint.y, hint.z) or hint.z
    if ok and same_destination(hint.x, hint.y, z) then
        hand = { from = from_key, to = hint.key, until_t = R.now() + HAND_S }
        N.LA.last_ask = "next waypoint hint"
        stats.handovers = (stats.handovers or 0) + 1
        R.trail("nav", "next waypoint hint: %.1f yd before the current point, walking on to (%.0f, %.0f) without a stop",
            to_a, hint.x, hint.y)
    end
end
N._hint_tick = hint_tick

-- ROLLING PATH HORIZON (user, 2026-11-15: "calculates and creates pathing 20
-- yards ahead of the player ... the player movement isn't waiting on a generated
-- path"). A walk never lets its planned path run out under the player: while
-- Sentinel walks, the path left ahead is measured every LA.GAP s, and when it is
-- shorter than the horizon (LA.H = 20 yd at least) while the goal is still
-- farther than the path's end, the walk is handed to Sentinel AGAIN at once -
-- a second move_to re-plans without stopping (recorded 0.12 s), so the next
-- stretch is generated while the player is still walking the buffer instead of
-- after it ends (the stall, the "arrived short" re-plan, the 5 s waypoint
-- recheck). The horizon grows with the measured path latency and walking speed
-- (speed * (latency + 0.5 s)), capped at LA.H_MAX, so a slow server or a mount
-- still gets its answer before the buffer is gone. Guard: needs 4 yd of progress
-- toward the goal between two re-issues, at most LA.MAX per goal chain.
-- Sentinel does the planning; this only decides WHEN to ask. Off for combat,
-- NPC, portal, swim, A* and recorded-route walks and while a detour runs.
local LA = { H = 20, H_MAX = 40, GAP = 0.25, SHORT_YD = 3.0, MIN_GOAL = 25, PROGRESS = 4.0, MAX = 6, CHAIN_S = 60,
    speed = 7, latency = 0.3, last_t = -1e9, id = -1, lat_done = true, pos = nil, pos_t = 0,
    key = nil, n = 0, goal_d = nil, chain_t = -1e9 }
N.LA = LA
local LA_SKIP = { combat = true, npc = true, portal = true, swim = true, astar = true, route = true, corpse = true }

--- The horizon in yards for the speed and path latency measured so far.
function LA.horizon()
    return math.max(LA.H, math.min(LA.H_MAX, LA.speed * (LA.latency + 0.5)))
end

--- Yards of planned path left ahead of the player and the path's last point.
function LA.path_left()
    local pts = N.path_ahead(300)
    if #pts < 2 then return nil end
    local len = 0
    for i = 2, #pts do len = len + R.dist2(pts[i - 1].x, pts[i - 1].y, pts[i].x, pts[i].y) end
    return len, pts[#pts]
end

function LA.tick(c)
    local now = R.now()
    if now - LA.last_t < LA.GAP then return end
    LA.last_t = now
    if not cur.x or cur.done or LA_SKIP[cur.mode or "move"] or det or stop_req or N.holding() or R.turning
        or not S.moving(c) then
        LA.pos, LA.still_t, LA.still_logged = nil, nil, false
        return
    end
    local px, py = R.here()
    if not px then return end
    -- walking speed (only while actually moving) and path latency of this walk
    if LA.pos and now > LA.pos_t then
        local v = R.dist2(px, py, LA.pos.x, LA.pos.y) / (now - LA.pos_t)
        if v > 1 and v < 40 then LA.speed = LA.speed * 0.8 + v * 0.2 end
        -- STALL TELEMETRY: the player stands while a walk runs. Logged once per
        -- stall with what Sentinel and this layer were doing, so a "stutter" in
        -- game can be matched to its cause (awaiting_path after a re-issue, a
        -- recovery, a hold, ...) from the trail.
        if v < 0.5 then
            LA.still_t = LA.still_t or now
            if not LA.still_logged and now - LA.still_t >= 0.6 then
                LA.still_logged = true
                stats.stalls = (stats.stalls or 0) + 1
                R.trail("nav", "stall: standing %.1f s on a running walk - state %s, leg %.1f s old, mode %s, hand %s, last ask: %s",
                    now - LA.still_t, tostring(S.full_state(c)), now - (cur.leg_t or now), tostring(cur.mode),
                    tostring(hand ~= nil), tostring(LA.last_ask or "-"))
            end
        else
            LA.still_t, LA.still_logged = nil, false
        end
    end
    LA.pos, LA.pos_t = { x = px, y = py }, now
    if LA.id ~= cur.id then LA.id, LA.lat_done = cur.id, false end
    if S.path_pending(c) then return end
    if not LA.lat_done then
        LA.lat_done = true
        LA.latency = LA.latency * 0.7 + math.max(0, math.min(5, now - cur.t)) * 0.3
    end
    local fs = S.full_state(c) or ""
    if fs:find("recovering", 1, true) or fs:find("repathing", 1, true) then return end
    local goal_d = R.dist2(px, py, cur.x, cur.y)
    if goal_d < LA.MIN_GOAL or not replaceable(c) then return end
    local key = key_of(cur.x, cur.y)
    if LA.key ~= key or now - LA.chain_t > LA.CHAIN_S then LA.key, LA.n, LA.goal_d = key, 0, nil end
    if LA.n >= LA.MAX then return end
    if LA.goal_d and goal_d > LA.goal_d - LA.PROGRESS then return end      -- no progress since the last ask
    local left, last = LA.path_left()
    local H = LA.horizon()
    if not left or left >= H then return end
    if R.dist2(last.x, last.y, cur.x, cur.y) <= LA.SHORT_YD then return end   -- the path reaches the goal
    LA.n, LA.goal_d, LA.chain_t = LA.n + 1, goal_d, now
    stats.horizon = (stats.horizon or 0) + 1
    local pre = cur.pre
    if pre and pre.id == cur.id and not pre.done and pre.started then
        LA.last_ask = "path extension"
        R.trail("nav", "horizon: %.0f yd of path left (want %.0f), goal %.0f yd away - planning the continuation from the path's end",
            left, H, goal_d)
        pre.extend()
        return
    end
    R.trail("nav", "horizon: %.0f yd of path left (want %.0f: speed %.1f, latency %.2f s), goal %.0f yd away - next path requested while walking",
        left, H, LA.speed, LA.latency, goal_d)
    LA.last_ask = "path horizon"
    walk_again(c, { x = cur.x, y = cur.y, z = cur.z, mode = cur.mode, route = cur.route }, "path horizon")
end

function N.pulse()
    if escape_poll then escape_poll() end
    if det and R.now() > det.until_t then detour_done("took too long") end      -- 1.7.23
    -- a path SEGMENT hands over to the next walk before its end: the new move_to
    -- re-plans without stopping, so the player never stands for the next path
    if det and det.segment then
        local hx, hy = R.here()
        local c0 = N.client()
        local lead = math.max(3, math.min(10, N.LA.speed * (N.LA.latency + 0.3)))
        if hx and c0 and S.moving(c0) and not S.path_pending(c0) and (R.now() - cur.t) >= FRESH_LEG
            and R.dist2(hx, hy, det.x, det.y) <= lead then
            detour_done("handed over before arrival")
        end
    end
    -- 1.7.5: death or a loading screen flagged by the event callback - the walk
    -- stops here, on the update tick (Sentinel does not stop on death / loading)
    local nf = event_flags()
    if nf and nf.stop then
        local why = nf.stop
        nf.stop = nil
        held.reasons, held.dest = {}, nil
        N.stop(why)
        R.trail("nav", "walk stopped: %s", why)
    end
    local c = N.client()
    if not c then return end
    if stop_req then
        if not S.moving(c) and not S.path_pending(c) then
            stop_req = nil
        elseif not S.path_pending(c) and (R.now() - (cur.leg_t or 0)) >= FRESH_LEG then
            S.stop(c)
            R.trail("nav", "deferred stop sent (%s)", tostring(stop_req.reason))
            stop_req = nil
        end
    end
    -- a walk of ours that Sentinel ended without a callback (its UI stopped it,
    -- another consumer took over): closed here
    if cur.x and not cur.done and not cur.scanning and (R.now() - cur.t) >= LOST_WALK then
        local st = S.state(c)
        if st == "idle" or st == "arrived" then
            cur.done = true
            MEM.walk_ended(false)
            R.trail("nav", "walk to (%.0f, %.0f) ended without a callback (state %s)", cur.x, cur.y, st)
        elseif st == "failed" then
            cur.done = true
            MEM.walk_ended(false)
            record_fail("failed", cur.x, cur.y, cur.z)
        end
    end
    -- 1.9.0: the memory loads with the first client; a walk past a black point
    -- counts; changed snapshots are written (every 10 s at most)
    do   -- a plan with no reply for WAIT_S s: Sentinel plans the walk itself
        local st = cur.pre
        if st and st.id == cur.id and st.planning and not st.started and not st.done
            and R.now() - (st.plan_t or R.now()) > PRE.WAIT_S then
            st.planning = false
            st.fallback("no reply in " .. PRE.WAIT_S .. " s")
        end
    end
    pcall(N.flush_stuck_zones, c)
    pcall(hint_tick, c)
    pcall(LA.tick, c)
    pcall(audit_new_path, c)
    if guard_path(c) then outdoor_segment(c) end
    MEM.load()
    if cur.mode ~= "combat" and S.moving(c) then MEM.tick(R.here()) end
    MEM.flush()
end

-- ----------------------------------------------------------------------------
-- failures
-- ----------------------------------------------------------------------------
function N.last_fail_reason() return fail.reason end
function N.last_fail_offmesh() return fail.offmesh == true end
function N.clear_fail() fail.reason, fail.offmesh = nil, false end

--- A walk is being planned or its floors are being asked for - not a stand.
function N.pending()
    if AS.searching() then return true end          -- the local A* search (the player stands)
    local c = N.client()
    if c and cur.x and not cur.done and S.path_pending(c) then return true end
    return cur.scanning ~= nil and cur.scanning == cur.id and (R.now() - (cur.scan_t or 0)) < HEIGHT_SCAN_HOLD
end

--- A failure reason that is the server's, not the place's.
function N.server_trouble(code) return SERVER_CODES[code] == true end

-- ----------------------------------------------------------------------------
-- reachability (validate_destination, cached; never blocks the caller)
-- ----------------------------------------------------------------------------
local reach, reach_n, reach_next = {}, 0, 0

--- false only once Sentinel said "not reachable" (also at the floors there);
--- true while pending, unknown, far, or with no server.
function N.reachable(pos)
    local x, y, z = R.xyz(pos)
    if not x then return true end
    local hx, hy = R.here()
    local far = not hx or R.dist2(hx, hy, x, y) > REACH_TRUST_FAR
    local k = key_of(x, y)
    local t = R.now()
    local e = reach[k]
    if e and (t - e.t) < ((e.ok == false) and REACH_TTL_BAD or REACH_TTL) then
        return e.ok ~= false or far
    end
    local c = N.client()
    if not c or t < reach_next then return true end
    reach_next = t + REACH_GAP
    if reach_n > 300 then reach, reach_n = {}, 0 end
    if not e then reach_n = reach_n + 1 end
    e = { ok = nil, t = t, z = nil }
    reach[k] = e
    S.validate(c, { x = x, y = y, z = z }, function(ok)
        e.t = R.now()
        if ok == true then e.ok = true return end
        if far then e.ok = true return end
        -- the height may be the guess: ask at the floors there before saying no
        floors_for(c, k, x, y, z, function(list)
            local gz = nil
            for i = 1, #list do if math.abs(list[i] - z) > HEIGHT_SAME then gz = list[i] break end end
            if not gz then e.ok, e.t = false, R.now() return end
            S.validate(c, { x = x, y = y, z = gz }, function(ok2)
                e.ok, e.t = ok2 == true, R.now()
                if ok2 == true then e.z = gz cache_put(zfix, "zfix", k, { z = gz, hint = z }) end
            end)
        end)
    end)
    return true
end

function N.node_reachable(pos) return N.reachable(pos) end

--- The ground height found at (x, y) when the given one was wrong, or nil.
function N.reach_z(pos)
    local x, y, z = R.xyz(pos)
    if not x then return nil end
    return corrected_z(x, y, z)
end

function N.reach_forget(pos)
    local x, y = R.xyz(pos)
    if not x then return end
    local k = key_of(x, y)
    if reach[k] then reach[k] = nil end
end

--- One path query (movement/sight, the stuck fan): cb(points|nil, ok, info).
--- False when there is no client to ask.
function N.path_probe(from, to, cb)
    local c = N.client()
    if not c then return false end
    return S.find_path(c, R.point(from), R.point(to), cb)
end

function N.nav_ready()
    local c = N.client()
    return c ~= nil and S.server_up(c)
end

--- 1.3.0 KITE: a ranged retreat point from Sentinel's nav_client:kite (a path
--- round the target at KITE.RADIUS yd; the walk goes to its last point).
--- cb(point | nil). The FIRST answer of an unexpected shape switches kiting
--- off for the session (logged with what came back) - the call was read from
--- the v0.0.6 source, so its v0.24 answer is checked live. True when asked.
local KITE = { RADIUS = 15, off = false, said = false }
N.KITE = KITE
function N.kite(from, target, cb)
    if KITE.off then return false end
    local c = N.client()
    if not c then return false end
    return S.kite(c, R.point(from), R.point(target), KITE.RADIUS, function(pts, ok, info)
        if info and info.shape_bad then
            KITE.off = true
            if not KITE.said then
                KITE.said = true
                R.log("Sentinel kite answered in an unknown shape (" .. tostring(info.got) .. ") - kiting off for this session")
            end
            pcall(cb, nil)
            return
        end
        local last = pts and pts[#pts] or nil
        local x, y, z                          -- (not `last and R.xyz(last)`: that keeps one value)
        if last then x, y, z = R.xyz(last) end
        if x then
            stats.kites = (stats.kites or 0) + 1
            pcall(cb, { x = x, y = y, z = z })
        else
            if info and info.error then R.trail("nav", "kite: no point (%s)", info.error) end
            pcall(cb, nil)
        end
    end)
end

--- Escape destination selection using the public Sentinel reachability API.
--- cb(point | nil); combat owns the bounded request lifetime and starts the walk.
local FLEE = { DISTANCE = 30, off = false, said = false }
N.FLEE = FLEE
function N.flee(from, threats, cb, search_radius, ambient, rejoin_goal)
    if type(threats) ~= "table" or #threats < 1 then return false end
    local c = N.client()
    if not c or not S.server_up(c) then return false end
    local x, y, z = R.xyz(from)
    if not x then return false end
    local radius=type(search_radius)=="number" and math.max(30,math.min(180,search_radius)) or FLEE.DISTANCE
    local enemies = {}
    for _, threat in ipairs(threats) do
        local tx, ty = R.xyz(threat)
        if tx then enemies[#enemies + 1] = { x = tx, y = ty } end
    end
    if #enemies == 0 then return false end
    -- Rank escape headings by worst separation gain. Penalize headings that
    -- initially approach an attacker. Sentinel still plans the actual walk.
    local candidates = {}
    local rings=type(search_radius)=="number" and {radius} or {radius,15,8}
    for _,ring in ipairs(rings) do
    for i = 0, 15 do
        local angle = i * math.pi / 8
        local dx, dy = math.cos(angle), math.sin(angle)
        local px, py = x + dx * ring, y + dy * ring
        local gain, approach = math.huge, 0
        for _, enemy in ipairs(enemies) do
            local ex, ey = enemy.x - x, enemy.y - y
            local before = math.sqrt(ex * ex + ey * ey)
            local ax, ay = enemy.x - px, enemy.y - py
            gain = math.min(gain, math.sqrt(ax * ax + ay * ay) - before)
            approach = math.max(approach, (ex * dx + ey * dy) / math.max(1, before))
        end
        if gain > 3 then
            local risk=0
            for _,hazard in ipairs(ambient or {}) do
                local hx,hy,hz=R.xyz(hazard)
                if hx and math.abs(hz-z)<=8 then
                    local along=math.max(0,math.min(ring,(hx-x)*dx+(hy-y)*dy))
                    local ox,oy=hx-(x+dx*along),hy-(y+dy*along)
                    local clearance=math.sqrt(ox*ox+oy*oy)
                    local aggro=tonumber(hazard.radius) or 20
                    if clearance<aggro then risk=risk+80+(aggro-clearance)*3 end
                end
            end
            -- Compare separation gained per yard so all short cave exits
            -- are not starved behind the entire outer ring's floor queries.
            local benefit=type(search_radius)=="number" and gain or gain/ring*radius
            candidates[#candidates + 1] = { x = px, y = py, z = z, radius=ring, score = benefit - approach * 15 - risk }
        end
    end
    end
    table.sort(candidates, function(a, b)
        if math.abs(a.score-b.score)<0.0001 then return a.radius>b.radius end
        return a.score>b.score
    end)
    -- Only one query at a time: some client versions share their pending
    -- validator. Every candidate has its own token and bounded stage timeout.
    local index, token, done = 0, 0, false
    local recovery=type(search_radius)=="number"
    local reply_budget=recovery and 1.5 or 0.6
    local deadline, stage_until = R.now()+(recovery and 6 or 2.7), R.now()
    local poll, next_candidate
    local function finish(point,path)
        if done then return end
        done=true
        if escape_poll==poll then escape_poll=nil end
        if point then stats.flees=(stats.flees or 0)+1 end
        pcall(cb,point,path)
    end
    next_candidate=function()
        if done then return end
        index,token=index+1,token+1
        if index>#candidates or R.now()>=deadline then
            R.trail("nav","flee: exhausted candidates or deadline")
            finish(nil); return
        end
        local id,point=token,candidates[index]
        -- Give the floor request enough time for a network round trip while
        -- retaining the overall combat deadline. Rapidly replacing queries
        -- discarded every heading in the live two-attacker fight.
        local floor_started=R.now()
        stage_until=math.min(deadline,floor_started+(recovery and 2.5 or 1.2))
        R.trail("nav","flee candidate %d: floor query at %.1f, %.1f",index,point.x,point.y)
        local sent=S.floors(c,point,function(floors)
            R.trail("nav","flee candidate %d: floor reply after %.2f s, current=%s",id,R.now()-floor_started,
                tostring(not done and escape_poll==poll and token==id and R.now()<stage_until))
            if done or escape_poll~=poll or token~=id or R.now()>=stage_until then return end
            local floor=type(floors)=="table" and floors[1]
            -- Recovery validates the whole curved route below (up to two
            -- radii long). Its endpoint rise need not fit the shorter chord.
            -- Combat keeps the conservative direct-distance floor filter.
            local height_run=point.radius*(recovery and 2 or 1)
            if not floor or math.abs(floor-z)>height_run*ST.UP then
                R.trail("nav","flee candidate %d: rejected floor %s (origin Z %.1f)",index,tostring(floor),z)
                next_candidate(); return
            end
            point.z=floor
            stage_until=math.min(deadline,R.now()+reply_budget)
            local accepted=S.validate(c,point,function(reachable,reason,distance)
                if done or escape_poll~=poll or token~=id or R.now()>=stage_until then return end
                R.trail("nav","flee candidate %d: reachable=%s reason=%s distance=%s",index,tostring(reachable),tostring(reason),tostring(distance))
                local route_limit=point.radius*(recovery and 6 or 2)
                if reachable and (distance==nil or (type(distance)=="number" and distance==distance and distance>=0 and distance<=route_limit)) then
                    if type(search_radius)~="number" then finish(point); return end
                    stage_until=math.min(deadline,R.now()+reply_budget)
                    local planned=S.plan_probe(c,from,point,function(raw)
                        if done or escape_poll~=poll or token~=id or R.now()>=stage_until then return end
                        local path={}
                        for _,p in ipairs(raw or {}) do
                            local q=R.point(p)
                            if not q or not R.finite(q.z) then path={} break end
                            path[#path+1]=q
                        end
                        local function near(a,b)
                            return a and R.dist2(a.x,a.y,b.x,b.y)<=5 and math.abs(a.z-b.z)<=3
                        end
                        if #path>=2 and near(path[#path],from) and near(path[1],point) then
                            local reversed={} for j=#path,1,-1 do reversed[#reversed+1]=path[j] end
                            path=reversed
                        end
                        local endpoints=#path>=2 and near(path[1],from) and near(path[#path],point)
                        local route_length=0
                        for n=1,#path-1 do
                            local a,b=path[n],path[n+1]
                            route_length=route_length+R.dist3(a.x,a.y,a.z,b.x,b.y,b.z)
                        end
                        if route_length>route_limit then
                            R.trail("nav","recovery rejected route length %.1f (limit %.1f)",route_length,route_limit)
                            next_candidate(); return
                        end
                        -- Endpoint snapping can put the first mesh point a
                        -- few yards above the player. Include the real entry
                        -- and exit connections, not just the mesh interior.
                        if endpoints then
                            table.insert(path,1,{x=from.x,y=from.y,z=from.z})
                            path[#path+1]={x=point.x,y=point.y,z=point.z}
                        end
                        if endpoints then path=ST.preflight_path(path) end
                        local steep,steep_end
                        if endpoints then steep,steep_end=ST.first_steep(path,nil,true) end
                        R.trail("nav","recovery detour preflight: %d points, endpoints=%s, steep=%s",#path,tostring(endpoints),tostring(steep))
                        if steep then
                            local a,b=path[steep],path[steep_end or steep+1]
                            local trace=require("movement/trace")
                            local ga,gb=trace.player_ground(a,1.5),trace.player_ground(b,1.5)
                            local run_xy=R.dist2(a.x,a.y,b.x,b.y)
                            R.event("nav","recovery_span_rejected",{stage="recovery",
                                ax=a.x,ay=a.y,az=a.z,bx=b.x,by=b.y,bz=b.z,rise=b.z-a.z,run=run_xy,
                                grade=run_xy>0 and (b.z-a.z)/run_xy or nil,limit=ST.UP,
                                ground_start=ga,ground_end=gb,measured_rise=ga and gb and gb-ga or nil,
                                points=#path,span_points=(steep_end or steep+1)-steep+1,candidate=index})
                        end
                        if not endpoints or steep then next_candidate(); return end
                        if not rejoin_goal then finish(point,path); return end
                        -- A safe retreat that immediately returns to the
                        -- same cliff is not recovery. Look beyond the
                        -- retreat's round trip plus normal hazard lookahead;
                        -- a fixed 30 yd check can end before the old obstacle.
                        local onward_limit=radius*2+28
                        stage_until=math.min(deadline,R.now()+reply_budget)
                        local onward=S.plan_probe(c,point,rejoin_goal,function(raw_next)
                            if done or escape_poll~=poll or token~=id or R.now()>=stage_until then return end
                            local next_path={}
                            for _,p in ipairs(raw_next or {}) do
                                local q=R.point(p)
                                if not q or not R.finite(q.z) then next_path={} break end
                                next_path[#next_path+1]=q
                            end
                            -- A goal whose height is a guess (the world-map corpse marker
                            -- answers the ghost's own height when the body's floor is
                            -- unknown) is matched by position alone. A 3 yd height test
                            -- rejected every valid onward route to a body 35 yd above or
                            -- below the guess (log 2026-11-06 15:51: connected=false for
                            -- all candidates, the ghost idle for 110 s).
                            local function near_goal(a)
                                if not a then return false end
                                if rejoin_goal.z_guess then return R.dist2(a.x,a.y,rejoin_goal.x,rejoin_goal.y)<=5 end
                                return near(a,rejoin_goal)
                            end
                            if #next_path>=2 and near(next_path[#next_path],point) and near_goal(next_path[1]) then
                                local reversed={} for j=#next_path,1,-1 do reversed[#reversed+1]=next_path[j] end
                                next_path=reversed
                            end
                            local connected=#next_path>=2 and near(next_path[1],point) and near_goal(next_path[#next_path])
                            local prefix={{x=point.x,y=point.y,z=point.z}}
                            local walked=0
                            if connected then
                                for _,q in ipairs(next_path) do
                                    local a=prefix[#prefix]
                                    local run=R.dist2(a.x,a.y,q.x,q.y)
                                    if walked+run>onward_limit then
                                        local u=(onward_limit-walked)/run
                                        prefix[#prefix+1]={x=a.x+(q.x-a.x)*u,y=a.y+(q.y-a.y)*u,z=a.z+(q.z-a.z)*u}
                                        break
                                    end
                                    prefix[#prefix+1]=q;walked=walked+run
                                end
                            end
                            if connected then prefix=ST.preflight_path(prefix) end
                            local bad,bad_end
                            if connected then bad,bad_end=ST.first_steep(prefix,nil,true) end
                            R.trail("nav","recovery onward preflight: horizon=%.0f connected=%s steep=%s",onward_limit,tostring(connected),tostring(bad))
                            if bad then
                                local a,b=prefix[bad],prefix[bad_end or bad+1]
                                local trace=require("movement/trace")
                                local ga,gb=trace.player_ground(a,1.5),trace.player_ground(b,1.5)
                                local run_xy=R.dist2(a.x,a.y,b.x,b.y)
                                R.event("nav","onward_span_rejected",{stage="onward",
                                    ax=a.x,ay=a.y,az=a.z,bx=b.x,by=b.y,bz=b.z,rise=b.z-a.z,run=run_xy,
                                    grade=run_xy>0 and (b.z-a.z)/run_xy or nil,limit=ST.UP,
                                    ground_start=ga,ground_end=gb,measured_rise=ga and gb and gb-ga or nil,
                                    points=#prefix,candidate=index})
                            end
                            if connected and not bad then finish(point,path) else next_candidate() end
                        end)
                        if not onward and token==id then next_candidate() end
                    end)
                    if not planned and token==id then next_candidate() end
                else next_candidate() end
            end)
            if not accepted and token==id then next_candidate() end
        end)
        if not sent and token==id then next_candidate() end
    end
    poll=function()
        if done then return end
        if S.client()~=c or R.now()>=deadline then finish(nil)
        elseif R.now()>=stage_until then
            R.trail("nav","flee candidate %d: stage timeout; trying another heading",index)
            next_candidate()
        end
    end
    escape_poll=poll
    next_candidate()
    return true
end

--- 1.7.0 LIVE SENTINEL STATUS (restedXP 4.14.0, improvements 5 and 11): the
--- walk's progress, the recorded route's progress, the distance to the
--- destination, the avoidance zone count and the consecutive path failures.
--- Read at most every STATUS.GAP s, on the update tick only (movement.lua's
--- snapshot) - the GUI reads the cached table. nil without a client.
local STATUS = { GAP = 0.5, t = -1e9, v = nil }
function N.status()
    local now = R.now()
    if (now - STATUS.t) < STATUS.GAP then return STATUS.v end
    STATUS.t = now
    local c = N.client()
    if not c then STATUS.v = nil return nil end
    local v = { progress = S.progress(c), route = S.route_progress(c), zones = S.zone_count(c),
        failures = S.failures(c), state = S.state(c),
        -- nav audit 18: what the terrain avoidance has done this session
        terrain = { audit_zones = stats.audit_zones or 0, edge_zones = stats.edge_zones or 0,
            stuck_zones = stats.stuck_zones or 0, zones = stats.zones or 0, stalls = stats.stalls or 0,
            pre_walks = stats.pre_walks or 0, pre_fallbacks = stats.pre_fallbacks or 0,
            pre_regens = stats.pre_regens or 0, pre_extends = stats.pre_extends or 0,
            horizon = stats.horizon or 0, handovers = stats.handovers or 0 } }
    local d = S.destination(c)
    local hx, hy, hz = R.here()
    if d and hx then v.dest_yd = R.dist3(hx, hy, hz, d.x, d.y, tonumber(d.z) or hz) end
    STATUS.v = v
    return v
end

--- One line for the GUI from a status table (no game call).
function N.status_text(v)
    if type(v) ~= "table" then return nil end
    local parts = {}
    local pr = v.progress
    if v.state == "navigating" and pr and pr.total and pr.total > 0 then
        parts[#parts + 1] = string.format("%.0f%% (wp %d/%d)", pr.percent or 0, pr.index or 0, pr.total)
    end
    if v.dest_yd then parts[#parts + 1] = string.format("%.0f yd to go", v.dest_yd) end
    if v.route and v.route.percent then parts[#parts + 1] = string.format("route %.0f%%", v.route.percent) end
    if v.zones and v.zones > 0 then parts[#parts + 1] = string.format("%d zone%s", v.zones, v.zones == 1 and "" or "s") end
    if v.failures and v.failures > 0 then parts[#parts + 1] = string.format("%d failed path%s", v.failures, v.failures == 1 and "" or "s") end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

-- tests
-- ----------------------------------------------------------------------------
-- 1.2.0 AVOID AREAS (user: never walk into the threat range of a mob 3+ levels
-- above the player or an elite - "path-threat avoidance through Sentinel
-- avoidance zones + soft re-path"). N.avoid_area(pos, radius, why): a
-- Sentinel avoidance zone of `radius` yd there (S.add_zone - every path
-- request after it plans round it) and a SOFT re-path of the walk that runs
-- (S.soft_replan - no stop), at most one re-path every AV.REPLAN_GAP s. A spot
-- already zoned (within AV.SAME yd, inside AV.TTL s - Sentinel ages zones out
-- at 120 s) is not zoned again. True when the area is avoided (now or before).
-- ----------------------------------------------------------------------------
local AV = { zones = {}, replan_t = -1e9, REPLAN_GAP = 3.0, SAME = 4.0, TTL = 110 }
N.AV = AV

function N.avoided(x, y)
    local t = R.now()
    for i = #AV.zones, 1, -1 do
        local z = AV.zones[i]
        if (t - z.t) > AV.TTL then table.remove(AV.zones, i)
        elseif R.dist2(z.x, z.y, x, y) <= AV.SAME then return true end
    end
    return false
end

function N.avoid_area(p, radius, why)
    local x, y, z = R.xyz(p)
    if not x then return false end
    if N.avoided(x, y) then return true end
    local c = N.client()
    if not c or not S.add_zone(c, { x = x, y = y, z = z }, radius) then return false end
    AV.zones[#AV.zones + 1] = { x = x, y = y, t = R.now(), r = radius }
    stats.zones = (stats.zones or 0) + 1
    local replanned = false
    if S.moving(c) and (R.now() - AV.replan_t) >= AV.REPLAN_GAP then
        AV.replan_t = R.now()
        replanned = N.regen(c, "mf_avoid")
        stats.soft_replans = (stats.soft_replans or 0) + (replanned and 1 or 0)
    end
    R.trail("nav", "avoid %s: Sentinel avoidance zone %.0f yd at (%.0f, %.0f)%s", tostring(why), radius, x, y,
        replanned and ", path re-planned (soft, no stop)" or "")
    return true
end

--- A hazard span a -> b (steep ground / a drop) as one avoidance zone at its
--- middle: radius from its length (2.5 .. 6 yd, 3.5+ for a drop). Not placed
--- on the player or on the goal (that would trap the walk). Returns "new" when
--- a zone was just added, true when one already covers it, false otherwise.
--- Re-generate the running walk's path (a zone, a hazard, a loop): a
--- precomputed walk plans a fresh path from the player's spot and swaps it in;
--- any other walk asks Sentinel to re-plan softly.
function N.regen(c, reason)
    local st = cur.pre
    if st and st.id == cur.id and not st.done and st.started and cur.x and not cur.done then
        return st.again(reason) == true
    end
    return S.soft_replan(c, reason)
end

function N.zone_point(p, r, kind)
    local px, py = R.here()
    if not px or R.dist2(px, py, p.x, p.y) <= r + 1 then return false end
    if cur.x and R.dist2(cur.x, cur.y, p.x, p.y) <= r + 2 then return false end
    local was = N.avoided(p.x, p.y)
    if not N.avoid_area(p, r, kind) then return false end
    return was and true or "new"
end

function N.zone_span(a, b, kind)
    local mx, my = (a.x + b.x) / 2, (a.y + b.y) / 2
    local r = math.max(2.5, math.min(6, R.dist2(a.x, a.y, b.x, b.y) / 2 + 1.5))
    if kind == "unsupported ground / drop" then r = math.max(r, 3.5) end
    return N.zone_point({ x = mx, y = my, z = ((a.z or 0) + (b.z or 0)) / 2 }, r, kind)
end

--- Queued stuck spots (mem_black) -> Sentinel zones, while a walk runs and the
--- player is clear of them; a spot not zoned within 90 s is dropped.
function N.flush_stuck_zones(c)
    if #stuck_zone == 0 then return end
    local now = R.now()
    local walking = cur.x and not cur.done and S.moving(c)
    for i = #stuck_zone, 1, -1 do
        local q = stuck_zone[i]
        if now - q.t > 90 then table.remove(stuck_zone, i)
        elseif walking then
            local r = N.zone_point(q, q.r, "stuck point")
            if r then
                table.remove(stuck_zone, i)
                if r == "new" then stats.stuck_zones = (stats.stuck_zones or 0) + 1 end
            end
        end
    end
end
N._stuck_zone = stuck_zone

function N._reset()
    audit.id, audit.tight_id = -1, -1
    LA.id, LA.key, LA.n, LA.goal_d, LA.pos, LA.last_t = -1, nil, 0, nil, nil, -1e9
    hint, hand = nil, nil
    for i = #stuck_zone, 1, -1 do stuck_zone[i] = nil end
    escape_poll = nil
    blocked_terrain,orbit = {},{}
    terrain_guard = { next_t=0, key=nil, tries=0, blocked_until=0 }
    cur = { id = 0, x = nil, y = nil, z = nil, mode = nil, t = 0, route = nil, done = false }
    fail = { reason = nil, offmesh = false, t = 0 }
    fails_at, zfix, zscan, reach, reach_n = {}, {}, {}, {}, 0
    cache_n = { fails = 0, zfix = 0, zscan = 0 }
    stop_req, held, det = nil, { reasons = {}, dest = nil }, nil
    wp_walk = { key = nil, t = -1e9, failed = nil }
    warned = nil
end

return N
