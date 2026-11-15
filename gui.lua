-- ============================================================================
-- Master Farmer - Forever Questing
-- GUI — Shamele chrome, class auto-detect, popup Path/Vendor/Grind
-- ============================================================================
-- Authors: BLIZZ - Anthonyk
-- Version: 4.0.0
-- Folder: Forever_Questing
-- ============================================================================

---@type color

-- 1.0.28 (user): the Grind mode is removed - Forever Questing quests only
-- (there was no grind/ folder; the mode could not load).

local color = require("common/color")

-- Every colour this file draws with, built once (2.27.0). They were created
-- inside the draw functions - 54 call sites, every frame - and the GUI draw
-- was the largest source of garbage in the plugin: about 83 KB a frame, 60%
-- of everything allocated, in the 20:25 session log.
local COLOR_CACHE = {}
local function C(r, g, b, a)
    a = a or 255
    local key = ((r * 256 + g) * 256 + b) * 256 + a
    local c = COLOR_CACHE[key]
    if c == nil then
        c = color.new(r, g, b, a)
        COLOR_CACHE[key] = c
    end
    return c
end

---@type vec2
local vec2 = require("common/geometry/vector_2")

---@type enums
local enums = require("common/enums")

---@type izi_api
local izi = require("common/izi_sdk")

---@type plugin_helper
local plugin_helper = require("common/utility/plugin_helper")

local identity = require("version")
local ui = require("ui")
-- The bot modes (were modes.lua, removed in 2.217.0 with the unused Path
-- mode; Gathering added in 2.237.0). gui.mode() returns one of these;
-- main.lua reads them as gui.modes.
local modes = { QUEST = "quest" }           -- 1.0.28: questing only
local state = require("state")
local spellbook = require("spellbook")
local loader = require("loader")

local gui = {}

local FONT_SMALL = enums.window_enums.font_id.FONT_SMALL

local CLASS_LABELS = {
    "Warrior", "Paladin", "Hunter", "Rogue", "Priest",
    "Shaman", "Mage", "Warlock", "Druid",
}

local CLASS_IDS = {
    enums.class_id.WARRIOR,
    enums.class_id.PALADIN,
    enums.class_id.HUNTER,
    enums.class_id.ROGUE,
    enums.class_id.PRIEST,
    enums.class_id.SHAMAN,
    enums.class_id.MAGE,
    enums.class_id.WARLOCK,
    enums.class_id.DRUID,
}

local MODE_LABELS = { "Grind", "Quest", "Path" }
local REGION_LABELS = { "Eastern Kingdoms", "Kalimdor", "Outland", "Alliance 1-60 w/Vendoring", "Custom" }
local REGION_KEYS = { "ek", "kalimdor", "outland", "ally160", "custom" }

local factions = require("data/factions")

-- PATH MODULES, LAZY (2.142.0). The grind tab called path_format.count and
-- path_profiles.last_loaded / save_path / remember as globals nothing ever
-- declared ("attempt to index a nil value" once a route was armed, or on
-- Save). These proxies require the module on first use, so gui.lua still
-- loads nothing extra at start.
local function lazy_module(name)
    local mod = nil
    return setmetatable({}, { __index = function(_, key)
        if mod == nil then
            local ok, m = pcall(require, name)
            mod = (ok and type(m) == "table") and m or false
        end
        return mod and mod[key] or nil
    end })
end
local path_format = lazy_module("path_format")
local path_profiles = lazy_module("path_profiles")
local EMPTY_PATH = "(no route)"

local PATH_LABELS = { EMPTY_PATH }

