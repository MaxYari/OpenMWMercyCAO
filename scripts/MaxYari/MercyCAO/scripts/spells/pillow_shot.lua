-- Pillow Invocation: the caster conjures a spray of pillows and flings them at its target, like a shotgun. The pillows are
-- Lua Physics objects, so the spell is only available with Lua Physics installed. A pillow hitting the target deals
-- physical (ranged) damage, reduced by armor, which staggers like any hit; the whole shot deals at most SHOT_MAX_DAMAGE
-- (a Daedric Claymore's best chop). Only the target is hurt, so the pillows can't start fights with bystanders. The
-- pillows lie around for a few seconds, then vanish.
local core = require('openmw.core')
local RANGE = core.magic.RANGE
local CHARACTER = require("scripts/MaxYari/MercyCAO/scripts/enums").CHARACTER_TYPE
local TimedObjects = require("scripts/MaxYari/MercyCAO/scripts/spells/timed_objects")

local PILLOW_TEMPLATE = "misc_uni_pillow_01"
local PILLOW_NAME = "Conjured Pillow"
local PILLOW_COUNT = 8
local SHOT_MAX_DAMAGE = 60
local PILLOW_DAMAGE = SHOT_MAX_DAMAGE / 5 -- Each pillow that hits deals this (before armor)
local LAUNCH_SPEED = 1050
local MIN_HIT_SPEED = LAUNCH_SPEED * 0.15 -- Slower pillows (rolling, bouncing around) don't hurt
local SPREAD = 0.21 -- Random deviation of each pillow's velocity, as a share of its speed
local SPAWN_AHEAD = 70 -- Pillows appear this far in front of the caster's torso...
local SPAWN_SCATTER = 20 -- ...scattered up to this far from that point
local GRAVITY = 9.8 * 69.99 -- The same as Lua Physics
local LIFETIME = 5
local DESPAWN_VFX_SCALE = 0.66
local LAUNCH_DELAY_FRAMES = 2 -- Let a new pillow's physics script start before it's launched
local SPAWN_EVENT = "Mercy_PillowShot_Spawn"
local HIT_EVENT = "Mercy_PillowShot_Hit"

local spell = {
    key = "pillowShot",
    version = 2,
    bundle = "exotic",
    minLevel = 10,
    character_type = { CHARACTER.Spellcaster },
    playerTargetOnly = true,
    weight = 1,
    cooldown = 3,
    available = function() return core.contentFiles.has("LuaPhysicsEngine.omwscripts") end,
    record = {
        name = "Pillow Invocation",
        type = core.magic.SPELL_TYPE.Spell,
        cost = 25,
        alwaysSucceedFlag = true,
        isAutocalc = false,
        effects = {
            -- A harmless stand-in, so the engine plays a normal self cast. The pillows are spawned by Lua on release.
            { id = "detectanimal", range = RANGE.Self, area = 0, duration = 1, magnitudeMin = 1, magnitudeMax = 1 },
        },
    },
}

-- Caster's local script: pillow spawn spots in front of the caster and velocities that carry them to the target's
-- centre along a ballistic arc, each a bit off
function spell.onCast(caster, target, state)
    local util = require('openmw.util')
    local types = require('openmw.types')
    local casterHalfExtents = types.Actor.getPathfindingAgentBounds(caster).halfExtents
    local targetHalfExtents = types.Actor.getPathfindingAgentBounds(target).halfExtents
    local from = caster.position + util.vector3(0, 0, casterHalfExtents.z * 2 * 0.75)
    local aimAt = target.position + util.vector3(0, 0, targetHalfExtents.z)
    local origin = from + (aimAt - from):normalize() * SPAWN_AHEAD

    local function randomInUnitSphere()
        while true do
            local v = util.vector3(math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1)
            if v:length() <= 1 then return v end
        end
    end

    local pillows = {}
    for i = 1, PILLOW_COUNT do
        local position = origin + randomInUnitSphere() * SPAWN_SCATTER
        local toTarget = aimAt - position
        local time = toTarget:length() / LAUNCH_SPEED
        local velocity = toTarget / time + util.vector3(0, 0, 0.5 * GRAVITY * time)
        velocity = velocity + randomInUnitSphere() * (velocity:length() * SPREAD)
        pillows[i] = { position = position, velocity = velocity }
    end
    core.sendGlobalEvent(SPAWN_EVENT, { caster = caster, target = target, pillows = pillows })
end

-- Any actor's local script (NPCs and the player): a pillow bumped into this actor, let the global script judge the hit
spell.targetEventHandlers = {
    LuaPhysics_CollidingWithPhysObj = function(data)
        local other = data.other
        local pillow = other and other.object
        if not pillow or not pillow:isValid() then return end
        local types = require('openmw.types')
        if not types.Miscellaneous.objectIsInstance(pillow) or types.Miscellaneous.record(pillow).name ~= PILLOW_NAME then
            return
        end
        core.sendGlobalEvent(HIT_EVENT, {
            pillow = pillow,
            target = require('openmw.self').object,
            speed = other.velocity and other.velocity:length() or 0,
        })
    end,
}

-- Global script side -----------------------------------------------------------------------------------------------
local pillowRecordId = nil -- Created once per game (records are saved with the game)
local shotsByPillow = {} -- Pillow object id -> its shot: { caster, target, dealt, hitPillows }
local launches = {} -- Pillows waiting for their physics script: { object, velocity, caster, framesLeft }

local function removePillow(object)
    shotsByPillow[object.id] = nil
    core.sendGlobalEvent("LuaPhysics_RemoveObject", { object = object })
end
local spawned = TimedObjects.new("vfx_summon_end", { remove = removePillow, vfxScale = DESPAWN_VFX_SCALE })

local function pillowRecord()
    local types = require('openmw.types')
    if pillowRecordId and types.Miscellaneous.records[pillowRecordId] then return pillowRecordId end
    local world = require('openmw.world')
    local draft = types.Miscellaneous.createRecordDraft({
        template = types.Miscellaneous.records[PILLOW_TEMPLATE],
        name = PILLOW_NAME,
        value = 0,
    })
    pillowRecordId = world.createRecord(draft).id
    return pillowRecordId
end

local function log(...)
    require("scripts/MaxYari/MercyCAO/scripts/magic_util").log(spell.key, ...)
end

spell.global = {
    eventHandlers = {
        [SPAWN_EVENT] = function(data)
            local world = require('openmw.world')
            local util = require('openmw.util')
            local recordId = pillowRecord()
            local shot = { caster = data.caster, target = data.target, dealt = 0, hitPillows = {} }
            for _, pillow in ipairs(data.pillows) do
                local object = world.createObject(recordId, 1)
                local rotation = util.transform.rotateZ(math.random() * 2 * math.pi) * util.transform.rotateX(math.random() * math.pi)
                object:teleport(data.caster.cell, pillow.position, { rotation = rotation })
                shotsByPillow[object.id] = shot
                launches[#launches + 1] = { object = object, velocity = pillow.velocity, caster = data.caster,
                    framesLeft = LAUNCH_DELAY_FRAMES }
                spawned:add(object, LIFETIME)
            end
            TimedObjects.spawnVfx("vfx_summon_start", data.pillows[1].position)
            core.sound.playSound3d("conjuration hit", data.caster)
        end,

        [HIT_EVENT] = function(data)
            local shot = shotsByPillow[data.pillow.id]
            if not shot or shot.hitPillows[data.pillow.id] or data.target ~= shot.target then return end
            if data.speed < MIN_HIT_SPEED then return end
            shot.hitPillows[data.pillow.id] = true
            local damage = math.min(PILLOW_DAMAGE, SHOT_MAX_DAMAGE - shot.dealt)
            if damage <= 0 then
                log("pillow hit", data.target.recordId, "- the shot already dealt its", SHOT_MAX_DAMAGE, "damage")
                return
            end
            shot.dealt = shot.dealt + damage
            log("pillow hit", data.target.recordId, "at speed", math.floor(data.speed), "for", damage,
                "damage before armor, shot total", shot.dealt)
            data.target:sendEvent("Hit", {
                attacker = shot.caster:isValid() and shot.caster or nil,
                successful = true,
                sourceType = "ranged",
                strength = 1,
                damage = { health = damage },
            })
        end,
    },

    onUpdate = function()
        spawned:update()
        if #launches == 0 then return end
        local util = require('openmw.util')
        for i = #launches, 1, -1 do
            local launch = launches[i]
            launch.framesLeft = launch.framesLeft - 1
            if launch.framesLeft <= 0 then
                table.remove(launches, i)
                if launch.object:isValid() and launch.object.count > 0 then
                    -- Setting the velocity directly doesn't depend on the pillow's mass; the zero impulse wakes it up
                    -- and names the caster as the one who threw it
                    launch.object:sendEvent("LuaPhysics_SetPhysicsProperties", {
                        velocity = launch.velocity,
                        ignorePhysObjectCollisions = true,
                    })
                    launch.object:sendEvent("LuaPhysics_ApplyImpulse", {
                        impulse = util.vector3(0, 0, 0),
                        culprit = launch.caster,
                    })
                end
            end
        end
    end,

    onSave = function() return { pillows = spawned:save(), pillowRecordId = pillowRecordId } end,
    onLoad = function(saved)
        saved = saved or {}
        spawned:load(saved.pillows)
        pillowRecordId = saved.pillowRecordId
    end,
}

return spell
