mp = "scripts/MaxYari/MercyCAO/"

-- OpenMW version check: Mercy needs OpenMW 0.51 (Lua API revision 129) or newer. Checked before anything else loads, the
-- player script tells the user.
local core = require("openmw.core")
if core.API_REVISION < 129 then return end

local gutils = require(mp .. "scripts/gutils")
local json = require(mp .. "libs/json")
local magicUtil = require(mp .. "scripts/magic_util")
local manaPotions = require(mp .. "scripts/mana_potions")

local types = require("openmw.types")
local I = require("openmw.interfaces")
local vfs = require('openmw.vfs')
local markup = require("openmw.markup")
local world = require("openmw.world")

DebugLevel = gutils.debugLevel()

-- Parsing JSON behaviourtree -----
gutils.print("Global: Reading Behavior3 project", 1)
-- The project is serialized and rebuilt for every NPC Mercy starts on, so only what the tree builder reads
-- (behavior3_parser.lua) is kept. The editor's own data - node descriptions, node positions on its canvas, its custom
-- node definitions - is over a third of the file.
local function stripEditorData(project)
    local trees = {}
    for i, tree in ipairs((project.data or project).trees) do
        local nodes = {}
        for id, node in pairs(tree.nodes) do
            nodes[id] = { name = node.name, title = node.title, properties = node.properties, child = node.child,
                children = node.children, isStealthy = node.isStealthy }
        end
        trees[i] = { id = tree.id, title = tree.title, root = tree.root, nodes = nodes }
    end
    return { data = { trees = trees } }
end
-- Read the behaviour tree JSON file exported from the editor---------------
local file = vfs.open(mp .. "OpenMW AI.b3")
if not file then error("Failed opening behaviour tree file.") end
-- Decode it
local b3projectJson = stripEditorData(json.decode(file:read("*a")))
-- And close it
file:close()
----------------------------------------------------------------------------

-- Loading the blacklist yaml files from configs folder -----
local function loadBlacklists()
    local mergedBlacklist = {
        full_disable = { recordIds = {}, cellIds = {} },
        surrender_disable = { recordIds = {}, cellIds = {} },
        -- Actors/cells where Mercy's NPCs never say Mercy's voice lines
        voice_disable = { recordIds = {}, cellIds = {} },
        -- Item record ids that are never dropped on the ground during surrender (cellIds unused)
        item_dump_disable = { recordIds = {}, cellIds = {} }
    }

    -- Helper to merge list entries from a section
    local function mergeSection(source, target)
        if source.recordIds then
            for _, id in ipairs(source.recordIds) do
                table.insert(target.recordIds, id)
            end
        end
        if source.cellIds then
            for _, id in ipairs(source.cellIds) do
                table.insert(target.cellIds, id)
            end
        end
    end

    -- Collect all YAML files from configs folder
    for configPath in vfs.pathsWithPrefix(mp .. "configs/") do
        -- Check if it's a yaml file
        if configPath:match("%.yaml$") then
            local blacklistData = markup.loadYaml(configPath)
            if blacklistData then
                for key, target in pairs(mergedBlacklist) do
                    if blacklistData[key] then mergeSection(blacklistData[key], target) end
                end
            end
        end
    end

    -- Convert lists to maps for O(1) lookup performance
    local function listToMap(list, lowercase)
        local map = {}
        for _, id in ipairs(list) do
            if lowercase then id = string.lower(id) end
            map[id] = true
        end
        return map
    end

    local processedBlacklist = {}
    for key, section in pairs(mergedBlacklist) do
        processedBlacklist[key] = {
            -- Lua always reports record ids in lowercase, yaml entries may be typed in any case
            recordIdsMap = listToMap(section.recordIds, true),
            cellIdsMap = listToMap(section.cellIds)
        }
    end

    return processedBlacklist
end

blacklist = loadBlacklists()
-----------------------------------------------------------------------------


-- Mercy's custom spells ----------------------------------------------------
-- Records are created once per game and saved with it, and again when a definition's version changes.
-- Their generated ids are kept in this script's save data. A 'recordId' spell just maps to that existing record.
local customSpells = {}        -- key -> spell record id
local customSpellVersions = {} -- key -> version of the definition the record was created from

