-- Rend (needs the Magic Slash Spell mod): a bolt carrying that mod's own Magic Slash effect. The mod's actor script on
-- the target does the rest: holds it in place while slashing it for about 2.4 seconds, then takes the magnitude off its
-- health (above 25 it also staggers, above 50 knocks down, above 75 knocks out).
-- Not in use: kept here, outside the spells folder Mercy loads, as a worked example of a spell built on another mod's
-- custom effect. Put back in scripts/spells it would be left out by itself without the mod (see init.lua). Note that
-- the engine's AI can cast it too, in its own magic windows, outside Mercy's cooldown.
local core = require('openmw.core')
local RANGE = core.magic.RANGE
local CHARACTER = require("scripts/MaxYari/MercyCAO/scripts/enums").CHARACTER_TYPE

return {
    key = "magicSlash",
    version = 1,
    bundle = "exotic",
    minLevel = 10,
    character_type = { CHARACTER.Spellcaster },
    weight = 1,
    prewarm = 3,
    cooldown = 25,
    record = {
        name = "Rend",
        type = core.magic.SPELL_TYPE.Spell,
        cost = 20,
        alwaysSucceedFlag = true,
        isAutocalc = false,
        effects = {
            { id = "MagicSlash", range = RANGE.Target, area = 0, magnitudeMin = 20, magnitudeMax = 40 },
        },
    },
    cast = {
        condition = "$range < 2000 and $:enemyInLineOfSight()",
        period = { 4, 7 },
        aim = true,
    },
}
