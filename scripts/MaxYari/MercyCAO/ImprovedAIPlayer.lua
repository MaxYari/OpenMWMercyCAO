mp = "scripts/MaxYari/MercyCAO/"

local core = require("openmw.core")
local ui = require("openmw.ui")
local nearby = require("openmw.nearby")
local omwself = require("openmw.self")
local selfObject = omwself.object
local types = require("openmw.types")

local gutils = require(mp .. "scripts/gutils")
local selfActor = gutils.Actor:new(omwself)

DebugLevel = 2

if core.API_REVISION < 64 then
    return ui.showMessage("Mercy: CAO requiers a newer version of OpenMW, please update.")
end

gutils.print("Hi! Mercy: CAO BETA is now E-N-G-A-G-E-D", 0)

-- Max Yari's Script Services (MSS) is a required dependency: checked once, when this script loads.
if not core.contentFiles.has("MaxYariScriptServices.omwscripts") then
    print("[Mercy: CAO] ERROR: critical dependency is missing: Max Yari's Script Services (MSS). Please install it.")
    ui.showMessage("Mercy: CAO: Critical dependency is missing, please install Max Yari's Script Services (MSS)")
end

local actorI = 1
local actors = nil

local function onUpdate(dt)
    
    local use = omwself.controls.use

    if not actors then
        actors = nearby.actors 
        actorI = 1
    end
    local actor = actors[actorI]
    if actor then
        if actor.type == types.NPC then
            actor:sendEvent('PlayerUse', { source = selfObject, use = use })
        end
        actorI = actorI + 1
    else
        actors = nil
    end

    -- Some experimental stuff
    -- local Attribute = {}
    -- for i, attribute in pairs(core.stats.Attribute.records) do
    --     Attribute[attribute.name] = attribute
    -- end
    -- if omwself.controls.use > 0 then
    --     types.Actor.activeEffects(omwself):set(100,core.magic.EFFECT_TYPE.FortifyAttribute, "speed")
    -- else
    --     types.Actor.activeEffects(omwself):set(0,core.magic.EFFECT_TYPE.FortifyAttribute, "speed")
    -- end
end

-- Testing: the "luamercy" console command gives Mercy's custom spells to an NPC. Console commands starting with "lua"
-- are passed to Lua scripts instead of the game's own console.
--   luamercy blink boxPrison   with an NPC selected: that NPC learns exactly these spells right away
--   luamercy blink boxPrison   with nothing selected: the next spellcaster nearby to start a fight learns them
local CONSOLE_COMMAND = "luamercy"

local function printToConsole(text, color)
    ui.printToConsole(text, color or ui.CONSOLE_COLOR.Info)
end

local function sendToNearbyNpcs(eventName, data)
    for _, actor in ipairs(nearby.actors) do
        if actor.type == types.NPC then actor:sendEvent(eventName, data) end
    end
end

local function onConsoleCommand(mode, command, selectedObject)
    if mode ~= "" then return end
    local words = {}
    for word in command:gmatch("%S+") do words[#words + 1] = word end
    if not words[1] or words[1]:lower() ~= CONSOLE_COMMAND then return end

    local spellKeys = {}
    for _, spell in ipairs(require(mp .. "scripts/spells/init")) do spellKeys[spell.key:lower()] = spell.key end
    local keys = {}
    for i = 2, #words do
        local key = spellKeys[words[i]:lower():gsub(",", "")]
        if not key then
            printToConsole("Mercy: unknown spell '" .. words[i] .. "'", ui.CONSOLE_COLOR.Error)
            keys = nil
            break
        end
        keys[#keys + 1] = key
    end
    if not keys or #keys == 0 then
        local names = {}
        for _, key in pairs(spellKeys) do names[#names + 1] = key end
        table.sort(names)
        printToConsole("Usage: " .. CONSOLE_COMMAND .. " <spells>. Select an NPC first to give the spells to it, or select " ..
            "nothing to give them to the next spellcaster that starts a fight. Spells: " .. table.concat(names, ", "))
        return
    end

    local request = { keys = keys, player = selfObject }
    if selectedObject and selectedObject.type == types.NPC then
        selectedObject:sendEvent("Mercy_ConsoleSpells", request)
        printToConsole("Mercy: giving " .. table.concat(keys, ", ") .. " to " .. selectedObject.recordId)
    else
        request.next = true
        sendToNearbyNpcs("Mercy_ConsoleSpells", request)
        printToConsole("Mercy: the next spellcaster nearby to start a fight learns " .. table.concat(keys, ", "))
    end
end

local eventHandlers = {
    Mercy_ConsoleSpellsLearned = function(e)
        -- Only one actor takes a 'next' request
        if e.next then sendToNearbyNpcs("Mercy_ConsoleSpells", { cancel = true }) end
        printToConsole(e.text, ui.CONSOLE_COLOR.Success)
        ui.showMessage(e.text)
    end,
}
-- Custom spells' own event handlers for the player as a possible target, and their per-frame player work, from their
-- files in scripts/spells
local spellPlayerFrames = {}
for _, spell in ipairs(require(mp .. "scripts/spells/init")) do
    for name, handler in pairs(spell.targetEventHandlers or {}) do
        eventHandlers[name] = handler
    end
    if spell.playerFrame then spellPlayerFrames[#spellPlayerFrames + 1] = spell.playerFrame end
end

local function onFrame(dt)
    for i = 1, #spellPlayerFrames do spellPlayerFrames[i](dt) end
end

return {
    engineHandlers = {
        onUpdate = onUpdate,
        onConsoleCommand = onConsoleCommand,
        onFrame = onFrame,
    },
    eventHandlers = eventHandlers,
}
