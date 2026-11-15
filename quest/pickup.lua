-- ============================================================================
-- Master Farmer - Forever Questing
-- quest/pickup.lua - ground objects a RestedXP step picks up (ESP + use)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- ============================================================================
-- 1.0.24 (user: "When the active RestedXP step is a ground pickup, draw that
-- object with ESP and walk over to use it"). A step is a ground pickup ONLY
-- when the Forever guide names the object with a "|cRXP_PICK_<name>|r" line -
-- the importer stores that name on the step's complete / collect row
-- (data/rxp_forever.lua M.quest_pick). A .collect that is mob loot or a vendor
-- buy has no such line and stays on fight_goal; questCompleteItems (an item in
-- the bags that is used) is never a ground object.
--
-- THE OBJECT: get_name() equal to the pick name, the case folded and a
-- trailing plural "s" / "es" on each word ignored ("Weapons" = "Weapon");
-- never a name that only shares a word. The step's .collect item id is a match
-- too (get_item_id) - a world object usually has none.
--
-- THE CACHE (shape of mf_herbing/gather/esp.lua): on the UPDATE tick, at most
-- every SCAN_S, core.object_manager.get_all_objects; each match copied into a
-- plain entry (name, ids, guid, x, y, z, type string, usable, lootable). The
-- live handle stays in a table only the update tick reads (use_object needs
-- it). The render pass draws cached entries only (circle_3d + text_3d with the
-- distance), at most MAX_DRAW, within DRAW_RANGE yd of the player and, when the
-- step's .goto converts to a world point, within GOTO_RANGE yd of that point.
-- The marker shows only while that goal is being worked (P.goal this tick).
--
-- THE USE: walked to with the quest engine's own walk (walk_to: the waypoint
-- walk the NPC goals use). Arrived: a world object (can_be_used, not a unit)
-- gets core.input.use_object ONCE; again only after USE_RETRY s if it is still
-- there and the count has not moved; after MAX_USES the object is skipped. A
-- unit that can be looted is a corpse: loot.lua's loot_object owns it. In
-- combat the marker is drawn and no walk starts.
-- ============================================================================

local P = {}

P.SCAN_S = 0.5
P.MAX_DRAW = 20
P.DRAW_RANGE = 80
P.GOTO_RANGE = 40
P.ARRIVE = 2.0
P.USE_RETRY = 8.0 -- allow object cast, loot window and objective update to settle
P.MAX_USES = 3
P.RETRY_AFTER = 30.0
P.SEARCH_WAIT = 2.0
P.SHOW_S = 1.5            -- s the marker stays after the last P.goal call

local cache = { t = -1e9, list = {} }
local live = {}            -- guid -> game object (update tick only)
local want = nil           -- { name, norm, item, center, quest_id, t }
local use = nil            -- { guid, t, n, count }
local blocked_quest = nil
local loot_trip_until = 0
local skipped = {}         -- guid -> true: did not go after MAX_USES

local function now()
    local ok, t = pcall(core.time)
    return ok and type(t) == "number" and t or 0
end

local function call(o, name)
    local f = o and o[name]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, o)
    if ok then return v end
    return nil
end

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then pcall(el.trail, "act", fmt, ...) end
end

--- A name folded for matching: lower case, single spaces, each word's plural
--- "s" (and "es" after x / ch / sh / s) removed.
function P.norm(name)
    if type(name) ~= "string" then return nil end
    local words = {}
    for w in string.lower(name):gmatch("[^%s]+") do
        if w:match("[xs]es$") or w:match("[cs]hes$") then
            w = w:sub(1, -3)
        elseif #w > 1 and w:sub(-1) == "s" and w:sub(-2) ~= "ss" then
            w = w:sub(1, -2)
        end
        words[#words + 1] = w
    end
    if #words == 0 then return nil end
    return table.concat(words, " ")
end

--- Does an object with `name` / `item_id` match what the step picks up?
function P.matches(name, item_id, w)
    w = w or want
    if not w then return false end
    if w.norm then return P.norm(name) == w.norm end
    return w.item ~= nil and type(item_id) == "number" and item_id == w.item
end

local function dist3(a, b)
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + ((a.z or 0) - (b.z or 0)) ^ 2)
end

