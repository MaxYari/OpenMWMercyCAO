-- Mending: the caster shrugs off attribute damage on itself.
--
-- Restore rather than Dispel on purpose. Dispel would work for Drain (removing the spell reverts it) but it also
-- rolls against every other temporary spell the caster has, including its own Mercy buffs, so it would strip
-- Quickstep or Vanish to undo a Drain Strength. Damage Attribute is permanent until restored and Dispel can't touch
-- it at all. Restore fixes both and can never cost the caster anything.
local core = require('openmw.core')
local RANGE = core.magic.RANGE
local CHARACTER = require("scripts/MaxYari/MercyCAO/scripts/enums").CHARACTER_TYPE

local magicUtilPath = "scripts/MaxYari/MercyCAO/scripts/magic_util"

-- Only the attributes that decide a fight
local WATCHED = { "strength", "agility", "speed", "endurance", "willpower" }
-- Cast when an attribute is down to this share of its base, or this many points down outright (whichever trips
-- first - a percentage alone is too forgiving for an NPC whose attributes are low to begin with)
local SHORTFALL_FRACTION = 0.7
local SHORTFALL_POINTS = 15
local SCAN_PERIOD = 0.5

local RESTORE = 20

-- The caster's gutils.Actor, built on first use and kept: it caches the stat objects, so the check below costs no
-- engine call after the first. Spell files are loaded by the global script too, hence the lazy require.
local selfActor = nil
local function actor()
    if not selfActor then
        local gutils = require("scripts/MaxYari/MercyCAO/scripts/gutils")
        selfActor = gutils.Actor:new(require('openmw.self'))
    end
    return selfActor
end

local function restoreEffect(attribute)
    return { id = "restoreattribute", affectedAttribute = attribute, range = RANGE.Self, area = 0, duration = 1,
        magnitudeMin = RESTORE, magnitudeMax = RESTORE }
end

local spell = {
    key = "restoreSelf",
    version = 1,
    bundle = "counter",
    minLevel = 8,
    character_type = CHARACTER.All,
    weight = 1,
    prewarm = 2,
    cooldown = 3,
    record = {
        name = "Mending",
        type = core.magic.SPELL_TYPE.Spell,
        cost = 15,
        alwaysSucceedFlag = true,
        isAutocalc = false,
        effects = {
            restoreEffect("strength"), restoreEffect("agility"), restoreEffect("speed"),
            restoreEffect("endurance"), restoreEffect("willpower"), restoreEffect("intelligence"),
            restoreEffect("personality"), restoreEffect("luck"),
        },
    },
}

-- Caster's local script, every combat frame. Leaves state.selfNeedsMending for the tree, checked at SCAN_PERIOD.
function spell.combatUpdate(state)
    local now = core.getSimulationTime()
    if now < (state.mendScanAt or 0) then return end
    if not state:canCastCustom(spell.key) then
        state.selfNeedsMending = false
        state.mendScanAt = now + SCAN_PERIOD
        return
    end
    state.mendScanAt = now + SCAN_PERIOD

    local me = actor()
    for _, attribute in ipairs(WATCHED) do
        local stat = me:getAttributeStat(attribute)
        if stat and stat.base > 0 then
            local shortfall = stat.base - stat.modified
            if shortfall >= SHORTFALL_POINTS or stat.modified <= stat.base * SHORTFALL_FRACTION then
                require(magicUtilPath).log("Mending:", attribute, "is", math.floor(stat.modified), "of",
                    math.floor(stat.base))
                state.selfNeedsMending = true
                return
            end
        end
    end
    state.selfNeedsMending = false
end

return spell
