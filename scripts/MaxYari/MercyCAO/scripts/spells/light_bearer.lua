-- Light Bearer: a light on the caster for dark places (the tree only casts it in interiors or outside at night), and a
-- little extra agility. Agility adds a fifth of itself to both hitting and evading, so +20 is about +4 to each.
local core = require('openmw.core')
local RANGE = core.magic.RANGE
local CHARACTER = require("scripts/MaxYari/MercyCAO/scripts/enums").CHARACTER_TYPE

return {
    key = "lightBearer",
    version = 3,
    bundle = "aux",
    minLevel = 3,
    character_type = { CHARACTER.Spellcaster },
    weight = 0.5,
    prewarm = 0,
    cooldown = 35,
    incompatibleWith = { "invisibility" },
    record = {
        name = "Light Bearer",
        type = core.magic.SPELL_TYPE.Spell,
        cost = 5,
        alwaysSucceedFlag = true,
        isAutocalc = false,
        effects = {
            { id = "light", range = RANGE.Self, area = 0, duration = 30, magnitudeMin = 20, magnitudeMax = 20 },
            { id = "fortifyattribute", affectedAttribute = "agility", range = RANGE.Self, area = 0, duration = 30, magnitudeMin = 20, magnitudeMax = 20 },
        },
    },
}