--- Refresh the cache (update tick), at most every SCAN_S.
function P.scan(player, force)
    local t = now()
    if not want then cache.list, live = {}, {} return cache.list end
    if not force and (t - cache.t) < P.SCAN_S then return cache.list end
    cache.t = t
    local list, lv = {}, {}
    for guid, until_t in pairs(skipped) do
        if type(until_t) == "number" and t >= until_t then skipped[guid] = nil end
    end
    local me = player and call(player, "get_position")
    local ok, objects = pcall(core.object_manager.get_all_objects)
    if ok and type(objects) == "table" and me then
        for i = 1, #objects do
            local o = objects[i]
            if o and call(o, "is_valid") == true then
                local name = call(o, "get_name")
                local item_id = call(o, "get_item_id")
                if P.matches(name, item_id) then
                    local p = call(o, "get_position")
                    if type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" then
                        local e = { x = p.x, y = p.y, z = tonumber(p.z) or 0 }
                        local d = dist3(e, me)
                        local in_goto = not want.center or dist3(e, want.center) <= P.GOTO_RANGE
                        if not in_goto then
                            for _, point in ipairs(want.route or {}) do
                                if dist3(e, point) <= P.GOTO_RANGE then in_goto = true break end
                            end
                        end
                        if d <= P.DRAW_RANGE and in_goto then
                            local guid = call(o, "get_guid")
                            guid = guid ~= nil and tostring(guid) or nil
                            local tstr = call(o, "get_object_type_string")
                            e.name, e.item_id, e.guid, e.dist = tostring(name or want.name), item_id, guid, d
                            e.entry = tonumber(call(o, "get_npc_id"))
                            e.type = type(tstr) == "string" and tstr ~= "" and tstr or tostring(call(o, "get_type") or "object")
                            e.unit = call(o, "is_unit") == true or string.lower(e.type):find("unit", 1, true) ~= nil
                            e.usable = call(o, "can_be_used") == true
                            e.lootable = call(o, "can_be_looted") == true
                            if not (guid and skipped[guid]) then
                                list[#list + 1] = e
                                if guid then lv[guid] = o end
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)
    cache.list, live = list, lv
    return list
end

function P.list() return cache.list end
function P.wanted() return want end

--- The goal is not a ground pickup (any more): the marker goes.
function P.clear()
    want, use = nil, nil
    cache.list, live = {}, {}
end

-- ----------------------------------------------------------------------------
-- drawing (render pass: cached data only)
-- ----------------------------------------------------------------------------
local kit = nil
local function draw_kit()
    if kit ~= nil then return kit end
    local okc, color = pcall(require, "common/color")
    local okv, v = pcall(require, "common/geometry/vector_3")
    if not okc or not okv or type(color) ~= "table" or type(v) ~= "table" then kit = false return false end
    kit = { vec3 = v, col = color.new(255, 215, 80, 235), ring = color.new(255, 255, 255, 140) }
    return kit
end

function P.draw()
    if not want or (now() - want.t) > P.SHOW_S then return end
    local list = cache.list
    if #list == 0 then return end
    local k = draw_kit()
    if not k then return end
    for i = 1, math.min(#list, P.MAX_DRAW) do
        local e = list[i]
        local selected = want.selected ~= nil and want.selected == e.guid
        local status = selected and "TARGET" or ((e.usable or e.lootable) and "candidate" or "unusable")
        local label = string.format("%s [%s] ID %s Q %s  %.1f yd", e.name, status, tostring(e.entry or "?"), tostring(want.quest_id or "-"), e.dist)
        pcall(core.graphics.text_3d, label, k.vec3.new(e.x, e.y, e.z + 0.8), 12, k.col, true, 10)
        pcall(core.graphics.circle_3d, k.vec3.new(e.x, e.y, e.z), 1.2, selected and k.col or k.ring, 2.0, 1.0)
    end
end

-- ----------------------------------------------------------------------------
-- the goal (update tick, from quest/engine.lua)
-- ----------------------------------------------------------------------------
--- The goal's count now (the bag count of a collect item, else "n/m" of the
--- goal text), or nil.
local function goal_count(goal, item)
    if item then
        local okb, bags = pcall(require, "bags")
        if okb and type(bags) == "table" and type(bags.count) == "function" then
            local okc, n = pcall(bags.count, item)
            if okc and type(n) == "number" then return n end
        end
    end
    if goal.quest_id and core.quests and type(core.quests.get_quest_objectives) == "function" then
        local ok, rows = pcall(core.quests.get_quest_objectives, goal.quest_id)
        if ok and type(rows) == "table" and #rows > 0 then
            local index = tonumber(goal.objective) or 0
            if index > 0 and rows[index] then return tonumber(rows[index].fulfilled) end
            local total = 0
            for _, row in ipairs(rows) do
                if type(row.fulfilled) ~= "number" then return nil end
                total = total + row.fulfilled
            end
            return total
        end
    end
    return type(goal.text) == "string" and tonumber(goal.text:match("(%d+)%s*/")) or nil
