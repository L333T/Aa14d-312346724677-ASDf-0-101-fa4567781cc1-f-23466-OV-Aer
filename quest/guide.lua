-- ============================================================================
-- Master Farmer - Forever Questing
-- Guide adapter - RestedXP Guides (core.addons.rested_xp)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Product version: see version.lua
-- ============================================================================
-- THE RESTEDXP READS (Core_Api addon-integrations---project-sylvanas.txt, the
-- RestedXP section; docs/addons.md). Nothing else of RestedXP is read: no
-- guide file is parsed, Guides\*.lua is never read.
--   is_loaded() -> boolean                  gate for everything below
--   has_current_step() -> boolean           tells "no guide" from the zero step
--   get_current_step() -> step              num, is_complete, active, requires,
--                                           requires_step, level, label, goals[]
--   get_current_stickies() -> step[]        the current step is not in it
--   get_objectives(quest_id) -> objective[] text, type, num_required,
--                                           num_fulfilled, finished (always WITH
--                                           a quest id)
--   get_current_waypoint() -> waypoint      map_id, x, y (0-1), dist, title, type,
--                                           goal_num, is_manual, wrong_continent
--   get_step_waypoints() -> waypoint[]      active steps only, dist 0
--   skip_current_step() -> boolean          the one step control
--
-- GOAL FIELDS (the field table of the page): action, quest_id, text,
-- is_complete, text_only, ids, objective / objective_max (.complete), reward
-- (.turnin), money / money_greater_than (.money), item_total / item_operator /
-- item_eq (.itemcount), units (.target / .mob / .unitscan).
--
-- HANDLED ACTIONS - only the tags that field table names:
--   complete                -> "complete"  (walk the arrow, fight the step's units,
--                                           progress from get_objectives)
--   turnin                  -> "turnin"    (the waypoint title's NPC, reward choice)
--   accept                  -> "accept"    (1.0.4, the user: the same NPC lookup as
--                                           a turn-in; done once the quest is in the log)
--   money                   -> "money"     (player copper vs money / money_greater_than)
--   itemcount               -> "itemcount" (bag count of ids vs item_total)
--   target, mob, unitscan   -> "kill"      (the units field)
-- Any other action string is "unknown": logged with its quest id and text and
-- never guessed. The user's answer (2026-10-20): a step whose remaining goals
-- no API handles is skipped with skip_current_step (quest/engine.lua).
--
-- READS ONLY FROM THE UPDATE CALLBACK: main.lua opens the window around
-- on_update (allow_reads); render / GUI only see the last snapshot.
-- ============================================================================

---@type izi_api
local izi = require("common/izi_sdk")

---@type vec3
local vec3 = require("common/geometry/vector_3")

local geometry = require("geometry")

local guide = {}

local MAX_RANGE = 300

-- ============================================================================
-- PLAIN READS (a bound userdata result never leaks)
-- ============================================================================
local function safe(fn)
    local ok, res = pcall(fn)
    if ok then return res end
    return nil
end

local function is_obj(v)
    local t = type(v)
    return t == "table" or t == "userdata"
end

local function index_of(o, k) return o[k] end

local function get(o, k)
    if not is_obj(o) then return nil end
    local ok, v = pcall(index_of, o, k)
    if ok then return v end
    return nil
end

local function call(fn, a, b)
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, a, b)
    if ok then return result end
    return nil
end

local function length_of(o) return #o end

