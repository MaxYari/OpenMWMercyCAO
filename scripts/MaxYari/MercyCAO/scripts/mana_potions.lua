-- Magicka potions for spellcasters. On their first fight casters get a level appropriate Restore Magicka potion with the
-- Mana Potion Chance setting. In combat, the first time a caster can't afford any of its spells it waits a random
-- DRINK_DELAY_MIN - MAX seconds, then drinks its best Restore Magicka potion (then none for DRINK_COOLDOWN seconds) (any it carries, not only Mercy's). Vanilla
-- AI would drink them too, but Mercy keeps it switched off most of the time. Fair Care only handles health potions.
local core = require('openmw.core')
local types = require('openmw.types')

local module = {}

local CHECK_PERIOD = 0.5
local NO_POTION_CHECK_PERIOD = 5 -- Looking for a potion again later, e.g. one given on this fight's start arrives late
local DRINK_DELAY_MIN, DRINK_DELAY_MAX = 1, 10
local DRINK_COOLDOWN = 60 -- No other potion for this long after drinking one
local GIVE_EVENT = "Mercy_GiveManaPotion"
-- Up to this level -> potion given
local POTIONS_BY_LEVEL = {
    { maxLevel = 5, id = "p_restore_magicka_c" },   -- Cheap: 10 magicka
    { maxLevel = 12, id = "p_restore_magicka_s" },  -- Standard: 50
    { maxLevel = 20, id = "p_restore_magicka_q" },  -- Quality: 100
    { maxLevel = math.huge, id = "p_restore_magicka_e" }, -- Exclusive: 200
}

local function log(...)
    require("scripts/MaxYari/MercyCAO/scripts/magic_util").log("[mana potions]", ...)
end

-- Total magicka a potion restores, 0 if it doesn't restore magicka
local function restoredMagicka(potion)
    local total = 0
    for _, effect in ipairs(types.Potion.record(potion).effects) do
        if effect.id == "restoremagicka" then
            total = total + (effect.magnitudeMin + effect.magnitudeMax) / 2 * math.max(1, effect.duration)
        end
    end
    return total
end

local function bestPotion(actor)
    local best, bestAmount = nil, 0
    for _, potion in ipairs(types.Actor.inventory(actor):getAll(types.Potion)) do
        local amount = restoredMagicka(potion)
        if amount > bestAmount then best, bestAmount = potion, amount end
    end
    return best
end

-- Local script ------------------------------------------------------------------------------------------------------
-- Per actor drinking state, reset every fight
local cheapestCost = nil  -- Cheapest spell the actor could cast in combat, nil if none
local nextCheckAt = 0
local drinkAt = nil       -- A drink is scheduled for this time

-- On combat start. 'firstFightCaster': this is the actor's first fight and it's a spellcaster (or was upgraded to one).
-- 'combatSpellCost': cheapest vanilla combat spell cost, 'customSpellIds': Mercy spells it knows.
function module.onCombatStart(actor, chance, firstFightCaster, combatSpellCost, customSpellIds)
    cheapestCost = combatSpellCost
    for _, spellId in ipairs(customSpellIds) do
        local spell = core.magic.spells.records[spellId]
        if spell and (not cheapestCost or spell.cost < cheapestCost) then cheapestCost = spell.cost end
    end
    nextCheckAt = 0
    drinkAt = nil

    if firstFightCaster and math.random() < chance then
        local level = types.Actor.stats.level(actor).current
        for _, entry in ipairs(POTIONS_BY_LEVEL) do
            if level <= entry.maxLevel then
                log("level", level, "caster gets", entry.id)
                core.sendGlobalEvent(GIVE_EVENT, { actor = actor, potionId = entry.id })
                break
            end
        end
    end
end

-- Every combat frame; cheap unless it's time to check
function module.combatUpdate(actor, now)
    if not cheapestCost or types.Actor.isDead(actor) then return end
    if drinkAt then
        if now < drinkAt then return end
        drinkAt = nil
        local potion = bestPotion(actor)
        if potion then
            log("drinking", potion.recordId, "with", math.floor(types.Actor.stats.dynamic.magicka(actor).current), "magicka")
            core.sendGlobalEvent("UseItem", { object = potion, actor = actor })
            nextCheckAt = now + DRINK_COOLDOWN
        end
        return
    end
    if now < nextCheckAt then return end
    nextCheckAt = now + CHECK_PERIOD
    if types.Actor.stats.dynamic.magicka(actor).current >= cheapestCost then return end
    if not bestPotion(actor) then
        nextCheckAt = now + NO_POTION_CHECK_PERIOD
        return
    end
    drinkAt = now + DRINK_DELAY_MIN + math.random() * (DRINK_DELAY_MAX - DRINK_DELAY_MIN)
    log("out of magicka for spells costing", cheapestCost, "- drinking in", string.format("%.1f", drinkAt - now), "s")
end

-- Global script -----------------------------------------------------------------------------------------------------
module.globalEventHandlers = {
    [GIVE_EVENT] = function(data)
        local world = require('openmw.world')
        if not data.actor:isValid() or not types.Potion.records[data.potionId] then return end
        world.createObject(data.potionId, 1):moveInto(types.Actor.inventory(data.actor))
    end,
}

return module
