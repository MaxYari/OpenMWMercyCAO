-- Objects a spell spawns for a limited time (global scripts only). Once their time is up they're removed with a visual
-- effect. The remaining time is kept in saves through save() and load(). Each spell makes its own list with new().
local core = require('openmw.core')

local TimedObjects = {}
TimedObjects.__index = TimedObjects

-- despawnVfx: id of a static whose model plays where an object is removed (optional)
-- options (optional):
--   remove    function(object) removing an object, for objects that need more than object:remove()
--   vfxScale  size of the despawn visual effect (1 by default)
function TimedObjects.new(despawnVfx, options)
    options = options or {}
    return setmetatable({ entries = {}, despawnVfx = despawnVfx, remove = options.remove, vfxScale = options.vfxScale },
        TimedObjects)
end

function TimedObjects:add(object, lifetime)
    self.entries[#self.entries + 1] = { object = object, removeAt = core.getSimulationTime() + lifetime }
end

-- Spawns a static's model as a one-off visual effect (global scripts only), optionally scaled
function TimedObjects.spawnVfx(staticId, position, scale)
    local types = require('openmw.types')
    local record = staticId and types.Static.records[staticId]
    if record then require('openmw.world').vfx.spawn(record.model, position, { scale = scale or 1 }) end
end

function TimedObjects:update()
    local entries = self.entries
    if #entries == 0 then return end
    local now = core.getSimulationTime()
    for i = #entries, 1, -1 do
        local entry = entries[i]
        if now >= entry.removeAt then
            table.remove(entries, i)
            local object = entry.object
            if object:isValid() and object.count > 0 then
                if object.cell then TimedObjects.spawnVfx(self.despawnVfx, object.position, self.vfxScale) end
                if self.remove then self.remove(object) else object:remove() end
            end
        end
    end
end

function TimedObjects:save()
    local now = core.getSimulationTime()
    local saved = {}
    for _, entry in ipairs(self.entries) do
        saved[#saved + 1] = { object = entry.object, timeLeft = math.max(0, entry.removeAt - now) }
    end
    return saved
end

function TimedObjects:load(saved)
    local now = core.getSimulationTime()
    self.entries = {}
    for _, entry in ipairs(saved or {}) do
        self.entries[#self.entries + 1] = { object = entry.object, removeAt = now + entry.timeLeft }
    end
end

return TimedObjects