local MAX_LIST = 512
local function to_list(v)
    local out = {}
    if not is_obj(v) then return out end
    local ok, n = pcall(length_of, v)
    if ok and type(n) == "number" and n > 0 then
        for i = 1, math.min(n, MAX_LIST) do out[#out + 1] = get(v, i) end
        return out
    end
    for i = 1, MAX_LIST do
        local item = get(v, i)
        if item == nil then break end
        out[#out + 1] = item
    end
    return out
end

local function as_bool(v) return v == true or v == 1 end

--- Text without WoW escape codes (colours, textures, links).
local function clean_text(s)
    if type(s) ~= "string" or s == "" then return s end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
    s = s:gsub("|r", "")
    s = s:gsub("|T.-|t", "")
    s = s:gsub("|A.-|a", "")
    s = s:gsub("|H.-|h", "")
    s = s:gsub("|h", "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end
guide.clean_text = clean_text

local function as_str(v)
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

local function as_id(v)
    local n = tonumber(v)
    if n and n > 0 then return n end
    return nil
end

--- RestedXP's action string, lower case, a leading "." dropped.
local function norm_action(v)
    local a = string.lower(as_str(v) or "")
    return (a:gsub("^%.", ""))
end

local function plain_goal(raw)
    if not is_obj(raw) then return nil end
    local ids = {}
    for _, v in ipairs(to_list(get(raw, "ids"))) do
        local n = as_id(v)
        if n then ids[#ids + 1] = n end
    end
    local units = {}
    for _, v in ipairs(to_list(get(raw, "units"))) do
        if type(v) == "number" and v > 0 then
            units[#units + 1] = v
        elseif type(v) == "string" then
            local n = tonumber(v)
            local s = clean_text(v)
            -- RestedXP target entries may encode "Name:creatureID". The
            -- numeric suffix is metadata, not part of the visible NPC name.
            if s then s = s:gsub(":+%d+%s*$", ""):gsub("%s+$", "") end
            if n and n > 0 then units[#units + 1] = n elseif s and s ~= "" then units[#units + 1] = s end
        end
    end
    local money_gt = get(raw, "money_greater_than")
    local item_eq = get(raw, "item_eq")
    return {
        action = norm_action(get(raw, "action")),
        quest_id = as_id(get(raw, "quest_id")),
        text = clean_text(as_str(get(raw, "text"))),
        is_complete = as_bool(get(raw, "is_complete")),
        text_only = as_bool(get(raw, "text_only")),
        ids = ids,
        objective = tonumber(get(raw, "objective")) or 0,
        objective_max = tonumber(get(raw, "objective_max")) or 0,
        reward = tonumber(get(raw, "reward")) or 0,
        money = tonumber(get(raw, "money")),
        money_greater_than = (money_gt == nil) and nil or as_bool(money_gt),
        item_total = tonumber(get(raw, "item_total")),
        item_operator = tonumber(get(raw, "item_operator")),
        item_eq = (item_eq == nil) and nil or as_bool(item_eq),
        units = units,
    }
end

local function plain_step(raw)
    if not is_obj(raw) then return nil end
    local goals = {}
    local raw_goals = to_list(get(raw, "goals"))
    for i = 1, #raw_goals do
        local g = plain_goal(raw_goals[i])
        if g then
            g.index = i
            goals[#goals + 1] = g
        end
    end
    return {
        num = tonumber(get(raw, "num")) or 0,
        is_complete = as_bool(get(raw, "is_complete")),
        active = as_bool(get(raw, "active")),
        requires = as_str(get(raw, "requires")) or "",
        requires_step = tonumber(get(raw, "requires_step")) or 0,
        level = tonumber(get(raw, "level")) or 0,
        label = as_str(get(raw, "label")) or "",
        goals = goals,
    }
end

local function plain_waypoint(raw)
    if not is_obj(raw) then return nil end
    return {
        map_id = tonumber(get(raw, "map_id")) or 0,
        x = tonumber(get(raw, "x")),
        y = tonumber(get(raw, "y")),
        dist = tonumber(get(raw, "dist")),
        title = clean_text(as_str(get(raw, "title"))),
        type = string.lower(as_str(get(raw, "type")) or ""),
        goal_num = tonumber(get(raw, "goal_num")),
        is_manual = as_bool(get(raw, "is_manual")),
        wrong_continent = as_bool(get(raw, "wrong_continent")),
    }
end

--- The addon namespace, or nil when this build has no core.addons.rested_xp.
local function api()
    local addons = get(rawget(_G, "core"), "addons")
    local ns = get(addons, "rested_xp")
    if not is_obj(ns) then return nil end
    return ns
end

local errorlog_mod = nil
local function elog()
    if errorlog_mod == nil then
        local ok, mod = pcall(require, "errorlog")
        errorlog_mod = (ok and type(mod) == "table") and mod or false
    end
    return errorlog_mod or nil
end
local function probe(tag)
    local e = elog()
    if e and type(e.probe) == "function" then e.probe(tag) end
end
local function trail(tag, fmt, ...)
    local e = elog()
    if e and type(e.trail) == "function" then e.trail(tag, fmt, ...) end
end

-- audit F7 (port 2026-10-28): quest/diag.lua - logging only, never consulted
-- by a decision. Lazy, so it cannot affect this file's load order, and
-- nil-safe throughout.
local diag_mod = nil
local function diag()
    if diag_mod == nil then
        local ok, m = pcall(require, "quest/diag")
        diag_mod = (ok and type(m) == "table") and m or false
    end
    return diag_mod or nil
end
guide.diag = diag
-- One closure, not one per read: resolved through the guide table so it does
-- not depend on where the hold test is declared in this file.
local function held_test(i, g)
    if type(guide.goal_held) ~= "function" then return false end
    return guide.goal_held(i, g) == true
end

local reads_ok = false
local update_id = 0
function guide.allow_reads(on)
    reads_ok = on == true
    if reads_ok then update_id = update_id + 1 end
end

local function ns_call(name, ...)
    if not reads_ok then return nil, "outside the update callback" end
    local ns = api()
    if not ns then return nil, "core.addons.rested_xp missing" end
    local fn = get(ns, name)
    if type(fn) ~= "function" then return nil, name .. " missing" end
    probe("rxp:" .. name)
    local ok, res = pcall(fn, ...)
    if not ok then return nil, tostring(res) end
    return res, nil
end

local function clock()
    local ok, t = pcall(izi.now)
    if ok and type(t) == "number" then return t end
    return 0
end

-- ============================================================================
-- ONE READ PER UPDATE
-- ============================================================================
local snap = {
    t = -1, read_id = nil,
    loaded = false, ready = false,
    step = nil, stickies = {},
    wp = nil, live = nil, step_wps = {},
    objectives = {},           -- quest id -> plain objective list (get_objectives)
    memo = {},
}

local function refresh()
    if not reads_ok then return end
    if snap.read_id == update_id and snap.t >= 0 then return end
    snap.read_id = update_id
    snap.t = clock()
    snap.loaded = as_bool((ns_call("is_loaded")))
    snap.ready, snap.step, snap.stickies = false, nil, {}
    snap.wp, snap.live, snap.step_wps, snap.objectives, snap.memo = nil, nil, {}, {}, {}
    if not snap.loaded then return end
    -- has_current_step() first: get_current_step() is zero-valued without a guide
    if not as_bool((ns_call("has_current_step"))) then return end
    local step = plain_step((ns_call("get_current_step")))
    if not step or step.num == 0 then return end
    snap.ready, snap.step = true, step
    do                                   -- audit F7: step transitions (log only)
        local d = diag()
        if d then pcall(d.step, step, held_test) end
    end
    for _, raw in ipairs(to_list((ns_call("get_current_stickies")))) do
        local st = plain_step(raw)
        if st then snap.stickies[#snap.stickies + 1] = st end
    end
    local arrow = plain_waypoint((ns_call("get_current_waypoint")))
    if arrow and arrow.map_id > 0 and arrow.x and arrow.y
        and arrow.x==arrow.x and arrow.y==arrow.y
        and arrow.x>=0 and arrow.x<=1 and arrow.y>=0 and arrow.y<=1
        and not (arrow.x==0 and arrow.y==0) and not arrow.is_manual then
        snap.wp = arrow
        -- RestedXP-TomTom 1.4.0 mirrors RXPG_ARROW.element. The supported
        -- core bridge returns this shared live waypoint already normalized.
        -- Do not divide these coordinates by 100 a second time.
        snap.live={source="RestedXP live arrow (TomTom mirror)",map_id=arrow.map_id,
            x=arrow.x,y=arrow.y,x_percent=arrow.x*100,y_percent=arrow.y*100,
            step=arrow.goal_num,title=arrow.title,wrong_continent=arrow.wrong_continent,
            observed_at=snap.t}
        trail("live_waypoint","step %s map %d %.2f, %.2f percent; %s%s",
            tostring(arrow.goal_num),arrow.map_id,arrow.x*100,arrow.y*100,
            tostring(arrow.title or ""),arrow.wrong_continent and " (other continent)" or "")
    end
    do                                   -- audit F7: the arrow tally (log only)
        local d = diag()
        if d then
            pcall(d.arrow, arrow and arrow.type or nil,
                arrow ~= nil and arrow.map_id ~= 0 or nil)
        end
    end
    for _, raw in ipairs(to_list((ns_call("get_step_waypoints")))) do
        local wp = plain_waypoint(raw)
        if wp and wp.map_id ~= 0 then snap.step_wps[#snap.step_wps + 1] = wp end
    end
end

local function memo(key, fn)
    refresh()
    local v = snap.memo[key]
    if v == nil then
        v = fn()
        if v == nil then v = false end
        if reads_ok then snap.memo[key] = v end
    end
    if v == false then return nil end
    return v
end

function guide.invalidate()
    snap.t, snap.read_id = -1, nil
    snap.memo = {}
end

function guide.is_loaded() refresh() return snap.loaded end
function guide.ready() refresh() return snap.ready end
function guide.update() refresh() end
function guide.step() refresh() return snap.step end
function guide.stickies() refresh() return snap.stickies end
function guide.step_num()
    local s = guide.step()
    return s and s.num or 0
end

-- ============================================================================
-- OBJECTIVES - get_objectives(quest_id), the argument always given
-- ============================================================================
function guide.objectives(quest_id)
    quest_id = as_id(quest_id)
    if not quest_id then return {} end
    refresh()
    local hit = snap.objectives[quest_id]
    if hit then return hit end
    local out = {}
    if not reads_ok then return out end
    for _, o in ipairs(to_list((ns_call("get_objectives", quest_id)))) do
        if is_obj(o) then
            out[#out + 1] = {
                text = clean_text(as_str(get(o, "text"))),
                type = string.lower(as_str(get(o, "type")) or ""),
                num_required = tonumber(get(o, "num_required")) or 0,
                num_fulfilled = tonumber(get(o, "num_fulfilled")) or 0,
                finished = as_bool(get(o, "finished")),
            }
        end
    end
    snap.objectives[quest_id] = out
    return out
end

--- Is a .complete goal finished? goal.is_complete true is trusted; false is
--- checked against get_objectives: its own objective (objective index, with
--- objective_max when set), else every objective of the quest. nil = RestedXP
--- has no row (unknown).
function guide.complete_done(goal)
    if goal.is_complete then return true end
    local list = guide.objectives(goal.quest_id)
    if #list == 0 then return nil end
    local idx = tonumber(goal.objective) or 0
    if idx > 0 then
        local o = list[idx]
        if not o then return nil end
        if o.finished then return true end
        local want = (goal.objective_max or 0) > 0 and goal.objective_max or nil
        if want and o.num_fulfilled >= want then return true end
        return false
    end
    for i = 1, #list do if not list[i].finished then return false end end
    return true
end

-- ============================================================================
-- CONDITIONS - .money and .itemcount
-- ============================================================================
--- The player's money in copper (game_object:get_gold - get_money does not exist).
function guide.player_copper()
    local me = safe(function() return izi.me() end)
    if not me then return nil end
    local v = safe(function() return me:get_gold() end)
    return tonumber(v)
end

--- .money: true when the comparison is met (money_greater_than true: done once
--- money reaches the threshold; false: once it is below). nil = unknown.
function guide.money_met(goal)
    local need = tonumber(goal.money)
    if not need or goal.money_greater_than == nil then return nil end
    local have = guide.player_copper()
    if not have then return nil end
    if goal.money_greater_than then return have >= need end
    return have < need
end

local function bag_count(id)
    local ok, bags = pcall(require, "bags")
    if not ok or type(bags) ~= "table" or type(bags.count) ~= "function" then return nil end
    local okc, n = pcall(bags.count, id)
    return okc and tonumber(n) or nil
end
guide.bag_count = bag_count

--- .itemcount: the bag count of the goal's ids against item_total with
--- item_operator (-1 less, 0 equal, 1 more) and item_eq (true = <= / >=).
--- Only the goal's own ids are counted. nil = unknown.
function guide.itemcount_met(goal)
    local total, op = tonumber(goal.item_total), tonumber(goal.item_operator)
    if not total or op == nil or type(goal.ids) ~= "table" or #goal.ids == 0 then return nil end
    local have = 0
    for _, id in ipairs(goal.ids) do
        local n = bag_count(id)
        if n == nil then return nil end
        have = have + n
    end
    if op < 0 then
        if goal.item_eq then return have <= total end
        return have < total
    elseif op > 0 then
        if goal.item_eq then return have >= total end
        return have > total
    end
    return have == total
end

-- ============================================================================
-- GOALS AND THE STEP RULES
-- ============================================================================
local ACTIONS = {
    complete = "complete",
    turnin = "turnin",
    accept = "accept",          -- 1.0.4 (user: "add the accept handler ... same NPC lookup as turn-ins")
    collect = "collect",        -- 1.0.8 (log 17:47, step 8 "Nibbled-On Book: 0/1"): loot an item from the step's mobs
    money = "money",
    itemcount = "itemcount",
    target = "kill",
    mob = "kill",
    unitscan = "kill",
    -- 1.13.0 (user: "completes the steps that require using items from inventory
    -- for completing quest tasks OR starting quests"): ".use <item>" is used from
    -- the bags (quest/engine item_goal, quest/bagstart)
    use = "item",
}
guide.ACTIONS = ACTIONS

function guide.classify(goal)
    if type(goal) ~= "table" then return "unknown" end
    return ACTIONS[norm_action(goal.action)] or "unknown"
end

local function skipped(quest_id)
    if type(quest_id) ~= "number" then return false end
    local ok, state = pcall(require, "state")
    if not ok or type(state) ~= "table" or type(state.quest) ~= "table" then return false end
    local bag = state.quest.skipped
    return type(bag) == "table" and bag[quest_id] == true
end
guide.skipped = skipped

--- Does this step still have an unfinished .complete goal (or a kill goal
--- with an unfinished quest of its own)? Kill goals are work only then: a
--- .mob / .target / .unitscan line has no completion of its own to wait on.
local function step_wants_kills(step)
    for _, g in ipairs(step.goals or {}) do
        if not g.text_only and not g.is_complete then
            if g.action == "complete" and guide.complete_done(g) ~= true then return true end
            if ACTIONS[g.action] == "kill" and g.quest_id then
                local list = guide.objectives(g.quest_id)
                for i = 1, #list do if not list[i].finished then return true end end
            end
        end
    end
    return false
end

-- 1.0.1 (user: "turn-in waypoints with no title should never pause"): a goal
-- the bot could not finish here (no NPC took the turn-in) is DEFERRED for a
-- while - the step's next goal, the stickies or the skip rule go on meanwhile.
local deferred = {}            -- "step|sticky|index" -> { t = until, why }
local function goal_key(goal, step)
    return string.format("%d|%s|%d", step and step.num or 0, tostring(goal.sticky_step or 0), goal.index or 0)
end
function guide.defer(goal, seconds, why)
    if type(goal) ~= "table" then return end
    local st = goal.sticky_step and { num = goal.sticky_step } or guide.step()
    deferred[goal_key(goal, st)] = { t = clock() + (seconds or 60), why = why }
    snap.memo = {}
end
local function is_deferred(goal, step)
    local d = deferred[goal_key(goal, step)]
    if d and clock() < d.t then return d.why end
    return nil
end

--- audit F7: is the bot holding this goal itself (guide.defer)? A held goal is
--- not an open goal, and quest/diag must not count it as one. Index-and-goal
--- so diag needs nothing of this file's internals.
function guide.goal_held(index, goal)
    if type(goal) ~= "table" then return false end
    local step = snap.step
    if type(step) ~= "table" then return false end
    return is_deferred(goal, step) ~= nil
end

--- 1.13.0: the quests `step` (the current step) accepts that are not in the log - a set.
function guide.step_open_accepts(step)
    step = step or guide.step()
    local out = {}
    for _, g in ipairs((step or {}).goals or {}) do
        if ACTIONS[g.action] == "accept" and not g.is_complete then
            local list = {}
            if g.quest_id then list[1] = g.quest_id end
            if #list == 0 then for _, id in ipairs(g.ids or {}) do list[#list + 1] = id end end
            for _, q in ipairs(list) do
                if safe(function() return core.quests.is_on_quest(q) end) ~= true and not skipped(q) then out[q] = true end
            end
        end
    end
    return out
end

--- 1.13.0: the item ids the step names - its .use goals' ids, its .collect items.
function guide.step_item_ids(step)
    step = step or guide.step()
    local out, seen = {}, {}
    for _, g in ipairs((step or {}).goals or {}) do
        local a = ACTIONS[g.action]
        local ids = {}
        if a == "item" then ids = g.ids or {} elseif a == "collect" then ids = { (guide.collect_item(g)) } end
        for _, id in ipairs(ids) do
            id = tonumber(id)
            if id and not seen[id] then seen[id] = true out[#out + 1] = id end
        end
    end
    return out
end

--- 1.13.0: the bag item a ".use" goal uses, or nil: its own ids in the bags; else
--- a step item in the bags with a use spell, or (the step accepting a quest not
--- taken yet) the guides' item for that quest or any bag quest starter
--- (quest/bagstart: quest class, no use spell).
function guide.item_for(goal, step)
    if type(goal) ~= "table" then return nil end
    for _, id in ipairs(goal.ids or {}) do
        if (bag_count(id) or 0) > 0 then return id end
    end
    local okb, bs = pcall(require, "quest/bagstart")
    if not okb or type(bs) ~= "table" then return nil end
    local accepts = guide.step_open_accepts(step)
    local any = next(accepts) ~= nil
    for _, id in ipairs(guide.step_item_ids(step)) do
        local f = bs.facts(id)
        if f.quest and (f.spell or any) and bs.has(id) then return id end      -- never a food / drink guess
    end
    if any then
        local okd, rd = pcall(require, "data/rxp_forever")
        for q in pairs(accepts) do
            local it = okd and type(rd) == "table" and type(rd.accept_item) == "function" and rd.accept_item(q) or nil
            if it and bs.has(it) then return it end
        end
        local st = bs.starters()
        if st[1] then return st[1] end
    end
    return nil
end

--- The work state of one goal: "done", "held", "work" or "unhandled" (+ a reason).
local function goal_state(goal, step)
    if goal.text_only then return "done", "text only" end
    if goal.is_complete then return "done", "complete" end
    do
        local why = is_deferred(goal, step)
        if why then return "held", "deferred: " .. tostring(why) end
    end
    local kind = guide.classify(goal)
    if kind == "unknown" then return "unhandled", "action '" .. tostring(goal.action) .. "' has no handler" end
    -- 1.4.0: a goal for quests already completed (none in the log) is done
    -- (quest/done.lua: core.game_ui.get_all_completed_quest_ids, one set)
    do
        local okd, D = pcall(require, "quest/done")
        if okd and type(D) == "table" and D.skip(goal, kind) then return "done", "quest already completed" end
    end
    if kind == "complete" then
        if guide.complete_done(goal) == true then return "done", "objectives finished" end
        return "work"
    end
    if kind == "turnin" then
        if skipped(goal.quest_id) then return "done", "quest skipped in the bot" end
        return "work"
    end
    if kind == "collect" then
        -- 1.0.8: the item in the bags (the count the text or the guides give),
        -- or the quest it serves already taken / done
        local q = goal.quest_id
        local item, need = guide.collect_item(goal)
        if q then
            -- 1.0.25 (log 2026-10-20 22:58-23:10: ".collect 769,4,86" Chunk of
            -- Boar Meat counted done once Pie for Billy (86) was taken, the
            -- BoarMeatQuest sticky never farmed, step 44 waited on it for good):
            -- "quest taken" ends a collect only when the item STARTS that quest
            -- (the guides' accept step uses it, rxp_forever.accept_item) - an
            -- item for the quest's objective is done by the bag count below
            if safe(function() return core.quests.is_on_quest(q) end) == true then
                local okd, rd = pcall(require, "data/rxp_forever")
                local starts = okd and type(rd) == "table" and type(rd.accept_item) == "function"
                    and item ~= nil and rd.accept_item(q) == item
                if starts then return "done", "quest taken" end
            end
            if safe(function() return core.quests.is_quest_flagged_completed(q) end) == true then return "done", "quest done" end
        end
        if item then
            local n = bag_count(item)
            if n and n >= (need or 1) then return "done", "item in the bags" end
        end
        return "work"
    end
    if kind == "accept" then
        -- every quest the goal names (quest_id, else ids) already in the log, or
        -- skipped in the bot (a grey quest): nothing to accept
        local list = {}
        if goal.quest_id then list[1] = goal.quest_id end
        if #list == 0 then for _, id in ipairs(goal.ids or {}) do list[#list + 1] = id end end
        if #list == 0 then return "unhandled", "accept names no quest id" end
        local open = 0
        for _, id in ipairs(list) do
            local on = safe(function() return core.quests.is_on_quest(id) end) == true
            if not on and not skipped(id) then open = open + 1 end
        end
        if open == 0 then return "done", "already on the quest" end
        return "work"
    end
    if kind == "item" then
        -- 1.13.0: nothing in the bags to use: nothing to do here
        if not guide.item_for(goal, step) then return "done", "no item for it in the bags" end
        return "work"
    end
    if kind == "money" then
        local m = guide.money_met(goal)
        if m == true then return "done", "money met" end
        return "unhandled", "money not met (nothing earns money on its own)"
    end
    if kind == "itemcount" then
        local m = guide.itemcount_met(goal)
        if m == true then return "done", "item count met" end
        return "unhandled", "item count not met"
    end
    if kind == "kill" then
        if #(goal.units or {}) == 0 then return "unhandled", "no units named" end
        if not step_wants_kills(step) then return "done", "no unfinished objective on the step" end
        return "work"
    end
    return "unhandled", "no handler"
end
guide.goal_state = goal_state

local function player_level()
    local me = safe(function() return izi.me() end)
    return me and tonumber(safe(function() return me:get_level() end)) or nil
end

--- The decision for this update. Returns a table:
---   state = "no_addon" | "no_step" | "wait_requires" | "inactive" | "wait_level"
---         | "work" | "skip" | "wait_complete" | "wait_deferred"
---   goal  = the goal to work (state "work"), with goal.kind / goal.sticky
---   why   = a reason line
local function compute_decision()
    if not guide.is_loaded() then return { state = "no_addon", why = "RestedXP Guides is not loaded" } end
    if not guide.ready() then return { state = "no_step", why = "RestedXP has no current step" } end
    local step = guide.step()
    if step.requires_step ~= 0 and not step.active then
        -- 1.0.25 (log 2026-10-20 23:06-23:10: "step 44 waits on step 26
        -- (BoarMeatQuest)" every beat, 0 walks issued - the sticky that would
        -- finish the label was never worked, its loop below is only reached on
        -- an active step): the sticky the step requires (num = requires_step,
        -- or label = requires) is WORKED - its first goal to work, as the
        -- sticky loop returns it. Gone from get_current_stickies, or every
        -- goal on it done: waiting cannot finish the label - skipped (the
        -- "inactive" path). Present with goals that are not done but cannot be
        -- worked here: wait.
        local st_s, st = nil, nil
        for s, sk in ipairs(snap.stickies) do
            if sk.num == step.requires_step or (step.requires ~= "" and sk.label == step.requires) then
                st_s, st = s, sk
                break
            end
        end
        local open = false
        if st and not st.is_complete then
            local lvl = player_level()
            local low = lvl and (st.level or 0) > 0 and lvl < st.level
            for _, g in ipairs(st.goals) do
                g.sticky_step = st.num
                local gs = goal_state(g, st)
                if gs == "work" then
                    local kind = guide.classify(g)
                    if not (low and (kind == "kill" or kind == "complete" or kind == "collect")) then
                        g.kind, g.sticky, g.sticky_step = kind, st_s, st.num
                        return { state = "work", goal = g, step = step }
                    end
                    open = true
                elseif gs ~= "done" then
                    open = true
                end
            end
        end
        if not st or st.is_complete or not open then
            return { state = "inactive", why = string.format("step %d waits on step %d (%s), which is %s - skipped",
                step.num, step.requires_step, step.requires, st and "done" or "not a current sticky") }
        end
        return { state = "wait_requires", why = string.format("step %d waits on step %d (%s)", step.num,
            step.requires_step, step.requires) }
    end
    if not step.active then
        -- requires_step 0: the label points at nothing. Its turn-ins do not count.
        return { state = "inactive", why = string.format("step %d is inactive (requires_step 0)", step.num) }
    end
    if step.is_complete then return { state = "wait_complete", why = "RestedXP marked the step complete" } end
    local lvl = player_level()
    local low = lvl and step.level > 0 and lvl < step.level
    local unhandled, held_kill, held_reason = {}, false, nil
    for _, g in ipairs(step.goals) do
        local st, why = goal_state(g, step)
        if st == "work" then
            local kind = guide.classify(g)
            if low and (kind == "kill" or kind == "complete" or kind == "collect") then
                held_kill = true
            else
                g.kind = kind
                return { state = "work", goal = g, step = step }
            end
        elseif st == "held" then
            held_reason = why
        elseif st == "unhandled" then
            unhandled[#unhandled + 1] = { goal = g, why = why }
        end
    end
    -- active stickies: after the current step's own goals, one goal per tick
    for s, st in ipairs(snap.stickies) do
        if st.active and not st.is_complete then
            for _, g in ipairs(st.goals) do
                g.sticky_step = st.num
                local gs = goal_state(g, st)
                if gs == "work" then
                    local kind = guide.classify(g)
                    if not (low and (kind == "kill" or kind == "complete" or kind == "collect")) then
                        g.kind, g.sticky, g.sticky_step = kind, s, st.num
                        return { state = "work", goal = g, step = step }
                    end
                end
            end
        end
    end
    if held_kill then
        return { state = "wait_level", why = string.format("level %d is below step %d's level %d - its kills wait",
            lvl or 0, step.num, step.level) }
    end
    if held_reason then
        return { state = "wait_deferred", why = held_reason, step = step }
    end
    return { state = "skip", unhandled = unhandled, step = step,
        why = (#unhandled > 0) and ("no handler for: " .. unhandled[1].why)
            or "every remaining goal is display text or done" }
end

function guide.decision()
    return memo("decision", compute_decision)
end

--- The goal being worked, or nil.
function guide.goal()
    local d = guide.decision()
    local g = d and d.state == "work" and d.goal or nil
    do                                   -- audit F7: goal transitions (log only)
        local dg = diag()
        if dg then pcall(dg.goal, g) end
    end
    return g
end

function guide.goals()
    local s = guide.step()
    return s and s.goals or {}
end

--- 1.0.8: a collect goal's item id and count - goal.ids (documented for
--- .itemcount; used when present), else the guides' ".collect item,count,quest";
--- the count from the goal text "x/N" when it says.
function guide.collect_item(goal)
    if type(goal) ~= "table" then return nil end
    local item = goal.ids and goal.ids[1] or nil
    local need = nil
    if not item and goal.quest_id then
        local okd, rd = pcall(require, "data/rxp_forever")
        if okd and type(rd) == "table" and type(rd.quest_collect) == "function" then item, need = rd.quest_collect(goal.quest_id) end
    end
    local tn = type(goal.text) == "string" and tonumber(goal.text:match("%d+%s*/%s*(%d+)")) or nil
    return item, tn or need or 1
end

--- skip_current_step(): true when RestedXP moved on.
function guide.skip_current()
    local r = ns_call("skip_current_step")
    guide.invalidate()
    return r == true
end

-- ============================================================================
-- TARGETS - the units field
-- ============================================================================
--- Names and npc ids of the units a goal fights: a kill goal's own units; a
--- .complete goal takes the units of the step's kill goals (RestedXP pairs a
--- .complete line with its .mob lines).
function guide.targets(goal)
    local ids, names = {}, {}
    if type(goal) ~= "table" then return ids, names end
    local function add(list)
        for _, u in ipairs(list or {}) do
            if type(u) == "number" then ids[u] = true elseif type(u) == "string" then names[u] = true end
        end
    end
    local ck = guide.classify(goal)
    if ck == "collect" and goal.quest_id then
        local okd, rd = pcall(require, "data/rxp_forever")
        if okd and type(rd.collect_mobs)=="function" then
            local item = guide.collect_item(goal)
            add(rd.collect_mobs(goal.quest_id,item))
            if next(names) then return ids,names end
        end
    end
    if ck == "kill" then
        add(goal.units)
    elseif ck == "complete" or ck == "collect" then
        local step = guide.step()
        if goal.sticky then
            step = nil
            for _, st in ipairs(snap.stickies) do if st.num == goal.sticky_step then step = st end end
        end
        for _, g in ipairs((step or {}).goals or {}) do
            if ACTIONS[g.action] == "kill" then add(g.units) end
        end
        -- 1.0.5: none on the live step: the Forever guides' .mob lines for the
        -- quest (1.0.8: a collect's too; the step's text_only .mob lines carry
        -- no units on Forever - log 17:47 step 8 "mob ... text 'nil'")
        if next(ids) == nil and next(names) == nil and goal.quest_id then
            local okd, rd = pcall(require, "data/rxp_forever")
            if okd and type(rd) == "table" and type(rd.quest_mobs) == "function" then
                add(rd.quest_mobs(goal.quest_id))
            end
        end
    end
    -- A step can name several species while only one indexed kill objective
    -- remains. Never let the pooled .mob list override that objective. Leave
    -- item collection and unrecognized/localized text on the existing fallback.
    if ck == "complete" and (tonumber(goal.objective) or 0) > 0 then
        local objective = guide.objectives(goal.quest_id)[goal.objective]
        local text = objective and objective.text
        -- Exploration/event completion is triggered at its waypoint. The
        -- quest's other objectives may name mobs, but killing those cannot
        -- complete this objective (for example Frostmane Hold exploration).
        if objective and objective.type == "event" then return {}, {} end
        if type(text) == "string" and objective.type == "monster" then
            local name = text:gsub("^%s*%d+%s*/%s*%d+%s+", ""):match("^%s*(.-)%s+[Ss]lain")
            if name and name ~= "" then
                return {}, { [name] = true }
            end
        end
    end
    return ids, names
end

local targeting_mod = nil
local function targeting()
    if targeting_mod == nil then
        local ok, mod = pcall(require, "targeting")
        targeting_mod = (ok and type(mod) == "table") and mod or false
    end
    return targeting_mod or nil
end

local function visible_objects()
    local t = targeting()
    if t and type(t.visible_objects) == "function" then
        local ok, list = pcall(t.visible_objects)
        if ok and type(list) == "table" then return list end
        return nil
    end
    local ok, list = pcall(function() return core.object_manager.get_visible_objects() end)
    return (ok and type(list) == "table") and list or nil
end

local function tap_denied(u)
    local v = call(u.is_tap_denied, u)
    return v == true or (type(v) == "number" and v ~= 0)
end

--- Can the bot fight this unit? Alive, not a player, attackable, not 6+
--- levels up, not given up on, not in a death zone, in sight.
local function fightable(player, u)
    if not (is_obj(u) and call(u.is_valid, u) == true and call(u.is_unit, u) == true
        and call(u.is_dead_or_ghost, u) ~= true and call(u.is_player, u) ~= true
        and not tap_denied(u) and call(player.can_attack, player, u) == true) then
        return false
    end
    local my_lvl, lvl = call(player.get_level, player), call(u.get_level, u)
    if type(my_lvl) == "number" and type(lvl) == "number" and lvl > my_lvl + 5 then return false end
    local ok_s, st = pcall(require, "state")
    if ok_s and type(st) == "table" and type(st.is_unreachable) == "function" and st.is_unreachable(call(u.get_guid, u)) then
        return false
    end
    local t = targeting()
    if t and type(t.in_death_zone) == "function" and t.in_death_zone(u) then return false end
    if t and type(t.can_see) == "function" then return t.can_see(player, u) == true end
    return true
end
guide.fightable = fightable

--- The closest unit the goal wants that the player can fight, and its distance.
local mob_scan_log_t = -1e9
function guide.find_mob(player, range, goal)
    if not player then return nil, nil end
    range = math.min(tonumber(range) or 40, MAX_RANGE)
    local ids, names = guide.targets(goal)
    if next(ids) == nil and next(names) == nil then return nil, nil end
    local list = visible_objects()
    if type(list) ~= "table" then return nil, nil end
    local best, best_d = nil, nil
    local unsafe_pull, unsafe_elite = false, false
    local matches, nearest, nearest_pos, nearest_name = 0, nil, nil, nil
    for i = 1, #list do
        local u = list[i]
        if is_obj(u) and call(u.is_valid, u) == true and call(u.is_unit, u) == true and call(u.is_player, u) ~= true then
            local uid = call(u.get_npc_id, u)
            local want = (type(uid) == "number" and ids[uid] == true) or names[call(u.get_name, u) or false] == true
            if want then
                local d = call(player.distance_to, player, u)
                matches = matches + 1
                if type(d)=="number" and (not nearest or d<nearest) then
                    nearest, nearest_pos, nearest_name = d, call(u.get_position,u), call(u.get_name,u)
                end
                if type(d) == "number" and d <= range and (best_d == nil or d < best_d) and fightable(player, u) then
                    local t = targeting()
                    -- Defense is handled separately; do not initiate a quest
                    -- pull through a pack just because its name matches.
                    local elite = t and type(t.too_strong)=="function" and t.too_strong(player,u)
                    if not elite and t and type(t.travel_pull_safe) == "function" and t.travel_pull_safe(player, u, 1) then
                        best, best_d = u, d
                    else
                        unsafe_pull = true
                        unsafe_elite = unsafe_elite or elite == true
                    end
                end
            end
        end
    end
    if not best and clock()-mob_scan_log_t>=15 then
        mob_scan_log_t=clock()
        local p=nearest_pos
        trail("quest", "enemy search Q%s: matches=%d range=%.0f unsafe_pack=%s nearest=%s distance=%s XYZ=%s",
            tostring(goal.quest_id),matches,range,tostring(unsafe_pull),tostring(nearest_name),
            nearest and string.format("%.1f",nearest) or "none",
            p and string.format("%.1f,%.1f,%.1f",p.x,p.y,p.z) or "none")
    end
    return best, best_d, unsafe_pull, unsafe_elite
end

--- The closest living, non-hostile unit named `name` within `range` of
--- `center` (the waypoint), or of the player when there is no center.
function guide.find_named_npc(player, name, range, center, exclude)
    if not player or type(name) ~= "string" or name == "" then return nil end
    local list = visible_objects()
    if type(list) ~= "table" then return nil end
    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if is_obj(u) and call(u.is_valid, u) == true and call(u.is_unit, u) == true and call(u.is_player, u) ~= true
            and call(u.is_dead, u) ~= true and call(u.get_name, u) == name
            and not (exclude and exclude[call(u.get_guid, u) or false]) then
            local pos = call(u.get_position, u)
            local d = center and pos and geometry.distance_flat(center, pos) or call(player.distance_to, player, u)
            if type(d) == "number" and d <= range and (best_d == nil or d < best_d) then best, best_d = u, d end
        end
    end
    return best, best_d
end

--- 1.8.0 (user: "Player not interacting with objects to turn in quests"): the
--- closest non-unit OBJECT named `name` (case-insensitive) within `range` of
--- `center` (the waypoint) or of the player - a quest handed in / taken at a
--- cauldron, a diary, a cabinet (Target: Dalson's Tears at the Scourge Cauldron).
function guide.find_named_object(player, name, range, center, exclude)
    if not player or type(name) ~= "string" or name == "" then return nil end
    local list = visible_objects()
    if type(list) ~= "table" then return nil end
    local want = string.lower(name)
    local best, best_d = nil, nil
    for i = 1, #list do
        local o = list[i]
        if is_obj(o) and call(o.is_valid, o) == true and call(o.is_unit, o) ~= true
            and not (exclude and exclude[call(o.get_guid, o) or false]) then
            local n = call(o.get_name, o)
            if type(n) == "string" and string.lower(n) == want then
                local pos = call(o.get_position, o)
                local d = center and pos and geometry.distance_flat(center, pos) or call(player.distance_to, player, o)
                if type(d) == "number" and d <= range and (best_d == nil or d < best_d) then best, best_d = o, d end
            end
        end
    end
    return best, best_d
end

local QUESTGIVER_FLAG = 0x2
--- Does the unit carry the quest-giver npc flag (object:get_npc_flags)?
function guide.gives_quests(u)
    local f = tonumber(call(u.get_npc_flags, u))
    if not f then return false end
    return math.floor(f / QUESTGIVER_FLAG) % 2 == 1
end

--- The closest living quest giver (npc flag 0x2, not attackable) within
--- `range` of `center` (the waypoint) or of the player, skipping `exclude`
--- guids - the turn-in candidates when the waypoint names no NPC.
function guide.nearest_quest_giver(player, center, range, exclude)
    if not player then return nil end
    local list = visible_objects()
    if type(list) ~= "table" then return nil end
    local best, best_d = nil, nil
    for i = 1, #list do
        local u = list[i]
        if is_obj(u) and call(u.is_valid, u) == true and call(u.is_unit, u) == true and call(u.is_player, u) ~= true
            and call(u.is_dead, u) ~= true and call(player.can_attack, player, u) ~= true and guide.gives_quests(u)
            and not (exclude and exclude[call(u.get_guid, u) or false]) then
            local pos = call(u.get_position, u)
            local d = center and pos and geometry.distance_flat(center, pos) or call(player.distance_to, player, u)
            if type(d) == "number" and d <= range and (best_d == nil or d < best_d) then best, best_d = u, d end
        end
    end
    return best, best_d
end

-- ============================================================================
-- WAYPOINTS -> WORLD
-- ============================================================================
-- A RestedXP waypoint is a UI map point with no height (Sentinel Navigation's
-- anav/coords.lua says the same - not required from here). It is converted
-- with core.game_ui.get_world_pos_from_map_pos(map_id, vec2) -> vec2,
-- continent; the continent must equal core.get_map_id() or the point is not
-- walked. wrong_continent true: not walked. The height: core.get_height_for_
-- position (0 is a miss unless the player stands near 0), then the mesh
-- floors (the nav client's get_all_heights) nearest it, then a height
-- movement/nav found a path at (reach_z). The UI map id is not the navmesh map.
local WORLD_LIMIT = 20000
local CONV_MAX = 400
local conv, conv_n = {}, 0

local vec2_mod = nil
local function vec2_new(x, y)
    if vec2_mod == nil then
        local ok, mod = pcall(require, "common/geometry/vector_2")
        vec2_mod = (ok and type(mod) == "table") and mod or false
    end
    if vec2_mod and type(vec2_mod.new) == "function" then
        local ok, v = pcall(vec2_mod.new, x, y)
        if ok and v ~= nil then return v end
    end
    return nil
end

local function finite(n) return type(n) == "number" and n == n and n > -WORLD_LIMIT and n < WORLD_LIMIT end

local function convert(map_id, x, y)
    local mp = vec2_new(x, y)
    if not mp then return nil end
    local gui = safe(function() return core.game_ui end)
    if gui and type(gui.get_world_pos_from_map_pos) == "function" then
        local ok, w, cont = pcall(gui.get_world_pos_from_map_pos, map_id, mp)
        if ok and w ~= nil then
            local wx, wy = tonumber(get(w, "x")), tonumber(get(w, "y"))
            if finite(wx) and finite(wy) and not (wx == 0 and wy == 0) then
                return { x = wx, y = wy, continent = tonumber(cont) }
            end
        end
    end
    return nil
end

local function my_map()
    local ok, id = pcall(function() return core.get_map_id() end)
    return ok and tonumber(id) or nil
end

-- 1.0.3 (log 2026-10-20 17:05: "no walkable waypoint (continent 0, player map
-- 1432)" for every waypoint in Loch Modan): core.get_map_id() answers the
-- zone's UI map (1432) on Forever, while get_world_pos_from_map_pos's second
-- return is "the continent (instance map id)" (game_ui page) - the id
-- core.get_instance_id() answers in the open world ("where it is the
-- continent", core page). The continent is compared with that; a client
-- whose get_map_id() is the instance id matches too.
local function my_instance()
    local ok, id = pcall(function() return core.get_instance_id() end)
    return ok and tonumber(id) or nil
end

--- The mesh floors under (x, y) from the nav client (get_all_heights, async):
--- the one closest to z, or nil while the answer is pending. 1.1.0: asked
--- through movement/nav N.all_heights (Sentinel get_all_heights via
--- movement/sentinel.lua; the values are heights, nearest z first).
local FLOOR_TTL, FLOOR_BAD_TTL, FLOOR_GAP, FLOOR_MAX, FLOOR_DZ = 60, 10, 0.5, 200, 60
local floors, floors_n, floor_next = {}, 0, -1e9
local function floor_value(v)
    if type(v) == "table" then v = v.z end
    v = tonumber(v)
    if finite(v) then return v end
    return nil
end
local function floor_pick(key, x, y, z)
    local t = clock()
    local e = floors[key]
    if e and e.values and (t - e.t) < FLOOR_TTL then
        local best = nil
        for i = 1, #e.values do
            local v = floor_value(e.values[i])
            if v and math.abs(v - z) <= FLOOR_DZ and (best == nil or math.abs(v - z) < math.abs(best - z)) then best = v end
        end
        return best, e.values                               -- 1.0.22: the cached floors too
    end
    if e and e.pending and (t - e.t) < 5 then return nil end
    if e and not e.pending and not e.values and (t - e.t) < FLOOR_BAD_TTL then return nil end
    if not reads_ok or t < floor_next then return nil end
    local nav = package.loaded["movement/nav"]
    if type(nav) ~= "table" or type(nav.all_heights) ~= "function" then return nil end
    floor_next = t + FLOOR_GAP
    if floors_n >= FLOOR_MAX then floors, floors_n = {}, 0 end
    if not e then floors_n = floors_n + 1 end
    local rec = { t = t, pending = true }
    floors[key] = rec
    local okc, sent = pcall(nav.all_heights, { x = x, y = y, z = z }, function(vals)
        rec.pending, rec.t = false, clock()
        if type(vals) == "table" and #vals > 0 then
            rec.values = vals
            local heights={}
            for _,v in ipairs(vals) do local h=floor_value(v); if h then heights[#heights+1]=string.format("%.1f",h) end end
            trail("waypoint","mesh floors at (%.1f, %.1f), hint %.1f: [%s]",x,y,z,table.concat(heights,", "))
        end
    end)
    if not okc or sent ~= true then rec.pending = false end
    return nil
end

--- A RestedXP waypoint in world coordinates (vec3), or nil (no waypoint,
--- wrong continent, not convertible). The second return says why not.
function guide.to_world(wp)
    if type(wp) ~= "table" or (wp.map_id or 0) == 0 then return nil, "no waypoint" end
    if wp.wrong_continent then return nil, "wrong continent (RestedXP)" end
    local x, y = tonumber(wp.x), tonumber(wp.y)
    if not x or not y or x ~= x or y ~= y or x < 0 or x > 1 or y < 0 or y > 1 or (x == 0 and y == 0) then
        return nil, "no map position"
    end
    local key = string.format("%d|%.4f|%.4f", wp.map_id, x, y)
    local e = conv[key]
    if e == nil then
        if conv_n >= CONV_MAX then conv, conv_n = {}, 0 end
        e = convert(wp.map_id, x, y) or false
        conv[key], conv_n = e, conv_n + 1
        if e then
            trail("waypoint", "map %d (%.4f, %.4f) -> world (%.1f, %.1f) continent %s", wp.map_id, x, y, e.x, e.y,
                tostring(e.continent))
        else
            trail("waypoint", "map %d (%.4f, %.4f) could not be converted", wp.map_id, x, y)
        end
    end
    if not e then return nil, "not convertible" end
    local inst, here = my_instance(), my_map()
    if e.continent == nil or not ((inst ~= nil and e.continent == inst) or (here ~= nil and e.continent == here)) then
        return nil, string.format("continent %s, player instance %s / map %s", tostring(e.continent), tostring(inst),
            tostring(here))
    end
    local pos=vec3.new(e.x, e.y, guide.height_at(key, e.x, e.y))
    if wp==snap.wp and snap.live then snap.live.world={x=pos.x,y=pos.y,z=pos.z} end
    return pos
end

--- The height at world (x, y): core.get_height_for_position from the
--- player's own floor (probe_up 4 indoors, 30 then 80 outdoors; a 0 miss
--- counts only near z 0), the nav client's mesh floor nearest it, then a
--- height movement/nav found a path at. `key` caches the mesh floor answer.
-- 1.0.11 (user: the Coords Helper API for indoor and outdoor navigation):
-- within COORDS_NEAR yd of the player the height is coords_helper:
-- get_terrain_height(x, y, extra_height) - a ray down from the PLAYER's own
-- height + extra_height: indoors +4 (the same floor: a higher start hits the
-- floor or ceiling above), outdoors +30 (ground well above the player, a
-- hill). Farther points use the same start: the player's z, probe_up 30,
-- then 80. A probe from z 0 with probe_up 1000 hits the first solid under
-- the sky (a roof, a canopy), which is not the ground being walked.
-- A 0 (no character, or a miss) counts only when the player stands near z 0.
local COORDS_NEAR = 150
local COORDS_UP_IN, COORDS_UP_OUT = 0.5, 30
local coords_mod = nil
local function coords_helper()
    if coords_mod == nil then
        local ok, m = pcall(require, "common/utility/coords_helper")
        coords_mod = (ok and type(m) == "table") and m or false
    end
    return coords_mod or nil
end
guide._coords_reset = function() coords_mod = nil end

-- 1.0.22 THE CAVE FLOOR (user: "When an outdoor walk aims at a cave, the goal
-- height is the hill on top of the cave"). Outdoors the surface sample
-- (coords_helper +30 / probe_up 30 then 80 from the player's floor) is the first solid from above - over
-- a cave, its roof - and the mesh floor nearest it is the hill. From floor_pick's
-- CACHED mesh floors (get_all_heights - not asked more often): when one lies at
-- least CAVE_BELOW yd under the surface sample and within CAVE_NEAR yd of the
-- player's own z, the player stands at the mouth - that floor is the waypoint's
-- z (several: the one nearest the player). The player within CAVE_BELOW yd of the
-- surface (on the hill, a bridge), a single floor, or a lower floor far from
-- the player (not a mouth): today's floor. Not indoors, not swimming.
local CAVE_BELOW, CAVE_NEAR = 8, 6
local cave_logged = nil
local function cave_floor(values, z_surface, mz)
    if type(values) ~= "table" or #values < 2 or not finite(z_surface) or not finite(mz) then return nil end
    if math.abs(mz - z_surface) <= CAVE_BELOW then return nil end
    local best = nil
    for i = 1, #values do
        local v = floor_value(values[i])
        if v and v <= z_surface - CAVE_BELOW and math.abs(v - mz) <= CAVE_NEAR
            and (best == nil or math.abs(v - mz) < math.abs(best - mz)) then
            best = v
        end
    end
    return best
end
guide._cave_floor = cave_floor
local outdoor_floor_log

function guide.height_at(key, ex, ey)
    local e = { x = ex, y = ey }
    local me = safe(function() return izi.me() end)
    local mp = me and safe(function() return me:get_position() end) or nil
    local mz = mp and tonumber(mp.z) or nil
    local indoors = me and safe(function() return me:is_indoors() end) == true
    local swim = safe(function() return core.character.is_swimming() end) == true
    local z = nil
    local near0 = mp and ((e.x - mp.x) ^ 2 + (e.y - mp.y) ^ 2) <= COORDS_NEAR * COORDS_NEAR
    if not swim and not indoors and near0 and mz then
        local ch = coords_helper()
        if ch and type(ch.get_terrain_height) == "function" then
            local okc, h = pcall(ch.get_terrain_height, ch, e.x, e.y, indoors and COORDS_UP_IN or COORDS_UP_OUT)
            if okc and type(h) == "number" and h == h and (h ~= 0 or math.abs(mz) < 8) then z = h end
        end
    end
    if not swim and not z then
        local ok_h, h
        local base = mz or 0
        if indoors and mz then
            ok_h, h = pcall(core.get_height_for_position, vec3.new(e.x, e.y, mz), { probe_up = COORDS_UP_IN })
        else
            -- 1.0.24: from the player's floor, 30 yd up, then 80. Not from
            -- z 0 with probe_up 1000 (that z is a roof or a canopy).
            ok_h, h = pcall(core.get_height_for_position, vec3.new(e.x, e.y, base), { probe_up = COORDS_UP_OUT })
            local good = ok_h and type(h) == "number" and h == h and (h ~= 0 or math.abs(base) < 8)
            if not good then
                ok_h, h = pcall(core.get_height_for_position, vec3.new(e.x, e.y, base), { probe_up = 80 })
            end
        end
        -- a miss answers 0, which is also a real height: 0 counts only near z 0
        if ok_h and type(h) == "number" and h == h and (h ~= 0 or math.abs(base) < 8) then z = h end
    end
    -- A valid low hit can still be the cave under a higher outdoor target:
    -- the +30 probe started inside the hill. Verify that case from the same
    -- bounded +80 origin used for misses, before snapping to a mesh layer.
    -- Indoor queries must retain their shallow origin to avoid ceilings.
    if not indoors and not swim and finite(mz) and finite(z) and z<mz-8 then
        local ok_high,high=pcall(core.get_height_for_position,vec3.new(e.x,e.y,mz),{probe_up=80})
        if ok_high and finite(high) and high~=0 and high>z+8 and high<=mz+80 then
            local t=clock()
            if not outdoor_floor_log or outdoor_floor_log.key~=key
                or math.abs(outdoor_floor_log.z-high)>3 or t-outdoor_floor_log.t>=30 then
                outdoor_floor_log={key=key,z=high,t=t}
                trail("waypoint","outdoor floor corrected at (%.0f, %.0f): low hit %.1f, upper surface %.1f, player %.1f",e.x,e.y,z,high,mz)
            end
            z=high
        end
    end
    z = z or mz or 0
    local near = mp and ((e.x - mp.x) ^ 2 + (e.y - mp.y) ^ 2) <= 150 * 150
    if near then
        local z_surface = z
        local fz, vals = floor_pick(key, e.x, e.y, z)
        if fz then z = fz end
        -- 1.0.22: outdoors, at a cave mouth - the cave floor, not the roof
        if not indoors and not swim then
            local cz = cave_floor(vals, z_surface, mz)
            if cz and math.abs(cz - z) > 0.5 then
                if cave_logged ~= key then
                    cave_logged = key
                    trail("waypoint", "(%.0f, %.0f): surface z %.1f is a roof %.0f yd above the player - the cave floor z %.1f",
                        e.x, e.y, z_surface, z_surface - mz, cz)
                end
                z = cz
            end
        end
    end
    local nav = package.loaded["movement/nav"]
    if type(nav) == "table" and type(nav.reach_z) == "function" then
        local zf = safe(function() return nav.reach_z({ x = e.x, y = e.y, z = z }) end)
        if type(zf) == "number" then z = zf end
    end
    return z
end

--- 1.0.5: a point from the imported guide data (data/rxp_forever guideQuests
--- gotos) in world coordinates, or nil: a world point { wx, wy, instance }
--- (instance must be core.get_instance_id()), or a map point { map, x, y }
--- converted like a RestedXP waypoint.
function guide.point_world(p)
    if type(p) ~= "table" then return nil end
    if type(p.wx) == "number" and type(p.wy) == "number" then
        local inst = my_instance()
        if p.instance ~= nil and inst ~= nil and tonumber(p.instance) ~= inst then return nil end
        local key = string.format("w|%.1f|%.1f", p.wx, p.wy)
        return vec3.new(p.wx, p.wy, guide.height_at(key, p.wx, p.wy))
    end
    if type(p.map) == "number" and type(p.x) == "number" and type(p.y) == "number" then
        return (guide.to_world({ map_id = p.map, x = p.x, y = p.y }))
    end
    return nil
end

--- RestedXP's arrow: the raw waypoint (map_id 0 = none).
function guide.raw_waypoint() refresh() return snap.wp end
-- Cached only: safe for GUI and diagnostic snapshots; no addon/game reads.
function guide.live_navigation() return snap.live end
function guide.raw_step_waypoints() refresh() return snap.step_wps end

--- The arrow in world coordinates: pos, title, dist (dist only when the
--- waypoint is on this continent - wrong_continent makes it meaningless).
function guide.waypoint()
    local wp = guide.raw_waypoint()
    local pos = guide.to_world(wp)
    if not pos then return nil end
    return pos, wp.title, (not wp.wrong_continent) and wp.dist or nil
end

--- The goal's own step waypoint (goal_num = its index) in world coordinates,
--- else the arrow: { pos, title, own }.
-- 1.0.3 (log 2026-10-20 17:05: step 27's waypoint goal_num 27, step 9's 9,
-- step 14's eight route points all 14): a waypoint's goal_num is the STEP it
-- belongs to, not a goal index. A goal's place is RestedXP's arrow when the
-- arrow belongs to the goal's step (the point it is walking now), else that
-- step's last waypoint (its destination). Another step's arrow is used only
-- when `any_arrow` (the .complete handler: "go to the current waypoint").
function guide.goal_waypoint(goal, any_arrow)
    if type(goal) ~= "table" then return nil end
    local num = goal.sticky_step or guide.step_num()
    local arrow = guide.raw_waypoint()
    if arrow and tonumber(arrow.goal_num) == num then
        local pos = guide.to_world(arrow)
        if pos then return { pos = pos, title = arrow.title, own = true } end
    end
    local last = nil
    for _, wp in ipairs(guide.raw_step_waypoints()) do
        if tonumber(wp.goal_num) == num then last = wp end
    end
    if last then
        local pos = guide.to_world(last)
        if pos then return { pos = pos, title = last.title, own = true } end
    end
    if any_arrow then
        local pos, title = guide.waypoint()
        if pos then return { pos = pos, title = title, own = false } end
    end
    return nil
end

--- 1.0.7 (Zygor-style route walking): every waypoint of the goal's step
--- (goal_num = the step) in RestedXP's order, as { pos, title }; the step's
--- live arrow takes precedence for its own step; the list is a fallback.
--- {} when the step has no convertible point here.
local quest_floor_hint
-- A 2-D arrow can sit directly above a cave. Live, living quest enemies
-- near the arrow identify the objective's layer; mesh heights confirm it.
-- This changes only the destination Z, never combat eligibility or steering.
function guide.quest_floor(goal, pos)
    local kind=guide.classify(goal)
    if not pos or (kind~="complete" and kind~="collect" and kind~="kill") then return pos end
    local key=string.format("questfloor|%s|%s|%.1f|%.1f",tostring(goal.sticky_step or guide.step_num()),tostring(goal.quest_id),pos.x,pos.y)
    local t=clock()
    if quest_floor_hint and quest_floor_hint.key==key and t-quest_floor_hint.t<180 then
        return vec3.new(pos.x,pos.y,quest_floor_hint.z), true
    end
    local ids,names=guide.targets(goal)
    if next(ids)==nil and next(names)==nil then return pos end
    local _,values=floor_pick(key,pos.x,pos.y,pos.z)
    if type(values)~="table" or #values<2 then return pos end
    local best,best_d
    for _,u in ipairs(visible_objects() or {}) do
        if is_obj(u) and call(u.is_valid,u)==true and call(u.is_unit,u)==true
            and call(u.is_player,u)~=true and call(u.is_dead_or_ghost,u)==false
            and (ids[call(u.get_npc_id,u) or false] or names[call(u.get_name,u) or false]) then
            local p=call(u.get_position,u)
            if p and finite(p.x) and finite(p.y) and finite(p.z) then
                local d=(p.x-pos.x)^2+(p.y-pos.y)^2
                if d<=60^2 and (not best_d or d<best_d) then
                    for _,v in ipairs(values) do
                        local z=floor_value(v)
                        if z and math.abs(z-p.z)<=6 and math.abs(z-pos.z)>=8 and math.abs(z-pos.z)<=100 then
                            best,best_d=z,d
                        end
                    end
                end
            end
        end
    end
    if best then
        quest_floor_hint={key=key,z=best,t=t}
        trail("waypoint","quest Q%s floor evidence: (%.1f, %.1f) Z %.1f -> %.1f; living quest enemy %.1f yd from arrow",tostring(goal.quest_id),pos.x,pos.y,pos.z,best,math.sqrt(best_d))
        return vec3.new(pos.x,pos.y,best), true
    end
    return pos
end

function guide.step_route(goal)
    local out = {}
    if type(goal) ~= "table" then return out end
    local num = goal.sticky_step or guide.step_num()
    local arrow=guide.raw_waypoint()
    local approach=false
    -- Optional #completewith travel can own the arrow while collection is
    -- current. Preserve that approach, but never borrow another quest's goal.
    if arrow and not goal.sticky_step and tonumber(arrow.goal_num)
        and arrow.goal_num<num then
        for _,st in ipairs(guide.stickies()) do
            if st.num==arrow.goal_num and not st.is_complete then
                local travel,work=false,false
                for _,g in ipairs(st.goals or {}) do
                    if not g.is_complete then
                        if g.action=="goto" then travel=true end
                        if not g.text_only and ACTIONS[g.action] then work=true end
                    end
                end
                approach=travel and not work
                break
            end
        end
    end
    if arrow and (tonumber(arrow.goal_num)==num or approach) then
        local pos=guide.to_world(arrow)
        if pos then
            local verified
            if not approach then pos,verified=guide.quest_floor(goal,pos) end
            return {{pos=pos,floor_verified=verified,title=arrow.title,source="live_arrow",step=arrow.goal_num,approach=approach}}
        end
    end
    for _, wp in ipairs(guide.raw_step_waypoints()) do
        if tonumber(wp.goal_num) == num then
            local pos = guide.to_world(wp)
            if pos then
                local selected,verified=guide.quest_floor(goal,pos)
                out[#out + 1] = { pos = selected, floor_verified=verified, title = wp.title }
            end
        end
    end
    if #out == 0 then
        local arrow = guide.raw_waypoint()
        if arrow and tonumber(arrow.goal_num) == num then
            local pos = guide.to_world(arrow)
            if pos then out[1] = { pos = pos, title = arrow.title } end
        end
    end
    return out
end

-- 1.0.3 (log 2026-10-20 17:05, step 3 "Talk to Mountaineer Stormpike" / turnin
-- 353 - no waypoint title): the step's own display line names the NPC. The
-- name is the capitalised words after "Talk to " ("Captain Rugelfuss" from
-- "Talk to Captain Rugelfuss in the bunker"). goal.text is a documented field.
function guide.talk_to_name(goal)
    local st = guide.step()
    if goal and goal.sticky_step then
        for _, s in ipairs(guide.stickies()) do if s.num == goal.sticky_step then st = s end end
    end
    -- Multi-NPC steps place .target after each quest action. Do not assign
    -- both quests to the first name in a shared "Talk to A and B" line.
    local after = false
    for _, line in ipairs((st or {}).goals or {}) do
        if goal and line.index == goal.index then
            after = true
        elseif after then
            if line.action == "accept" or line.action == "turnin" then break end
            if line.action == "target" and type(line.units) == "table"
                and #line.units == 1 and type(line.units[1]) == "string" then
                return line.units[1]
            end
        end
    end
    for _, g in ipairs((st or {}).goals or {}) do
        local t = type(g.text) == "string" and g.text:match("^[Tt]alk to (.+)$") or nil
        if t then
            t = t:gsub(":+%d+", "")
            local words = {}
            for w in t:gmatch("%S+") do
                local c = w:sub(1, 1)
                if c:match("%u") then
                    words[#words + 1] = (w:gsub("[,.;:!]+$", ""))
                elseif #words > 0 then
                    break
                end
            end
            if #words > 0 then return table.concat(words, " ") end
        end
    end
    return nil
end

--- Why the arrow is not walked, or nil when it is.
function guide.waypoint_refusal()
    local wp = guide.raw_waypoint()
    if not wp then return "no waypoint" end
    local pos, why = guide.to_world(wp)
    if pos then return nil end
    return why
end

-- ============================================================================
-- STATUS
-- ============================================================================
function guide.describe()
    local d = guide.decision()
    if not d then return "RestedXP not read yet" end
    if d.state == "work" then
        local g = d.goal
        return string.format("step %d: %s %s", guide.step_num(), tostring(g.kind), tostring(g.text or g.quest_id or ""))
    end
    return tostring(d.why or d.state)
end

local DIAG_PENDING = { addons = "-", namespace = "-", missing = {}, is_loaded = "(reading)",
    has_step = "(reading)", step_type = "-", step_num = 0, goal_count = 0, waypoint = "(reading)",
    step_waypoints = 0, objectives = 0 }
local diag_cache, diag_t = nil, -1
function guide.diagnose()
    if not reads_ok then return diag_cache or DIAG_PENDING end
    local now = clock()
    if diag_cache and now >= diag_t and (now - diag_t) < 1.0 then return diag_cache end
    diag_t = now
    local out = {}
    local addons = get(rawget(_G, "core"), "addons")
    local ns = get(addons, "rested_xp")
    out.addons, out.namespace = type(addons), type(ns)
    local missing = {}
    for _, f in ipairs({ "is_loaded", "has_current_step", "get_current_step", "get_current_stickies",
        "get_objectives", "get_current_waypoint", "get_step_waypoints", "skip_current_step" }) do
        if type(get(ns, f)) ~= "function" then missing[#missing + 1] = f end
    end
    out.missing = missing
    refresh()
    out.is_loaded = tostring(snap.loaded)
    out.has_step = tostring(snap.ready)
    out.step_num = snap.step and snap.step.num or 0
    out.goal_count = snap.step and #snap.step.goals or 0
    local wp = snap.wp
    out.waypoint = wp and string.format("map %d  %.3f,%.3f  %s  [%s]%s", wp.map_id, wp.x or 0, wp.y or 0,
        tostring(wp.title or "-"), tostring(wp.type), wp.wrong_continent and "  wrong continent" or "") or "none"
    out.step_waypoints = #snap.step_wps
    out.step_type = snap.step and "table" or "-"
    out.objectives = 0
    diag_cache = out
    return out
end

--- One line per goal and waypoint of the step, for the log on every step change.
function guide.dump_step()
    local out = {}
    local step = guide.step()
    if not step then return out end
    out[#out + 1] = string.format("step %d active %s complete %s requires '%s' (step %d) level %d label '%s', %d goal(s)",
        step.num, tostring(step.active), tostring(step.is_complete), step.requires, step.requires_step, step.level,
        step.label, #step.goals)
    for _, g in ipairs(step.goals) do
        local st, why = goal_state(g, step)
        local u = {}
        for _, x in ipairs(g.units or {}) do u[#u + 1] = tostring(x) end
        local ids = {}
        for _, x in ipairs(g.ids or {}) do ids[#ids + 1] = tostring(x) end
        out[#out + 1] = string.format("  goal %d: action '%s' quest %s text '%s' complete %s text_only %s units [%s] ids [%s] -> %s %s",
            g.index, g.action, tostring(g.quest_id), tostring(g.text), tostring(g.is_complete), tostring(g.text_only),
            table.concat(u, ", "), table.concat(ids, ", "), st, why and ("(" .. why .. ")") or "")
    end
    for _, wp in ipairs(guide.raw_step_waypoints()) do
        out[#out + 1] = string.format("  waypoint goal_num %s: map %d (%.4f, %.4f) type '%s' '%s'%s", tostring(wp.goal_num),
            wp.map_id, wp.x or 0, wp.y or 0, wp.type, tostring(wp.title), wp.wrong_continent and " wrong continent" or "")
    end
    local a = guide.raw_waypoint()
    if a then
        out[#out + 1] = string.format("  arrow: map %d (%.4f, %.4f) '%s' dist %s goal_num %s%s", a.map_id, a.x or 0, a.y or 0,
            tostring(a.title), tostring(a.dist), tostring(a.goal_num), a.wrong_continent and " wrong continent" or "")
    end
    return out
end

function guide.snapshot()
    return memo("snapshot", function()
        local d = guide.decision()
        local out = {
            loaded = guide.is_loaded(), ready = guide.ready(), step = guide.step_num(),
            goals = {}, goal = nil, kind = nil, stickies = #guide.stickies(),
            state = d and d.state or "-", describe = guide.describe(), waypoint = nil,
        }
        local step = guide.step()
        if step then
            for _, g in ipairs(step.goals) do
                local st = goal_state(g, step)
                out.goals[#out.goals + 1] = { index = g.index, action = g.action, text = g.text, quest_id = g.quest_id,
                    is_complete = st == "done", unhandled = st == "unhandled" }
            end
        end
        if d and d.state == "work" then out.goal, out.kind = d.goal, d.goal.kind end
        local wp = guide.raw_waypoint()
        if wp then out.waypoint = { title = wp.title, dist = (not wp.wrong_continent) and wp.dist or nil,
            map_id = wp.map_id, wrong_continent = wp.wrong_continent } end
        return out
    end)
end

-- Kept for main.lua's saved-state hooks (nothing is learned across sessions).
function guide.serialise() return "" end
function guide.deserialise() end

return guide