end

-- Only drain a loot window belonging to an object this handler just used.
-- One slot per update; wait for acknowledgement instead of immediately closing it.
local function pending_loot(player, goal, ctx)
    if not use or ctx.in_combat then return false end
    local t = now()
    local ok, n = pcall(function() return core.game_ui.get_loot_item_count() end)
    if ok and type(n) == "number" and n > 0 and t - use.t < 20 then
        ctx.nav_stop()
        local okb, bags = pcall(require, "bags")
        local free = okb and type(bags.free_slots) == "function" and bags.free_slots(player) or nil
        local oke, events=pcall(require,"events")
        local full=oke and type(events.inventory_full_since)=="function" and events.inventory_full_since(use.t)
        if free == 0 or full then
            local okv, vendor = pcall(require, "vendor")
            if okv and type(vendor.request_loot_trip) == "function" then vendor.request_loot_trip(player) end
            pcall(function() core.input.close_loot() end)
            trail("quest object loot yielded to vendor: full inventory, object %s",tostring(use.guid))
            use=nil; loot_trip_until=t+20
            ctx.note("Guide: bags full - quest object loot pending")
            return false -- allow main's vendor tick to run this frame
        end
        if t >= (use.loot_at or 0) then
            local order = require("lootorder").order(n)
            if order[1] ~= nil then pcall(core.input.loot_item, order[1]) end
            use.loot_at = t + 0.5
            trail("quest object loot: %s, %d slot(s) remaining", tostring(use.guid), n)
        end
        ctx.note("Guide: looting " .. tostring(want and want.name or "quest object"))
        return true
    end
    local count = goal_count(goal, want and want.item)
    if count and use.count and count > use.count then
        skipped[use.guid] = t + P.RETRY_AFTER
        trail("quest object verified: %s, objective %d -> %d", tostring(use.guid), use.count, count)
        use, cache.t = nil, -1e9
        ctx.note("Guide: quest object collected")
        return true
    end
    return false
end

function P.loot_pending(player)
    if not use or not use.goal then return false end
    local movement = require("movement")
    return pending_loot(player, use.goal, {
        in_combat = call(player, "is_in_combat") == true,
        nav_stop = movement.nav_stop,
        note = function(text) require("state").set_note("Quest loot", text) end,
    })
end

--- A complete / collect goal: true when it is a ground pickup and was handled
--- this tick. `ctx` = { rxpdata, guide, walk_to, note, nav_stop, in_combat }.
local function guarded_pickup(player, point, ctx)
    if not point or not want or ctx.in_combat then return false end
    local t=now()
    local ok_z, zones=pcall(require,"deathzones")
    local zone
    if ok_z and type(zones.zone_at_pos)=="function" then
        local good, found=pcall(zones.zone_at_pos,point)
        if good then zone=found end
    end
    if zone then
        ctx.nav_stop()
        want.progress_t=t
        ctx.note("Guide: quest object deferred after repeated deaths")
        if t-(want.zone_log or -1e9)>=30 then
            want.zone_log=t
            trail("pickup death-zone hold: quest %s target %.1f %.1f %.1f, %s, deaths %s, remaining %.0f s",
                tostring(want.quest_id),point.x,point.y,point.z or 0,tostring(zone.name),
                tostring(zone.deaths),math.max(0,(zone.until_t or t)-t))
        end
        return true
    end
    if not want.danger_t or t-want.danger_t >= 0.5 then
        want.danger_t, want.dangers=t, {}
        local ok, targeting=pcall(require,"targeting")
        if ok and type(targeting.danger_mobs)=="function" then
            local good, list=pcall(targeting.danger_mobs,player,120,3,true)
            if good and type(list)=="table" then want.dangers=list end
        end
    end
    for _, d in ipairs(want.dangers or {}) do
        if type(d.z)=="number" and type(point.z)=="number" and math.abs(d.z-point.z)<=8
            and (d.x-point.x)^2+(d.y-point.y)^2 <= ((d.r or 20)+4)^2 then
            ctx.nav_stop()
            want.progress_t=t -- waiting for a patrol is not a navigation stall
            ctx.note("Guide: waiting for danger to clear " .. (want.name or "quest object"))
            if t-(want.danger_log or -1e9)>=10 then
                want.danger_log=t
                trail("pickup approach held: quest %s target %.1f %.1f %.1f danger %.1f %.1f %.1f radius %.1f level %s",
                    tostring(want.quest_id),point.x,point.y,point.z,d.x,d.y,d.z,d.r or 20,tostring(d.level))
            end
            return true
        end
    end
    return false
