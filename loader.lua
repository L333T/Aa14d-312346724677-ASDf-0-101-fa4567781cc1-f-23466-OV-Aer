-- ============================================================================
-- Master Farmer - Forever Questing
-- Lazy quest pack loader (4.0.0: gathering is the Herbing & Mining product;
-- 1.0.28: the Grind mode is removed - this product quests only).
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Product version: see version.lua
-- Folder: Forever_Questing
-- ============================================================================

local loader = {}

local quest_mod = nil
local quest_on = false

local QUEST_PACK = {
    "quest/npc",
    "quest/done",       -- 1.4.0: completed-quest set
    "quest/engine",
    "quest",
}


local function drop(list)
    for i = #list, 1, -1 do
        package.loaded[list[i]] = nil
    end
    local ok, pf = pcall(require, "path_format")
    if ok and pf and type(pf.drop) == "function" then
        pf.drop()
    end
    pcall(collectgarbage, "step", 400)
end

function loader.ensure_quest()
    if quest_mod then
        quest_on = true
        return quest_mod
    end
    local ok, mod = pcall(require, "quest")
    if not ok or type(mod) ~= "table" then
        core.log_error("[Master Farmer - Forever Questing] quest pack failed: " .. tostring(mod))
        return nil
    end
    quest_mod = mod
    quest_on = true
    return quest_mod
end

function loader.unload_quest()
    quest_mod = nil
    quest_on = false
    drop(QUEST_PACK)
end

function loader.quest()
    return quest_mod
end

function loader.quest_ready()
    return quest_on and quest_mod ~= nil
end

return loader
