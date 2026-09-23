-- Quickstep: the caster moves a lot faster for a while
local core = require('openmw.core')
local RANGE = core.magic.RANGE
local CHARACTER = require("scripts/MaxYari/MercyCAO/scripts/enums").CHARACTER_TYPE

return {
    key = "speedBoost",
    version = 3,
    bundle = "aux",
    minLevel = 8,
    character_type = CHARACTER.All,
    weight = 0.75,
    warmup = 0,
    cooldown = 40,
    record = {
        name = "Quickstep",
        type = core.magic.SPELL_TYPE.Spell,
        cost = 10,
        alwaysSucceedFlag = true,
        isAutocalc = false,
        effects = {
            { id = "fortifyattribute", affectedAttribute = "speed", range = RANGE.Self, area = 0, duration = 25, magnitudeMin = 80, magnitudeMax = 80 },
        },
    },
}
