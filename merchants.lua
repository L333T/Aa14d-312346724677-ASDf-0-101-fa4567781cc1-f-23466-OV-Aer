-- ============================================================================
-- Master Farmer - Forever Questing
-- merchants.lua - remembered repair NPCs and innkeepers
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.0
-- ============================================================================
-- The user (2.318.0): "Grinding path should vendor at repair NPC or INN if
-- bags are full". A grind route without its own merchant record had only the
-- zone merchant table (few zones), a vendor in sight, the Hearthstone and the
-- Alliance Eastern Kingdoms inn list - full bags elsewhere had nowhere to go.
--
-- Every NPC the bot sees that the game flags as a repairer (npc flag 0x1000)
-- or an innkeeper (0x10000) is remembered: npc id, name, position, continent.
-- Scanned every SCAN_EVERY s from the visible objects; kept per continent in
-- scripts_data/fqb/merchants.txt so it survives reloads and sessions.
-- merchants.nearest(player, want_repair) gives the nearest one on the
-- player's continent as a merchant record { npc_id, name, x, y, z } - the
-- shape vendor.lua already walks to and talks to.
-- ============================================================================

local M = {}

local FOLDER = "fqb"
local FILE = FOLDER .. "/merchants.txt"
local NPC_REPAIR, NPC_INNKEEPER = 0x1000, 0x10000
local SCAN_EVERY = 5.0
local SAVE_GAP = 15.0
local MAX_KEEP = 400
local MAX_DIST = 3000          -- yd: farther than this is not "the nearest" any more

M.NPC_REPAIR, M.NPC_INNKEEPER = NPC_REPAIR, NPC_INNKEEPER

local book = {}                -- "cont|npc" -> { cont, npc, x, y, z, repair, inn, name }
local book_n = 0
local loaded = false
local dirty, next_save = false, 0
local next_scan = -1e9

local function safe(fn)
    local ok, r = pcall(fn)
    if ok then return r end
    return nil
end

local function now()
    return safe(core.time) or 0
end

local function trail(fmt, ...)
    local ok, el = pcall(require, "errorlog")
    if ok and type(el) == "table" and type(el.trail) == "function" then pcall(el.trail, "merchants", fmt, ...) end
end

local function has_flag(v, bit)
    return type(v) == "number" and v > 0 and math.floor(v / bit) % 2 == 1
end

--- The continent the player is on (0 / 1 / 530), else the raw map id.
local function continent(pos)
    local ok, gv = pcall(require, "gamever")
    if ok and type(gv) == "table" and type(gv.continent_of) == "function" then
        local c, raw = gv.continent_of(pos)
        if c ~= nil then return c end
        if raw ~= nil then return raw end
    end
    return safe(function() return core.get_map_id() end) or -1
end

local function load()
    loaded = true
    local body = safe(function() return core.read_data_file(FILE) end)
    if type(body) ~= "string" or body == "" then return end
    for line in body:gmatch("[^\n]+") do
        local cont, npc, x, y, z, rep, inn, name =
            line:match("^(%-?%d+) (%d+) (%-?[%d%.]+) (%-?[%d%.]+) (%-?[%d%.]+) (%d) (%d) (.*)$")
        cont, npc, x, y, z = tonumber(cont), tonumber(npc), tonumber(x), tonumber(y), tonumber(z)
        if cont and npc and x and y and z then
            local key = cont .. "|" .. npc
            if not book[key] then book_n = book_n + 1 end
            book[key] = { cont = cont, npc = npc, x = x, y = y, z = z, repair = rep == "1", inn = inn == "1",
                name = (name or "?"):gsub("_", " ") }
        end
    end
    trail("loaded %d repair NPC(s) / innkeeper(s)", book_n)
end

local function save()
    dirty = false
    local out = {}
    for _, e in pairs(book) do
        out[#out + 1] = string.format("%d %d %.1f %.1f %.1f %d %d %s", e.cont, e.npc, e.x, e.y, e.z,
            e.repair and 1 or 0, e.inn and 1 or 0, (tostring(e.name or "?"):gsub("%s", "_")))
    end
    pcall(function() core.create_data_folder(FOLDER) end)
    -- write_data_file APPENDS: empty the file first (deathzones.lua)
    pcall(function() core.create_data_file(FILE) end)
    pcall(function() core.write_data_file(FILE, table.concat(out, "\n") .. "\n") end)
end

