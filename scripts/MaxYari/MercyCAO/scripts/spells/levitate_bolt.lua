-- Hex of Floating: a bolt that leaves the target hanging in the air with barely any control, and slows it down
local core = require('openmw.core')
local RANGE = core.magic.RANGE
local CHARACTER = require("scripts/MaxYari/MercyCAO/scripts/enums").CHARACTER_TYPE

return {
    key = "levitateBolt",
    version = 7,
    bundle = "exotic",
    minLevel = 8,
    character_type = { CHARACTER.Spellcaster, CHARACTER.Marksman },
    weight = 1,
    prewarm = 1,
    cooldown = 20,
    record = {
        name = "Hex of Floating",
        type = core.magic.SPELL_TYPE.Spell,
        cost = 15,
        alwaysSucceedFlag = true,
        isAutocalc = false,
        effects = {
            { id = "levitate", range = RANGE.Target, area = 6, duration = 5, magnitudeMin = 1, magnitudeMax = 1 },
            { id = "drainattribute", affectedAttribute = "speed", range = RANGE.Target, area = 6, duration = 5, magnitudeMin = 30, magnitudeMax = 30 },
        },
    },
}
