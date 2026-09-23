-- Unweaving: strips the magic an enemy is visibly running on - shields, concealment, levitation, conjured gear and
-- summons. The engine's Dispel only takes temporary effects from normal spells (never potions, enchantments,
-- abilities or powers) and removes whole spells at once, one roll each against the magnitude, so the magnitude is
-- high enough that what it can take, it takes.
--
-- What counts as worth dispelling is magic_util.DISPEL_WORTHY_EFFECTS: only things an NPC could actually see on its
-- enemy. Resistances and fortify effects are deliberately not in it - the NPC has no way of knowing about those.
local core = require('openmw.core')
local RANGE = core.magic.RANGE
local CHARACTER = require("scripts/MaxYari/MercyCAO/scripts/enums").CHARACTER_TYPE

local magicUtilPath = "scripts/MaxYari/MercyCAO/scripts/magic_util"

-- The enemy's spells are only looked at this often, and only while a fight is on and this spell is off cooldown
local SCAN_PERIOD = 0.5

local spell = {
    key = "dispel",
    version = 2,
    bundle = "counter",
    minLevel = 8,
    character_type = CHARACTER.All,
    weight = 1,
    prewarm = 2,
    cooldown = 12,
    record = {
        name = "Unweaving",
        type = core.magic.SPELL_TYPE.Spell,
        cost = 20,
        alwaysSucceedFlag = true,
        isAutocalc = false,
        effects = {
            { id = "dispel", range = RANGE.Target, area = 0, duration = 1, magnitudeMin = 50, magnitudeMax = 100 },
        },
    },
}

-- Caster's local script, every combat frame. Keeps state.enemyDispelWorth up to date for the tree to read, at
-- SCAN_PERIOD rather than every frame, and only while the spell is off cooldown. Not gated on the full canCastCustom:
-- that fails during every attack burst, and the answer has to be fresh for the moment right after one, when the tree
-- gets to its spells.
function spell.combatUpdate(state)
    local now = core.getSimulationTime()
    if now < (state.dispelScanAt or 0) then return end
    state.dispelScanAt = now + SCAN_PERIOD
    if not state.enemyActor or (state.customSpellCooldowns[spell.key] or 0) > now then
        state.enemyDispelWorth = 0
        return
    end
    local magicUtil = require(magicUtilPath)
    state.enemyDispelWorth = magicUtil.dispelWorthyCount(state.enemyActor)
    if state.enemyDispelWorth > 0 then
        magicUtil.log("Dispel: enemy has", state.enemyDispelWorth, "spell(s) worth unweaving")
    end
end

-- Caster's local script, on release: remember how much there was to unweave, for landed() below
function spell.onCast(caster, target, state)
    state.dispelWorthAtCast = require(magicUtilPath).dispelWorthyCount(target)
end

-- Dispel is instant: it leaves nothing on the target that the usual hit check could find (the engine drops the spell
-- again on its next update), so it has landed when there's less on the enemy worth unweaving than at release.
-- A bolt that hit but whose rolls stripped nothing reads as a miss - which is what it is for the caster: the enemy's
-- magic is still up, so it may try again soon.
function spell.landed(caster, target, state)
    return require(magicUtilPath).dispelWorthyCount(target) < (state.dispelWorthAtCast or 0)
end

return spell