--- Remember one NPC (exposed for the tests).
function M.remember(cont, npc, x, y, z, repair, inn, name)
    if not loaded then load() end
    if type(npc) ~= "number" or npc <= 0 or type(x) ~= "number" then return false end
    local key = cont .. "|" .. npc
    local e = book[key]
    if e and math.abs(e.x - x) < 3 and math.abs(e.y - y) < 3 and e.repair == repair and e.inn == inn then
        return false
    end
    if not e then
        if book_n >= MAX_KEEP then return false end
        book_n = book_n + 1
        trail("%s %s (npc %d) at (%.0f, %.0f)", repair and "repairer" or "innkeeper", tostring(name), npc, x, y)
    end
    book[key] = { cont = cont, npc = npc, x = x, y = y, z = z, repair = repair, inn = inn, name = name }
    dirty = true
    return true
end

--- Note every repairer / innkeeper in sight (every SCAN_EVERY s).
function M.scan(player)
    if not loaded then load() end
    local t = now()
    if dirty and t >= next_save then
        next_save = t + SAVE_GAP
        save()
    end
    if t < next_scan or not player then return end
    next_scan = t + SCAN_EVERY
    local okt, targeting = pcall(require, "targeting")
    if not okt or type(targeting) ~= "table" or type(targeting.visible_objects) ~= "function" then return end
    local list = safe(function() return targeting.visible_objects() end)
    if type(list) ~= "table" then return end
    local here = safe(function() return player:get_position() end)
    local cont = continent(here)
    for i = 1, #list do
        local u = list[i]
        if u and safe(function() return u:is_valid() end) == true
            and safe(function() return u:is_unit() end) == true
            and safe(function() return u:is_player() end) ~= true
            and safe(function() return player:can_attack(u) end) ~= true then
            local flags = safe(function() return u:get_npc_flags() end)
            local rep, inn = has_flag(flags, NPC_REPAIR), has_flag(flags, NPC_INNKEEPER)
            if rep or inn then
                local p = safe(function() return u:get_position() end)
                local npc = safe(function() return u:get_npc_id() end)
                if p and npc then
                    M.remember(cont, npc, p.x, p.y, p.z, rep, inn, safe(function() return u:get_name() end))
                end
            end
        end
    end
end