-- Mercy's spells are Mercy's to cast: OSSC (Oblivion-Style Spell Casting) is told never to pick them for its own
-- quick-casts. Its filter is global, saved with the game and broadcast to every caster it manages, and an explicit
-- castSpellAtTarget still works - which is exactly how Mercy casts them when OSSC is installed. Not another mod's record
-- cast through 'recordId': NPCs that know it on their own keep casting it through OSSC.
local osscIgnored = {}
local function ignoreInOSSC()
    local osscCasters = I.OSSC_Casters
    if not osscCasters or type(osscCasters.ignoreSpell) ~= "function" then return end
    for key, definition in pairs(magicUtil.CUSTOM_SPELLS) do
        local id = not definition.recordId and customSpells[key] or nil
        if osscIgnored[key] ~= id then
            if id then osscCasters.ignoreSpell(id) end
            -- The record is recreated when a definition's version changes, so the old id can go back to OSSC
            if osscIgnored[key] and osscCasters.unignoreSpell then osscCasters.unignoreSpell(osscIgnored[key]) end
            osscIgnored[key] = id
            magicUtil.log("OSSC told to ignore", key, id)
        end
    end
end

-- Only for the spells usable in this game (magicUtil.CUSTOM_SPELLS): one whose mod isn't installed never gets a record,
-- which couldn't be made anyway with an effect that doesn't exist. Ids of spells left out stay in the save, in case
-- their mod comes back.
local BORROWED = "borrowed" -- In customSpellVersions: a 'recordId' spell, so switching it back to a 'record' creates one
local function ensureCustomSpells()
    for key, definition in pairs(magicUtil.CUSTOM_SPELLS) do
        local id = customSpells[key]
        if definition.recordId then
            customSpells[key] = core.magic.spells.records[definition.recordId].id
            customSpellVersions[key] = BORROWED
        elseif not id or not core.magic.spells.records[id] or customSpellVersions[key] ~= definition.version then
            local record = world.createRecord(core.magic.spells.createRecordDraft(definition.record))
            customSpells[key] = record.id
            customSpellVersions[key] = definition.version
            magicUtil.log("Created custom spell", key, "version", definition.version, record.id)
        end
    end
    ignoreInOSSC()
end

-- What actors get: the usable spells only
local function usableCustomSpells()
    local usable = {}
    for key in pairs(magicUtil.CUSTOM_SPELLS) do usable[key] = customSpells[key] end
    return usable
end

for _, skipped in ipairs(magicUtil.SKIPPED_SPELLS) do
    gutils.print("Mercy: custom spell file " .. skipped.file .. " isn't used: " .. skipped.reason, 0)
end

