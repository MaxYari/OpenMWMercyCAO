-- Box Prison (not in use: not listed in spells/init.lua, Skeleton Jail took its place): a bolt that, when it lands, closes
-- its target in a ring of crates for a while. The crates are low enough to
-- jump over. Sometimes the caster then runs away, leaving the target stuck.
local core = require('openmw.core')
local RANGE = core.magic.RANGE
local CHARACTER = require("scripts/MaxYari/MercyCAO/scripts/enums").CHARACTER_TYPE
local TimedObjects = require("scripts/MaxYari/MercyCAO/scripts/spells/timed_objects")

-- Closed crates look like containers, but containers can be looted: the crates are statics made with a container's model
local CRATE_MODEL_FROM = "crate_01" -- A container using o\Contain_crate_01.nif: a 64 unit cube, origin at its centre
local CRATE_HALF_SIZE = 32
local COUNT = 5
local DURATION = 10
local CORNER_OVERLAP = 0.95 -- Neighbouring crates overlap a little at their inner corners, leaving no gap
local RUN_AWAY_CHANCE = 0.33 -- After a hit the caster goes RETREAT (retreat to friends or run off and hide); for an even
                             -- match, scaled by the caster's scaredness
local SPAWN_EVENT = "Mercy_BoxPrison_Spawn"

local spell = {
    key = "boxPrison",
    version = 3,
    bundle = "exotic",
    minLevel = 8,
    character_type = { CHARACTER.Spellcaster },
    weight = 1,
    cooldown = 60,
    record = {
        name = "Box Prison",
        type = core.magic.SPELL_TYPE.Spell,
        cost = 25,
        alwaysSucceedFlag = true,
        isAutocalc = false,
        effects = {
            -- A harmless stand-in that flies as a mysticism bolt and tells the hit check the bolt landed. The crates are
            -- spawned by Lua on the hit. Unreflectable, so a reflect can't turn it on the caster. (Not Turn Undead: the
            -- engine drops it on anything but undead creatures, so it never lands on the player.)
            { id = "soultrap", range = RANGE.Target, area = 6, duration = 1, magnitudeMin = 1, magnitudeMax = 1 },
        },
    },
}

-- Caster's local script: a ring of COUNT crates around the target, facing its centre, standing on the ground. Square
-- crates on a ring touch at their inner corners when their inner faces are halfSize / tan(pi / COUNT) from the centre.
function spell.onHit(caster, target, state)
    local util = require('openmw.util')
    local nearby = require('openmw.nearby')
    local types = require('openmw.types')
    local halfExtents = types.Actor.getPathfindingAgentBounds(target).halfExtents
    local radius = CORNER_OVERLAP * CRATE_HALF_SIZE / math.tan(math.pi / COUNT) + CRATE_HALF_SIZE

    local center = target.position
    local offset = math.random() * 2 * math.pi
    local crates = {}
    for i = 1, COUNT do
        local angle = offset + (i - 1) * 2 * math.pi / COUNT
        local spot = center + util.vector3(math.cos(angle) * radius, math.sin(angle) * radius, 0)
        local ray = nearby.castRay(spot + util.vector3(0, 0, halfExtents.z * 2), spot - util.vector3(0, 0, 200), {
            collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap,
            ignore = target,
        })
        if ray.hit then spot = ray.hitPos end
        crates[i] = { position = spot + util.vector3(0, 0, CRATE_HALF_SIZE), yaw = angle }
    end
    core.sendGlobalEvent(SPAWN_EVENT, { target = target, crates = crates })

    state:rollRunAway(RUN_AWAY_CHANCE, "Box Prison")
end

-- Global script side -----------------------------------------------------------------------------------------------
local spawned = TimedObjects.new("vfx_summon_end")
local crateRecordId = nil -- The crate static, created once per game (records are saved with the game)

local function crateRecord()
    local types = require('openmw.types')
    if crateRecordId and types.Static.records[crateRecordId] then return crateRecordId end
    local world = require('openmw.world')
    local container = types.Container.records[CRATE_MODEL_FROM]
    local record = world.createRecord(types.Static.createRecordDraft({ model = container.model }))
    crateRecordId = record.id
    return crateRecordId
end

spell.global = {
    eventHandlers = {
        [SPAWN_EVENT] = function(data)
            local world = require('openmw.world')
            local util = require('openmw.util')
            local recordId = crateRecord()
            for _, crate in ipairs(data.crates) do
                local object = world.createObject(recordId, 1)
                object:teleport(data.target.cell, crate.position, { rotation = util.transform.rotateZ(crate.yaw) })
                TimedObjects.spawnVfx("vfx_summon_start", crate.position)
                spawned:add(object, DURATION)
            end
            core.sound.playSound3d("conjuration hit", data.target)
        end,
    },
    onUpdate = function() spawned:update() end,
    onSave = function() return { crates = spawned:save(), crateRecordId = crateRecordId } end,
    onLoad = function(saved)
        saved = saved or {}
        spawned:load(saved.crates)
        crateRecordId = saved.crateRecordId
    end,
}

return spell
