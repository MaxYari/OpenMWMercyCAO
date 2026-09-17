-- Veil of Darkness: a bolt that blinds its target. On the player OpenMW also darkens the screen by the blindness amount.
-- The engine's AI can rate Blind on an enemy, so vanilla AI may cast it too during a handover.
local core = require('openmw.core')
local RANGE = core.magic.RANGE
local CHARACTER = require("scripts/MaxYari/MercyCAO/scripts/enums").CHARACTER_TYPE

return {
    key = "blindness",
    version = 1,
    bundle = "normal",
    minLevel = 8,
    character_type = { CHARACTER.Spellcaster, CHARACTER.Marksman },
    weight = 1,
    prewarm = 1,
    cooldown = 10,
    record = {
        name = "Veil of Darkness",
        type = core.magic.SPELL_TYPE.Spell,
        cost = 15,
        alwaysSucceedFlag = true,
        isAutocalc = false,
        effects = {
            { id = "blind", range = RANGE.Target, area = 0, duration = 10, magnitudeMin = 80, magnitudeMax = 80 },
        },
    },
}
