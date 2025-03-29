mp = "scripts/MaxYari/MercyCAO/"

local gutils = require(mp .. "scripts/gutils")
local json = require(mp .. "libs/json")

local core = require("openmw.core")
local types = require("openmw.types")
local vfs = require('openmw.vfs')

DebugLevel = 1

if core.API_REVISION < 64 then return end

-- Parsing JSON behaviourtree -----
gutils.print("Global: Reading Behavior3 project", 1)
-- Read the behaviour tree JSON file exported from the editor---------------
local file = vfs.open("scripts/MaxYari/MercyCAO/OpenMW AI.b3")
if not file then error("Failed opening behaviour tree file.") end
-- Decode it
local projectJsonTable = json.decode(file:read("*a"))
-- And close it
file:close()
----------------------------------------------------------------------------


local pendingActors = {}

local function onUpdate() 
    -- Send one actor event per frame. Hopefully distributing the workload and removing the stutter.
    if #pendingActors > 0 then
        local actor = table.remove(pendingActors)
        actor:sendEvent("BTJsonData",projectJsonTable)
    end
end

return {
    engineHandlers = {
        onUpdate = onUpdate,
    },
    eventHandlers = {
        HiImMercyActor = function(data)
            table.insert(pendingActors,data.source)
        end,
        dumpInventory = function(data)
            -- data.actor, data.position
            local actor = gutils.Actor:new(data.actorObject)
            local items = actor:getDumpableInventoryItems()
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
    },
}
