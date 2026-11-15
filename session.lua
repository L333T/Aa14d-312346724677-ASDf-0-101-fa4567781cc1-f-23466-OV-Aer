-- ============================================================================
-- Master Farmer - Forever Questing
-- session.lua - what this run of the bot has done (the running pop-up)
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Product version: see version.lua
-- ============================================================================
-- 1.0.10 (user: the pop-up shows currency looted, the player's level and the
-- quests completed). A run starts at Start and lasts until Stop.
--
-- CURRENCY LOOTED: no documented call gives the coin of a loot slot, so the
-- player's copper (game_object:get_gold, read on the update tick) is watched
-- and a rise counts as looted only while a loot window is open - events.lua's
-- LOOT_OPENED / LOOT_CLOSED stamps, else core.game_ui.get_loot_item_count() >
-- 0 - or within LOOT_TAIL s after it closed. Quest rewards and vendor sales
-- (no loot window) are not loot.
-- QUESTS COMPLETED: QUEST_TURNED_IN events since Start (events.lua counts
-- them); a client that sends none: the turn-ins quest/npc confirmed.
-- ============================================================================

local S = { active = false, looted = 0, last_copper = nil, turned0 = 0, npc0 = 0, start_t = 0 }

local LOOT_TAIL = 1.5

local function safe(fn)
    local ok, r = pcall(fn)
    if ok then return r end
    return nil
end

local function clock()
    return tonumber(safe(function() return core.time() end)) or 0
end

local function events_mod()
    local ok, ev = pcall(require, "events")
    return (ok and type(ev) == "table") and ev or nil
end

local function npc_turned()
    local ok, npc = pcall(require, "quest/npc")
    if ok and type(npc) == "table" and type(npc.turned_in_count) == "function" then
        return tonumber(npc.turned_in_count()) or 0
    end
    return 0
end

local function looting()
    local ev = events_mod()
    local ui = ev and ev.ui
    if type(ui) == "table" and (ui.LOOT_OPENED or ui.LOOT_CLOSED) then
        local o, c = ui.LOOT_OPENED or -1e9, ui.LOOT_CLOSED or -1e9
        local t = safe(function() return require("common/izi_sdk").now() end) or 0
        if o > c then return true end
        return (t - c) <= LOOT_TAIL
    end
    local n = tonumber(safe(function() return core.game_ui.get_loot_item_count() end))
    return n ~= nil and n > 0
end

local function turned_count()
    local ev = events_mod()
    return ev and type(ev.count) == "function" and ev.count("QUEST_TURNED_IN") or 0
end

--- The update tick: `started` = the bot runs. Start begins a new run.
function S.tick(player, started)
    if not started then
        S.active = false
        return
    end
    local copper = player and tonumber(safe(function() return player:get_gold() end)) or nil
    if not S.active then
        S.active, S.looted, S.last_copper, S.start_t = true, 0, copper, clock()
        S.turned0, S.npc0 = turned_count(), npc_turned()
        return
    end
    if copper and S.last_copper and copper > S.last_copper and looting() then
        S.looted = S.looted + (copper - S.last_copper)
    end
    if copper then S.last_copper = copper end
end

--- Copper looted this run.
function S.looted_copper() return S.looted end

--- Quests handed in this run.
function S.quests_completed()
    local n = turned_count() - S.turned0
    if n > 0 then return n end
    return math.max(0, npc_turned() - S.npc0)
end

--- copper -> gold, silver, copper.
function S.split(copper)
    copper = math.max(0, math.floor(tonumber(copper) or 0))
    return math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
end

function S._reset() S.active, S.looted, S.last_copper, S.turned0, S.npc0 = false, 0, nil, 0, 0 end

return S
