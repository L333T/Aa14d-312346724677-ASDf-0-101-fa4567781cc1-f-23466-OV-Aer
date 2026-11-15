-- ============================================================================
-- Master Farmer - Forever Questing
-- movement/trace.lua - ray helpers for Sentinel walks (1.32.0)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- ============================================================================
-- 2026-10-25 (user: "Remove Raycast and traceline rules. Use similar helper
-- logic that the Helper folder contains for Raycast and Traceline that Sentinel
-- can use and implement it"). Desktop\Helper trace.lua / move.lua reworked for a
-- bot that never steers with keys over a Sentinel walk: the rays only LOOK; what
-- they see goes to Sentinel (an avoidance zone + a re-plan) or is one jump.
--
--   T.hit(a, b, flags) / T.clear       one ray (true = something in the way)
--   T.los_xyz(point)                   eye-level line of sight to a point
--   T.path_blocked(me)                 "front" / "left" / "right" / false - the
--                                      Helper's 3-height probes 1 yd ahead
--   T.obstacle_height(me)              highest thing in the next 2 yd above the feet
--   T.leg_blocked(a, b)                knee / chest rays along a walk leg
--   T.clear_spot_near(dest, from)      Helper step_to_xyz: a spot 3-5 yd round
--                                      `dest` with a clear line from `from`
--   T.hit_z(x, y, top, bottom, which)  the height a vertical ray meets something
--                                      (an 8-step binary search: trace_line only
--                                      says hit / no hit) - false = nothing there
--   T.ground_z(p)                      the floor under p: core height query, else
--                                      a ray snap (WMO floors / doodads it misses)
--   T.jump_ok(me, h)                   room to hop an h yd obstacle: head clear above
--                                      it, and no drop past DROP_MAX behind it
--   T.tick(t, ctx)                     every pulse while Sentinel walks: no
--                                      progress for STALL_S with "front" blocked
--                                      -> a low obstacle (JUMP_MIN..JUMP_MAX yd)
--                                      is jumped, a wall gets an avoidance zone
--                                      (Sentinel walks round it itself); 2026-10-26:
--                                      a step with no headroom / a drop behind it is
--                                      a wall too, and a body snagged on a corner at
--                                      the side ("left" / "right") gets a small zone
--                                      on that side
-- 2026-10-26 (user: "Add traceline and raycast logic using logic from this example
-- or similar" - the Orca A* port): hit_z, ground_z, the jump checks and the side
-- snag are from it; its A* is Zygor's movement/astar.lua already.
--
-- SAFEGUARDS (the A* fallback's, movement/astar.lua): T.ON kill switch; at most
-- T.BUDGET rays a frame; a self-check ray down through the ground under the
-- player must hit, else off for the session; T.ERRORS call errors -> off for the
-- session (logged). Never the EntityRender flag (raises / crashed classic).
-- ============================================================================

local R = require("movement/core")

local T = {}

T.ON = true                      -- KILL SWITCH
T.BUDGET = 40                    -- rays per frame (a frame = one R.now() value)
T.ERRORS = 3
T.STALL_S = 0.8                  -- no progress this long with Sentinel walking
T.STALL_YD = 0.4
T.JUMP_MIN, T.JUMP_MAX = 0.45, 1.7   -- yd above the feet: a step Sentinel's walk can hop
T.JUMP_GAP = 2.0
T.WALL_GAP = 5.0
T.WALL_R = 2.5                   -- yd: the avoidance zone put on a wall ahead
T.LOOK_GAP = 0.25                -- s between two looks ahead
T.DROP_MAX = (R.TERRAIN or {}).DROP_MAX or 6.0   -- yd of fall behind an obstacle that is still jumped
T.SNAG_GAP = 4.0                 -- s between two side-snag zones
T.SNAG_R = 1.2                   -- yd: the zone put on a corner at the side
-- 2026-10-28 (user: "Always dismount when attempting to enter doorways, use get
-- player height when mounted, to check entrances to keep player from getting
-- stuck"): get_height() answers the body we have NOW, so mounted it is the
-- taller body. A lintel between the on-foot head and the mounted head is a
-- doorway the player fits through on foot and the mount does not - we come off
-- the mount before it, not after we are wedged in it.
T.DOOR_LOOK = 3.0                -- yd ahead probed for a low entrance
T.DOOR_GAP = 3.0                 -- s between two dismounts
T.DOOR_CLEAR = 0.2               -- yd the mounted body must exceed the on-foot one by
T.GAP_GAP, T.GAP_ZONE_GAP, T.GAP_R = 0.5, 4.0, 1.0   -- s between probes; s between slot zones; zone yd
T.FOOT_H = 2.0                   -- the on-foot body height until a real one is read

local st = { off = false, why = nil, errors = 0, checked = false, frame_t = -1, frame_n = 0,
    pos = nil, pos_t = -1e9, look_t = -1e9, jump_t = -1e9, wall_t = -1e9, snag_t = -1e9,
    door_t = -1e9, foot_h = nil, gap_t = -1e9, gapz_t = -1e9,
    self_t = -1e9, self_n = 0 }        -- the self-check's own retry clock
T._st = st
T.stats = { rays = 0, jumps = 0, walls = 0, snags = 0, doors = 0, gaps = 0 }

local vec3_mod = nil
local function v3(x, y, z)
    if vec3_mod == nil then
        local ok, m = pcall(require, "common/geometry/vector_3")
        vec3_mod = (ok and type(m) == "table") and m or false
    end
    if vec3_mod then return vec3_mod.new(x, y, z) end
    return { x = x, y = y, z = z }
end

local FLAGS = nil
local function flags()
    if FLAGS == nil then
        local ok, enums = pcall(require, "common/enums")
        local cf = ok and type(enums) == "table" and enums.collision_flags or nil
        local function c(...)
            local okc, v = pcall(function(...) return cf.combine(...) end, ...)
            return okc and type(v) == "number" and v or nil
        end
        FLAGS = {
            COLLISION = c("DoodadCollision", "WmoCollision", "EntityCollision", "Terrain"),
            WALK = c("DoodadCollision", "WmoCollision"),
            LOS = c("WmoCollision", "DoodadCollision", "LineOfSight"),
            GROUND = c("DoodadCollision", "WmoCollision", "Terrain"),
        }
        if not (FLAGS.COLLISION and FLAGS.WALK and FLAGS.LOS and FLAGS.GROUND) then FLAGS = false end
    end
    return FLAGS or nil
end

local function turn_off(why)
    if st.off then return end
    st.off, st.why = true, why
    R.log("Ray helpers switched off for this session: " .. tostring(why))
    R.trail("trace", "switched off: %s", tostring(why))
end

function T.enabled() return T.ON and not st.off end

--- One ray; true = something in the way, false = clear, nil = no ray (off, over
--- budget, an error).
function T.hit(a, b, which)
    T.last_hit=nil
    if not T.enabled() then return nil end
    local f = flags()
    if not f then turn_off("no collision flags") return nil end
    if not f[which or "COLLISION"] then return nil end
    local now = R.now()
    if now ~= st.frame_t then st.frame_t, st.frame_n = now, 0 end
    if st.frame_n >= T.BUDGET then return nil end
    st.frame_n = st.frame_n + 1
    T.stats.rays = T.stats.rays + 1
    local ok, hit = pcall(core.graphics.trace_line, v3(a.x, a.y, a.z), v3(b.x, b.y, b.z), f[which or "COLLISION"])
    if not ok then
        st.errors = st.errors + 1
        R.trail("trace", "trace_line failed (%d of %d)", st.errors, T.ERRORS)
        if st.errors >= T.ERRORS then turn_off("trace_line calls fail") end
        return nil
    end
    -- Live Forever evidence (2026-11-05): ground raw=false/native hit=true;
    -- clear air raw=true/native hit=false. trace_line reports CLEAR, not hit.
    if hit == false then
        T.last_hit={source="trace_line",a=a,b=b,mask=which or "COLLISION"}
        return true
    end
    -- The native query returns explicit hit/position/distance. Some Forever
    -- builds miss collision in trace_line; never infer clearance from a
    -- malformed or failed native answer.
    if type(core.graphics.native_intersect) == "function" then
        if st.frame_n >= T.BUDGET then return nil end
        st.frame_n = st.frame_n + 1
        T.stats.rays = T.stats.rays + 1
        local length = R.dist3(a.x,a.y,a.z,b.x,b.y,b.z)
        local good, native_hit, hit_pos, hit_distance = pcall(core.graphics.native_intersect,
            v3(b.x,b.y,b.z), v3(a.x,a.y,a.z), length, f[which or "COLLISION"])
        if not good or type(native_hit) ~= "boolean" then return nil end
        if native_hit then T.last_hit={source="native_intersect",a=a,b=b,mask=which or "COLLISION",
            distance=hit_distance,position=hit_pos} end
        return native_hit
    end
    if hit == true then return false end
    return nil
end
function T.clear(a, b, which)
    local h = T.hit(a, b, which)
    if h == nil then return nil end
    return not h
end

-- SELF-CHECK (auto_bg 2.62.0, session log 2026-10-28: "Ray helpers switched off
-- for this session: self-check: a ray through the ground under the player did
-- not hit", in BOTH plugin loads of one Warsong Gulch session - so the local A*
-- fallback was off for the whole match).
--
-- A trace_line that THROWS is a broken client and still stops every ray user at
-- once (that rule does not change). A trace_line that ANSWERS TRUE is a
-- different thing: it says this one segment hit nothing. The check used to
-- treat the very first such answer as proof the client could not trace, for the
-- rest of the session.
--
-- A miss is expected from plenty of honest positions: in the air after a jump or
-- a knock-back, swimming (the bed can be further down than the segment reached),
-- riding a lift, standing on a thin WMO edge. So the SAMPLE has to be
-- trustworthy before its answer counts - not falling, not swimming, not flying -
-- and it takes SELF_TRIES misses from such positions, SELF_GAP s apart, to
-- conclude the client cannot trace at all. A budget or error answer (nil) is not
-- counted as a miss.
--
-- The segment is also deeper than it was (was +1.5 / -2.0, a 3.5 yd window
-- centred on the feet): the question is only "is there anything under me", and a
-- longer downward leg cannot turn a real hit into a miss.
local SELF_TRIES, SELF_GAP = 5, 2.0
local SELF_UP, SELF_DOWN = 2.0, 5.0

--- Is the player somewhere a ground ray is a fair test? Every predicate is in
--- the live stub (game_object.lua is_falling / is_swimming / is_flying,
--- core.character.is_swimming).
local function sample_ok(me)
    if me == nil then return false end
    local function yes(name)
        local ok, v = pcall(function() return me[name](me) end)
        return ok and v == true
    end
    if yes("is_falling") or yes("is_swimming") or yes("is_flying") then return false end
    local oks, sw = pcall(function() return core.character.is_swimming() end)
    if oks and sw == true then return false end
    return true
end
T._sample_ok = sample_ok

--- The self-check: a ray down through the ground under the player must hit.
--- False until it has passed; it keeps trying rather than condemning the client
--- on one miss.
function T.ready()
    if not T.enabled() then return false end
    if st.checked then return true end
    local now = R.now()
    if now - (st.self_t or -1e9) < SELF_GAP then return false end
    if not sample_ok(R.me()) then return false end
    local x, y, z = R.here()
    if not x then return false end
    st.self_t = now
    if not st.polarity_logged and type(core.graphics.native_intersect)=="function" then
        st.polarity_logged=true
        local f=flags()
        if f then
            for _,probe in ipairs({
                {name="ground",a={x=x,y=y,z=z+2},b={x=x,y=y,z=z-5}},
                {name="air",a={x=x,y=y,z=z+3},b={x=x+0.25,y=y,z=z+3}},
            }) do
                local a,b=probe.a,probe.b
                local tr,raw=pcall(core.graphics.trace_line,v3(a.x,a.y,a.z),v3(b.x,b.y,b.z),f.GROUND)
                local nr,hit,_,distance=pcall(core.graphics.native_intersect,v3(b.x,b.y,b.z),v3(a.x,a.y,a.z),
                    R.dist3(a.x,a.y,a.z,b.x,b.y,b.z),f.GROUND)
                R.trail("trace","polarity evidence %s: trace_ok=%s raw=%s native_ok=%s hit=%s distance=%s",
                    probe.name,tostring(tr),tostring(raw),tostring(nr),tostring(hit),tostring(distance))
            end
        end
    end
    local h = T.hit({ x = x, y = y, z = z + SELF_UP }, { x = x, y = y, z = z - SELF_DOWN }, "GROUND")
    if h == nil then return false end                     -- budget or error, not an answer
    if h == true then
        st.checked = true
        R.trail("trace", "self-check passed (trace_line false = hit)%s",
            (st.self_n or 0) > 0 and string.format(" after %d miss(es)", st.self_n) or "")
        return true
    end
    st.self_n = (st.self_n or 0) + 1
    R.trail("trace", "self-check miss %d of %d: a ray %.0f yd down at %.0f %.0f %.0f hit nothing",
        st.self_n, SELF_TRIES, SELF_UP + SELF_DOWN, x, y, z)
    if st.self_n >= SELF_TRIES then
        turn_off(string.format(
            "self-check: %d rays through the ground under the player did not hit (%d s apart, on foot each time)",
            st.self_n, SELF_GAP))
    end
    return false
end

local function body(me)
    local h = me and select(2, pcall(function() return me:get_height() end))
    if type(h) ~= "number" or h <= 0 or h > 6 then h = 2 end
    return h
end
local function facing(me)
    local ok, f = pcall(function() return me:get_rotation() end)
    return ok and type(f) == "number" and f or nil
end
local function off(x, y, f, ang, reach)
    return x + math.cos(f + ang) * reach, y + math.sin(f + ang) * reach
end

--- Mounted right now? (get_height answers the mounted body while we are.)
local function mounted(me)
    if not me then return false end
    local ok, v = pcall(function() return me:is_mounted() end)
    return ok and v == true
end

--- The body height the player has ON FOOT. get_height() answers the current
--- body, so it is read whenever we are not mounted and remembered for while we
--- are. No rays.
local function foot_height(me)
    if not mounted(me) then
        local h = body(me)
        if h > 0 then st.foot_h = h end
    end
    return st.foot_h or T.FOOT_H
end
T._foot_height = foot_height

--- A doorway / entrance ahead low enough to stop the mount but not the player on
--- foot - true, false, or nil when no ray could be cast. At each probe distance:
--- clear at the waist and at the on-foot head (we fit through on foot) and
--- blocked at the mounted head (the mount does not). Blocked at the waist is a
--- WALL, not a doorway, and is left to the wall logic.
function T.low_entrance(me)
    me = me or R.me()
    local x, y, z = R.here()
    local f = facing(me)
    if not x or not f then return nil end
    local foot = foot_height(me)
    local ride = body(me)                       -- mounted: the taller body
    if ride <= foot + T.DOOR_CLEAR then return false end
    for _, d in ipairs({ 1.0, 2.0, T.DOOR_LOOK }) do
        local px, py = off(x, y, f, 0, d)
        local waist = T.hit({ x = x, y = y, z = z + foot * 0.5 }, { x = px, y = py, z = z + foot * 0.5 }, "COLLISION")
        if waist == nil then return nil end
        if not waist then
            local head = T.hit({ x = x, y = y, z = z + foot }, { x = px, y = py, z = z + foot }, "COLLISION")
            if head == nil then return nil end
            if not head then
                local top = T.hit({ x = x, y = y, z = z + ride }, { x = px, y = py, z = z + ride }, "COLLISION")
                if top == nil then return nil end
                if top then return true end
            end
        end
    end
    return false
end

--- GAP PROBE (nav audit item 8): is there a slot ahead too narrow for the
--- body? At 1.5 and 3 yd ahead: the centre is open at hip height (so it is not a
--- wall) and a ray of half the body width to each side hits on BOTH sides - the
--- opening is narrower than the body. `body_w` is TM.BODY_W on foot, TM.MOUNT_W
--- mounted. Returns true, yards-ahead / false / nil (no ray). Rays only look.
T.GAP_AT = { 1.5, 3.0 }
function T.gap_ahead(me, body_w)
    me = me or R.me()
    local x, y, z = R.here()
    local f = facing(me)
    if not x or not f then return nil end
    local hip = z + body(me) * 0.5
    local half = (body_w or R.TERRAIN.BODY_W) * 0.5
    for _, d in ipairs(T.GAP_AT) do
        local cx, cy = off(x, y, f, 0, d)
        local front = T.hit({ x = x, y = y, z = hip }, { x = cx, y = cy, z = hip }, "WALK")
        if front == nil then return nil end
        if front then return false, d end            -- a wall: the wall logic's job
        local lx, ly = off(cx, cy, f, -1.5708, half)
        local left = T.hit({ x = cx, y = cy, z = hip }, { x = lx, y = ly, z = hip }, "WALK")
        if left == nil then return nil end
        if left then
            local rx, ry = off(cx, cy, f, 1.5708, half)
            local right = T.hit({ x = cx, y = cy, z = hip }, { x = rx, y = ry, z = hip }, "WALK")
            if right == nil then return nil end
            if right then return true, d end
        end
    end
    return false
end

--- Eye-level line of sight from the player to a point (Helper los_xyz).
function T.los_xyz(p, me)
    me = me or R.me()
    local x, y, z = R.here()
    if not x or not p then return nil end
    local h = body(me)
    return T.clear({ x = p.x, y = p.y, z = p.z + h }, { x = x, y = y, z = z + h }, "LOS")
end

local function side_blocked(ax, ay, z, bx, by, h)
    local probes = { { 0.3, 0.3 }, { h * 0.5, h * 0.5 }, { h, h } }      -- feet / waist / head
    for i = 1, #probes do
        local r = T.hit({ x = ax, y = ay, z = z + probes[i][1] }, { x = bx, y = by, z = z + probes[i][2] }, "COLLISION")
        if r == nil then return nil end
        if r then return true end
    end
    return false
end

-- Swept body corridor along a path segment. Perpendicular offsets protect
-- shoulders at corners; three vertical bands include low and high objects.
function T.corridor_blocked(a, b, body_only, measured_floor)
    local len = R.dist2(a.x,a.y,b.x,b.y)
    if len < 0.05 then return false end
    local sx, sy = -(b.y-a.y)/len*0.35, (b.x-a.x)/len*0.35
    local h = body(R.me())
    if body_only then
        local torso=T.hit({x=a.x,y=a.y,z=a.z+math.max(0.8,h*0.5)},
            {x=b.x,y=b.y,z=b.z+math.max(0.8,h*0.5)},"WALK")
        local head=T.hit({x=a.x,y=a.y,z=a.z+h},{x=b.x,y=b.y,z=b.z+h},"WALK")
        if torso==nil or head==nil then return nil end
        return torso and head
    end
    for _, side in ipairs({0,-1,1}) do
        -- Full clearance remains required when validating a detour.
        -- With a separately measured walkable floor, knee-height chords
        -- must not classify the slope itself as an impassable body wall.
        for _, lift in ipairs(measured_floor and {math.max(0.8,h*0.5),h} or {0.3,h*0.5,h}) do
            local hit = T.hit({x=a.x+sx*side,y=a.y+sy*side,z=a.z+lift},
                {x=b.x+sx*side,y=b.y+sy*side,z=b.z+lift}, "WALK")
            if hit == nil then return nil end
            if hit then return true end
        end
    end
    return false
end

--- "front" / "left" / "right" / false: the Helper's probes 1 yd ahead of the
--- player (front first). nil when no ray could be cast.
function T.path_blocked(me)
    me = me or R.me()
    local x, y, z = R.here()
    local f = facing(me)
    if not x or not f then return nil end
    local h = body(me)
    local fx, fy = off(x, y, f, 0, 1)
    local sx, sy = off(x, y, f, 0, 1 / 3)
    local a = side_blocked(x, y, z, sx, sy, h)
    if a == nil then return nil end
    if a or side_blocked(x, y, z, fx, fy, h) then return "front" end
    local rx, ry = off(x, y, f, 1.5708, 1)
    local frx, fry = off(fx, fy, f, 1.5708, 1)
    if side_blocked(rx, ry, z, frx, fry, h) then return "right" end
    local lx, ly = off(x, y, f, -1.5708, 1)
    local flx, fly = off(fx, fy, f, -1.5708, 1)
    if side_blocked(lx, ly, z, flx, fly, h) then return "left" end
    return false
end

--- The height where a ray from `top` straight down to `bottom` first meets
--- something (the Orca port's hit_z) - a binary search, trace_line only says hit
--- or not. false = nothing between, nil = no ray (off / budget / an error).
function T.hit_z(x, y, top, bottom, which, steps)
    local first = T.hit({ x = x, y = y, z = top }, { x = x, y = y, z = bottom }, which)
    if first == nil then return nil end
    if not first then return false end
    local lo, hi = bottom, top
    for _ = 1, steps or 8 do
        local mid = (lo + hi) * 0.5
        local r = T.hit({ x = x, y = y, z = top }, { x = x, y = y, z = mid }, which)
        if r == nil then return nil end
        if r then lo = mid else hi = mid end
    end
    return lo
end

--- The floor under `p` - the game's height query, else a ray snap down (the Orca
--- port's ground_z / Handler:expand). nil when unknown.
function T.ground_z(p)
    if not p then return nil end
    local ok, h = pcall(core.get_height_for_position, v3(p.x, p.y, p.z))
    if ok and type(h) == "number" and h == h and h ~= 0 then return h end
    local z = T.hit_z(p.x, p.y, p.z + 3, p.z - 20, "GROUND", 10)
    return z or nil
end

-- Diagnostic only: preserve the native player XYZ, sample the surface at
-- exactly that XY, and never subtract body height or replace the player Z.
function T.player_ground(p, probe_up)
    if not p then return nil end
    local ok, z = pcall(core.get_height_for_position, v3(p.x, p.y, p.z), { probe_up = probe_up or 0.5 })
    if ok and R.finite(z) and (z ~= 0 or math.abs(p.z) < 8) then return z end
    return nil
end

--- LEDGE TEST along a path edge a -> b (2026-11-15, nav audit item 5): the
--- ground is sampled every ~2 yd (at most 4 samples) EDGE_SIDE yd to each side
--- of the edge; true when the ground beside it lies TM.EDGE_DROP or more below
--- the path - the path runs along a cliff edge. Samples are height queries, not
--- rays; `q` ({ n, max }) is the caller's per-scan query budget. Returns true,
--- drop, x, y / false / nil (budget spent - not an answer).
function T.edge_drop(a, b, q)
    local TM = R.TERRAIN
    local len = R.dist2(a.x, a.y, b.x, b.y)
    if len < 0.5 then return false end
    local ux, uy = (b.x - a.x) / len, (b.y - a.y) / len
    local sx, sy = -uy * TM.EDGE_SIDE, ux * TM.EDGE_SIDE
    local n = math.min(4, math.max(1, math.floor(len / 2)))
    for i = 1, n do
        local u = i / (n + 1)
        local px, py, pz = a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u, a.z + (b.z - a.z) * u
        for _, side in ipairs({ 1, -1 }) do
            if q.n >= q.max then return nil end
            q.n = q.n + 1
            local qx, qy = px + sx * side, py + sy * side
            local g = T.player_ground({ x = qx, y = qy, z = pz }, 1.5)
            if g and pz - g >= TM.EDGE_DROP then return true, pz - g, qx, qy end
        end
    end
    return false
end

--- The highest thing above the feet in the next `yards` (Helper should_jump):
--- three samples, a 6-step height search each. nil when no ray.
function T.obstacle_height(me, yards)
    me = me or R.me()
    local x, y, z = R.here()
    local f = facing(me)
    if not x or not f then return nil end
    yards = yards or 2
    local top = 0
    for _, d in ipairs({ 0.7, 1.2, yards }) do
        local px, py = off(x, y, f, 0, d)
        local hz = T.hit_z(px, py, z + 3, z + 0.05, "COLLISION", 6)
        if hz == nil then return nil end
        if hz and hz - z > top then top = hz - z end
    end
    return top
end

--- Room to hop an obstacle `h` yd high ahead: the head clear above its top 1.2 yd
--- ahead, and no fall past DROP_MAX 2.5 yd ahead. true / false, why / nil (no ray).
function T.jump_ok(me, h)
    me = me or R.me()
    local x, y, z = R.here()
    local f = facing(me)
    if not x or not f or not h then return nil end
    local top = z + h
    local ax, ay = off(x, y, f, 0, 1.2)
    local r = T.hit({ x = ax, y = ay, z = top + 0.15 }, { x = ax, y = ay, z = top + 0.15 + body(me) }, "COLLISION")
    if r == nil then return nil end
    if r then return false, "no headroom over it" end
    local lx, ly = off(x, y, f, 0, 2.5)
    local g = T.ground_z({ x = lx, y = ly, z = top + 0.5 })
    if g and z - g > T.DROP_MAX then return false, string.format("a %.0f yd drop behind it", z - g) end
    return true
end

--- Knee and chest rays along a walk leg a -> b (at most the first 6 yd). true =
--- blocked, false = clear, nil = no ray.
function T.leg_blocked(a, b)
    local dx, dy = b.x - a.x, b.y - a.y
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 0.5 then return false end
    local k = math.min(1, 6 / d)
    local e = { x = a.x + dx * k, y = a.y + dy * k, z = a.z + ((b.z or a.z) - a.z) * k }
    for _, hgt in ipairs({ 0.9, 1.8 }) do
        local r = T.hit({ x = a.x, y = a.y, z = a.z + hgt }, { x = e.x, y = e.y, z = e.z + hgt }, "WALK")
        if r == nil then return nil end
        if r then return true end
    end
    return false
end

--- A spot `near`..`far` yd round `dest` with a clear line from `from` at eye
--- level and knee level (Helper step_to_xyz, 24 directions from the side facing
--- `from` first). nil when none (or no rays).
function T.clear_spot_near(dest, from, near_yd, far_yd)
    if not dest or not from then return nil end
    near_yd, far_yd = near_yd or 3, far_yd or 5
    local yaw = math.atan2(from.y - dest.y, from.x - dest.x)
    for i = 0, 23 do
        local step = math.floor((i + 1) / 2) * (i % 2 == 0 and 1 or -1)
        local a = yaw + math.rad(15) * step
        local n = { x = dest.x + math.cos(a) * near_yd, y = dest.y + math.sin(a) * near_yd, z = dest.z }
        local f = { x = dest.x + math.cos(a) * far_yd, y = dest.y + math.sin(a) * far_yd, z = dest.z }
        local ok1 = T.clear({ x = from.x, y = from.y, z = from.z + 1.8 }, { x = f.x, y = f.y, z = f.z + 1.8 }, "LOS")
        if ok1 == nil then return nil end
        if ok1 then
            local ok2 = T.clear({ x = from.x, y = from.y, z = from.z + 0.9 }, { x = n.x, y = n.y, z = n.z + 0.9 }, "WALK")
            if ok2 == nil then return nil end
            if ok2 then return n end
        end
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- the walk assistant
-- ----------------------------------------------------------------------------
--- Every pulse. ctx = { walking, no_jump, riding, mounted_flying, avoid(p, r, why),
--- jump() }. True when it acted.
function T.tick(t, ctx)
    foot_height(R.me())                         -- no rays; keeps the on-foot height current
    if not T.enabled() or not ctx or not ctx.walking then st.pos = nil return false end
    local x, y, z = R.here()
    if not x then return false end
    -- DOORWAY: this runs while we are still MOVING (the checks below only look
    -- once a walk has stalled) - the point is to be off the mount before the
    -- entrance. Never in the air, and the walk is not stopped: Sentinel keeps the
    -- path it has, we are simply shorter when we reach the gap.
    if type(ctx.dismount) == "function" and not ctx.mounted_flying and mounted(R.me())
        and t - st.door_t >= T.DOOR_GAP and T.ready() then
        if T.low_entrance() == true then
            st.door_t = t
            T.stats.doors = T.stats.doors + 1
            R.trail("trace", "an entrance ahead is too low for the mount (mounted body %.1f yd, on foot %.1f) - dismounting",
                body(R.me()), st.foot_h or T.FOOT_H)
            pcall(ctx.dismount)
            return true
        end
    end
    -- GAP PROBE (every GAP_GAP s while walking, on foot or mounted): a slot ahead
    -- narrower than the body. Mounted -> off the mount before it (as for a low
    -- entrance). On foot -> a narrower-than-body slot cannot be walked: a small
    -- avoidance zone on it so Sentinel plans another way (no keys, no stop).
    if t - st.gap_t >= T.GAP_GAP and T.ready() then
        st.gap_t = t
        local me, ride = R.me(), mounted(R.me())
        local g, d = T.gap_ahead(me, ride and R.TERRAIN.MOUNT_W or R.TERRAIN.BODY_W)
        if g == true then
            T.stats.gaps = T.stats.gaps + 1
            if ride then
                if type(ctx.dismount) == "function" and not ctx.mounted_flying and t - st.door_t >= T.DOOR_GAP then
                    st.door_t = t
                    R.trail("trace", "a slot %.1f yd ahead is narrower than the mount (%.1f yd) - dismounting", d, R.TERRAIN.MOUNT_W)
                    pcall(ctx.dismount)
                    return true
                end
            elseif type(ctx.avoid) == "function" and t - st.gapz_t >= T.GAP_ZONE_GAP then
                st.gapz_t = t
                local f = facing(me) or 0
                local gx, gy = off(x, y, f, 0, d)
                R.trail("trace", "a slot %.1f yd ahead is narrower than the body (%.1f yd) - avoidance zone %.1f yd, re-plan",
                    d, R.TERRAIN.BODY_W, T.GAP_R)
                pcall(ctx.avoid, { x = gx, y = gy, z = z }, T.GAP_R, "slot narrower than the body (ray)")
                return true
            end
        end
    end
    if not st.pos or R.dist3(x, y, z, st.pos.x, st.pos.y, st.pos.z) > T.STALL_YD then
        st.pos, st.pos_t = { x = x, y = y, z = z }, t
        return false
    end
    if t - st.pos_t < T.STALL_S or t - st.look_t < T.LOOK_GAP then return false end
    st.look_t = t
    if not T.ready() then return false end
    local me = R.me()
    local blocked = T.path_blocked(me)
    if (blocked == "left" or blocked == "right") and type(ctx.avoid) == "function" and t - st.snag_t >= T.SNAG_GAP then
        -- front clear, no progress, a corner at the side: a small zone on it
        st.snag_t = t
        local f = facing(me) or 0
        local sx, sy = off(x, y, f, blocked == "right" and 1.5708 or -1.5708, 0.9)
        sx, sy = off(sx, sy, f, 0, 0.5)
        T.stats.snags = T.stats.snags + 1
        R.trail("trace", "snagged on the %s, no progress %.1f s - avoidance zone %.1f yd, re-plan", blocked, t - st.pos_t, T.SNAG_R)
        pcall(ctx.avoid, { x = sx, y = sy, z = z }, T.SNAG_R, "corner at the " .. blocked .. " (ray)")
        st.pos = nil
        return true
    end
    if blocked ~= "front" then return false end
    local h = T.obstacle_height(me)
    if h == nil then return false end
    local hop, why = true, nil
    if h >= T.JUMP_MIN and h <= T.JUMP_MAX then
        hop, why = T.jump_ok(me, h)
        if hop == nil then return false end
    end
    if hop and h >= T.JUMP_MIN and h <= T.JUMP_MAX then
        if ctx.no_jump or ctx.riding or ctx.mounted_flying or t - st.jump_t < T.JUMP_GAP then return false end
        st.jump_t = t
        T.stats.jumps = T.stats.jumps + 1
        R.trail("trace", "an obstacle %.1f yd high ahead, no progress %.1f s - jump", h, t - st.pos_t)
        if type(ctx.jump) == "function" then pcall(ctx.jump) end
        st.pos = nil
        return true
    end
    if (h > T.JUMP_MAX or (not hop and h >= T.JUMP_MIN)) and t - st.wall_t >= T.WALL_GAP and type(ctx.avoid) == "function" then
        st.wall_t = t
        local f = facing(me) or 0
        local wx, wy = off(x, y, f, 0, 1.5)
        T.stats.walls = T.stats.walls + 1
        R.trail("trace", "a wall %.1f yd high ahead%s, no progress %.1f s - avoidance zone %.1f yd, re-plan", h,
            why and (" (" .. why .. ")") or "", t - st.pos_t, T.WALL_R)
        pcall(ctx.avoid, { x = wx, y = wy, z = z }, T.WALL_R, "wall ahead (ray)")
        st.pos = nil
        return true
    end
    return false
end

function T.reset()
    st.pos, st.look_t, st.jump_t, st.wall_t, st.snag_t = nil, -1e9, -1e9, -1e9, -1e9
    st.door_t, st.gap_t, st.gapz_t = -1e9, -1e9, -1e9
end

return T