-- 1.15.0 (user: "GUI resolution is no longer applied"): the window id no longer
-- carries the product version. A release used to mint a NEW core.menu.window id,
-- so the saved size / position / active tab were dropped and the window reopened
-- at the hard-coded 1080p default instead of this screen's size. A fixed id keeps
-- them across releases (mf_route_tool has always used one), and a window opened
-- for the first time takes the size mf_skin computes for this screen's artwork
-- set (S.window_px: units 896 x 500 at the screen's pixel scale), not 1100 x 640.
local function window_size()
    local ok, SK = pcall(require, "mf_skin")
    if ok and type(SK) == "table" and type(SK.window_px) == "function" then
        local oks, s = pcall(function() return core.graphics.get_screen_size() end)
        if oks and type(s) == "table" and type(s.x) == "number" and type(s.y) == "number" then
            local w, h = SK.window_px(s.x, s.y)
            if type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then return w, h end
        end
    end
    return 1100, 640
end
local WIN_W, WIN_H = window_size()

local menu = ui.new({
    id = "fq_main",                        -- 1.15.0: fixed (was "fq_<version>_main")
    name = "MASTER FARMER",
    version = identity.version,
    header_text = identity.description,
    subtitle = identity.description,
    footer = "Contact Us On Discord: 1stblizz",
    header_hints = {
        { key = "Numpad 0", command = "Start" },
        { key = "Numpad 1", command = "Pause" },
        { key = "Numpad 2", command = "Stop" },
        { key = "Numpad 4", command = "Show / Hide GUI" },
    },
    size = { w = WIN_W, h = WIN_H },       -- 1.15.0: this screen's size, not a 1080p default
    position = { x = 80, y = 180 },
    nav = "top",
    product = "Forever Questing",
    -- 1.0.10 (user: "make the window larger taller, some of the elements are
    -- not visible"): 140 WoW UI units taller (896 x 640 units = 1260 x 900 px
    -- on 1080p at 768 / screen height) - mf_skin.lua stretches a band inside
    -- the panels and moves the buttons / footer down
    skin_extra_h = 140,
    -- 3.6.0: the 5-tab window; Spells + Resting share a tab (sub-tabs in the panel).
    -- 4.0.0: Gathering moved to the Herbing & Mining product (launcher card 4).
    tab_groups = {
        { label = "Spells", tabs = { "class", "healing" } },
    },
    tabs = {
        { id = "general", label = "General" },
        { id = "questing", label = "Questing" },
        { id = "class", label = "Spells" },
        { id = "healing", label = "Resting" },   -- id kept: saved settings and code refer to it
        { id = "settings", label = "Settings" },
    },
})

menu:checkbox("fq_enable", false, {
    label = "Start Bot",
    tab = "general",
    skip_draw = true,
    tooltip = "Internal run flag. Set by Start.",
})
-- One switch for all looting, on the always-visible General tab: grinding,
-- questing and path mode all loot through loot.lua.
menu:checkbox("fq_mount", true, {
    label = "Use Mount",
    tab = "general",
    tooltip = "Questing and grinding: mount (or Travel Form) before every walk of 30 yards or more - a class mount spell, a mount in the bags or the mount list, from level 30, outdoors and out of combat. Dismounts for a fight.",
})
menu:checkbox("fq_loot", true, {
    label = "Auto Loot Corpses",
    tab = "general",
    tooltip = "After each kill, walk to the corpse and auto loot at 2 yards (core.input.loot_object). Anything attacking you is fought first. Turn off to leave corpses alone.",
})
menu:checkbox("fq_astar", true, {
    label = "Local A* Fallback",
    tab = "general",
    tooltip = "When Sentinel cannot reach a spot within 15 yards (off its navmesh), search a short local path with game raycasts and walk it through Sentinel. Budgeted per frame; on by default.",
})
menu:checkbox("fq_rotation_only", false, {
    label = "Enable Rotation Only",
    tab = "general",
    tooltip = "Run the Class tab rotation on your current target with no bot movement. Leave Play off and steer the character yourself. Uncheck this, load a path, then Play to automate travel.",
})
-- 1.0.19: Auto Load - 15 s after the box is on (and the bot is not running)
-- the update tick presses Start (gui.try_start). A blocked Start tries again
-- 15 s later; the box stays on.
menu:checkbox("fq_auto_load", false, {
    label = "Auto Load",
    tab = "general",
    tooltip = "Start after 15 seconds. Stop or Pause cancels auto-start for this session; toggle Auto Load off and on to re-arm it.",
})

menu:combobox("fq_class", 7, CLASS_LABELS, {
    label = "Class Rotation",
    tooltip = "Hidden selector. Synced to the loaded player class.",
})

menu:combobox("fq_mode", 1, MODE_LABELS, {
    label = "Bot Mode",
    skip_draw = true,
    tooltip = "Legacy mode index (2 = Quest).",
})

-- These sit at the top of their own tab. A normal tab draws its registered
-- controls first and its custom content underneath, so the enable is always
-- the first thing on the page.
menu:checkbox("fq_use_quest", true, {
    skip_draw = true,            -- Forever Questing: questing is the only mode
    label = "Enable Questing",
    tab = "questing",
    tooltip = "Turn questing on. The RestedXP Guides addon supplies every step, waypoint and mob to kill - load a guide in it, then Start.",
})


-- Which side's routes to list. Defaults to the character's own faction the
-- first time a player object is available, so the common case needs no click.
menu:combobox("fq_faction", 1, factions.labels, {
    label = "Faction",
    tab = "path",
    skip_draw = true,
    tooltip = "Alliance or Horde. The route list below shows only that side's profiles.",
})
menu:combobox("fq_path", 1, PATH_LABELS, {
    label = "Route",
    tab = "path",
    skip_draw = true,
    tooltip = "All grind loops and travel routes for the selected continent. Load arms the profile; Play starts it.",
})

menu:checkbox("fq_path_loop", false, {
    label = "Loop Path",
    tab = "path",
    tooltip = "Grind paths always loop until the bot is paused or stopped (2.233.0): a closed loop starts over, an open path turns round at its ends.",
})
menu:checkbox("fq_path_reverse", false, {
    label = "Reverse Path",
    tab = "path",
    tooltip = "Play the loaded path last-to-first. Works on travel routes and grind loops. Loop still repeats that reversed order.",
})
menu:checkbox("fq_path_combat", true, {
    label = "Attack Along Path",
    tab = "path",
    tooltip = "Auto-target the closest PvE mob in rotation range and fight from the loaded path (10-yard leash). Starts melee auto-attack so any class swings when the mob is in melee.",
})
menu:checkbox("fq_draw_path", true, {
    label = "Draw Loaded Path",
    tab = "path",
    tooltip = "Draw the loaded travel path in the world.",
})

-- 3.2.0: movement/pivot.lua
menu:checkbox("fq_sharp_turn_stop", true, {
    label = "Stop and Turn on Sharp Turns",
    tab = "path",
    tooltip = "When the next waypoint is more than 70 degrees off the way you face, stop running, turn in place to face it, then walk on - sharp corners are not taken as wide arcs into walls and mobs. Applies to every walk (questing, grinding, routes, NPC runs).",
})


menu:checkbox("fq_eat_drink", true, {
    label = "Eat / Drink",
    tab = "healing",
    tooltip = "Out of combat: when health or mana falls to the percentages set below, stop and eat / drink until that resource is full. Uses the highest-ranked food and water in the bags. Untick to turn eating and drinking off.",
})
-- Shown only while Eat / Drink is ticked (ui.lua visible_if). 10-90%: the
-- old 20-35% range was too narrow to be worth a slider.
local function eat_drink_on()
    local v = menu:get("fq_eat_drink")
    return v == true
end
menu:slider_int("fq_eat_hp", 10, 90, 50, {        -- 1.7.8: default 50 (the rest starts at 50 % or lower)
    label = "Eat when Health below %",
    tab = "healing",
    visible_if = eat_drink_on,
    tooltip = "Out of combat, sit and eat when health falls to this percentage or lower, and keep eating until health is full.",
})
menu:slider_int("fq_drink_mana", 10, 90, 50, {    -- 1.7.8: default 50
    label = "Drink when Mana below %",
    tab = "healing",
    visible_if = eat_drink_on,
    tooltip = "Out of combat, sit and drink when mana falls to this percentage or lower, and keep drinking until mana is full. Classes without mana never drink.",
})
menu:checkbox("fq_potions", true, {
    label = "Use Potions",
    tab = "healing",
})
menu:slider_int("fq_hp_pot", 10, 60, 35, {
    label = "Health Potion %",
    tab = "healing",
})
menu:slider_int("fq_mp_pot", 5, 50, 20, {
    label = "Mana Potion %",
    tab = "healing",
})

menu:checkbox("fq_random_path", false, {
    label = "Random Patrol Skip",
    tab = "settings",
    skip_draw = true,   -- 1.0.28: questing reads it; only the removed Grind popup showed it
})
menu:slider_int("fq_max_kill", 15, 180, 60, {
    label = "Max Kill Time (s)",
    tab = "settings",
    skip_draw = true,   -- 1.0.28: questing reads it; only the removed Grind popup showed it
})
menu:checkbox("fq_fight_back", true, {
    label = "Fight Back",
    tab = "settings",
    skip_draw = true,   -- 1.0.28: questing reads it; only the removed Grind popup showed it
})
menu:slider_int("fq_fight_back_hp", 20, 90, 70, {
    label = "Fight Back HP %",
    tab = "settings",
    skip_draw = true,   -- 1.0.28: questing reads it; only the removed Grind popup showed it
})
-- 3.0.3: enemies are searched for within this many yards of the player
-- (grinding, and Zygor "grind to N xp" steps)
menu:slider_int("fq_pull_radius", 10, 60, 20, {
    label = "Pull Radius (yd)",
    tab = "settings",
    skip_draw = true,   -- 1.0.28: questing reads it; only the removed Grind popup showed it
    tooltip = "Enemies within this many yards of the player are pulled: the bot walks into melee or casting range, then attacks.",
})
menu:slider_int("fq_fight_back_yards", 10, 80, 30, {
    label = "Fight Back Range",
    tab = "settings",
    skip_draw = true,   -- 1.0.28: questing reads it; only the removed Grind popup showed it
})
menu:checkbox("fq_atk_any", false, {
    label = "Attack Any Level",
    tab = "settings",
    skip_draw = true,   -- 1.0.28: questing reads it; only the removed Grind popup showed it
    tooltip = "Attack every valid enemy in range, regardless of level. Only one level option can be on.",
})
menu:checkbox("fq_atk_5", false, {
    label = "Attack within 5 levels",
    tab = "settings",
    skip_draw = true,   -- 1.0.28: questing reads it; only the removed Grind popup showed it
    tooltip = "Attack enemies 5 levels below, the same level, or 5 levels above you. Only one level option can be on.",
})
menu:checkbox("fq_atk_3", true, {
    label = "Attack within 3 levels",
    tab = "settings",
    skip_draw = true,   -- 1.0.28: questing reads it; only the removed Grind popup showed it
    tooltip = "Attack enemies 3 levels below, the same level, or 3 levels above you. Only one level option can be on.",
})
menu:checkbox("fq_untapped", true, {
    label = "Skip Tapped Mobs",
    tab = "settings",
    skip_draw = true,   -- 1.0.28: questing reads it; only the removed Grind popup showed it
})
-- 2.273.0: travel steers around the aggro range of hostile mobs at or below
-- the player's level (targeting.scan_enemies -> movement danger map).

-- Every questing setting lives on the Questing tab, under Enable Questing.
-- There is no quest list to pick from: Zygor decides what comes next.
menu:checkbox("fq_skip_trivial", true, {
    label = "Skip Grey Quests",
    tab = "questing",
    tooltip = "Skip a quest the NPC reports as trivial (grey). The bot moves on to the step's next goal; advance the RestedXP guide yourself if the whole step was that quest.",
})
menu:checkbox("fq_logging", true, {
    label = "Enable diagnostic logging",
    tab = "general",
    tooltip = "Write one structured session log with errors, decisions, player/target context and navigation state to scripts_log/MASTER_FARMER_ERRORS. Enabled by default; repeated messages and heartbeats are limited automatically.",
})

menu:checkbox("fq_vendor_sell", true, {
    label = "Sell at Vendor",
    tab = "vendor",
    tooltip = "Walk to the zone merchant when free bag slots drop to the trigger.",
})
menu:checkbox("fq_repair", true, {
    label = "Repair at Vendor",
    tab = "vendor",
    tooltip = "Walk to the zone merchant when equipped durability is at or below the trigger.",
})
menu:checkbox("fq_sell_grey", true, {
    label = "Sell Grey",
    tab = "vendor",
})
menu:checkbox("fq_sell_white", true, {
    label = "Sell White",
    tab = "vendor",
})
menu:checkbox("fq_sell_green", false, {
    label = "Sell Green",
    tab = "vendor",
    tooltip = "Off by default. Greens can be upgrades.",
})
menu:checkbox("fq_sell_blue", false, {
    label = "Sell Blue",
    tab = "vendor",
    tooltip = "Sell rare items only when enabled. Armor and weapon upgrades stay protected.",
})
menu:checkbox("fq_delete_junk", true, {
    label = "Delete Junk When Full",
    tab = "vendor",
    tooltip = "When the bags are full and loot is left on a corpse, delete the cheapest grey item so the loot fits (a nearly full cheap stack goes first). Greys only - never food, drink, consumables, ammo or quest items. Deleting cannot be undone.",
})
menu:slider_int("fq_max_shards", 0, 40, 0, {
    label = "Max Soul Shards",
    tab = "vendor",
    tooltip = "Warlock: keep at most this many Soul Shards and delete the rest (out of combat). 0 = no cap.",
})
menu:slider_int("fq_bag_free", 1, 10, 1, {
    label = "Vendor at Free Slots",
    tab = "vendor",
    tooltip = "At this many free bag slots or fewer, walk to the closest vendor (any vendor NPC in sight, else the zone merchant, else the nearest inn), sell / buy / repair with the settings on this tab, then go back to the quest step or route.",
})
menu:checkbox("fq_vendor_each_lap", true, {
    label = "Vendor Every Lap",
    tab = "vendor",
    tooltip = "On an Alliance 1-60 w/Vendoring loop that names a merchant, sell and repair once per completed lap. Those routes begin and end at their vendor, so the stop costs no extra travel. Routes with no vendor in their notes are unaffected.",
})
menu:slider_int("fq_repair_pct", 5, 50, 25, {      -- 1.7.10: default 25 (a trip below 25 % at most)
    label = "Repair at Durability %",
    tab = "vendor",
})
-- 3.0.0: the NPC a route sells / repairs at. The click is only recorded here
-- (render pass); merchants.tick saves the current target on the update tick.
menu:button("fq_save_route_vendor", {
    label = "Save Target as Route Vendor",
    tab = "vendor",
    tooltip = "Target a vendor or repair NPC and press this: the loaded (or selected) grind route sells and repairs there whenever the bags are full or the gear is worn, and walks back to the nearest waypoint afterwards.",
    on_click = function()
        local okm, mer = pcall(function() return package.loaded["merchants"] end)
        if okm and type(mer) == "table" and type(mer.request) == "function" then mer.request("save") end
    end,
})
menu:button("fq_clear_route_vendor", {
    label = "Clear Route Vendor",
    tab = "vendor",
    tooltip = "Forget the vendor saved for the loaded (or selected) route.",
    on_click = function()
        local okm, mer = pcall(function() return package.loaded["merchants"] end)
        if okm and type(mer) == "table" and type(mer.request) == "function" then mer.request("clear") end
    end,
})

menu:checkbox("fq_show_gui", true, {
    label = "Show GUI",
    tab = "settings",
})

menu:add_popup({
    id = "path",
    title = "Load Profile",
    tab = "path",
    w = 460,
    h = 720,
    x = 870,
    y = 36,
    on_open = function()
        gui.sync_profile_list(true)
    end,
})
menu:add_popup({
    id = "vendor",
    title = "Vendor",
    tab = "vendor",
    w = 440,
    h = 480,
    x = 870,
    y = 76,
})
-- SPELLS TAB SETTINGS (2.64.0). The tab lists the known class spells and
-- racials; these four tune how smart.lua uses them.
-- ENGAGE DISTANCE (2.90.0): how close the bot gets before the rotation starts
-- on a target. Melee classes (and a Cat / Bear druid, a Stormstrike shaman)
-- use the melee distance; casters and hunters the ranged one, capped just
-- inside the longest ticked damage spell's own range.
-- BUFF RANDOMS (2.91.0): mages only.
local function is_mage()
    local ok, cid = pcall(function() return menu:player_class() end)
    return ok and cid == enums.class_id.MAGE
end
menu:checkbox("fq_buff_randoms", false, {
    label = "Buff Randoms",
    tab = "class",
    visible_if = is_mage,
    tooltip = "Out of combat, cast Arcane Intellect (Rank 1, spell 1459) on friendly players within 30 yards who do not have it (or Arcane Brilliance). Not in a fight, while resting or under 50% mana; one player every 4 s, each player at most once per 10 minutes.",
})
-- STRAFE COMBAT (2.212.0): rogues only. class_id is the same per-class gate
-- the Spells-tab sliders use, so no other class ever sees the row. strafe.lua
-- checks the class again at run time, because a menu element is saved per
-- account and a tick made on a rogue is still set when a mage logs in.
-- 2.284.0: Hunter - the pet takes the aggro first, back-jump at 5 yd
-- (smart.lua HUNTER PET AGGRO). Hunters only, off by default.
-- 1.7.12 (user): on-use trinkets (trinkets.lua) - each slot's "Use:" effect
-- decides when: a heal / mana / defensive one when low, an escape one under a
-- stun / fear, an attack one at the target, a burst buff at a fresh target.
-- 1.7.13 (user): minimap click to walk (mapwalk.lua), with the bot stopped
menu:checkbox("fq_minimap_walk", true, {
    label = "Minimap Click to Walk",
    tab = "general",
    tooltip = "With the bot stopped: left-click a spot on the minimap and the character walks there with Sentinel Navigation (stops within 3 yards, or after 15 seconds without progress). A new click replaces the goal; Start hands over to the guide.",
})
menu:checkbox("fq_use_trinkets", true, {
    label = "Use Trinkets",
    tab = "class",
    tooltip = "Use equipped on-use trinkets in combat. Each trinket's Use: effect decides when: a heal below 45% health, mana below 35% mana, a damage shield / armor below 60% health, a stun / fear breaker when you lose control, a damage trinket on your target, a stat buff at the start of a fight. Passive trinkets are left alone.",
})
-- 1.7.15 (user): Mage Blink Away (rotations/mage.lua escape, movement/locks.lua)
menu:checkbox("fq_blink_away", true, {
    label = "Blink Away",
    tab = "class",
    class_id = enums.class_id.MAGE,
    tooltip = "Mage: when an enemy fighting you comes within 5 yards and Blink is ready - turn away from it, run, Blink after 0.25 s, stop after 1.5 s, face the enemy again and go on with the rotation (at most once every 3 s).",
})
menu:checkbox("fq_hunter_pet_aggro", false, {
    label = "Pet Takes Aggro",
    tab = "class",
    class_id = enums.class_id.HUNTER,
    tooltip = "With a pet out: the pet is sent in and you hold your own attacks (Auto Shot too) until the mob is on the pet "
        .. "(or attacks you, or 6 s pass). If the mob gets within 5 yd of you, you walk backward for 2.5 s with a jump "
        .. "0.5 s in, then stop (at most once every 4 s).",
})
-- 2.294.0: the same for Warriors, in their own box (a menu element is saved
-- per account: one shared box ticked on a rogue would switch warriors on).
menu:checkbox("fq_strafe_combat_warrior", false, {
    label = "Strafe in Combat",
    tab = "class",
    class_id = enums.class_id.WARRIOR,
    tooltip = "In combat, once in melee range of the target, tap strafe right and left (0.2-0.5 s each, random) so the warrior does not stand still. Stops the moment the target leaves melee range, so the bot can chase it.",
})
menu:checkbox("fq_strafe_combat", false, {
    label = "Strafe Combat",
    tab = "class",
    class_id = enums.class_id.ROGUE,
    tooltip = "In combat, once in melee range of the target, tap strafe right and left (0.2-0.5 s each, random) so the rogue does not stand still. Stops the moment the target leaves melee range, so the bot can chase it.",
})
-- Spells-tab sliders, one saved element per class (2.129.0). The menu
-- stores a slider by its id for the whole account, so a single fq_sp_heal
-- was the mage's value on a hunter. class_id hides every other class's row.
local class_slider_ids = {}

-- 2.249.0: rotation casts through the Sylvanas spell queue (castq.lua)
menu:checkbox("fq_spell_queue", true, {
    label = "Spell Queue Casting",
    tab = "class",
    tooltip = "Cast the rotation through the spell queue (priority 1): the next spell is queued in the last 0.35 s of a cast so it goes out the moment the cast ends, and off-GCD spells use the fast queue. Untick to cast through izi directly.",
})

-- 2.274.0: adaptive rotation (adapt.lua)
menu:checkbox("fq_adaptive", true, {
    label = "Adaptive Rotation",
    tab = "class",
    tooltip = "Learns, per character, what kills fastest and casts that: reads every spell you cast and the damage it does, "
        .. "orders the ticked damage spells by damage per second of casting (by damage per mana when low on mana), "
        .. "casts a spell that kills the target now first, skips DoTs and cooldowns in fights too short for them, "
        .. "and in melee waits for the swing instead of clipping it. Saved per character (scripts_data/fq/adapt_<guid>.txt) "
        .. "and updated when new spells or ranks are learned. Untick for the plain Spells-tab order.",
})

local function add_class_slider(class_id, key, min_v, max_v, default, label, tip)
    local id = string.format("fq_%s_%d", key, class_id)
    menu:slider_int(id, min_v, max_v, default, {
        label = label,
        tab = "class",
        class_id = class_id,
        tooltip = tip,
    })
    local map = class_slider_ids[class_id]
    if not map then
        map = {}
        class_slider_ids[class_id] = map
    end
    map[key] = id
end

local TIP_MELEE = "How close this class walks before it starts swinging."
local TIP_RANGED = "How close this class walks before it starts casting. Never farther than the longest ticked damage spell."
local TIP_SHOOT = "The Hunter closes to this distance, then uses the ranged weapon (13-40 yd, never past the weapon's real reach). Default 25. A mob at 11 yd or closer is fought in melee at 3 yd."
local TIP_HEAL = "Ticked healing spells are cast on yourself below this health."
local TIP_DEF = "Ticked defensive spells are used below this health."
local TIP_AOE = "Ticked area spells are used when at least this many enemies are in reach."
local TIP_WAND = "With a wand equipped, Shoot once mana drops below this. 0 never wands; 100 wands whenever no heal, DoT or other spell is due."
local TIP_PET = "Mend Pet is cast when the pet's health drops below this."

-- Not named C: that upvalue is the colour helper, and a second local C here
-- shadowed it for the rest of the file. The Spells list and the mini window
-- then called the class-id table (gui.draw: attempt to call upvalue 'C').
local class_ids = enums.class_id
-- Melee classes.
add_class_slider(class_ids.WARRIOR, "melee_yards", 1, 5, 5, "Melee attack distance (yd)", TIP_MELEE)
add_class_slider(class_ids.WARRIOR, "sp_def", 10, 70, 35, "Defensives below %", TIP_DEF)
add_class_slider(class_ids.WARRIOR, "sp_aoe", 2, 6, 3, "Area of effect at enemies", TIP_AOE)

add_class_slider(class_ids.PALADIN, "melee_yards", 1, 5, 5, "Melee attack distance (yd)", TIP_MELEE)
add_class_slider(class_ids.PALADIN, "sp_heal", 20, 90, 50, "Self-heal below %", TIP_HEAL)
add_class_slider(class_ids.PALADIN, "sp_def", 10, 70, 35, "Defensives below %", TIP_DEF)
add_class_slider(class_ids.PALADIN, "sp_aoe", 2, 6, 3, "Area of effect at enemies", TIP_AOE)

add_class_slider(class_ids.ROGUE, "melee_yards", 1, 5, 5, "Melee attack distance (yd)", TIP_MELEE)
add_class_slider(class_ids.ROGUE, "sp_def", 10, 70, 35, "Defensives below %", TIP_DEF)
add_class_slider(class_ids.ROGUE, "sp_aoe", 2, 6, 3, "Area of effect at enemies", TIP_AOE)

-- Hunter: shooting distance, then melee only after the mob closes. No wand.
add_class_slider(class_ids.HUNTER, "ranged_yards", 13, 40, 25, "Shooting distance (yd)", TIP_SHOOT)
add_class_slider(class_ids.HUNTER, "melee_yards", 1, 3, 3, "Melee distance (yd)", TIP_MELEE)
add_class_slider(class_ids.HUNTER, "pet_heal_pct", 20, 90, 50, "Mend Pet below %", TIP_PET)
add_class_slider(class_ids.HUNTER, "sp_def", 10, 70, 35, "Defensives below %", TIP_DEF)
add_class_slider(class_ids.HUNTER, "sp_aoe", 2, 6, 3, "Area of effect at enemies", TIP_AOE)

-- Casters.
add_class_slider(class_ids.PRIEST, "ranged_yards", 10, 40, 30, "Ranged attack distance (yd)", TIP_RANGED)
add_class_slider(class_ids.PRIEST, "sp_heal", 20, 90, 50, "Self-heal below %", TIP_HEAL)
add_class_slider(class_ids.PRIEST, "sp_def", 10, 70, 35, "Defensives below %", TIP_DEF)
add_class_slider(class_ids.PRIEST, "sp_aoe", 2, 6, 3, "Area of effect at enemies", TIP_AOE)
add_class_slider(class_ids.PRIEST, "sp_wand", 0, 100, 20, "Wand below mana %", TIP_WAND)

add_class_slider(class_ids.SHAMAN, "ranged_yards", 10, 40, 30, "Ranged attack distance (yd)", TIP_RANGED)
add_class_slider(class_ids.SHAMAN, "melee_yards", 1, 5, 5, "Melee distance (yd)", TIP_MELEE)
add_class_slider(class_ids.SHAMAN, "sp_heal", 20, 90, 50, "Self-heal below %", TIP_HEAL)
add_class_slider(class_ids.SHAMAN, "sp_def", 10, 70, 35, "Defensives below %", TIP_DEF)
add_class_slider(class_ids.SHAMAN, "sp_aoe", 2, 6, 3, "Area of effect at enemies", TIP_AOE)

add_class_slider(class_ids.MAGE, "ranged_yards", 10, 40, 30, "Ranged attack distance (yd)", TIP_RANGED)
add_class_slider(class_ids.MAGE, "sp_def", 10, 70, 35, "Defensives below %", TIP_DEF)
add_class_slider(class_ids.MAGE, "sp_aoe", 2, 6, 3, "Area of effect at enemies", TIP_AOE)
add_class_slider(class_ids.MAGE, "sp_wand", 0, 60, 20, "Wand below mana %", TIP_WAND)

add_class_slider(class_ids.WARLOCK, "ranged_yards", 10, 40, 30, "Ranged attack distance (yd)", TIP_RANGED)
add_class_slider(class_ids.WARLOCK, "sp_heal", 20, 90, 45, "Drain Life below %", TIP_HEAL)
add_class_slider(class_ids.WARLOCK, "sp_def", 10, 70, 35, "Defensives below %", TIP_DEF)
add_class_slider(class_ids.WARLOCK, "sp_aoe", 2, 6, 3, "Area of effect at enemies", TIP_AOE)
add_class_slider(class_ids.WARLOCK, "pet_heal_pct", 20, 90, 50, "Health Funnel below %", TIP_PET)
add_class_slider(class_ids.WARLOCK, "sp_wand", 0, 100, 20, "Wand below mana %", TIP_WAND)

-- Druid stands at range until Cat or Bear, so both distances are kept.
add_class_slider(class_ids.DRUID, "melee_yards", 1, 5, 5, "Melee attack distance (yd)", TIP_MELEE)
add_class_slider(class_ids.DRUID, "ranged_yards", 10, 40, 30, "Ranged attack distance (yd)", TIP_RANGED)
add_class_slider(class_ids.DRUID, "sp_heal", 20, 90, 50, "Self-heal below %", TIP_HEAL)
add_class_slider(class_ids.DRUID, "sp_def", 10, 70, 35, "Defensives below %", TIP_DEF)
add_class_slider(class_ids.DRUID, "sp_aoe", 2, 6, 3, "Area of effect at enemies", TIP_AOE)


local keybinds = {
    enable = core.menu.keybind(996, false, "fq_kb_start"),
    pause = core.menu.keybind(997, false, "fq_kb_pause"),
    stop = core.menu.keybind(998, false, "fq_kb_stop"),
}

local aliases = {
    enable = "fq_enable",
    eat_drink = "fq_eat_drink",
    potions = "fq_potions",
    rest_debug = "fq_rest_debug",
    crash_recorder = "fq_crash_recorder",
    crash_capture = "fq_crash_capture",
    session_detail = "fq_session_detail",
    print_action = "fq_print_action",
    buff_randoms = "fq_buff_randoms",
    strafe_combat = "fq_strafe_combat",
    strafe_combat_warrior = "fq_strafe_combat_warrior",   -- 2.294.0
    skip_trivial = "fq_skip_trivial",
    train = "fq_train",
    vendor_each_lap = "fq_vendor_each_lap",
    random_path = "fq_random_path",
    fight_back = "fq_fight_back",
    untapped = "fq_untapped",
    loot = "fq_loot",
    sell = "fq_vendor_sell",
    repair = "fq_repair",
    sell_grey = "fq_sell_grey",
    sell_white = "fq_sell_white",
    sell_green = "fq_sell_green",
    sell_blue = "fq_sell_blue",
    delete_junk = "fq_delete_junk",
    spell_queue = "fq_spell_queue",
    hunter_pet_aggro = "fq_hunter_pet_aggro",  -- 2.284.0
    use_trinkets = "fq_use_trinkets",          -- 1.7.12
    minimap_walk = "fq_minimap_walk",          -- 1.7.13
    blink_away = "fq_blink_away",              -- 1.7.15
    adaptive = "fq_adaptive",                 -- 2.274.0
    path_loop = "fq_path_loop",
    path_reverse = "fq_path_reverse",
    path_combat = "fq_path_combat",
    draw_path = "fq_draw_path",
    move_debug = "fq_move_debug",
    sharp_turn_stop = "fq_sharp_turn_stop",   -- 3.2.0
    rotation_only = "fq_rotation_only",
    use_quest = "fq_use_quest",
    show_gui = "fq_show_gui",
    -- Hunter / Warlock / Shaman / Rogue rotations
    aspect_hawk = "fq_aspect_hawk",
    trueshot = "fq_trueshot",
    hunter_pet = "fq_hunter_pet",
    mend_pet = "fq_mend_pet",
    hunters_mark = "fq_hunters_mark",
    serpent_sting = "fq_serpent_sting",
    arcane_shot = "fq_arcane_shot",
    steady_shot = "fq_steady_shot",
    multi_shot = "fq_multi_shot",
    concussive = "fq_concussive",
    hunter_debug = "fq_hunter_debug",
    warlock_armour = "fq_warlock_armour",
    health_funnel = "fq_health_funnel",
    corruption = "fq_corruption",
    curse_agony = "fq_curse_agony",
    immolate = "fq_immolate",
    shadow_bolt = "fq_shadow_bolt",
    drain_life = "fq_drain_life",
    life_tap = "fq_life_tap",
    warlock_debug = "fq_warlock_debug",
    enhancement = "fq_enhancement",
    lightning_shield = "fq_lightning_shield",
    flame_shock = "fq_flame_shock",
    earth_shock = "fq_earth_shock",
    frost_shock = "fq_frost_shock",
    lightning_bolt = "fq_lightning_bolt",
    healing_wave = "fq_healing_wave",
    shaman_debug = "fq_shaman_debug",
    sinister_strike = "fq_sinister_strike",
    backstab = "fq_backstab",
    slice_dice = "fq_slice_dice",
    rupture = "fq_rupture",
    eviscerate = "fq_eviscerate",
    evasion = "fq_evasion",
    kick = "fq_kick",
    rogue_debug = "fq_rogue_debug",
    -- Warrior (rotations/warrior.lua)
    battle_shout = "fq_battle_shout",
    battle_stance = "fq_battle_stance",
    bloodrage = "fq_bloodrage",
    berserker_rage = "fq_berserker_rage",
    victory_rush = "fq_victory_rush",
    execute = "fq_execute",
    mortal_strike = "fq_mortal_strike",
    bloodthirst = "fq_bloodthirst",
    whirlwind = "fq_whirlwind",
    overpower = "fq_overpower",
    rend = "fq_rend",
    thunder_clap = "fq_thunder_clap",
    cleave = "fq_cleave",
    heroic_strike = "fq_heroic_strike",
    sunder_armor = "fq_sunder_armor",
    demo_shout = "fq_demo_shout",
    hamstring = "fq_hamstring",
    pummel = "fq_pummel",
    shield_bash = "fq_shield_bash",
    warrior_debug = "fq_warrior_debug",
    -- Supplies (supplies.lua)
    buy_supplies = "fq_buy_supplies",
    vendor_debug = "fq_vendor_debug",
    -- Auto-equip (equip.lua)
    auto_equip = "fq_auto_equip",
    equip_weapons = "fq_equip_weapons",
    equip_debug = "fq_equip_debug",
    -- Druid (rotations/druid.lua)
    mark_of_wild = "fq_mark_of_wild",
    thorns = "fq_thorns",
    moonfire = "fq_moonfire",
    wrath = "fq_wrath",
    faerie_fire = "fq_faerie_fire",
    entangling = "fq_entangling",
    rejuvenation = "fq_rejuvenation",
    regrowth = "fq_regrowth",
    healing_touch = "fq_healing_touch",
    druid_debug = "fq_druid_debug",
    -- Paladin (rotations/paladin.lua)
    blessing = "fq_blessing",
    seal = "fq_seal",
    judgement = "fq_judgement",
    crusader_strike = "fq_crusader_strike",
    hammer_wrath = "fq_hammer_wrath",
    consecration = "fq_consecration",
    flash_light = "fq_flash_light",
    holy_light = "fq_holy_light",
    paladin_debug = "fq_paladin_debug",
    -- Priest (rotations/priest.lua)
    pw_fortitude = "fq_pw_fortitude",
    inner_fire = "fq_inner_fire",
    shadowform = "fq_shadowform",
    pw_shield = "fq_pw_shield",
    swp = "fq_swp",
    mind_blast = "fq_mind_blast",
    mind_flay = "fq_mind_flay",
    smite = "fq_smite",
    renew = "fq_renew",
    flash_heal = "fq_flash_heal",
    priest_debug = "fq_priest_debug",
    ice_armor = "fq_ice_armor",
    mage_armor = "fq_mage_armor",
    molten_armor = "fq_molten_armor",
    ice_barrier = "fq_ice_barrier",
    mana_shield = "fq_mana_shield",
    icy_veins = "fq_icy_veins",
    presence_of_mind = "fq_presence_of_mind",
    combustion = "fq_combustion",
    arcane_power = "fq_arcane_power",
    frostbolt = "fq_frostbolt",
    fireball = "fq_fireball",
    scorch = "fq_scorch",
    arcane_missiles = "fq_arcane_missiles",
    pyroblast = "fq_pyroblast",
    fire_blast = "fq_fire_blast",
    frost_nova = "fq_frost_nova",
    ice_lance = "fq_ice_lance",
    cone = "fq_cone",
    flamestrike = "fq_flamestrike",
    blizzard = "fq_blizzard",
    blast_wave = "fq_blast_wave",
    dragons_breath = "fq_dragons_breath",
    water_ele = "fq_water_ele",
    counterspell = "fq_counterspell",
    mage_wand = "fq_mage_wand",
    atk_any = "fq_atk_any",
    atk_5 = "fq_atk_5",
    atk_3 = "fq_atk_3",
}

local slider_aliases = {
    sp_heal = "fq_sp_heal",
    melee_yards = "fq_melee_yards",
    ranged_yards = "fq_ranged_yards",
    sp_def = "fq_sp_def",
    sp_aoe = "fq_sp_aoe",
    sp_wand = "fq_sp_wand",
    eat_hp = "fq_eat_hp",
    drink_mana = "fq_drink_mana",
    hp_pot = "fq_hp_pot",
    mp_pot = "fq_mp_pot",
    max_kill = "fq_max_kill",
    fight_back_hp = "fq_fight_back_hp",
    fight_back_yards = "fq_fight_back_yards",
    pull_radius = "fq_pull_radius",
    bag_free = "fq_bag_free",
    max_shards = "fq_max_shards",
    repair_pct = "fq_repair_pct",
    -- class self-heal thresholds (rotations/*.lua read these via gui.slider)
    pet_heal_pct = "fq_pet_heal_pct",
    warlock_heal_pct = "fq_warlock_heal_pct",
    shaman_heal_pct = "fq_shaman_heal_pct",
    combo_finish = "fq_combo_finish",
    evasion_pct = "fq_evasion_pct",
    food_target = "fq_food_target",
    drink_target = "fq_drink_target",
    priest_heal_pct = "fq_priest_heal_pct",
    druid_heal_pct = "fq_druid_heal_pct",
    paladin_heal_pct = "fq_paladin_heal_pct",
    heroic_rage = "fq_heroic_rage",
    bloodrage_hp = "fq_bloodrage_hp",
    execute_pct = "fq_execute_pct",
}

-- Combobox ids read via gui.combo(). Kept separate from checkbox and slider
-- aliases because gui.slider() only accepts numbers and gui.is_on() only
-- booleans, so a dropdown routed through either silently returns the fallback.
local combo_aliases = {
    class = "fq_class",
    paladin_aura = "fq_paladin_aura",
    warlock_pet = "fq_warlock_pet",
    shaman_imbue = "fq_shaman_imbue",
}

local function checkbox_element(key)
    local id = aliases[key] or key
    return menu:element(id)
end

local function keybind_enabled(element)
    if not element then
        return nil
    end
    local ok, st = pcall(function()
        return plugin_helper:is_toggle_enabled(element)
    end)
    if ok and type(st) == "boolean" then
        return st
    end
    ok, st = pcall(function()
        return element:get_state()
    end)
    if ok and type(st) == "boolean" then
        return st
    end
    return nil
end

-- ============================================================================
-- THE SPELLS TAB IS THE ROTATION
-- ============================================================================
-- A checkbox registered with a `spell` names a rotation ability. The Spells
-- tab lists those same abilities by name, so a tick there has to win over the
-- class checkbox - otherwise the tab is a display that lies about what the
-- bot will cast.
--
-- picks answers three ways, and the third is what makes this safe: nil means
-- the user has not touched that spell, and the class checkbox keeps deciding.
-- Adding the tab therefore re-armed and disarmed nothing.
--
-- The name is resolved through the spellbook family, because the registry
-- holds a spell OBJECT while picks is keyed by name. A key whose spell is not
-- in the book yet simply has no override.

local pick_name_cache = {}

local function pick_name_for(id)
    local cached = pick_name_cache[id]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end

    -- Everything here is guarded: is_on is the hottest function in the
    -- project, called many times per frame from every rotation, and a menu
    -- whose `elements` is not a plain table must cost a nil rather than an
    -- error thrown up through the whole combat tick.
    local rec = nil
    pcall(function()
        local els = menu and menu.elements
        if type(els) == "table" then
            rec = els[id]
        end
    end)
    local sp = (type(rec) == "table") and rec.spell or nil
    if type(sp) == "table" and sp[1] ~= nil then
        sp = sp[1]           -- "Ice / Frost Armor" registers a list
    end
    if not sp then
        pick_name_cache[id] = false
        return nil
    end

    local sid = nil
    pcall(function() sid = sp:id() end)
    if type(sid) ~= "number" or sid <= 0 then
        pick_name_cache[id] = false
        return nil
    end

    local name = nil
    if type(spellbook.name_of_id) == "function" then
        pcall(function() name = spellbook.name_of_id(sid) end)
    end
    if type(name) ~= "string" or name == "" then
        pick_name_cache[id] = false
        return nil
    end
    pick_name_cache[id] = name
    return name
end

--- Forget the resolved names. The scan replaces the book, so a name that did
--- not resolve before the scan must be retried after it.
function gui.reset_pick_names()
    pick_name_cache = {}
end

-- picks is required lazily because it loads after this file. The require stays
-- lazy; only the LOOKUP is remembered.
--
-- is_on is the hottest function in the project - see the note above
-- pick_name_for - and it was paying a pcall and a package.loaded lookup on
-- every single call, of which there are roughly twenty per frame from the
-- rotations alone. Resolved once, on the first call that succeeds.
--
-- Cached on success only. A call that lands before picks is loadable must
-- leave the slot empty and retry, not remember the failure for the session.
local picks_mod = nil

local function get_picks()
    if picks_mod then return picks_mod end
    local ok, mod = pcall(require, "picks")
    if ok and type(mod) == "table" then picks_mod = mod end
    return picks_mod
end

local run_authorized = false -- Session-only; persisted checkboxes never start automation.

local function is_on(key)
    -- One fresh persistence key replaces all former logging preferences.
    local log_key = aliases[key] or key
    if log_key == "fq_crash_capture" or log_key == "fq_crash_recorder"
        or log_key == "fq_spell_debug" or log_key == "fq_print_action" then return false end
    if log_key == "fq_logging" or log_key == "fq_session_detail"
        or (type(log_key)=="string" and log_key:match("_debug$")) then
        return menu:get("fq_logging") ~= false
    end
    if (key == "enable" or key == "fq_enable") and not run_authorized then return false end
    -- ZYGOR QUESTING (1.0.0): questing is the only mode of this product
    if key == "use_quest" then return true end
    local id = aliases[key] or key

    -- A Spells tab choice outranks the class checkbox, but only when one was
    -- actually made.
    local picks = get_picks()
    if picks and type(picks.state) == "function" then
        local name = pick_name_for(id)
        if name then
            local st = picks.state(name)
            if type(st) == "boolean" then
                return st
            end
        end
    end

    local via_menu = menu:get(id)
    if type(via_menu) == "boolean" then
        return via_menu
    end
    local element = checkbox_element(key)
    if element then
        local ok, st = pcall(function()
            return element:get_state()
        end)
        if ok and type(st) == "boolean" then
            return st
        end
        ok, st = pcall(function()
            return element:get()
        end)
        if ok and type(st) == "boolean" then
            return st
        end
    end
    local kb = keybinds[key]
    if kb then
        local kb_state = keybind_enabled(kb)
        if type(kb_state) == "boolean" then
            return kb_state
        end
    end
    if key == "path_combat" then
        return true
    end
    return false
end

local function set_on(key, value)
    local on = value == true
    local element = checkbox_element(key)
    if element then
        pcall(function()
            element:set(on)
        end)
    end
    if keybinds[key] then
        pcall(function()
            keybinds[key]:set_toggle_state(on)
        end)
    end
end

gui.is_on = is_on
gui.set_on = set_on

local ATK_IDS = {
    any = "fq_atk_any",
    five = "fq_atk_5",
    three = "fq_atk_3",
}
local last_atk_mode = "three"

local function apply_atk_mode(mode)
    if mode ~= "any" and mode ~= "five" and mode ~= "three" then
        mode = "three"
    end
    last_atk_mode = mode
    menu:set(ATK_IDS.any, mode == "any")
    menu:set(ATK_IDS.five, mode == "five")
    menu:set(ATK_IDS.three, mode == "three")
end

function gui.sync_attack_level()
    local any = menu:get(ATK_IDS.any) == true
    local five = menu:get(ATK_IDS.five) == true
    local three = menu:get(ATK_IDS.three) == true
    local n = (any and 1 or 0) + (five and 1 or 0) + (three and 1 or 0)
    if n == 1 then
        if any then
            last_atk_mode = "any"
        elseif five then
            last_atk_mode = "five"
        else
            last_atk_mode = "three"
        end
        return
    end
    if n == 0 then
        apply_atk_mode(last_atk_mode)
        return
    end
    if any and last_atk_mode ~= "any" then
        apply_atk_mode("any")
    elseif five and last_atk_mode ~= "five" then
        apply_atk_mode("five")
    elseif three and last_atk_mode ~= "three" then
        apply_atk_mode("three")
    else
        apply_atk_mode(last_atk_mode)
    end
end

function gui.attack_level_band()
    gui.sync_attack_level()
    if menu:get(ATK_IDS.any) == true then
        return nil
    end
    if menu:get(ATK_IDS.five) == true then
        return 5
    end
    return 3
end

function gui.slider(key, fallback)
    local cid = menu:player_class()
    local map = cid and class_slider_ids[cid]
    local id = (map and map[key]) or slider_aliases[key] or key
    local value = menu:get(id)
    if type(value) == "number" then
        return value
    end
    return fallback
end

--- Read a combobox as a 1-based index. Returns `fallback` when the element is
--- missing or has not been resolved yet, so a caller never has to guard nil.
function gui.combo(key, fallback)
    local id = combo_aliases[key] or key
    local value = menu:get(id)
    if type(value) == "number" then
        return value
    end
    return fallback
end

function gui.get_menu()
    return menu
end

gui.modes = modes

function gui.mode()
    return modes.QUEST           -- questing only (RestedXP)
end

local path_source = "travel"
local armed_path = nil
local play_pending = false
local last_region_idx = nil
local last_path_key = ""
local picker_cache = {}
local picker_cache_key = ""

--- The faction whose routes the Grinding tab is listing, and its index.
---
--- Defaults to the character's own side the first time a player object is
--- available, so an Alliance character opens on Alliance routes without
--- touching anything. After that the player's choice sticks.
local faction_synced = false

function gui.faction_key()
    local idx = menu:get("fq_faction")
    if type(idx) ~= "number" or idx < 1 or idx > #factions.keys then
        idx = 1
    end
    return factions.key_at(idx), idx
end

--- Point the selector at the character's own side, once.
---
--- It will NOT move you to a side that has no routes. Auto-selecting Horde on
--- a Horde character is correct in principle and useless in practice while
--- every shipped route is Alliance: the list goes empty and it looks as though
--- the profiles have vanished. So a side with nothing in it is not selected,
--- and the reason is logged once.
function gui.sync_faction(player)
    if faction_synced or not player then
        return
    end
    local key, how = factions.of_player(player)
    if not key then
        return
    end
    faction_synced = true

    core.log(string.format("[Master Farmer - Forever Questing] Faction: %s (from %s).", key, tostring(how)))

    local want = factions.index_of(key)
    if menu:get("fq_faction") ~= want then
        menu:set("fq_faction", want)
        picker_cache_key = ""
        last_path_key = ""
    end
end


local function clamp_index(idx, n)
    if type(idx) ~= "number" or idx < 1 then
        idx = 1
    end
    if n < 1 then
        return 1
    end
    if idx > n then
        return n
    end
    return idx
end

--- 1.0.28: no route catalog - the picker holds the empty row only.
function gui.picker_entries()
    local key, region = gui.faction_key()
    return {
        {
            kind = "none",
            source = "",
            index = 0,
            id = nil,
            name = EMPTY_PATH,
            label = EMPTY_PATH,
        },
    }, key, region
end

function gui.combo_labels()
    local rows = gui.picker_entries()
    local labels = {}
    for i = 1, #rows do
        labels[i] = rows[i].label
    end
    return labels
end

function gui.travel_labels()
    return gui.combo_labels()
end

function gui.leveling_labels()
    return gui.combo_labels()
end

-- The chosen route index.
--
-- This used to be read straight back out of the fq_path COMBOBOX ELEMENT,
-- and that is what hid most of the list. That element is created with a single
-- placeholder item and its item list is only refreshed by sync_profile_list,
-- so a real combobox widget - which cannot select an index it has no item for
-- - clamped every set() to whatever stale count it happened to be holding.
-- The dropdown showed all 27 routes and picking anything past the clamp
-- snapped straight back.
--
-- The index is ours, so we keep it. The element is still mirrored for the
-- older popups, but nothing reads the selection back out of it.
local selected_path = 1

local function live_path_count()
    local labels = gui.combo_labels()
    local n = #labels
    if n == 1 and labels[1] == EMPTY_PATH then
        n = 0
    end
    return n, labels
end

function gui.path_index()
    local n = live_path_count()
    return clamp_index(selected_path, n)
end

--- The selected route as an id rather than an index, for settings.lua.
--- An index is meaningless across sessions: the catalog can gain routes and
--- the faction can differ, and index 14 would then be a different route.
function gui.selected_route_id()
    local rows = gui.picker_entries()
    local row = rows[gui.path_index()]
    return (row and row.id) or nil
end

--- Select a route by id. Silently does nothing when the id is not in the
--- current list, which is the right answer for a route that was removed or
--- belongs to the other faction.
function gui.select_route_id(id)
    if type(id) ~= "string" or id == "" then
        return false
    end
    local rows = gui.picker_entries()
    for i = 1, #rows do
        if rows[i].id == id then
            gui.set_path_index(i)
            return true
        end
    end
    return false
end

--- Choose a route. Clamped against the list as it is right now, never against
--- whatever the widget last heard about.
function gui.set_path_index(index)
    local n, labels = live_path_count()
    local before = selected_path
    selected_path = clamp_index(index, n)
    if selected_path ~= before then
        local ok, settings = pcall(require, "settings")
        if ok and settings and type(settings.mark_dirty) == "function" then
            settings.mark_dirty()
        end
    end
    -- Keep the element in step for the legacy popups: items FIRST, or the set
    -- is clamped away again.
    pcall(function()
        menu:set_combobox_items("fq_path", labels)
        menu:set("fq_path", selected_path)
    end)
    return selected_path
end

function gui.level_index()
    return gui.path_index()
end

function gui.selected_picker()
    local rows = gui.picker_entries()
    local idx = gui.path_index()
    return rows[idx]
end

function gui.profile_file()
    local row = gui.selected_picker()
    if not row or row.source ~= "custom" then
        return nil
    end
    return row.id
end

-- gui.load_travel_path and gui.region_key were removed in 2.9.0.
--
-- They were the only readers of path_catalog, which indexed 26 Kalimdor
-- travel routes that were never shipped - every module it named was missing
-- from disk. Nothing could reach them either: picker_entries only ever
-- produces rows of kind "grind" or "none", and load_selected_path routes
-- "grind" to load_grind_path and returns early on "none", so the travel
-- branch was unreachable regardless of what the catalog held.

--- 1.0.28: no route catalog (the grind routes went with the Grind mode).
function gui.load_selected_path()
    return nil, "no path"
end

--- 3.0.0: the id of the loaded route, or nil.
function gui.route_key()
    if type(armed_path) == "table" and type(armed_path.id) == "string" then return armed_path.id end
    return nil
end

--- 3.0.0: carry out the menu clicks queued during the render pass (main.lua
--- calls this first on every update).
function gui.run_deferred()
    menu:run_deferred()
end

function gui.ready_path()
    if type(armed_path) == "table" then
        return armed_path
    end
    return gui.load_selected_path()
end

--- 1.0.28: the route list is empty (no catalog) - the combobox is reset.
function gui.sync_profile_list(restore_selected)
    picker_cache_key = ""
    last_path_key = ""
    menu:set_combobox_items("fq_path", { EMPTY_PATH })
    gui.set_path_index(1)
end

function gui.class_id()
    local idx = menu:get("fq_class")
    if type(idx) ~= "number" then
        idx = 7
    end
    return CLASS_IDS[idx] or enums.class_id.MAGE
end

-- ONLY WHEN IT CHANGES (2.193.0). This ran twice a frame (on_update and
-- on_render) and pushed class, race and the class combo into the menu every
-- time - the largest steady cost in the 2026-10-01 PERF lines (0.069 ms a
-- frame). Class and race are read once a second and pushed only when they
-- differ; the combo is put back only if something moved it.
local SYNC_GAP = 1.0
local sync = { t = -1e9, class = nil, race = nil, idx = nil }

function gui.sync_player(player)
    if not player then
        return
    end
    local now = izi.now()
    if type(now) ~= "number" or (now - sync.t) >= SYNC_GAP or now < sync.t then
        sync.t = type(now) == "number" and now or sync.t
        local class_id = nil
        pcall(function()
            class_id = player:get_class()
        end)
        -- The race drives which racial toggles appear on the Class tab.
        local race_id = nil
        pcall(function()
            race_id = player:get_race_id()
        end)
        if type(race_id) == "number" and race_id ~= sync.race then
            sync.race = race_id
            menu:set_player_race(race_id)
        end
        gui.sync_faction(player)
        if class_id and class_id ~= sync.class then
            sync.class = class_id
            sync.idx = nil
            menu:set_player_class(class_id)
            for i = 1, #CLASS_IDS do
                if CLASS_IDS[i] == class_id then
                    sync.idx = i
                    break
                end
            end
        end
    end
    if sync.idx and menu:get("fq_class") ~= sync.idx then
        menu:set("fq_class", sync.idx)
    end
end

--- Questing has no profile of its own: the Zygor guide is the profile, so
--- questing is ready whenever the addon is loaded.
function gui.has_quest_profile()
    if not is_on("use_quest") then
        return false
    end
    local ok, guide = pcall(require, "quest/guide")
    return ok and type(guide) == "table" and guide.is_loaded() == true
end

-- ============================================================================
-- AUTO LOAD (1.0.19)
-- ============================================================================
-- Update tick only (refresh_view, from main.lua's on_update), never the render
-- pass. Timed with core.time(). gui.try_start() is the only way it starts.
local LOAD_AFTER = 15
local auto_load = { due = nil, suspended = false }

--- 1.0.19: one step of the Auto Load countdown. st.due is the deadline; true
--- when try_start was called. A blocked start sets the next deadline 15 s on.
local function auto_load_step(st, now, on, started, try_start)
    if not on then st.suspended = false end
    if not on or started or st.suspended then
        st.due = nil
        return false
    end
    if type(now) ~= "number" then
        return false
    end
    if st.due == nil then
        st.due = now + LOAD_AFTER
        return false
    end
    if now < st.due then
        return false
    end
    st.due = now + LOAD_AFTER
    local ok, started_ok, why = pcall(try_start)
    if not ok or started_ok == false then
        st.error = tostring(not ok and started_ok or why or "start declined")
        local ok_log, log = pcall(require, "errorlog")
        if ok_log and type(log.info) == "function" then
            pcall(log.info, "Auto Load could not start: %s", st.error)
        end
    else
        st.error = nil
    end
    return true
end

--- 1.0.19: whole seconds left ("12s"), or "-" while off or running.
local function auto_load_text(st, now, on, started)
    if st.tick_error then return "Error: " .. st.tick_error end
    if not on then return "Disabled" end
    if started then return "Running" end
    if st.suspended then return st.stop_reason or "Stopped / paused" end
    if st.due == nil or type(now) ~= "number" then
        return string.format("%ds", LOAD_AFTER)
    end
    if st.error then return "Retry: " .. st.error end
    return string.format("%ds", math.max(0, math.ceil(st.due - now)))
end

--- 1.0.19: the launcher's position-reload countdown as "m:ss", or "-".
local function reload_text()
    local mf = rawget(_G, "MF_CORE")
    local left = nil
    if type(mf) == "table" then local f = mf.reload_left if type(f) == "function" then local ok, v = pcall(f) if ok and type(v) == "number" then left = v end end end
    if left == nil then
        return "-"
    end
    local s = math.max(0, math.floor(left))
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function core_now()
    local ok, now = pcall(core.time)
    return ok and tonumber(now) or nil
end

function gui.auto_load_tick()
    local on, started = is_on("fq_auto_load"), gui.is_started()
    local status = tostring(on) .. "/" .. tostring(started) .. "/" .. tostring(auto_load.suspended)
    if auto_load.last_status ~= status then
        auto_load.last_status = status
        local ok, log = pcall(require, "errorlog")
        if ok and type(log.trail) == "function" then
            pcall(log.trail, "autoload", "enabled=%s running=%s suspended=%s", tostring(on), tostring(started), tostring(auto_load.suspended))
        end
    end
    auto_load_step(auto_load, core_now(), on, started, gui.try_start)
end

-- 1.0.19: the pure pieces, for tests/test_fq_autoload.lua
gui._auto_load = { step = auto_load_step, text = auto_load_text, reload_text = reload_text, LOAD_AFTER = LOAD_AFTER }

-- ============================================================================
-- RENDER CACHE (3.0.0)
-- ============================================================================
-- The windows are drawn on the render pass, where no game call may run (a
-- game call while drawing can take WoW Forever down). Everything they show
-- from the game is read here, on the update tick (main.lua -> refresh_view),
-- and the draw code reads only this table.
local view = {
    class_id = nil, level = nil, target_line = "Searching...",
    herb = nil, mine = nil, has_herb = false, has_mine = false, prof_cap = 0, map = nil,
    spell_rows = nil, t = -1e9, slow_t = -1e9,
}
local VIEW_EVERY, VIEW_SLOW = 0.25, 1.0

--- Update tick only: read what the windows show.
function gui.refresh_view(player)
    local auto_ok, auto_error = pcall(gui.auto_load_tick)
    if not auto_ok and auto_load.tick_error ~= tostring(auto_error) then
        auto_load.tick_error = tostring(auto_error)
        local ok, log = pcall(require, "errorlog")
        if ok and type(log.info) == "function" then pcall(log.info, "Auto Load tick failed: %s", auto_load.tick_error) end
    elseif auto_ok then auto_load.tick_error = nil end
    local now = izi.now()
    if type(now) ~= "number" or (now - view.t) < VIEW_EVERY then return end
    view.t = now
    if not player then return end
    local okc, cid = pcall(player.get_class, player)
    if okc and type(cid) == "number" then view.class_id = cid end
    local okl, lvl = pcall(player.get_level, player)
    if okl and type(lvl) == "number" then view.level = lvl end
    -- 1.0.10: the running pop-up's currency looted / quests completed (session.lua)
    do
        local ok_s, ses = pcall(require, "session")
        if ok_s and type(ses) == "table" then
            view.looted = ses.looted_copper()
            view.quests_done = ses.quests_completed()
        end
    end
    -- the HUD target line: Rotation Only fights the player's own target
    local line = type(state.note) == "string" and state.note ~= "" and state.note or "Searching..."
    pcall(function()
        local u = (is_on("rotation_only") and player:get_target()) or (state.target and state.target.unit)
        if u and u:is_valid() and not u:is_dead_or_ghost() then
            local d = player:distance_to(u)
            line = string.format("%s  %s", tostring(u:get_name()),
                type(d) == "number" and string.format("%.0f yd", d) or "?")
        end
    end)
    view.target_line = line
    pcall(gui.sync_faction, player)
    if (now - view.slow_t) >= VIEW_SLOW then
        view.slow_t = now
        pcall(function() view.map = core.game_ui.get_current_map_id() end)
        local oks, smart = pcall(require, "smart")
        if oks and type(smart) == "table" and type(smart.rows) == "function" then
            local okw, rows = pcall(smart.rows, player)
            view.spell_rows = okw and rows or nil
        end
        -- 1.0.1: the spell sequence recorder follows its box (update tick)
        local okp, prio = pcall(require, "priority")
        if okp and type(prio) == "table" then
            local want = is_on("fq_spell_debug") and is_on("fq_priority_mode")
            if want and not prio.recording() then prio.start()
            elseif not want and prio.recording() then prio.stop() end
        end
    end
end

function gui.is_started()
    if not is_on("enable") then
        return false
    end
    if not gui.has_quest_profile() then          -- 1.0.28: questing only
        return false
    end
    local ok, rotation = pcall(require, "rotation")
    if not ok or type(rotation) ~= "table" then
        return false
    end
    -- 3.0.0: the class from the render cache (this runs on the render pass)
    local class_id = view.class_id or gui.class_id()
    return rotation.supported(class_id) == true
end

menu.on_close = function()
    -- 1.24.0: closing the window stops the bot first (Sentinel, attack, keys).
    if type(gui.stop) == "function" then pcall(gui.stop, "GUI closed") end
    -- Keep the stopped session loaded: unloading would re-arm the launcher's Auto Load.
    set_on("show_gui", false)
end

_G.ForeverQuesting = _G.ForeverQuesting or {}
local NS = _G.ForeverQuesting
NS._sessions = NS._sessions or {}
local MY_SESSION = NS._sessions[identity.folder]

local last_toggle_at = { enable = -1, show_gui = -1 }
local last_activity = nil

local function can_start()
    local ok, rotation = pcall(require, "rotation")
    if not ok or type(rotation) ~= "table" then
        return false
    end
    local me = nil
    pcall(function()
        me = izi.me()
    end)
    local class_id = me and me.get_class and me:get_class() or nil
    if not class_id then
        return false
    end
    return rotation.supported(class_id) == true
end

local function start_bot(source)
    if NS._sessions[identity.folder] ~= MY_SESSION then
        return false, "session was replaced"
    end
    gui.sync_activity()
    if not can_start() then
        core.log("[Master Farmer - Forever Questing] Start blocked: no rotation for this class.")
        return false, "player class or rotation is not ready"
    end
    loader.ensure_quest()
    -- a missing RestedXP addon does not block Start: the engine waits for it
    menu:set("fq_mode", 2)
    run_authorized = true
    set_on("enable", true)
    -- 1.7.4: Sentinel travel while the bot runs (applied on the update tick)
    local ok_mv, mv = pcall(require, "movement")
    if ok_mv and type(mv) == "table" and type(mv.want_input_driver) == "function" then pcall(mv.want_input_driver, true) end
    local what = "questing"
    state.set_note("Start", "Quest")
    -- 1.4.3: Start gives held goals (a stall recovery that gave up) a fresh try
    local ok_qg, qg = pcall(require, "quest/guide")
    if ok_qg and type(qg) == "table" and type(qg.forget_local_done) == "function" then pcall(qg.forget_local_done) end
    local ok_e, errorlog = pcall(require, "errorlog")
    if ok_e and type(errorlog) == "table" then
        errorlog.info("Start: %s (%s)", what, type(source) == "string" and source or "Start control")
        -- The recorder writes a line per stage per frame - ~2.7 ms of disk
        -- each, 90+ ms a frame (2.28.0 log). Its own opt-in box only.
        if is_on("crash_recorder") then
            errorlog.arm("start " .. what)
        end
        -- The first 30 s after Start (2.88.0): most shutdowns came 4-45 s in.
        if is_on("crash_capture") and type(errorlog.arm_light) == "function" then
            errorlog.arm_light(30, "first 30 s after Start")
        end
    end
    return true
end

function gui.try_start()
    return start_bot("Auto Load timer")
end

function gui.apply_pending_play()
    return nil
end

function gui.use_quest_mode()
    set_on("use_quest", true)
    gui.sync_activity()
end

function gui.clear_quest_skips()
    state.quest.skipped = {}
    state.set_note("Quest", "Cleared skipped quests")
end

local function off_log(why)
    if is_on("enable") then
        local ok_e, el = pcall(require, "errorlog")
        if ok_e and type(el) == "table" and type(el.info) == "function" then pcall(el.info, "Stop: %s", why) end
        pcall(core.log, "[Master Farmer - Forever Questing] Stopped: " .. tostring(why))
    end
end

local function release_driver_wish()
    local ok_mv, mv = pcall(require, "movement")
    if ok_mv and type(mv) == "table" and type(mv.want_input_driver) == "function" then pcall(mv.want_input_driver, false) end
end

local function stop_bot(why)
    local ls = package.loaded["longstuck"]
    if type(ls) == "table" and type(ls.reset) == "function" then pcall(ls.reset) end
    local pickup = package.loaded["quest/pickup"]
    if type(pickup) == "table" and type(pickup.clear) == "function" then pcall(pickup.clear) end
    off_log(type(why) == "string" and why or "Stop")
    auto_load.stop_reason = type(why) == "string" and why or "Stop control"
    auto_load.suspended, auto_load.due = true, nil
    run_authorized = false
    set_on("enable", false)
    release_driver_wish()                                -- 1.7.4
    local ok, movement = pcall(require, "movement")
    if ok and movement then
        if type(movement.halt) == "function" then
            movement.halt()
        elseif type(movement.nav_stop) == "function" then
            movement.nav_stop()
        end
    end
    local ok_st, strafe = pcall(require, "strafe")
    if ok_st and strafe and type(strafe.stop) == "function" then pcall(strafe.stop) end
    local ok_path, path_runner = pcall(require, "path_runner")
    if ok_path and path_runner and type(path_runner.stop) == "function" then
        path_runner.stop()
    end
    local ok_vendor, vendor = pcall(require, "vendor")
    if ok_vendor and vendor and type(vendor.reset) == "function" then
        vendor.reset()
    end
    -- A new Start selects fresh work rather than resuming stale units or loot bursts.
    pcall(state.reset_target)
    local ok_loot, loot = pcall(require, "loot")
    if ok_loot and type(loot) == "table" and type(loot.reset) == "function" then pcall(loot.reset) end

end

local function pause_bot()
    stop_bot("Pause")
end

--- Stop the bot, as the Stop button does. Used by the NPC-stuck watchdog.
function gui.stop(why)
    stop_bot(type(why) == "string" and why or "stopped by the bot (watchdog)")
end

local function toggle_gui()
    local now = core.time()
    if type(now) ~= "number" then
        now = 0
    end
    if now - (last_toggle_at.show_gui or -1) < 0.20 then
        return
    end
    last_toggle_at.show_gui = now
    if is_on("show_gui") then stop_bot("GUI hidden") end
    set_on("show_gui", not is_on("show_gui"))
end

-- 2.315.0: no izi.on_key_release (fired by izi.on_update, which is no longer
-- called). Every hotkey is read with core.input.is_key_pressed in
-- gui.process_keybinds (KEY_CODES below); earlier loads' IZI watchers are
-- unbound once here.
local unsubs = {}
local function watch_key(code, fn)
    local _ = code
    local _ = fn
end

if type(NS.unbind_hotkeys) == "function" then
    pcall(NS.unbind_hotkeys)
    NS.unbind_hotkeys = nil
end

watch_key(996, start_bot)
watch_key(1006, start_bot)
watch_key(0x60, start_bot)
watch_key(997, pause_bot)
watch_key(0x61, pause_bot)
watch_key(998, stop_bot)
watch_key(0x62, stop_bot)
watch_key(1000, toggle_gui)
watch_key(0x64, toggle_gui)
watch_key(0x25, toggle_gui)

NS.unbind_hotkeys = function()
    for i = 1, #unsubs do
        pcall(unsubs[i])
    end
end

local KEY_CODES = {
    -- core.input takes Windows virtual-key codes, not IZI event IDs.
    enable = { 0x60 },
    pause = { 0x61 },
    stop = { 0x62 },
    show_gui = { 0x64 },
}
local key_was_down = { enable = false, pause = false, stop = false, show_gui = false }

local function key_is_down(codes)
    for i = 1, #codes do
        local ok, pressed = pcall(function()
            return core.input.is_key_pressed(codes[i])
        end)
        if ok and pressed == true then
            return true
        end
    end
    return false
end

function gui.sync_activity()
    local q = is_on("use_quest")
    if q then
        if last_activity ~= "quest" then
            last_activity = "quest"
            off_log("mode changed to quest")
            set_on("enable", false)
            armed_path = nil
            loader.ensure_quest()
            menu:set("fq_mode", 2)
            state.set_note("Mode", "Quest - load a RestedXP guide, then Start")
        end
        return
    end
    if last_activity ~= nil then
        last_activity = nil
        off_log("no mode selected (Quest off)")
        set_on("enable", false)
        loader.unload_quest()
        armed_path = nil
        picker_cache_key = ""
        last_path_key = ""
        menu:set_combobox_items("fq_path", { EMPTY_PATH })
        state.set_note("Mode", "Select Quest")
    end
end

function gui.process_keybinds()
    gui.sync_attack_level()
    gui.sync_activity()
    if key_is_down(KEY_CODES.enable) and not key_was_down.enable then
        start_bot()
    end
    if key_is_down(KEY_CODES.pause) and not key_was_down.pause then
        pause_bot()
    end
    if key_is_down(KEY_CODES.stop) and not key_was_down.stop then
        stop_bot("Numpad 2")
    end
    if key_is_down(KEY_CODES.show_gui) and not key_was_down.show_gui then
        toggle_gui()
    end
    key_was_down.enable = key_is_down(KEY_CODES.enable)
    key_was_down.pause = key_is_down(KEY_CODES.pause)
    key_was_down.stop = key_is_down(KEY_CODES.stop)
    key_was_down.show_gui = key_is_down(KEY_CODES.show_gui)
end

local function class_status()
    local ok, rotation = pcall(require, "rotation")
    local idx = menu:get("fq_class") or 7
    local name = CLASS_LABELS[idx] or "?"
    if ok and rotation and rotation.supported(CLASS_IDS[idx]) then
        return name .. " - ready"
    end
    return name .. " - no rotation yet"
end

local function mode_status()
    if gui.mode() == modes.QUEST then
        return "Quest"
    end
    return "Idle"
end

menu:set_status({
    {
        label = "State",
        value = function()
            return gui.is_started() and "Running" or "Idle"
        end,
        color = function()
            if gui.is_started() then
                return C(90, 210, 110, 255)
            end
            return C(210, 78, 78, 255)
        end,
    },
    { label = "Class", value = class_status },
    { label = "Mode", value = mode_status },
    {
        label = "Note",
        value = function()
            return state.note ~= "" and state.note or "-"
        end,
    },
    {
        -- Movement state machine at a glance: which state, who owns the player,
        -- and why it is not moving when it is not moving.
        label = "Movement",
        value = function()
            local ok, movement = pcall(require, "movement")
            if not ok or not movement then
                return "-"
            end
            local okd, snap = pcall(movement.debug_snapshot)
            if not okd or type(snap) ~= "table" then
                return "-"
            end
            local text = tostring(snap.state) .. " / " .. tostring(snap.owner)
            if snap.restriction then
                text = text .. " (" .. tostring(snap.restriction) .. ")"
            elseif snap.retreating then
                text = text .. " (kiting)"
            elseif snap.paused then
                text = text .. " (paused)"
            elseif snap.sentinel then
                text = text .. " (nav)"
            elseif snap.quiet then
                text = text .. " (settling)"
            end
            if snap.target_dist then
                text = text .. string.format("  %.0fyd", snap.target_dist)
            end
            return text
        end,
    },
    {
        label = "RXP / TomTom target",
        value = function()
            local g=package.loaded["quest/guide"]
            local p=g and g.live_navigation and g.live_navigation()
            if not p then return "No live guide waypoint" end
            return string.format("Map %d: %.2f, %.2f | step %s%s",p.map_id,p.x_percent,p.y_percent,
                tostring(p.step),p.wrong_continent and " (other continent)" or "")
        end,
    },
    {
        label = "Player / ground",
        value = function()
            local ok, mv = pcall(require, "movement")
            local snap = ok and mv.debug_snapshot and mv.debug_snapshot() or {}
            return snap.coordinates or "Waiting for position"
        end,
    },
    {
        -- Is out-of-combat travel going through Sentinel Navigation?
        -- 1.7.2 (CLAUDE_MASTERARTHASNAV_RULES R2.4): no navigation call on the
        -- draw path - the state comes from movement's update-tick snapshot.
        label = "Navigation",
        value = function()
            local okm, mv = pcall(require, "movement")
            local snap = okm and type(mv) == "table" and mv.debug_snapshot and mv.debug_snapshot() or {}
            -- 1.1.0: Sentinel Navigation (movement/sentinel.lua, server set by the launcher)
            -- 1.7.0: + the live status (progress, distance, zones, failed paths)
            if snap.nav == "ready" then return snap.nav_status and ("Sentinel: " .. snap.nav_status) or "Sentinel ready" end
            if snap.nav == "down" then return "Sentinel server not answering - retrying" end
            return tostring(snap.nav_why or "Sentinel Navigation not loaded")
        end,
        color = function()
            local okm, mv = pcall(require, "movement")
            local snap = okm and type(mv) == "table" and mv.debug_snapshot and mv.debug_snapshot() or {}
            if snap.nav == "ready" then return C(90, 210, 110, 255) end
            return C(210, 78, 78, 255)
        end,
    },
    {
        -- 1.0.19: seconds until Auto Load presses Start
        label = "Auto Load",
        value = function()
            return auto_load_text(auto_load, core_now(), is_on("fq_auto_load"), gui.is_started())
        end,
    },
    {
        -- 1.0.19: the launcher's position-reload countdown (MF_CORE.reload_left)
        label = "Reload",
        value = reload_text,
    },
    {
        label = "Last Action",
        value = function()
            local ok, rotation = pcall(require, "rotation")
            if ok and rotation and type(rotation.last_action) == "function" then
                return rotation.last_action()
            end
            return state.last_action or "-"
        end,
    },
})

menu:set_actions({
    {
        id = "toggle_enable",
        label = "Start",
        style = "start",
        on_click = start_bot,
    },
    {
        id = "toggle_pause",
        label = "Paused",
        style = "pause",
        on_click = pause_bot,
    },
    {
        id = "toggle_stop",
        label = "Stop",
        style = "stop",
        on_click = stop_bot,
    },
})

-- ============================================================================
-- QUESTING TAB
-- ============================================================================
-- Session-only: the detection panel is a diagnostic, not a setting.
-- Zygor detection is always shown while questing (2.188.0); the toggle
-- button is gone.

local show_quest_diag = true

menu:on_tab("questing", function(win, x, y, w, h)
    local gold = C(232, 222, 196, 255)
    local mute = C(180, 170, 150, 255)
    local hi = C(248, 226, 132, 255)
    local ok_col = C(90, 210, 110, 255)
    local warn = C(220, 176, 56, 255)

    -- ui.lua reserves eight control rows (~360px) under the registered
    -- checkboxes for this content; h is the whole viewport, not what is left.
    -- Text stops at BUDGET so a long step cannot run into the button.
    local LEFT = x + 12
    local LINE = 18
    local BUDGET = 330
    local bottom = y + BUDGET - LINE
    local cy = y + 4

    local function text(col, str, indent)
        if cy > bottom then
            return
        end
        win:render_text(FONT_SMALL, vec2.new(LEFT + (indent or 0), cy), col, str)
        cy = cy + LINE
    end

    if not is_on("use_quest") then
        text(warn, "Tick Enable Questing to follow the RestedXP guide.")
        return
    end

    local ok, quest = pcall(require, "quest")
    if not ok or type(quest) ~= "table" or type(quest.snapshot) ~= "function" then
        text(warn, "Quest engine not loaded: " .. tostring(quest))
        return
    end
    local info = quest.snapshot()
    local ok_g, guide = pcall(require, "quest/guide")

    -- Buttons first, at fixed places below the text budget, so an early
    -- return in the status below never hides them.
    local gap = 10
    local btn_w = math.floor((w - 24 - gap) / 2)
    local by = y + BUDGET + 8
    local skipped = 0
    if type(state.quest.skipped) == "table" then
        for _ in pairs(state.quest.skipped) do
            skipped = skipped + 1
        end
    end
    if menu:draw_launcher(win, LEFT, by, btn_w, 30, string.format("Clear Skipped (%d)", skipped)) then
        menu:defer(function()
            gui.clear_quest_skips()
        end)
    end
    if menu:draw_launcher(win, LEFT + btn_w + gap, by, btn_w, 30, "Vendor") then
        menu:open_popup("vendor")
    end

    -- What the bot actually reads from core.addons.rested_xp, raw. Shown on
    -- request, and always when the addon is not being read, because that is
    -- exactly when the answer is needed.
    if (show_quest_diag or not info.ready) and ok_g and type(guide.diagnose) == "function" then
        local d = guide.diagnose()
        text(hi, "RestedXP detection")
        text(mute, string.format("core.addons: %s   rested_xp: %s", d.addons, d.namespace), 12)
        if #d.missing > 0 then
            text(warn, "missing: " .. table.concat(d.missing, ", "), 12)
        end
        text(mute, "is_loaded() = " .. d.is_loaded, 12)
        text(mute, "has_current_step() = " .. d.has_step, 12)
        text(mute, string.format("get_current_step(): %s  step %d  %d goal%s",
            d.step_type, d.step_num, d.goal_count, d.goal_count == 1 and "" or "s"), 12)
        text(mute, "waypoint: " .. d.waypoint, 12)
        text(mute, string.format("step waypoints: %d   objectives: %d", d.step_waypoints, d.objectives or 0), 12)
        cy = cy + 6
    end

    -- 1. is the addon there, and does it have something to say
    if not info.loaded then
        text(warn, "RestedXP Guides is not loaded - the bot waits.")
        text(mute, "Install and enable the RestedXP Guides addon. It supplies every")
        text(mute, "quest, NPC location, waypoint and mob to kill.")
        return
    end
    if not info.ready then
        text(warn, "RestedXP is loaded but has no current step.")
        text(mute, "Open the RestedXP window and pick a guide for this character.")
        return
    end

    text(ok_col, string.format("RestedXP step %d   -   %d sticky step%s",
        info.step or 0, info.stickies or 0, (info.stickies or 0) == 1 and "" or "s"))
    cy = cy + 4

    -- 2. the step's goals, the one being worked on highlighted
    local current = info.goal and info.goal.index or nil
    local goals = info.goals or {}
    for i = 1, #goals do
        local g = goals[i]
        local mark = g.is_complete and "[x]" or (g.index == current and "[>]" or (g.unhandled and "[?]" or "[ ]"))
        local col = g.is_complete and mute or (g.index == current and hi or gold)
        local line = string.format("%s %s", mark, tostring(g.text or g.action or "?"))
        if g.quest_id then
            line = line .. string.format("  (%d)", g.quest_id)
        end
        text(col, line)
    end
    cy = cy + 4

    -- 3. what the bot makes of the current goal
    if info.goal then
        text(gold, "Doing: " .. tostring(info.kind or "?") .. "   (" .. tostring(info.goal.action) .. ")")
    else
        text(mute, "Guide: " .. tostring(info.describe or info.state or "-"))
    end
    if type(info.unhandled) == "table" and #info.unhandled > 0 then
        text(warn, "No handler yet: " .. table.concat(info.unhandled, ", "), 12)
    end

    -- 4. where it is going
    if info.waypoint and info.waypoint.wrong_continent then
        text(warn, "Waypoint is on another continent - travel there yourself.")
    elseif info.waypoint then
        local wp = info.waypoint
        text(gold, string.format("Waypoint: %s   %s   map %d",
            tostring(wp.title or "-"),
            wp.dist and string.format("%.0fy", wp.dist) or "-", wp.map_id or 0))
    else
        text(mute, "No waypoint for this step.")
    end
    text(mute, "Bot: " .. tostring(info.note or ""))
end)

-- ============================================================================
-- SPELLS TAB (2.64.0)
-- ============================================================================
-- Every spell of the character's class that it knows - DPS, healing and
-- tanking only, from data/class_spells.lua - and the race's castable
-- racials, grouped by what they do. A tick means smart.lua uses it; the
-- rotation for Rotation Only, grinding and questing is built from exactly
-- these. Groups that cannot stack (aura, seal, armor, stance, pet...) use the
-- first ticked spell and show the rest as "standby".
local SPELL_ROW = 22
local SPELL_HEAD = 24

-- 1.0.1 ROTATION ORDER (user: "list the spells to Enable or Disable AND design
-- Rotation Priority logic ... beside the enabled spells have an option to set
-- the rotation order by numeric value"). The list is every CASTABLE spell the
-- 5 s spellbook scan found (class spells, the race's racials, other castable
-- spells - passives, professions and auto attacks left out, smart.lua build).
-- A click on a row enables / disables it; "-" / "+" beside an enabled row set
-- its order number (priority.lua; lower = earlier). With "Use My Rotation
-- Order" ticked the fight tries the enabled rows in that order (smart.lua
-- priority_combat) and the list is drawn in it; "Record Spell Sequence" keeps
-- every decision for Export.
menu:checkbox("fq_priority_mode", false, {
    label = "Use My Rotation Order",
    tab = "class",
    tooltip = "Fight with the enabled spells in YOUR order (1 to 10): lowest number first, the first spell whose own checks pass (buff missing, range, resource, cooldown, its condition) is cast. Off: the bot's built-in role order (heals, defensives, interrupts, racials, buffs ... damage, filler).",
})

local ORDER_BTN = 16

menu:on_tab("class", function(win, x, y, w, h)
    local gold = C(232, 222, 196, 255)
    local mute = C(150, 142, 128, 255)
    local ok_col = C(90, 210, 110, 255)
    local warn = C(220, 176, 56, 255)
    local head = C(96, 150, 235, 255)
    local yy = y + 6

    local class_id = menu:player_class()
    if type(class_id) ~= "number" then
        win:render_text(FONT_SMALL, vec2.new(x + 10, yy), mute, "Waiting for player class...")
        return 30
    end
    if not spellbook.ready() then
        win:render_text(FONT_SMALL, vec2.new(x + 10, yy), warn,
            string.format("Scanning the spellbook... %.1fs", spellbook.wait_left()))
        win:render_text(FONT_SMALL, vec2.new(x + 10, yy + 18), mute,
            "Your castable spells and racials appear here once the scan is done.")
        return 48
    end

    local ok_s, smart = pcall(require, "smart")
    local ok_p, prio = pcall(require, "priority")
    if not ok_p then prio = nil end
    local rows = view.spell_rows     -- 3.0.0: built on the update tick
    local idx = menu:get("fq_class") or 7
    local name = CLASS_LABELS[idx] or "Unknown"
    if not ok_s or type(rows) ~= "table" or #rows == 0 then
        win:render_text(FONT_SMALL, vec2.new(x + 10, yy), warn,
            name .. ": no castable spells known yet.")
        return 30
    end
    local ordered = is_on("fq_priority_mode")

    local ticked = 0
    for i = 1, #rows do
        if smart.row_state(rows[i]) then ticked = ticked + 1 end
    end
    win:render_text(FONT_SMALL, vec2.new(x + 10, yy), ok_col,
        string.format("%s - %d of %d castable spells enabled  (%s)", name, ticked, #rows,
            ordered and "YOUR rotation order" or "built-in role order"))
    win:render_text(FONT_SMALL, vec2.new(x + 10, yy + 18), mute,
        "Click a spell to enable / disable it.  - / + set its order 1-10 (1 = cast first).")
    yy = yy + 40

    -- buttons: Export the recorded sequence, Reset the order numbers
    local bw = math.floor((w - 30) / 2)
    if prio and menu:draw_launcher(win, x + 20 + bw, yy, bw, 26, "Reset Order") then
        menu:defer(function() prio.reset_all() end)
    end
    yy = yy + 34

    -- one row: enable box, name, order controls (enabled rows), rank, tag
    local function draw_row(row, index)
        local on, active = smart.row_state(row)
        local bmin = vec2.new(x + 16, yy + 2)
        local bmax = vec2.new(x + 28, yy + 14)
        local rmin, rmax = vec2.new(x + 10, yy), vec2.new(x + w - 10, yy + SPELL_ROW - 2)
        local hover = false
        pcall(function() hover = win:is_mouse_hovering_rect(rmin, rmax) == true end)
        if hover then
            pcall(function() win:render_rect_filled(rmin, rmax, C(52, 58, 72, 120), 3.0) end)
        end
        pcall(function()
            win:render_rect_filled(bmin, bmax, on and C(90, 210, 110, 220) or C(38, 40, 48, 220), 2.0)
        end)
        pcall(function() win:render_rect(bmin, bmax, C(120, 130, 150, 220), 2.0, 1.0) end)
        win:render_text(FONT_SMALL, vec2.new(x + 36, yy + 1), (on and active) and gold or mute, tostring(row.name))

        local consumed = false
        if prio and on then
            local n = prio.number(row, index)
            local ox = x + w - 280
            local minus_min, minus_max = vec2.new(ox, yy + 1), vec2.new(ox + ORDER_BTN, yy + 1 + ORDER_BTN)
            local plus_min, plus_max = vec2.new(ox + 60, yy + 1), vec2.new(ox + 60 + ORDER_BTN, yy + 1 + ORDER_BTN)
            for _, b in ipairs({ { minus_min, minus_max, "-" }, { plus_min, plus_max, "+" } }) do
                pcall(function() win:render_rect_filled(b[1], b[2], C(60, 66, 82, 230), 2.0) end)
                win:render_text(FONT_SMALL, vec2.new(b[1].x + 4, yy + 1), gold, b[3])
            end
            win:render_text(FONT_SMALL, vec2.new(ox + 22, yy + 1), prio.is_custom(row.name) and ok_col or mute,
                string.format("%2d", n))
            local hit_m, hit_p = false, false
            pcall(function() hit_m = win:is_rect_clicked(minus_min, minus_max) == true end)
            pcall(function() hit_p = win:is_rect_clicked(plus_min, plus_max) == true end)
            if hit_m or hit_p then
                consumed = true
                local r, cur = row, n
                menu:defer(function() prio.set(r.name, cur + (hit_p and 1 or -1)) end)
            end
        end

        local tag
        if not on then
            tag = "off"
        elseif row.group and not active then
            tag = "standby"
        elseif row.group then
            tag = "in use"
        else
            tag = "on"
        end
        win:render_text(FONT_SMALL, vec2.new(x + w - 190, yy + 1), mute,
            (row.ranks or 1) > 1 and string.format("rank %d", row.ranks) or "")
        win:render_text(FONT_SMALL, vec2.new(x + w - 100, yy + 1), (on and active) and ok_col or mute, tag)
        if hover and row.tip then
            pcall(function() win:render_tooltip_text_only(row.tip, gold) end)
        end
        if not consumed then
            local hit = false
            pcall(function() hit = win:is_rect_clicked(rmin, rmax) == true end)
            if hit then
                local r = row
                menu:defer(function() smart.toggle(r) end)   -- 3.0.0: update tick
            end
        end
        yy = yy + SPELL_ROW
    end

    local index_of = {}
    for i = 1, #rows do index_of[rows[i]] = i end

    if ordered and prio then
        -- the rotation as it will run: enabled rows in order, then the rest
        win:render_text(FONT_SMALL, vec2.new(x + 10, yy + 2), head, "Rotation order (enabled)")
        yy = yy + SPELL_HEAD
        local on_rows = prio.sorted(rows, function(r) return (smart.row_state(r)) end)
        for i = 1, #on_rows do draw_row(on_rows[i], index_of[on_rows[i]]) end
        yy = yy + 6
        win:render_text(FONT_SMALL, vec2.new(x + 10, yy + 2), head, "Disabled")
        yy = yy + SPELL_HEAD
        for i = 1, #rows do
            if not smart.row_state(rows[i]) then draw_row(rows[i], i) end
        end
        return (yy - y) + 10
    end

    local ok_c, cats = pcall(require, "data/class_spells")
    local sections = (ok_c and cats and cats.sections) or {}
    for si = 1, #sections do
        local sec = sections[si]
        local count = 0
        for i = 1, #rows do
            if rows[i].section == sec.key then count = count + 1 end
        end
        if count > 0 then
            win:render_text(FONT_SMALL, vec2.new(x + 10, yy + 2), head, string.format("%s  (%d)", sec.label, count))
            yy = yy + SPELL_HEAD
            for i = 1, #rows do
                if rows[i].section == sec.key then draw_row(rows[i], i) end
            end
            yy = yy + 6
        end
    end
    return (yy - y) + 10
end)

-- 3.0.0: the list is rebuilt at most once a second while the tab is open
-- (every frame it reset the picker cache and rebuilt every label)
local path_tab_sync_t = -1e9
menu:on_tab("path", function(win, x, y, w, h)
    local clk = tonumber(izi.now()) or 0
    if (clk - path_tab_sync_t) >= 1.0 then
        path_tab_sync_t = clk
        gui.sync_profile_list(false)
    end
    local ok_pr, path_runner = pcall(require, "path_runner")
    local field_w = w - 20
    if field_w < 120 then
        field_w = math.max(80, w - 8)
    end
    local _, region_idx = gui.faction_key()
    local new_region, y2 = menu:draw_dropdown(win, "fq_dd_faction", x + 10, y, field_w, "Faction", factions.labels, region_idx)
    if new_region ~= region_idx then
        menu:set("fq_faction", new_region)
        gui.set_path_index(1)
        armed_path = nil
        last_path_key = ""
        picker_cache_key = ""
        gui.sync_profile_list(false)
    end
    local y3 = y2 + 4                            -- 1.0.28: no grind route button
    path_source = "leveling"
    local loaded = armed_path
    local name = "-"
    local count = 0
    local map_id = 0
    local ready = loaded ~= nil
    if loaded then
        name = loaded.name or loaded.id or "-"
        count = path_format.count(loaded)
        map_id = loaded.map_id or 0
    end
    local status = "Idle"
    if ok_pr and path_runner and type(path_runner.status_text) == "function" then
        status = path_runner.status_text()
    end
    win:render_text(FONT_SMALL, vec2.new(x + 10, y3), C(232, 222, 196, 255), string.format("%s   wp:%d   map:%s", tostring(name), count, tostring(map_id)))
    local ready_text = ready and ("Ready for Play - " .. tostring(name)) or "Select a path, then press Load."
    local ready_col = ready and C(90, 210, 110, 255) or C(180, 170, 150, 255)
    win:render_text(FONT_SMALL, vec2.new(x + 10, y3 + 18), ready_col, ready_text)
    win:render_text(FONT_SMALL, vec2.new(x + 10, y3 + 36), C(180, 170, 150, 255), "Status: " .. tostring(status))

    local gap = 10
    local btn_w = math.floor((w - 20 - gap) / 3)
    if btn_w < 70 then
        btn_w = 70
    end
    local btn_h = 32
    local by = y3 + 58
    local x1 = x + 10
    local x2 = x1 + btn_w + gap
    local x3 = x2 + btn_w + gap

    local function preview_path(path)
        if path and ok_pr and path_runner and type(path_runner.set_preview) == "function" then
            path_runner.set_preview(path)
        end
    end

    if menu:draw_launcher(win, x1, by, btn_w, btn_h, "Load") then
        menu:defer(function()
            local path, err = gui.load_selected_path()
            if path then
                preview_path(path)
                state.set_note("Path", "Loaded " .. tostring(path.name) .. " - ready for Play")
                core.log("[Master Farmer - Forever Questing] Loaded path: " .. tostring(path.name))
            else
                state.set_note("Path", err or "load failed")
                core.log_warning("[Master Farmer - Forever Questing] Profile load failed: " .. tostring(err))
            end
        end)
    end
    if menu:draw_launcher(win, x2, by, btn_w, btn_h, "Save") then
        menu:defer(function()
            local path = armed_path or path_profiles.last_loaded()
            if not path then
                path = select(1, gui.load_selected_path())
            end
            if path then
                local fname = (path.id or "path") .. ".json"
                local ok_save, saved = path_profiles.save_path(path, fname)
                if ok_save then
                    gui.sync_profile_list(false)
                    preview_path(path)
                    state.set_note("Path", "Saved " .. tostring(saved))
                    core.log("[Master Farmer - Forever Questing] Saved profile: " .. tostring(saved))
                else
                    state.set_note("Path", saved or "save failed")
                end
            else
                state.set_note("Path", "Nothing to save")
            end
        end)
    end
    if menu:draw_launcher(win, x3, by, btn_w, btn_h, "Play") then
        menu:defer(function()
            local path = armed_path
            local err = nil
            if not path then
                path, err = gui.load_selected_path()
            end
            if path then
                armed_path = path
                path_profiles.remember(path)
                preview_path(path)
                if gui.is_on("rotation_only") then
                    state.set_note("Path", "Rotation Only - movement off")
                    core.log("[Master Farmer - Forever Questing] Rotation Only is on; Play does not move.")
                else
                    play_pending = true
                    state.set_note("Path", "Starting " .. tostring(path.name))
                end
            else
                state.set_note("Path", err or "play failed - Load a path first")
            end
        end)
    end
end)

menu:on_tab("vendor", function(win, x, y, w, h)
    local line = "Idle"
    if state.vendor and state.vendor.active then
        line = "At vendor - " .. tostring(state.note or "")
    elseif state.note_head == "Vendor" then
        line = tostring(state.note or "")
    end
    win:render_text(FONT_SMALL, vec2.new(x + 10, y + 16), C(248, 226, 132, 255), line)
    win:render_text(FONT_SMALL, vec2.new(x + 10, y + 40), C(232, 222, 196, 255), "Quest walks to the nearest RestedXP vendor, a remembered repairer or the inn.")
    win:render_text(FONT_SMALL, vec2.new(x + 10, y + 62), C(180, 170, 150, 255), "Keeps hearthstone plus mage food and water. Path mode does not vendor.")
    win:render_text(FONT_SMALL, vec2.new(x + 10, y + 84), C(180, 170, 150, 255), "Repair uses core.input.repair_all_items. Greys/whites sell via use_container_item.")
end)

menu:on_tab("settings", function(win, x, y, w, h)
    win:render_text(FONT_SMALL, vec2.new(x + 10, y + 8), C(232, 222, 196, 255), "Show / hide GUI: Numpad 4.")
    win:render_text(FONT_SMALL, vec2.new(x + 10, y + 28), C(180, 170, 150, 255), "Path combat stays on the loaded path (10 yards) and hits the closest enemy in rotation range.")
end)

local draw_probe = nil
local function dprobe(tag)
    if draw_probe == nil then
        local ok, mod = pcall(require, "errorlog")
        draw_probe = (ok and type(mod) == "table" and type(mod.probe) == "function") and mod.probe or false
    end
    if draw_probe then
        draw_probe(tag)
    end
end

local function draw_menu()
    menu:draw()
end

-- ============================================================================
-- MINI STATUS WINDOW (2.83.0)
-- ============================================================================
-- While grinding, questing or Rotation Only runs, the main window is hidden
-- and this 200x100 window shows the time since the start and the player's
-- level, with a Stop button: Stop ends the run (grinding / questing and
-- Rotation Only), closes this window and brings the main window back. The
-- main window also comes back by itself when the run ends any other way
-- (Numpad 2, the NPC watchdog...). Its close cross stops the run and brings the main
-- window back.
-- 1.0.10 (user): also the currency looted this run (g / s / c in their coin
-- colours), the player's level and the quests completed - 250 x 158.
local MINI_W, MINI_H = 250, 158
local COIN_G, COIN_S, COIN_C = C(255, 209, 0, 255), C(199, 199, 207, 255), C(237, 127, 53, 255)
local mini = { win = nil, on = false, since = 0, was_running = false, shown = false }

local function fmt_elapsed(sec)
    sec = math.max(0, math.floor(sec))
    return string.format("%02d:%02d:%02d", math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60)
end

local function restore_main()
    mini.on = false
    set_on("show_gui", true)
    menu:set_visible(true)
    if mini.win and mini.shown then
        pcall(function() mini.win:set_visibility(false) end)
        mini.shown = false
    end
end

local function mini_stop()
    stop_bot()
    set_on("rotation_only", false)
    restore_main()
end

local function draw_mini()
    local WE = enums.window_enums
    if not mini.win then
        mini.win = core.menu.window("fq_mini_status")
        pcall(function() mini.win:set_initial_size(vec2.new(MINI_W, MINI_H)) end)
        pcall(function() mini.win:set_initial_position(vec2.new(80, 180)) end)
    end
    local win = mini.win
    if not mini.shown then
        pcall(function() win:set_visibility(true) end)
        mini.shown = true
    end
    pcall(function() win:force_window_size(vec2.new(MINI_W, MINI_H)) end)
    pcall(function() win:set_next_window_padding(vec2.new(0, 0)) end)

    local elapsed = fmt_elapsed(izi.now() - mini.since)
    -- 3.0.0: level and target line from the render cache (refresh_view)
    local level = view.level and tostring(view.level) or "?"
    local target_line = view.target_line or "Searching..."
    local mode = is_on("rotation_only") and "Rotation Only"
        or (is_on("use_quest") and "Questing" or "Idle")

    local gold = C(232, 222, 196, 255)
    local mute = C(180, 170, 150, 255)
    local ok_col = C(90, 210, 110, 255)
    local restore = false
    local stop = false
    pcall(function()
        win:begin(WE.window_resizing_flags.NO_RESIZE, true,
            C(22, 24, 30, 240), C(96, 150, 235, 200), WE.window_cross_visuals.BLUE_THEME,
            function()
                pcall(function()
                    local b = win:get_close_cross_bounds()
                    if type(b) == "table" and b.min and b.max and win:is_rect_clicked(b.min, b.max) then
                        restore = true
                    end
                end)
                win:render_text(FONT_SMALL, vec2.new(10, 5), ok_col, mode)
                win:render_text(FONT_SMALL, vec2.new(10, 22), gold, elapsed)
                win:render_text(FONT_SMALL, vec2.new(10, 39), gold, "Level " .. level)
                -- 1.0.10: currency looted this run - "0g 0s 0c", each in its coin colour
                do
                    local okses, ses = pcall(require, "session")
                    local g_, s_, c_ = 0, 0, 0
                    if okses and type(ses) == "table" then g_, s_, c_ = ses.split(view.looted or 0) end
                    local x = 10
                    local function piece(str, col)
                        win:render_text(FONT_SMALL, vec2.new(x, 56), col, str)
                        local w = nil
                        pcall(function() local sz = win:get_text_size(str) w = sz and sz.x end)
                        x = x + ((type(w) == "number" and w > 0) and w or (#str * 7))
                    end
                    piece("Looted  ", mute)
                    piece(tostring(g_) .. "g ", COIN_G)
                    piece(tostring(s_) .. "s ", COIN_S)
                    piece(tostring(c_) .. "c", COIN_C)
                end
                win:render_text(FONT_SMALL, vec2.new(10, 73), gold,
                    "Quests completed  " .. tostring(view.quests_done or 0))
                -- HUD line (2.98.0): who the bot is on, and how far - or
                -- "Searching..." while it has nobody.
                win:render_text(FONT_SMALL, vec2.new(10, 90), gold, target_line)

                local bmin, bmax = vec2.new(10, 114), vec2.new(MINI_W - 10, MINI_H - 8)
                local hover = false
                pcall(function() hover = win:is_mouse_hovering_rect(bmin, bmax) == true end)
                pcall(function()
                    win:render_rect_filled(bmin, bmax, hover and C(200, 70, 70, 240) or C(160, 50, 50, 230), 4.0)
                    win:render_rect(bmin, bmax, C(230, 120, 120, 255), 4.0, 1.0)
                end)
                win:render_text(FONT_SMALL, vec2.new(MINI_W / 2 - 14, 121), gold, "Stop")
                pcall(function()
                    if win:is_rect_clicked(bmin, bmax) then
                        stop = true
                    end
                end)
            end)
    end)
    if stop then
        menu:defer(mini_stop)                -- 3.0.0: the stop runs on the update tick
    elseif restore then
        menu:defer(mini_stop)
    end
    local _ = mute
end

--- Run the mini window; true when it has the screen (main window hidden).
local function mini_tick()
    local running = is_on("enable") and (gui.is_started() or is_on("rotation_only"))
    if running and not mini.was_running then
        mini.on = true
        mini.since = izi.now()
    elseif not running and mini.was_running and mini.on then
        restore_main()
    end
    mini.was_running = running
    if not mini.on then
        if mini.win and mini.shown then
            pcall(function() mini.win:set_visibility(false) end)
            mini.shown = false
        end
        return false
    end
    menu:set_visible(false)
    draw_mini()
    return true
end

function gui.draw()
    -- gui.sync_player runs from on_update (main.lua) - not again here (2.193.0).
    if mini_tick() then
        return
    end
    if not is_on("show_gui") then
        menu:set_visible(false)
        return
    end
    menu:set_visible(true)
    menu.width = 960
    menu.height = 695
    -- Once per frame, not three times: is_started walks the quest guide, the
    -- rotation registry and the player object.
    local started = gui.is_started()
    local start_btn = menu.actions[1]
    local pause_btn = menu.actions[2]
    if start_btn then
        start_btn.label = started and "Running" or "Start"
        start_btn.style = started and "neutral" or "start"
    end
    if pause_btn then
        pause_btn.label = started and "Pause" or "Paused"
    end
    dprobe("gui:menu.draw")
    local ok, err = pcall(draw_menu)
    dprobe("gui:sync_attack_level")
    gui.sync_attack_level()
    dprobe("gui:done")
    if not ok then
        core.log_error("[Master Farmer - Forever Questing] GUI draw failed: " .. tostring(err))
    end
end

set_on("show_gui", true)

return gui
