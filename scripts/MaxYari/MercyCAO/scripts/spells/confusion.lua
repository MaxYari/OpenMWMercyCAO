-- Confusion: a bolt that, when it lands on the player, inverts their walking for a few seconds: forward goes back and
-- left goes right. (Inverting the mouse isn't done: the engine turns the player straight from mouse input, so it would
-- mean taking mouse look over in Lua without knowing the player's sensitivity or invert settings.) While confused the
-- screen edges are slightly desaturated and swirl (shaders/mercyConfusion.omwfx, needs post processing enabled). The
-- confusion lasts as long as the spell's (stand-in) effect is active on the player, so dispelling it ends it too. It has
-- no effect on NPCs.
local core = require('openmw.core')
local RANGE = core.magic.RANGE
local CHARACTER = require("scripts/MaxYari/MercyCAO/scripts/enums").CHARACTER_TYPE

local DURATION = 5
local CONFUSE_EVENT = "Mercy_Confusion"
local SHADER = "mercyConfusion"
local FADE_IN, FADE_OUT = 0.4, 0.8 -- Seconds the screen effect takes to appear and to go away
local DISPEL_CHECK_PERIOD = 0.1     -- How often a confused player checks whether the spell is still active

local spell = {
    key = "confusion",
    version = 2,
    bundle = "exotic",
    minLevel = 8,
    character_type = { CHARACTER.Spellcaster, CHARACTER.Marksman },
    playerTargetOnly = true,
    weight = 1,
    prewarm = 1,
    cooldown = 10,
    record = {
        name = "Confusion",
        type = core.magic.SPELL_TYPE.Spell,
        cost = 20,
        alwaysSucceedFlag = true,
        isAutocalc = false,
        effects = {
            -- A harmless stand-in that flies as a mysticism bolt and tells the hit check the bolt landed. The confusion
            -- itself is done by the player script on the hit, for as long as this effect lasts (so a dispel ends it).
            -- Unreflectable, so a reflect can't turn it on the caster.
            { id = "soultrap", range = RANGE.Target, area = 0, duration = DURATION, magnitudeMin = 1, magnitudeMax = 1 },
        },
    },
}

-- Caster's local script: tell the target it's confused
function spell.onHit(caster, target, state)
    target:sendEvent(CONFUSE_EVENT, { duration = DURATION, spellId = state.customSpells[spell.key] })
end

-- Player script side -------------------------------------------------------------------------------------------------
local confusedSince = 0
local confusedUntil = 0
local confusionSpellId = nil
local nextDispelCheckAt = 0
local shader = nil
local shaderOn = false

spell.targetEventHandlers = {
    [CONFUSE_EVENT] = function(data)
        local types = require('openmw.types')
        if not types.Player.objectIsInstance(require('openmw.self').object) then return end
        local now = core.getSimulationTime()
        if now >= confusedUntil then confusedSince = now end
        confusedUntil = math.max(confusedUntil, now + data.duration)
        confusionSpellId = data.spellId
        nextDispelCheckAt = now + DISPEL_CHECK_PERIOD
        if not shader then shader = require('openmw.postprocessing').load(SHADER) end
        if not shaderOn then
            shader:setFloat("uStrength", 0)
            shader:enable()
            shaderOn = true
        end
    end,
}

-- Every frame in the player script, after the built-in controls script set this frame's movement
function spell.playerFrame()
    local now = core.getSimulationTime()
    -- Dispelled: the spell's effect is gone before its time is up
    if now < confusedUntil and confusionSpellId and now >= nextDispelCheckAt then
        nextDispelCheckAt = now + DISPEL_CHECK_PERIOD
        local types = require('openmw.types')
        if not types.Actor.activeSpells(require('openmw.self')):isSpellActive(confusionSpellId) then
            confusedUntil = now
            confusionSpellId = nil
        end
    end
    if now >= confusedUntil then
        if shaderOn then
            shader:disable()
            shaderOn = false
        end
        return
    end
    shader:setFloat("uStrength", math.min(1, (now - confusedSince) / FADE_IN, (confusedUntil - now) / FADE_OUT))
    local controls = require('openmw.self').controls
    controls.movement = -controls.movement
    controls.sideMovement = -controls.sideMovement
end

return spell
