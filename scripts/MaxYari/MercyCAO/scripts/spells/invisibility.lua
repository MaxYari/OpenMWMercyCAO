-- Vanish: the caster turns invisible, then repositions around the enemy or runs off to hide (both in the trees). When the
-- invisibility ends (runs out, or broken by attacking or casting) the same sound as when it started plays on the caster,
-- so the player can tell it's visible again.
-- The effect's cast and hit visuals are kept off the caster: they're a cloud at the torso that the engine doesn't fade
-- with the body, so it would give away where the invisible caster is. Cast the usual way the engine plays them and they
-- are taken off again over the first frames; cast through OSSC, Spell Framework Plus is asked not to add the hit cloud
-- (the engine plays neither then, and OSSC adds no cast visuals of its own to a cast Mercy hands it).
local core = require('openmw.core')
local RANGE = core.magic.RANGE
local CHARACTER = require("scripts/MaxYari/MercyCAO/scripts/enums").CHARACTER_TYPE

local WATCH_START_TIMEOUT = 2 -- Seconds to wait for the effect to show up after the cast before giving up watching
local VFX_REMOVE_TIME = 0.5   -- Seconds to keep taking the visuals off after the effect shows up, they can arrive late
-- The engine tags both visuals with the effect's id as spelled in its record. Not core.magic.EFFECT_TYPE.Invisibility:
-- that one is lower case, and removeVfx matches the tag case sensitively.
local VFX_ID = "Invisibility"

local spell = {
    key = "invisibility",
    version = 4,
    bundle = "normal",
    minLevel = 8,
    character_type = CHARACTER.All,
    weight = 1,
    prewarm = 3,
    cooldown = 40,
    osscUserData = { suppressImpactVfx = true },
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

local function removeVfx()
    local animation = require('openmw.animation')
    local omwself = require('openmw.self')
    -- removeVfx raises on an actor with no animation
    if animation.hasAnimation(omwself) then animation.removeVfx(omwself, VFX_ID) end
end

-- Caster's local script: start watching for the invisibility to end
function spell.onCast(caster, target, state)
    state.vanishWatch = { castAt = core.getSimulationTime(), seenAt = nil }
end

-- Caster's local script, every combat frame: does nothing unless watching
function spell.combatUpdate(state)
    local watch = state.vanishWatch
    if not watch then return end
    local now = core.getSimulationTime()
    if isInvisible() then
        watch.seenAt = watch.seenAt or now
        if now - watch.seenAt < VFX_REMOVE_TIME then removeVfx() end
    elseif watch.seenAt then
        state.vanishWatch = nil
        local effect = core.magic.effects.records[core.magic.EFFECT_TYPE.Invisibility]
        local sound = effect and effect.hitSound ~= "" and effect.hitSound or "illusion hit"
        core.sound.playSound3d(sound, require('openmw.self'))
        require("scripts/MaxYari/MercyCAO/scripts/magic_util").log(spell.key, "invisibility ended, played", sound)
    elseif now - watch.castAt > WATCH_START_TIMEOUT then
        state.vanishWatch = nil
    else
        -- The cast visual is on already, before the effect shows up
        removeVfx()
    end
end

return spell
