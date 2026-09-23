-- Skeleton Jail: a bolt that, when it lands, surrounds its target with weak skeletons for a few seconds. They side with
-- the caster (a Follow package on it makes the engine count them as its allies) and fight the target (a Combat package),
-- then vanish. They're created and removed by Lua rather than being engine summons, so they stay for their whole time
-- even if the caster dies, and their remaining time is kept in the save. Sometimes the caster then runs away.
local core = require('openmw.core')
local RANGE = core.magic.RANGE
local CHARACTER = require("scripts/MaxYari/MercyCAO/scripts/enums").CHARACTER_TYPE
local TimedObjects = require("scripts/MaxYari/MercyCAO/scripts/spells/timed_objects")

local CREATURE = "skeleton_weak"
local COUNT = 4
local DURATION = 6
local RADIUS = 75 -- Right around the target, about a body width away
local RUN_AWAY_CHANCE = 0.33 -- After a hit the caster goes RETREAT (retreat to friends or run off and hide); for an even
                             -- match, scaled by the caster's scaredness
local SUMMON_EVENT = "Mercy_SkeletonJail_Summon"

local spell = {
    key = "skeletonJail",
    version = 6,
    bundle = "exotic",
    minLevel = 8,
    character_type = { CHARACTER.Spellcaster },
    weight = 1,
    cooldown = 20,
    record = {
        name = "Skeleton Jail",
        type = core.magic.SPELL_TYPE.Spell,
        cost = 15,
        alwaysSucceedFlag = true,
        isAutocalc = false,
        effects = {
            -- A harmless stand-in that flies as a bolt with an area and tells the hit check the bolt landed. The skeletons
            -- are spawned by Lua on the hit. A 1 pt Swift Swim for 1 s: not harmful, since the area also touches actors
            -- next to the target and a harmful spell would count as an attack on them, and Alteration's area effect is a
            -- small glow rather than Illusion's (Light's) tall smoke cloud.
            { id = "swiftswim", range = RANGE.Target, area = 6, duration = 1, magnitudeMin = 1, magnitudeMax = 1 },
        },
    },
}

-- Caster's local script: spots evenly spread on a circle around the target, moved onto the navmesh
function spell.onHit(caster, target, state)
    local util = require('openmw.util')
    local nearby = require('openmw.nearby')
    local positions = {}
    local offset = math.random() * 2 * math.pi
    for i = 1, COUNT do
        local angle = offset + (i - 1) * 2 * math.pi / COUNT
        local point = target.position + util.vector3(math.cos(angle) * RADIUS, math.sin(angle) * RADIUS, 0)
        positions[i] = nearby.findNearestNavMeshPosition(point) or target.position
    end
    core.sendGlobalEvent(SUMMON_EVENT, { summoner = caster, target = target, positions = positions })
    state:rollRunAway(RUN_AWAY_CHANCE, "Skeleton Jail")
end

-- Global script side -----------------------------------------------------------------------------------------------
local skeletons = TimedObjects.new("vfx_summon_end")

local function summonSound()
    local effect = core.magic.effects.records["summonskeletalminion"]
    if effect and effect.hitSound and effect.hitSound ~= "" then return effect.hitSound end
    return "conjuration hit"
end

spell.global = {
    eventHandlers = {
        [SUMMON_EVENT] = function(data)
            local world = require('openmw.world')
            local types = require('openmw.types')
            local vfx = types.Static.records["vfx_summon_start"]
            local util = require('openmw.util')
            for _, position in ipairs(data.positions) do
                local creature = world.createObject(CREATURE, 1)
                -- Facing the target (yaw 0 faces +y)
                local toTarget = data.target.position - position
                local rotation = util.transform.rotateZ(math.atan2(toTarget.x, toTarget.y))
                creature:teleport(data.target.cell, position, { onGround = true, rotation = rotation })
                creature:sendEvent("StartAIPackage", { type = "Follow", target = data.summoner })
                creature:sendEvent("StartAIPackage", { type = "Combat", target = data.target, cancelOther = false })
                if vfx then creature:sendEvent("AddVfx", { model = vfx.model }) end
                skeletons:add(creature, DURATION)
            end
            core.sound.playSound3d(summonSound(), data.target)
        end,
    },
    onUpdate = function() skeletons:update() end,
    onSave = function() return skeletons:save() end,
    onLoad = function(saved) skeletons:load(saved) end,
}

return spell
