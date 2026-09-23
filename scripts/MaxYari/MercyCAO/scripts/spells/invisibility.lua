-- Vanish: the caster turns invisible, then repositions around the enemy or runs off to hide (both in the trees). When the
-- invisibility ends (runs out, or broken by attacking or casting) the same sound as when it started plays on the caster,
-- so the player can tell it's visible again.
local core = require('openmw.core')
local RANGE = core.magic.RANGE
local CHARACTER = require("scripts/MaxYari/MercyCAO/scripts/enums").CHARACTER_TYPE

local WATCH_START_TIMEOUT = 2 -- Seconds to wait for the effect to show up after the cast before giving up watching

local spell = {
    key = "invisibility",
    version = 4,
    bundle = "normal",
    minLevel = 8,
    character_type = CHARACTER.All,
    weight = 1,
    prewarm = 3,
    cooldown = 40,
    record = {
        name = "Vanish",
        type = core.magic.SPELL_TYPE.Spell,
        cost = 20,
        alwaysSucceedFlag = true,
        isAutocalc = false,
        effects = {
            { id = "invisibility", range = RANGE.Self, area = 0, duration = 20, magnitudeMin = 1, magnitudeMax = 1 },
        },
    },
}

local function isInvisible()
    local types = require('openmw.types')
    local omwself = require('openmw.self')
    local effect = types.Actor.activeEffects(omwself):getEffect(core.magic.EFFECT_TYPE.Invisibility)
    return effect ~= nil and effect.magnitude > 0
end

-- Caster's local script: start watching for the invisibility to end
function spell.onCast(caster, target, state)
    state.vanishWatch = { castAt = core.getSimulationTime(), seen = false }
end

-- Caster's local script, every combat frame: does nothing unless watching
function spell.combatUpdate(state)
    local watch = state.vanishWatch
    if not watch then return end
    if isInvisible() then
        watch.seen = true
    elseif watch.seen then
        state.vanishWatch = nil
        local effect = core.magic.effects.records[core.magic.EFFECT_TYPE.Invisibility]
        local sound = effect and effect.hitSound ~= "" and effect.hitSound or "illusion hit"
        core.sound.playSound3d(sound, require('openmw.self'))
        require("scripts/MaxYari/MercyCAO/scripts/magic_util").log(spell.key, "invisibility ended, played", sound)
    elseif core.getSimulationTime() - watch.castAt > WATCH_START_TIMEOUT then
        state.vanishWatch = nil
    end
end

return spell
