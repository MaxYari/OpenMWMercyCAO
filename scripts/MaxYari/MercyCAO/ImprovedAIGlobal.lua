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

return {
    eventHandlers = {
        HiImMercyActor = function(data)
            data.source:sendEvent("BTJsonData",projectJsonTable)
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