end

function P.goal(player, goal, label, ctx)
    if want and want.quest_id == goal.quest_id and pending_loot(player, goal, ctx) then return true end
    if now()<loot_trip_until then return true end
    local rd = ctx.rxpdata
    local name, gpt, item
    if rd and type(rd.quest_pick) == "function" and goal.quest_id then
        name, gpt, item = rd.quest_pick(goal.quest_id)
    end
    -- The live addon can contain newer steps than the imported data. Its
    -- explicit Open/Click instruction names the object, not the looted item.
    if not name then
        local lines = type(ctx.guide.goals) == "function" and ctx.guide.goals() or {}
        if goal.sticky_step and type(ctx.guide.stickies) == "function" then
            lines = {}
            for _, st in ipairs(ctx.guide.stickies()) do
                if st.num == goal.sticky_step then lines = st.goals or {} break end
            end
        end
        local objectives = 0
        for _, line in ipairs(lines) do
            if line.action == "complete" or line.action == "collect" then objectives = objectives + 1 end
        end
        local objective = type(goal.text) == "string" and goal.text:gsub("%d+%s*/%s*%d+", ""):gsub("^%s+", ""):gsub("[%s:]+$", "") or ""
        for _, line in ipairs(lines) do
            local text = type(line.text) == "string" and line.text or ""
            name = text:match("|cRXP_PICK_(.-)|r")
                or text:match("^[Oo]pen the (.-)[%.!]")
                or text:match("^[Cc]lick on the (.-)[%.!]")
                or text:match("^[Ll]oot (.-) on the ground")
            if name and objectives > 1 and (objective == "" or not text:lower():find(objective:lower(), 1, true)) then name = nil end
            if name then break end
        end
    end
    if not name then P.clear() return false end
    local qid = tonumber(goal.quest_id)
    if qid and qid > 0 then
        local okn, npc = pcall(require, "quest/npc")
        local okq, active = false, nil
        if okn and type(npc) == "table" and type(npc.in_log) == "function" then okq, active = pcall(npc.in_log, qid) end
        local complete = type(ctx.guide.complete_done) == "function" and ctx.guide.complete_done(goal) == true
        if not okq or active ~= true or complete then
            P.clear()
            ctx.nav_stop()
            local why = complete and "objective complete" or (active == false and "quest not in quest log" or "quest status unknown")
            local block = tostring(qid) .. "|" .. why
            if blocked_quest ~= block then trail("pickup blocked for quest %d (%s): %s", qid, name, why) blocked_quest = block end
            ctx.note("Guide: " .. name .. " - " .. why)
            return true
        end
    end
    blocked_quest = nil
    -- a collect already at its need is not worked (the decision says so too)
    local citem, need = nil, nil
    if goal.kind == "collect" and type(ctx.guide.collect_item) == "function" then citem, need = ctx.guide.collect_item(goal) end
    item = item or citem
    if goal.kind == "collect" and citem and need and (goal_count(goal, citem) or 0) >= need then P.clear() return false end
    local key = tostring(goal.quest_id) .. "|" .. name
    if not want or want.key ~= key then
        local center = gpt and ctx.guide.point_world and ctx.guide.point_world(gpt) or nil
        if not center and type(ctx.guide.goal_waypoint) == "function" then
            local wp = ctx.guide.goal_waypoint(goal, true)
            center = wp and wp.pos or nil
        end
        want = { key = key, name = name, norm = P.norm(name), item = item, quest_id = goal.quest_id,
            center = center and { x = center.x, y = center.y, z = center.z } or nil }
        want.route, want.search_index = {}, 1
        use, skipped, cache.t = nil, {}, -1e9
        trail("ground pickup for quest %s: %s%s", tostring(goal.quest_id), name,
            want.center and string.format(" near (%.0f, %.0f)", want.center.x, want.center.y) or "")
    end
    -- The live arrow can advance within the same collection goal. Keep its
    -- search route current without discarding the selected object's lock.
    local route = type(ctx.guide.step_route) == "function" and ctx.guide.step_route(goal) or {}
    -- A turn-in recovery must revisit the imported collection point, not
    -- follow the currently displayed arrow back to the quest giver.
    if ctx.recovery then route=want.center and {{pos=want.center}} or {} end
    local changed = #route ~= #want.route
    for i,wp in ipairs(route) do
        local old=want.route[i]
        if wp.pos and (not old or dist3(old,wp.pos)>1) then changed=true break end
    end
    if changed then
        want.route,want.search_index,want.search_since={},1,nil
        local me, nearest = call(player, "get_position"), nil
        for _, wp in ipairs(route) do
            local pos = wp.pos
            if pos and type(pos.x) == "number" and type(pos.y) == "number" then
                want.route[#want.route + 1] = {x=pos.x, y=pos.y, z=pos.z}
                local d = me and dist3(me, pos)
                if d and (not nearest or d < nearest) then nearest, want.search_index = d, #want.route end
            end
        end
        trail("pickup search route refreshed: quest %s, %d point(s)",tostring(goal.quest_id),#want.route)
    end
    want.t = now()
    P.scan(player)
    local e
    for _, candidate in ipairs(cache.list) do
        if (candidate.unit and candidate.lootable) or (not candidate.unit and candidate.usable) then
            if not e then e = candidate end
            if candidate.guid == want.selected then e = candidate break end
        end
    end
    local t = now()
    if want.selected and not skipped[want.selected] and want.locked then
        local selected
        for _, candidate in ipairs(cache.list) do
            if candidate.guid == want.selected then selected = candidate break end
        end
        if selected and (selected.usable or selected.lootable) then
            e, want.seen_t = selected, t
        elseif t - (want.seen_t or t) < 8 then
            -- Object streaming can briefly hide a cave target. Retain only
            -- its position; never interact through a stale native handle.
            if ctx.in_combat then return true end
            if guarded_pickup(player,want.locked,ctx) then return true end
            ctx.walk_to(want.locked, label .. " - reacquiring " .. name, P.ARRIVE, nil, "pick|" .. want.selected)
            return true
        end
    end
    if e and want.selected ~= e.guid then
        trail("ESP selected %s: entry %s GUID %s quest %s XYZ %.2f %.2f %.2f, %.1f yd", e.name,
            tostring(e.entry), tostring(e.guid), tostring(want.quest_id), e.x, e.y, e.z, e.dist)
        want.seen_t, want.progress_t, want.best_dist = t, t, e.dist
    end
    want.selected = e and e.guid or nil
    if e then
        want.locked = {x=e.x,y=e.y,z=e.z}
        if guarded_pickup(player,e,ctx) then return true end
        if ctx.in_combat or e.dist < (want.best_dist or math.huge) - 2 then
            want.progress_t, want.best_dist = t, e.dist
        elseif e.dist > P.ARRIVE and t - (want.progress_t or t) > 25 then
            skipped[e.guid] = t + P.RETRY_AFTER
            trail("object approach deferred: %s, no progress for 25 s", tostring(e.guid))
            want.selected, want.locked, cache.t = nil, nil, -1e9
            ctx.nav_stop()
            return true
        end
    else want.locked = nil end
    if ctx.in_combat then
        ctx.note("Guide: " .. name .. " (in combat)")
        return true
    end
    if not e then
        use = nil
        -- Some collection objectives allow both containers and enemy loot.
        -- Without a visible container, let the normal quest combat handler
        -- search its declared enemies instead of monopolizing the goal.
        local mobs = ctx.rxpdata and type(ctx.rxpdata.quest_mobs) == "function"
            and ctx.rxpdata.quest_mobs(goal.quest_id) or nil
        if not ctx.recovery and type(mobs) == "table" and #mobs > 0 then
            if not want.mob_fallback then
                trail("pickup search yielding to quest enemies: quest %s, no usable %s", tostring(goal.quest_id), name)
                want.mob_fallback = true
            end
            return false
        end
        local point = want.route[want.search_index] or want.center
        if point then
            if guarded_pickup(player,point,ctx) then return true end
            if ctx.walk_to(point, label .. " - looking for " .. name, nil, nil, "pick|" .. key .. "|" .. want.search_index) then
                want.search_since = nil
                return true
            end
            want.search_since = want.search_since or now()
            if #want.route > 1 and now() - want.search_since >= P.SEARCH_WAIT then
                want.search_index = want.search_index % #want.route + 1
                want.search_since = nil
                trail("%s not at search point - checking route point %d/%d", name, want.search_index, #want.route)
            end
            ctx.note("Guide: looking for " .. name)
            return true
        end
        ctx.note("Guide: " .. name .. " - no position from the guide")
        return true
    end
    if e.unit then
        -- a corpse: loot.lua's loot_object owns it
        ctx.note("Guide: " .. name .. " (loot)")
        if e.dist > P.ARRIVE then
            ctx.walk_to(e, label .. " - " .. name, P.ARRIVE, nil, "pick|" .. tostring(e.guid))
        end
        return true
    end
    if e.dist > P.ARRIVE then
        ctx.walk_to(e, label .. " - " .. name, P.ARRIVE, nil, "pick|" .. tostring(e.guid))
        return true
    end
    ctx.nav_stop()
    local t = now()
    local count = goal_count(goal, item)
    if use and use.guid == e.guid then
        if (count and use.count and count ~= use.count) then
            if e.guid then skipped[e.guid] = t + P.USE_RETRY end
            use, cache.t = nil, -1e9
            ctx.note("Guide: collected " .. name)
            return true
        elseif (t - use.t) < P.USE_RETRY then
            ctx.note("Guide: using " .. name)
            return true
        elseif use.n >= P.MAX_USES then
            if e.guid then skipped[e.guid] = t + P.RETRY_AFTER end
            cache.t = -1e9
            trail("%s did not open after %d tries - the next one", name, use.n)
            use = nil
            return true
        end
    elseif use and use.guid ~= e.guid then
        use = nil
    end
    local o = e.guid and live[e.guid] or nil
    if not o or call(o, "is_valid") ~= true then return true end
    local fresh_guid, fresh_entry = call(o, "get_guid"), tonumber(call(o, "get_npc_id"))
    if fresh_guid == nil or tostring(fresh_guid) ~= e.guid
        or (e.entry and fresh_entry ~= e.entry) or call(o, "is_unit") == true
        or not P.matches(call(o, "get_name"), call(o, "get_item_id")) then
        cache.t = -1e9
        trail("ESP rejected changed object identity: expected entry %s GUID %s quest %s", tostring(e.entry), tostring(e.guid), tostring(want.quest_id))
        return true
    end
    local me, pos = call(player, "get_position"), call(o, "get_position")
    if not me or not pos then return true end
    local distance = dist3(me, pos)
    if distance > P.ARRIVE then
        cache.t = -1e9
        ctx.walk_to(pos, label .. " - " .. name, P.ARRIVE, true, "pick|" .. tostring(e.guid))
        return true
    end
    -- nav_stop can defer while Sentinel has a fresh/pending path. A request
    -- to stop is not proof that the character is stationary.
    if call(player, "is_moving") ~= false then
        ctx.nav_stop()
        ctx.note("Guide: stopping before using " .. name)
        return true
    end
    if call(o, "can_be_used") ~= true then
        ctx.note("Guide: " .. name .. " (cannot be used yet)")
        return true
    end
    use = { guid = e.guid, t = t, n = (use and use.n or 0) + 1, count = count, goal = goal }
    trail("use %s (%s, %.1f yd, try %d)", name, e.type, distance, use.n)
    local ok_use, sent = pcall(core.input.use_object, o)
    trail("ESP interaction %s: entry %s GUID %s quest %s, %.1f yd", ok_use and "requested; awaiting loot/objective" or "call failed",
        tostring(e.entry), tostring(e.guid), tostring(want.quest_id), distance)
    ctx.note("Guide: using " .. name)
    return true
end

--- Tests.
function P._reset() cache, live, want, use, skipped = { t = -1e9, list = {} }, {}, nil, nil, {} loot_trip_until=0 end

return P
