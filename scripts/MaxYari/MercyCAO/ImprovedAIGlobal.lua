mp = "scripts/MaxYari/MercyCAO/"

local gutils = require(mp .. "scripts/gutils")
local json = require(mp .. "libs/json")
local magicUtil = require(mp .. "scripts/magic_util")
local manaPotions = require(mp .. "scripts/mana_potions")

local core = require("openmw.core")
local types = require("openmw.types")
local vfs = require('openmw.vfs')
local markup = require("openmw.markup")
local world = require("openmw.world")

DebugLevel = 1

if core.API_REVISION < 64 then return end

-- Parsing JSON behaviourtree -----
gutils.print("Global: Reading Behavior3 project", 1)
-- Read the behaviour tree JSON file exported from the editor---------------
local file = vfs.open(mp .. "OpenMW AI.b3")
if not file then error("Failed opening behaviour tree file.") end
-- Decode it
local b3projectJson = json.decode(file:read("*a"))
-- And close it
file:close()
----------------------------------------------------------------------------

-- Loading the blacklist yaml files from configs folder -----
local function loadBlacklists()
    local mergedBlacklist = {
        full_disable = { recordIds = {}, cellIds = {} },
        surrender_disable = { recordIds = {}, cellIds = {} },
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
-- Their generated ids are kept in this script's save data.
local customSpells = {}        -- key -> spell record id
local customSpellVersions = {} -- key -> version of the definition the record was created from

local function ensureCustomSpells()
    for key, definition in pairs(magicUtil.CUSTOM_SPELLS) do
        local id = customSpells[key]
        if not id or not core.magic.spells.records[id] or customSpellVersions[key] ~= definition.version then
            local record = world.createRecord(core.magic.spells.createRecordDraft(definition.record))
            customSpells[key] = record.id
            customSpellVersions[key] = definition.version
            magicUtil.log("Created custom spell", key, "version", definition.version, record.id)
        end
    end
end

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


local pendingActors = {}

local function onUpdate()
    for i = 1, #spellUpdates do spellUpdates[i]() end

    -- Send one actor event per frame. Hopefully distributing the workload and removing the stutter.
    if #pendingActors > 0 then
        ensureCustomSpells()
        local actor = table.remove(pendingActors)
        actor:sendEvent("Mercy_StartupData",{
            b3projectJson = b3projectJson,
            blacklist = blacklist,
            customSpells = customSpells,
        })
    end
end

local eventHandlers = {
        HiImMercyActor = function(data)
            table.insert(pendingActors,data.source)
        end,
        dumpInventory = function(data)
            -- data.actor, data.position
            local actor = gutils.Actor:new(data.actorObject)
            local items = actor:getDumpableInventoryItems(blacklist.item_dump_disable.recordIdsMap)
            for _, item in pairs(items) do
                item:teleport(data.actorObject.cell, data.position, { onGround = true })
                item.owner.factionId = nil
                item.owner.recordId = nil
                ::continue::
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
