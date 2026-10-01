-- Hex of Lethargy: a bolt that slows its target down for a while
local core = require('openmw.core')
local RANGE = core.magic.RANGE
local CHARACTER = require("scripts/MaxYari/MercyCAO/scripts/enums").CHARACTER_TYPE

return {
    key = "slowBolt",
    version = 1,
    bundle = "exotic",
    minLevel = 8,
    character_type = { CHARACTER.Spellcaster, CHARACTER.Marksman },
    weight = 1,
    prewarm = 1,
    cooldown = 20,
    record = {
        name = "Hex of Lethargy",
        type = core.magic.SPELL_TYPE.Spell,
        cost = 15,
        alwaysSucceedFlag = true,
        isAutocalc = false,
        effects = {
            { id = "drainattribute", affectedAttribute = "speed", range = RANGE.Target, area = 6, duration = 5, magnitudeMin = 50, magnitudeMax = 50 },
        },
    },
}
