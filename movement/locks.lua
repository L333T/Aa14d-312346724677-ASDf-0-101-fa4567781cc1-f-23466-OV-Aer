-- ============================================================================
-- Master Farmer - Forever Questing
-- movement/locks.lua - rest, cast, channel and loot holds; backpedal
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Product version: see version.lua
-- ============================================================================
-- HOLDS go through movement/nav N.pause(reason) / N.resume(reason) - reasons
-- are counted separately, so a cast hold and a loot hold do not undo each
-- other. 1.1.0: Sentinel has no pause, so a hold stops the walk and nav walks
-- the remembered destination again when the last hold lifts; a new walk does
-- not start while the player casts or channels (movement/nav start_blocked).
-- The hold here covers the moment before the cast starts, when moving would
-- cancel it. Each hold has an end time and is lifted by the pulse even if
-- nobody calls release().
--
-- REST halts everything and refuses travel and combat movement until lifted.
--
-- BACKPEDAL (Frost Nova, hunter dead zone, unstacking) walks backwards with
-- the core movement keys for a set time, with an optional jump. While it
-- runs nothing else moves the player (nav refuses).
-- ============================================================================

local R = require("movement/core")
local N = require("movement/nav")

local Lk = {}

local HOLD_MAX = 12.0
local holds = {}               -- reason -> end time

local function hold(reason, seconds)
    seconds = tonumber(seconds) or 1.0
    if seconds > HOLD_MAX then seconds = HOLD_MAX end
    if seconds <= 0 then return end
    if not holds[reason] then N.pause("mf_" .. reason) end
    holds[reason] = R.now() + seconds
end

local function lift(reason)
    if holds[reason] then
        holds[reason] = nil
        N.resume("mf_" .. reason)
    end
end

local function face_pos(pos)
    local x, y, z = R.xyz(pos)
    if not x then return end
    local ok, vec3 = pcall(require, "common/geometry/vector_3")
    local p = (ok and vec3 and vec3.new) and vec3.new(x, y, z) or { x = x, y = y, z = z }
    -- 1.7.2 (CLAUDE_MASTERARTHASNAV_RULES R3.1): no look while the walk owns the
    -- keys - a cast that must face its target stops the walk first
    if N.busy() then N.stop("face for a cast") end
    if N.busy() then return end
    pcall(core.input.look_at, p)        -- audit 2026-10-17: movement_handler is not pumped here
end

--- Hold the walk for a cast of `seconds` and face `unit` (nil = no facing).
function Lk.prepare_cast(unit, seconds)
    hold("cast", seconds)
    if unit then
        local ok, pos = pcall(unit.get_position, unit)
        if ok and pos then face_pos(pos) end
    end
end

function Lk.prepare_channel(unit, seconds)
    Lk.prepare_cast(unit, seconds)
end

--- Hold for a ground-targeted spell at `pos`.
function Lk.prepare_ground(pos, seconds)
    hold("cast", seconds)
    face_pos(pos)
end

function Lk.pause_for_loot(seconds)
    hold("loot", seconds or 2)
end

--- 1.7.8: a cast / channel / loot hold is on (the walk is paused on purpose).
function Lk.holding() return next(holds) ~= nil end

--- Lift the cast / channel / loot holds (not rest).
function Lk.release()
    lift("cast")
    lift("loot")
end

--- The cast ended early (callbacks.lua): only the cast hold goes.
function Lk.cast_cancelled()
    lift("cast")
end

-- ----------------------------------------------------------------------------
-- rest
-- ----------------------------------------------------------------------------
function Lk.set_resting(on)
    on = on == true
    if on and not R.resting then
        N.stop("rest")
        Lk.backpedal_stop()
    end
    R.resting = on
end

function Lk.is_resting() return R.resting == true end

-- ----------------------------------------------------------------------------
-- backpedal
-- ----------------------------------------------------------------------------
local bp = { jump_at = nil, jumped = false, mode = nil }
local BACKPEDAL_JUMP_AT = 0.75 -- s in: the default jump (Frost Nova backpedal)

local function key(name)
    local f = core.input and core.input[name]
    if type(f) == "function" then pcall(f) end
end

--- Walk backwards for `seconds`, jumping `jump_at` s in (default 0.75 s; a
--- value past `seconds` means no jump).
--- True when started, false when one is already running.
function Lk.backpedal(seconds, jump_at)
    if R.backpedal_until or R.resting then return false end
    seconds = tonumber(seconds) or 1.5
    N.stop("backpedal")
    local t = R.now()
    R.backpedal_until = t + seconds
    bp.jump_at = t + (tonumber(jump_at) or BACKPEDAL_JUMP_AT)
    bp.jumped = false
    key("move_backward_start")
    R.trail("move", "backpedal %.1f s", seconds)
    return true