-- 1.7.19 ZYGOR'S REPAIR NPCs (user: "build the local Zygor NPC import and use
-- it in the repair search"). tools/import_zygor_npcs.py reads the ["Repair"]
-- list of the Zygor add-on installed on this machine and writes
-- scripts_data/fqb/zygor_repair.txt ("<npc> <A|H|B> <ui_map> <x 0-1> <y 0-1>
-- <Name>"); nothing of Zygor's is in the product itself. Each line becomes a
-- world point once (core.game_ui.get_world_pos_from_map_pos: world x / y and
-- the continent), kept for the player's faction (B = both), and offered to
-- M.nearest beside the repairers the bot has seen - never in place of one
-- with the same npc id. No height in the data: the player's own z stands in
-- (the walk finds the ground; the NPC is talked to by its npc id).
local ZY_FILE = FOLDER .. "/zygor_repair.txt"
local zy = nil                 -- { { cont, npc, x, y, side, name } ... } once read
-- 1.7.27: one reader for every local Zygor list (repairers, flight masters)
local function zy_read(file, what)
    local out = {}
    local body = safe(function() return core.read_data_file(file) end)
    if type(body) ~= "string" or body == "" then return out end
    local okv, vec2 = pcall(require, "common/geometry/vector_2")
    local okg, gv = pcall(require, "gamever")
    for line in body:gmatch("[^\n]+") do
        local npc, side, map, x, y, name = line:match("^(%d+) ([ABH]) (%d+) ([%d%.]+) ([%d%.]+) (.*)$")
        npc, map, x, y = tonumber(npc), tonumber(map), tonumber(x), tonumber(y)
        if npc and map and x and y and okv and type(vec2) == "table" and vec2.new then
            local mp = vec2.new(x, y)
            local ok, w, cont = pcall(core.game_ui.get_world_pos_from_map_pos, map, mp)
            local wx = ok and type(w) == "table" and tonumber(w.x) or (ok and w and tonumber(w.x)) or nil
            local wy = ok and w and tonumber(w.y) or nil
            cont = tonumber(cont)
            if cont == nil and okg and type(gv) == "table" and type(gv.continent_of_uimap) == "function" then
                cont = gv.continent_of_uimap(map)
            end
            if wx and wy and not (wx == 0 and wy == 0) and cont then
                out[#out + 1] = { cont = cont, npc = npc, x = wx, y = wy, side = side,
                    name = (name ~= "?" and name or (what .. " " .. npc)):gsub("_", " ") }
            end
        end
    end
    trail("loaded %d %s(s) from the local Zygor import", #out, what)
    return out
end
local function zy_load() zy = zy_read(ZY_FILE, "repairer") end
local function my_side(player)
    local ok, f = pcall(require, "data/factions")
    if ok and type(f) == "table" and type(f.of_player) == "function" then
        local k = safe(function() return f.of_player(player) end)
        if type(k) == "string" then
            k = k:lower()
            if k:find("alliance", 1, true) then return "A" end
            if k:find("horde", 1, true) then return "H" end
        end
    end
    return nil
end
function M.zygor_count()
    if zy == nil then zy_load() end
    return #zy
end

-- 1.7.27 ZYGOR'S FLIGHT MASTERS (user: "get all taxi NPCs from the Zygor
-- addon"): scripts_data/fqb/zygor_flight.txt from the same import (the
-- ["Flight master"] block), same line format. M.nearest_flight: the nearest
-- one of the player's faction (B = both) on the player's continent, as
-- { npc_id, name, x, y, z (the player's - no height in the data) }, distance.
-- `skip` (npc id -> true): flight masters already tried.
local FLY_FILE = FOLDER .. "/zygor_flight.txt"
local zfly = nil
function M.flight_count()
    if zfly == nil then zfly = zy_read(FLY_FILE, "flight master") end
    return #zfly
end
function M.nearest_flight(player, skip)
    if zfly == nil then zfly = zy_read(FLY_FILE, "flight master") end
    local me = safe(function() return player:get_position() end)
    if not me then return nil end
    local cont = continent(me)
    local side = my_side(player)
    local best, best_d = nil, nil
    for i = 1, #zfly do
        local e = zfly[i]
        if e.cont == cont and (e.side == "B" or side == nil or e.side == side) and not (skip and skip[e.npc]) then
            local d = math.sqrt((e.x - me.x) ^ 2 + (e.y - me.y) ^ 2)
            if d <= MAX_DIST and (best_d == nil or d < best_d) then best, best_d = e, d end
        end
    end
    if not best then return nil end
    return { npc_id = best.npc, name = best.name, x = best.x, y = best.y, z = me.z, from_zygor = true }, best_d
end

-- 1.0.14 RESTEDXP'S VENDORS (user: "Check Player inventory, if full make
-- vendor run. Extract ALL vendor ID and location from RestedXP"). The local
-- RXPGuides import (tools/import_rxp_forever.py, data/rxp_forever.lua) holds
-- every ".vendor" step of the Forever guides - `vendors`: npc id (when the
-- guide names one), name (.target), the step's .goto, repair - and the
-- vendorTreasures NPCs (name, ui map point). Each becomes a world point once:
-- a world .goto as it is (its instance = the continent), a map point through
-- core.game_ui.get_world_pos_from_map_pos (2nd return = the continent). Kept
-- when the continent is the player's (core.get_instance_id, else continent()).
-- A vendor with neither a name nor an id is a SPOT: the vendor-flagged NPC
-- nearest that point is used (vendor.lua). One that was not found or did not
-- open is skipped for BAD_S s (M.mark_bad).
local rxv = nil                -- { { cont, npc, x, y, name, repair, spot, src } ... } once read
local rx_bad = {}              -- rx key -> skip until
local BAD_S = 1800
local function rx_key(e) return string.format("%s|%.0f|%.0f", tostring(e.npc or e.name), e.x, e.y) end
local function rx_world(p)
    if type(p) ~= "table" then return nil end
    if tonumber(p.wx) and tonumber(p.wy) then return tonumber(p.wx), tonumber(p.wy), tonumber(p.instance) end
    local map, x, y = tonumber(p.map), tonumber(p.x), tonumber(p.y)
    if not (map and x and y) then return nil end
    local okv, vec2 = pcall(require, "common/geometry/vector_2")
    if not okv or type(vec2) ~= "table" or not vec2.new then return nil end
    local ok, w, cont = pcall(core.game_ui.get_world_pos_from_map_pos, map, vec2.new(x, y))
    local wx = ok and w and tonumber(w.x) or nil
    local wy = ok and w and tonumber(w.y) or nil
    if not wx or not wy or (wx == 0 and wy == 0) then return nil end
    return wx, wy, tonumber(cont)
end
local function rx_load()
    local okd, rd = pcall(require, "data/rxp_forever")
    if not okd or type(rd) ~= "table" or type(rd.get) ~= "function" then rxv = {} return end
    if not safe(function() return rd.faction() end) then return end      -- faction not known yet: ask again
    rxv = {}
    local seen = {}
    local function add(e)
        local k = rx_key(e)
        if seen[k] then return end
        seen[k] = true
        rxv[#rxv + 1] = e
    end
    for _, v in pairs(rd.get("vendors") or {}) do
        if type(v) == "table" then
            local x, y, cont = rx_world(v)
            local name = type(v.name) == "string" and v.name or nil
            local npc = tonumber(v.npc)
            if x and cont then
                add({ cont = cont, npc = npc, x = x, y = y, name = name, repair = v.repair == true,
                    spot = name == nil and npc == nil, src = "guide " .. tostring(v.guide) })
            end
        end
    end
    for map, npcs in pairs(rd.get("vendorTreasures") or {}) do
        if type(npcs) == "table" then
            for name, v in pairs(npcs) do
                if type(name) == "string" and type(v) == "table" then
                    local x, y, cont = rx_world({ map = map, x = v.x, y = v.y })
                    if x and cont then
                        add({ cont = cont, x = x, y = y, name = name, repair = false, spot = false,
                            src = "vendor treasures" })
                    end
                end
            end
        end
    end
    trail("loaded %d RestedXP vendor(s) (guide .vendor steps + vendor treasures)", #rxv)
end
function M.rxp_count()
    if rxv == nil then rx_load() end
    return rxv and #rxv or 0
end
--- A RestedXP vendor that was not there / did not open: skipped BAD_S s.
function M.mark_bad(rec)
    if type(rec) == "table" and rec.rx_key then rx_bad[rec.rx_key] = now() + BAD_S end
end
--- The nearest RestedXP vendor on the player's continent: record, distance, rank
--- (2 = cannot repair while want_repair).
function M.nearest_rxp(player, want_repair)
    if rxv == nil then rx_load() end
    if not rxv then return nil end
    local me = safe(function() return player:get_position() end)
    if not me then return nil end
    local inst = safe(function() return tonumber(core.get_instance_id()) end)
    local cont = continent(me)
    local t = now()
    local best, best_d, best_rank = nil, nil, nil
    for i = 1, #rxv do
        local e = rxv[i]
        if (e.cont == inst or e.cont == cont) and t >= (rx_bad[rx_key(e)] or 0) then
            local d = math.sqrt((e.x - me.x) ^ 2 + (e.y - me.y) ^ 2)
            local rank = (want_repair and not e.repair) and 2 or 1
            if d <= MAX_DIST and (best_rank == nil or rank < best_rank or (rank == best_rank and d < best_d)) then
                best, best_d, best_rank = e, d, rank
            end
        end
    end
    if not best then return nil end
    local z = me.z
    local okg, guide = pcall(require, "quest/guide")
    if okg and type(guide) == "table" and type(guide.height_at) == "function" then
        local okh, h = pcall(guide.height_at, "v|" .. rx_key(best), best.x, best.y)
        if okh and type(h) == "number" and h == h then z = h end
    end
    return { npc_id = best.npc, name = best.name or string.format("vendor spot (%.0f, %.0f)", best.x, best.y),
        x = best.x, y = best.y, z = z, repair = best.repair, inn = false, from_rxp = true, spot = best.spot,
        rx_key = rx_key(best), src = best.src }, best_d, best_rank
end

-- Class trainers from every Forever guide ".trainer" step (import_rxp_forever).
local rxt = nil
local CLASS_NAME = {
    [1] = "Warrior", [2] = "Paladin", [3] = "Hunter", [4] = "Rogue",
    [5] = "Priest", [7] = "Shaman", [8] = "Mage", [9] = "Warlock", [11] = "Druid",
}
-- Names from the class trainer lists in trainer.lua. A .trainer step with no
-- class tag still belongs to one class when the name is on that list.
local TRAINER_NAMES = {
    Warrior = { ["Llane Beshere"] = true, ["Lyria Du Lac"] = true, ["Thran Khorman"] = true,
        ["Granis Swiftaxe"] = true, ["Ilsa Corbin"] = true, ["Wu Shen"] = true, ["Ander Germaine"] = true },
    Paladin = { ["Brother Sammuel"] = true, ["Brother Wilhelm"] = true, ["Bromos Grummner"] = true,
        ["Azar Stronghammer"] = true, ["Arthur the Faithful"] = true, ["Brother Joshua"] = true },
    Hunter = { ["Thorgas Grimson"] = true, ["Grif Wildheart"] = true, ["Ayanna Everstride"] = true,
        ["Dazalar"] = true, ["Kildar"] = true },
    Rogue = { ["Jorik Kerridan"] = true, ["Keryn Sylvius"] = true, ["Solm Hargrin"] = true,
        ["Hogral Bakkan"] = true, ["Osborne the Night Man"] = true },
    Priest = { ["Priestess Anetta"] = true, ["Priestess Josetta"] = true, ["Branstock Khalder"] = true,
        ["Maxan Anvol"] = true, ["High Priestess Laurena"] = true, ["Brother Benjamin"] = true },
    Shaman = { ["Firmanvaar"] = true, ["Nobundo"] = true, ["Sulaa"] = true, ["Tuluun"] = true },
    Mage = { ["Khelden Bremen"] = true, ["Zaldimar Wefhellt"] = true, ["Marryk Nurribit"] = true,
        ["Magis Sparkmantle"] = true, ["Jennea Cannon"] = true, ["Elsharin"] = true },
    Warlock = { ["Drusilla La Salle"] = true, ["Maximillian Crowe"] = true, ["Alamar Grimm"] = true,
        ["Gimrizz Shadowcog"] = true, ["Demisette Cloyce"] = true, ["Ursula Deline"] = true },
    Druid = { ["Mardant Strongoak"] = true, ["Kal"] = true, ["Gart Mistrunner"] = true,
        ["Jannok Breezesong"] = true },
}
local function trainer_for_class(e, want)
    if not want then return false end
    if e.class and e.class == want then return true end
    if e.class and e.class ~= want then return false end
    local name = e.name
    if type(name) ~= "string" then return false end
    local mine = TRAINER_NAMES[want]
    if mine and mine[name] then return true end
    for cls, set in pairs(TRAINER_NAMES) do
        if cls ~= want and set[name] then return false end
    end
    return false
end
local function rxt_load()
    local okd, rd = pcall(require, "data/rxp_forever")
    if not okd or type(rd) ~= "table" or type(rd.get) ~= "function" then rxt = {} return end
    if not safe(function() return rd.faction() end) then return end
    rxt = {}
    local seen = {}
    for _, v in pairs(rd.get("trainers") or {}) do
        if type(v) == "table" then
            local x, y, cont = rx_world(v)
            local name = type(v.name) == "string" and v.name or nil
            local npc = tonumber(v.npc)
            local cls = type(v.class) == "string" and v.class or nil
            if x and cont and (name or npc) then
                local k = string.format("%s|%s|%.0f|%.0f", tostring(npc or name), tostring(cls or ""), x, y)
                if not seen[k] then
                    seen[k] = true
                    rxt[#rxt + 1] = { cont = cont, npc = npc, x = x, y = y, name = name, class = cls,
                        src = "guide " .. tostring(v.guide) }
                end
            end
        end
    end
    trail("loaded %d RestedXP class trainer(s)", #rxt)
end
function M.trainer_count()
    if rxt == nil then rxt_load() end
    return rxt and #rxt or 0
end
--- Class identity is required; a generic trainer flag is not class evidence.
function M.is_class_trainer(player, unit)
    if not player or not unit or safe(function() return unit:is_valid() end) ~= true then return false end
    local want = CLASS_NAME[safe(function() return player:get_class() end)]
    if not want then return false end
    local name = safe(function() return unit:get_name() end)
    local npc = safe(function() return unit:get_npc_id() end)
    if trainer_for_class({name=name}, want) then return true end
    if rxt == nil then rxt_load() end
    for _, e in ipairs(rxt or {}) do
        if ((npc and e.npc == npc) or (name and e.name == name)) and trainer_for_class(e, want) then return true end
    end
    return false
end

--- Closest RestedXP class trainer for this character on this continent.
function M.nearest_trainer(player)
    if rxt == nil then rxt_load() end
    if not rxt then return nil end
    local me = safe(function() return player:get_position() end)
    if not me then return nil end
    local cls = safe(function() return player:get_class() end)
    local want = CLASS_NAME[cls]
    local inst = safe(function() return tonumber(core.get_instance_id()) end)
    local cont = continent(me)
    local best, best_d = nil, nil
    for i = 1, #rxt do
        local e = rxt[i]
        if (e.cont == inst or e.cont == cont) and trainer_for_class(e, want) then
            local d = math.sqrt((e.x - me.x) ^ 2 + (e.y - me.y) ^ 2)
            if d <= MAX_DIST and (best_d == nil or d < best_d) then
                best, best_d = e, d
            end
        end
    end
    if not best then return nil end
    local z = me.z
    local okg, guide = pcall(require, "quest/guide")
    if okg and type(guide) == "table" and type(guide.height_at) == "function" then
        local okh, h = pcall(guide.height_at, "t|" .. tostring(best.npc or best.name), best.x, best.y)
        if okh and type(h) == "number" and h == h then z = h end
    end
    return { npc_id = best.npc, name = best.name or "class trainer", x = best.x, y = best.y, z = z,
        class = best.class, from_rxp = true, src = best.src }, best_d
end

--- The nearest remembered repairer or innkeeper on the player's continent,
--- as a merchant record { npc_id, name, x, y, z, repair, inn }, and its flat
--- distance. want_repair: a repairer is taken over a nearer innkeeper.
--- 1.0.14: RestedXP's vendors are candidates too (M.nearest_rxp).
function M.nearest(player, want_repair)
    local rec, d, rank = M.nearest_book(player, want_repair)
    local rrec, rd, rrank = M.nearest_rxp(player, want_repair)
    if rrec and (not rec or rrank < rank or (rrank == rank and rd < d)) then return rrec, rd end
    return rec, d
end

function M.nearest_book(player, want_repair, observed_only)
    if not loaded then load() end
    local me = safe(function() return player:get_position() end)
    if not me then return nil end
    local cont = continent(me)
    local best, best_d, best_rank = nil, nil, nil
    for _, e in pairs(book) do
        if e.cont == cont then
            local d = math.sqrt((e.x - me.x) ^ 2 + (e.y - me.y) ^ 2)
            local rank = (want_repair and not e.repair) and 2 or 1
            if d <= MAX_DIST and (best_rank == nil or rank < best_rank or (rank == best_rank and d < best_d)) then
                best, best_d, best_rank = e, d, rank
            end
        end
    end
    -- 1.7.19: Zygor's repairers (the local import) - the player's faction, this
    -- continent, an npc the bot has not recorded itself
    if not observed_only then
    if zy == nil then zy_load() end
    local side = my_side(player)
    local zbest, zbest_d = nil, nil
    for i = 1, #zy do
        local e = zy[i]
        if e.cont == cont and (e.side == "B" or side == nil or e.side == side) and not book[cont .. "|" .. e.npc] then
            local d = math.sqrt((e.x - me.x) ^ 2 + (e.y - me.y) ^ 2)
            if d <= MAX_DIST and (zbest_d == nil or d < zbest_d) then zbest, zbest_d = e, d end
        end
    end
    if zbest and (not best or best_rank == 2 or zbest_d < best_d) then
        return { npc_id = zbest.npc, name = zbest.name, x = zbest.x, y = zbest.y, z = me.z,
            repair = true, inn = false, from_zygor = true }, zbest_d, 1
    end
    end
    if not best then return nil end
    return { npc_id = best.npc, name = best.name, x = best.x, y = best.y, z = best.z,
        repair = best.repair, inn = best.inn, from_book = true }, best_d, best_rank
end

-- Repair trips require a confirmed repair flag or an explicit RestedXP repairer.
function M.nearest_repair(player)
    local rec, d = M.nearest_book(player, true, true)
    if rec and not rec.repair then rec, d = nil, nil end
    local rx, rd = M.nearest_rxp(player, true)
    if rx and rx.repair and (not rec or rd < d) then return rx, rd end
    return rec, d
end

function M.count()
    if not loaded then load() end
    return book_n
end

-- ============================================================================
-- ROUTE VENDOR (3.0.0): the user picks the NPC a route sells / repairs at.
-- "Save Target as Route Vendor" (Vendor tab) stores the targeted NPC for the
-- loaded / selected route: npc id, name, position, whether it repairs. A
-- grind route with a saved vendor goes there for full bags and worn gear
-- (vendor.lua path_merchant), before anything the bot finds on its own.
-- Kept in scripts_data/fqb/route_vendors.txt, one line per route id.
-- The menu button only records the click (the render pass must not touch
-- the game); M.tick carries it out on the update tick.
-- ============================================================================
local RV_FILE = FOLDER .. "/route_vendors.txt"
local NPC_VENDOR = 0x80
local rv, rv_loaded = {}, false
local pending = nil            -- "save" | "clear"

local function rv_load()
    rv_loaded = true
    local body = safe(function() return core.read_data_file(RV_FILE) end)
    if type(body) ~= "string" or body == "" then return end
    for line in body:gmatch("[^\n]+") do
        local key, npc, x, y, z, rep, name = line:match("^(%S+) (%d+) (%-?[%d%.]+) (%-?[%d%.]+) (%-?[%d%.]+) (%d) (.*)$")
        npc, x, y, z = tonumber(npc), tonumber(x), tonumber(y), tonumber(z)
        if key and npc and x and y and z then
            rv[key] = { npc_id = npc, x = x, y = y, z = z, repair = rep == "1",
                name = (name or "?"):gsub("_", " "), route_vendor = true }
        end
    end
end

local function rv_save()
    local out = {}
    for key, e in pairs(rv) do
        out[#out + 1] = string.format("%s %d %.1f %.1f %.1f %d %s", key, e.npc_id, e.x, e.y, e.z,
            e.repair and 1 or 0, (tostring(e.name or "?"):gsub("%s", "_")))
    end
    pcall(function() core.create_data_folder(FOLDER) end)
    pcall(function() core.create_data_file(RV_FILE) end)
    pcall(function() core.write_data_file(RV_FILE, table.concat(out, "\n") .. "\n") end)
end

--- The saved vendor of route `key` (path.id), or nil.
function M.route_vendor(key)
    if not rv_loaded then rv_load() end
    if type(key) ~= "string" or key == "" then return nil end
    return rv[key]
end

--- Menu click (render pass): only recorded.
function M.request(kind)
    pending = kind
end

--- Store `unit` as the vendor of route `key`. Returns ok, message.
function M.save_route_vendor(key, unit, player)
    if not rv_loaded then rv_load() end
    if type(key) ~= "string" or key == "" then return false, "load or select a route first" end
    if not unit then return false, "target the vendor NPC first" end
    if safe(function() return unit:is_player() end) == true then return false, "the target is a player" end
    local flags = safe(function() return unit:get_npc_flags() end)
    local sells, repairs = has_flag(flags, NPC_VENDOR), has_flag(flags, NPC_REPAIR)
    if not sells and not repairs then return false, "the target is not a vendor" end
    if player and safe(function() return player:can_attack(unit) end) == true then
        return false, "the target is hostile"
    end
    local p = safe(function() return unit:get_position() end)
    local npc = safe(function() return unit:get_npc_id() end)
    if not p or not npc then return false, "the target has no position / npc id" end
    local name = safe(function() return unit:get_name() end) or "?"
    rv[key] = { npc_id = npc, x = p.x, y = p.y, z = p.z, repair = repairs, name = name, route_vendor = true }
    rv_save()
    return true, string.format("%s (npc %d%s) saved as the vendor of route %s", name, npc,
        repairs and ", repairs" or "", key)
end

function M.clear_route_vendor(key)
    if not rv_loaded then rv_load() end
    if type(key) ~= "string" or rv[key] == nil then return false, "no saved vendor for this route" end
    rv[key] = nil
    rv_save()
    return true, "route vendor cleared for " .. key
end

--- Update tick: carry out a menu click. `route_key` = the loaded / selected route id.
function M.tick(player, route_key)
    local kind = pending
    if not kind then return end
    pending = nil
    local ok, msg
    if kind == "save" then
        local target = player and safe(function() return player:get_target() end)
        ok, msg = M.save_route_vendor(route_key, target, player)
    else
        ok, msg = M.clear_route_vendor(route_key)
    end
    local line = "[Master Farmer - Forever Questing] Route vendor: " .. tostring(msg)
    if ok then pcall(core.log, line) else pcall(core.log_warning, line) end
    trail("%s", tostring(msg))
end

--- Test hook.
function M._reset()
    book, book_n, loaded, dirty, next_scan = {}, 0, true, false, -1e9
    rxv, rx_bad, rxt = nil, {}, nil
end

return M