-- Every custom spell needs a branch in the tree's Spells subtree to be cast. Mercy's own are placed in the editor; the
-- others (e.g. other mods' spells) get one here, made from the spell's 'cast' (see scripts/spells/init.lua), before the
-- project is sent to any actor. It's the same as a placed one: a PeriodicCondition (its timer kept by its title) over a
-- CastSpell, added to the subtree's root with the rest.
local DEFAULT_CAST_CONDITION = "$range < 2000 and $:enemyInLineOfSight()"
local DEFAULT_CAST_PERIOD = { 4, 7 }
local function addSpellBranches(project)
    local spellsTree = nil
    for _, tree in pairs((project.data or project).trees) do
        if tree.title == "Spells" then spellsTree = tree end
    end
    local root = spellsTree and spellsTree.nodes[spellsTree.root]
    if not (root and root.children) then
        gutils.print("Mercy: the behaviour tree has no Spells subtree to add custom spell branches to", 0)
        return
    end
    local placed = {}
    for _, node in pairs(spellsTree.nodes) do
        if node.name == "CastSpell" and node.properties and node.properties.customSpell then
            placed[node.properties.customSpell] = true
        end
    end
    local keys = {}
    for key in pairs(magicUtil.CUSTOM_SPELLS) do
        if not placed[key] then keys[#keys + 1] = key end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local cast = magicUtil.CUSTOM_SPELLS[key].cast or {}
        local period = cast.period or DEFAULT_CAST_PERIOD
        local conditionId, castId = "mercy-spell-" .. key, "mercy-spell-cast-" .. key
        spellsTree.nodes[conditionId] = {
            id = conditionId,
            name = "PeriodicCondition",
            title = "Custom Spell " .. key,
            properties = {
                period = string.format("$r(%s,%s)", period[1], period[2]),
                condition = string.format('$:canCastCustom("%s") and (%s)', key,
                    cast.condition or DEFAULT_CAST_CONDITION),
            },
            child = castId,
        }
        spellsTree.nodes[castId] = {
            id = castId,
            name = "CastSpell",
            title = "Cast " .. key,
            properties = { customSpell = key, aim = tostring(cast.aim ~= false) },
        }
        root.children[#root.children + 1] = conditionId
        magicUtil.log("Added a tree branch for custom spell", key)
    end
end
addSpellBranches(b3projectJson)

-- Custom spells' own global side (event handlers, updates, save data), from their files in scripts/spells
local spellUpdates = {}
local spellEventHandlers = {}
for _, spell in pairs(magicUtil.CUSTOM_SPELLS) do
    if spell.global then
        if spell.global.onUpdate then spellUpdates[#spellUpdates + 1] = spell.global.onUpdate end
        for name, handler in pairs(spell.global.eventHandlers or {}) do spellEventHandlers[name] = handler end
    end
end
-----------------------------------------------------------------------------


-- Startup data for NPCs ----------------------------------------------------
-- NPCs ask for it when they enter the scene (HiImMercyActor) and build their trees from it over a few frames. It's
-- handed out to one NPC at a time, the nearest to the player first, so a town full of NPCs starts without stalling the
-- game. An NPC leaving the scene drops its own request (Mercy_StartupRelease), nothing here walks the actors around.
local pendingActors = {} -- actor id -> actor, waiting for their startup data
-- The NPC building its trees from the data it was sent last, until it says it's done or the timeout passes
local buildingActor = nil
local buildingSince = 0
-- Seconds the next NPC waits for the one building. After that it gets its data anyway, and the slow one keeps building.
local BUILD_TIMEOUT = 1

local function sendStartupData(actor)
    ensureCustomSpells()
    actor:sendEvent("Mercy_StartupData", {
        b3projectJson = b3projectJson,
        blacklist = blacklist,
        customSpells = usableCustomSpells(),
    })
end

local function nearestPendingActor()
    local player = world.players[1]
    if not player then return nil end
    local playerPos = player.position
    local nearest, nearestDist = nil, math.huge
    for id, actor in pairs(pendingActors) do
        if not actor:isValid() then
            pendingActors[id] = nil
        else
            local dist = (actor.position - playerPos):length2()
            if dist < nearestDist then nearest, nearestDist = actor, dist end
        end
    end
    return nearest
end

local function onUpdate()
    for i = 1, #spellUpdates do spellUpdates[i]() end

    if next(pendingActors) == nil then return end
    local now = core.getSimulationTime()
    if buildingActor and now - buildingSince < BUILD_TIMEOUT then return end
    buildingActor = nearestPendingActor()
    if buildingActor then
        pendingActors[buildingActor.id] = nil
        buildingSince = now
        sendStartupData(buildingActor)
    end
end

local eventHandlers = {
        HiImMercyActor = function(data)
            pendingActors[data.source.id] = data.source
        end,
        -- An NPC done building, or out of the scene: forget its request, and free the slot if it held it
        Mercy_StartupRelease = function(data)
            pendingActors[data.source.id] = nil
            if buildingActor and buildingActor.id == data.source.id then buildingActor = nil end
        end,
        dumpInventory = function(data)
            -- data.actor, data.position
            local actor = gutils.Actor:new(data.actorObject)
            local items = actor:getDumpableInventoryItems(blacklist.item_dump_disable.recordIdsMap)
            for _, item in pairs(items) do
                item:teleport(data.actorObject.cell, data.position, { onGround = true })
                item.owner.factionId = nil
                item.owner.recordId = nil
            end
        end,
        openTheDoor = function(data)
            local actor = gutils.Actor:new(data.actorObject)
            if actor:canOpenDoor(data.doorObject) then
                types.Door.activateDoor(data.doorObject, true)
            end
        end
}
for name, handler in pairs(spellEventHandlers) do eventHandlers[name] = handler end
for name, handler in pairs(manaPotions.globalEventHandlers) do eventHandlers[name] = handler end

return {
    engineHandlers = {
        onUpdate = onUpdate,
        onSave = function()
            local spellData = {}
            for key, spell in pairs(magicUtil.CUSTOM_SPELLS) do
                if spell.global and spell.global.onSave then spellData[key] = spell.global.onSave() end
            end
            return { customSpells = customSpells, customSpellVersions = customSpellVersions, spellData = spellData }
        end,
        onLoad = function(data)
            customSpells = (data and data.customSpells) or {}
            customSpellVersions = (data and data.customSpellVersions) or {}
            local spellData = (data and data.spellData) or {}
            for key, spell in pairs(magicUtil.CUSTOM_SPELLS) do
                if spell.global and spell.global.onLoad then spell.global.onLoad(spellData[key]) end
            end
        end,
    },
    eventHandlers = eventHandlers,
}
