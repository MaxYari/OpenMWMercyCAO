-- Fade: the caster becomes half transparent for a while
local core = require('openmw.core')
local RANGE = core.magic.RANGE
local CHARACTER = require("scripts/MaxYari/MercyCAO/scripts/enums").CHARACTER_TYPE

return {
    key = "chameleon",
    version = 3,
    bundle = "normal",
    minLevel = 3,
    character_type = CHARACTER.All,
    weight = 1,
    prewarm = 0,
    cooldown = 40,
    record = {
        name = "Fade",
        type = core.magic.SPELL_TYPE.Spell,
        cost = 15,
        alwaysSucceedFlag = true,
        isAutocalc = false,
        effects = {
            { id = "chameleon", range = RANGE.Self, area = 0, duration = 30, magnitudeMin = 50, magnitudeMax = 50 },
        },
    },
}