end

function Lk.backpedal_stop()
    if not R.backpedal_until then return end
    R.backpedal_until = nil
    if bp.mode == "blink" then
        bp.mode = nil
        key("move_forward_stop")
        return
    end
    key("move_backward_stop")
end

-- ----------------------------------------------------------------------------
-- 1.7.15 BLINK AWAY (user: Mage, an enemy within 5 yd - turn 180 degrees away,
-- move forward, Blink after 0.25 s, stop after 1.5 s, face the enemy again and
-- go on with the rotation). It runs as a mode of the backpedal hold
-- (R.backpedal_until), so nav, combat walks, facing, the pivot and the indoor
-- jump all leave the keys alone while it runs. Core API: look_at, the forward
-- keys, spellcheck.core_cast (core.spell_book checks + cast_target_spell).
-- ----------------------------------------------------------------------------
Lk.BLINK_ID = 1953
local BLINK_AT, BLINK_END = 0.25, 1.5
local blink = { t0 = 0, cast = false, enemy = nil, away = nil }

local function look(pos)
    if not pos then return end
    local ok, vec3 = pcall(require, "common/geometry/vector_3")
    local p = (ok and vec3 and vec3.new) and vec3.new(pos.x, pos.y, pos.z or 0) or pos
    pcall(core.input.look_at, p)
end

--- Start Blink Away from `enemy` (a unit). True when started.
function Lk.blink_away(enemy)
    if R.backpedal_until or R.resting or not enemy then return false end
    local me = R.me()
    local okp, pp = pcall(function() return me:get_position() end)
    local oke, ep = pcall(function() return enemy:get_position() end)
    if not (okp and pp and oke and ep) then return false end
    local dx, dy = pp.x - ep.x, pp.y - ep.y
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 0.05 then dx, dy, l = 1, 0, 1 end             -- standing on it: any direction
    N.stop("blink away")
    local t = R.now()
    R.backpedal_until = t + BLINK_END
    bp.mode, bp.jump_at, bp.jumped = "blink", nil, true
    blink.t0, blink.cast, blink.enemy = t, false, enemy
    blink.away = { x = pp.x + dx / l * 15, y = pp.y + dy / l * 15, z = pp.z }
    look(blink.away)                                       -- 180 degrees: facing away from the enemy
    key("move_forward_start")
    R.trail("move", "blink away: enemy %.1f yd - turned away, running", l)
    return true
end

function Lk.blinking() return bp.mode == "blink" end

local function blink_tick(t)
    if bp.mode ~= "blink" then return end
    if not blink.cast and t - blink.t0 >= BLINK_AT then
        blink.cast = true
        look(blink.away)                                   -- still facing away for the Blink
        local ok_s, spellcheck = pcall(require, "spellcheck")
        local sent = false
        if ok_s and type(spellcheck) == "table" and type(spellcheck.core_cast) == "function" then
            sent = spellcheck.core_cast(Lk.BLINK_ID, nil, { skip_casting = true }) == true
        end
        R.trail("move", "blink away: Blink %s", sent and "cast" or "refused")
    end
    if t >= (R.backpedal_until or 0) then
        local e = blink.enemy
        Lk.backpedal_stop()                                -- move_forward_stop
        local ok, ep = pcall(function() return e:get_position() end)
        if ok and ep then look(ep) end                     -- face the enemy: the rotation goes on
        blink.enemy, blink.away = nil, nil
        R.trail("move", "blink away: done - facing the enemy")
    end
end

function Lk.backpedaling() return R.backpedal_until ~= nil end

--- Per frame: end holds and the backpedal on time.
function Lk.tick(t)
    t = t or R.now()
    for reason, ends in pairs(holds) do
        if t >= ends then lift(reason) end
    end
    if R.backpedal_until and bp.mode == "blink" then
        blink_tick(t)                                      -- 1.7.15
    elseif R.backpedal_until then
        if bp.jump_at and not bp.jumped and t >= bp.jump_at then
            bp.jumped = true
            key("jump")
        end
        if t >= R.backpedal_until then Lk.backpedal_stop() end
    end
end

--- Everything off (bot stop, unload).
function Lk.clear()
    for reason in pairs(holds) do lift(reason) end
    Lk.backpedal_stop()
    R.resting = false
    R.npc_until, R.npc_ev_t = nil, nil
end

return Lk
