-- Blink: a bolt that, when it lands, teleports its target as far as it can find, up to MAX_DISTANCE away: the furthest
-- of ATTEMPTS random spots that's reachable on foot from where the target stood, without going through doors. If the caster loses sight of the target, it goes hiding.
local core = require('openmw.core')
local RANGE = core.magic.RANGE
local CHARACTER = require("scripts/MaxYari/MercyCAO/scripts/enums").CHARACTER_TYPE

local MAX_DISTANCE = 4000
local ATTEMPTS = 25
local HIDE_BASE_CHANCE = 1 -- Chance to go hiding with the target out of sight, scaled by the Hide Modifier setting
local TELEPORT_EVENT = "Mercy_Blink_Teleport"
local TELEPORTED_EVENT = "Mercy_Blink_Teleported"
-- The same visuals and sound as Recall and the Interventions
local TELEPORT_VFX = "vfx_mysticismhit"
local TELEPORT_SOUND = "mysticism hit"

local spell = {
    key = "blink",
    version = 2,
    bundle = "exotic",
    minLevel = 8,
    character_type = { CHARACTER.Spellcaster },
    playerTargetOnly = true,
    weight = 1,
    prewarm = 5,
    cooldown = 120,
    record = {
        name = "Blink",
        type = core.magic.SPELL_TYPE.Spell,
        cost = 25,
        alwaysSucceedFlag = true,
        isAutocalc = false,
        effects = {
            -- A harmless stand-in that flies as a mysticism bolt and tells the hit check the bolt landed. The teleport is
            -- done by Lua on the hit. Unreflectable, so a reflect can't turn it on the caster.
            { id = "soultrap", range = RANGE.Target, area = 0, duration = 1, magnitudeMin = 1, magnitudeMax = 1 },
        },
    },
}

-- Caster's local script: the furthest reachable of the random spots around the target. The navmesh query picks points
-- anywhere within the circle, not only on its edge. Paths are only checked from the furthest spot down, until one passes.
function spell.onHit(caster, target)
    local types = require('openmw.types')
    local nearby = require('openmw.nearby')
    local magicUtil = require("scripts/MaxYari/MercyCAO/scripts/magic_util")
    local from = target.position
    local navOptions = {
        agentBounds = types.Actor.getPathfindingAgentBounds(target),
        includeFlags = nearby.NAVIGATOR_FLAGS.Walk, -- No door crossings
    }
    local candidates = {}
    for _ = 1, ATTEMPTS do
        local point = nearby.findRandomPointAroundCircle(from, MAX_DISTANCE, navOptions)
        if point and (point - from):length() <= MAX_DISTANCE then candidates[#candidates + 1] = point end
    end
    table.sort(candidates, function(a, b) return (a - from):length() > (b - from):length() end)
    for i, point in ipairs(candidates) do
        local status, path = nearby.findPath(from, point, navOptions)
        if status == nearby.FIND_PATH_STATUS.Success and #path > 0 and (path[#path] - point):length() <= 50 then
            magicUtil.log(spell.key, "teleporting", target.recordId, math.floor((point - from):length()), "away, spot", i,
                "of", #candidates, "by distance")
            core.sendGlobalEvent(TELEPORT_EVENT, { caster = caster, target = target, position = point })
            return
        end
    end
    magicUtil.log(spell.key, "no reachable spot found around", target.recordId, "among", #candidates, "candidates")
end

-- Caster's local script, once the target was moved: out of sight, go hiding
spell.localEventHandlers = {
    [TELEPORTED_EVENT] = function(state, data)
        local enums = require("scripts/MaxYari/MercyCAO/scripts/enums")
        local magicUtil = require("scripts/MaxYari/MercyCAO/scripts/magic_util")
        if state.enemyActor ~= data.target or state.combatState ~= enums.COMBAT_STATE.FIGHT then return end
        if state:enemyInLineOfSight() then
            magicUtil.log(spell.key, "target still in sight - keeps fighting")
            return
        end
        local chance = state:hideChance(HIDE_BASE_CHANCE)
        if math.random() >= chance then
            magicUtil.log(spell.key, string.format("target out of sight - hide chance %.0f%% failed, keeps fighting", chance * 100))
            return
        end
        magicUtil.log(spell.key, "target out of sight - going hiding")
        state.hideSpotReady = false
        state.combatState = enums.COMBAT_STATE.HIDE
    end,
}

-- Global script side -----------------------------------------------------------------------------------------------
local function teleportEffect(position, object)
    local types = require('openmw.types')
    local record = types.Static.records[TELEPORT_VFX]
    if record then require('openmw.world').vfx.spawn(record.model, position) end
    core.sound.playSound3d(TELEPORT_SOUND, object)
end

spell.global = {
    eventHandlers = {
        [TELEPORT_EVENT] = function(data)
            local target = data.target
            if not (target:isValid() and target.count > 0) then return end
            teleportEffect(target.position, target)
            target:teleport(target.cell, data.position, { onGround = true })
            teleportEffect(data.position, target)
            if data.caster:isValid() then data.caster:sendEvent(TELEPORTED_EVENT, { target = target }) end
        end,
    },
}

return spell
