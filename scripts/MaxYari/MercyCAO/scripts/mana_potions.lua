-- Magicka potions for spellcasters. On their first fight casters roll the Mana Potion Chance POTION_ROLLS times, getting
-- a level appropriate Restore Magicka potion for each success. In combat, the first time a caster can't afford any of
-- its spells it waits a random DRINK_DELAY_MIN - MAX seconds, then drinks a potion (then none for DRINK_COOLDOWN seconds).
--
-- The potions Mercy gives are kept out of the inventory, only counted here, and created right when they're drunk: the
-- engine's AI drinks a Restore Magicka potion whenever it's short on magicka, again on every decision while the first
-- one is still restoring, and would chug them all in a row. Whatever is left goes into the inventory when the caster
-- dies, so it can still be looted. Potions the caster carried on its own are left to the engine's AI (Mercy drinks those
-- too when it has none of its own left). Fair Care only handles health potions.
local core = require('openmw.core')
local types = require('openmw.types')

local module = {}

local CHECK_PERIOD = 0.5
local NO_POTION_CHECK_PERIOD = 5 -- Looking for a potion again later
local DRINK_DELAY_MIN, DRINK_DELAY_MAX = 1, 5
local DRINK_COOLDOWN = 10 -- No other potion for this long after drinking one
local POTION_ROLLS = 3 -- A caster rolls the Mana Potion Chance this many times, getting a potion for each success
local GIVE_EVENT = "Mercy_GiveManaPotion"
local DRINK_EVENT = "Mercy_DrinkManaPotion"
-- Up to this level -> potion given, restoring at least about half of a typical caster's magicka at that level (vanilla
-- casters have ~90-100 magicka up to level 7, ~100-170 up to 20, ~120-200 above)
local POTIONS_BY_LEVEL = {
    { maxLevel = 5, id = "p_restore_magicka_s" },  -- Standard: 50 magicka over 5 s
    { maxLevel = 20, id = "p_restore_magicka_q" }, -- Quality: 100
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

-- The best Restore Magicka potion the caster carries on its own
local function bestCarriedPotion(actor)
    local best, bestAmount = nil, 0
    for _, potion in ipairs(types.Actor.inventory(actor):getAll(types.Potion)) do
        local amount = restoredMagicka(potion)
        if amount > bestAmount then best, bestAmount = potion, amount end
    end
    return best
end

-- Local script ------------------------------------------------------------------------------------------------------
-- Mercy's potions for this caster, kept out of the inventory. Saved.
local potionId = nil
local potionsLeft = 0
-- Per fight drinking state
local cheapestCost = nil  -- Cheapest spell the actor could cast in combat, nil if none
local nextCheckAt = 0
local drinkAt = nil       -- A drink is scheduled for this time

local function hasPotion(actor)
    return potionsLeft > 0 or bestCarriedPotion(actor) ~= nil
end

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

    if firstFightCaster then
        local count = 0
        for _ = 1, POTION_ROLLS do
            if math.random() < chance then count = count + 1 end
        end
        if count > 0 then
            local level = types.Actor.stats.level(actor).current
            for _, entry in ipairs(POTIONS_BY_LEVEL) do
                if level <= entry.maxLevel then
                    potionId, potionsLeft = entry.id, count
                    log("level", level, "caster gets", count, "x", entry.id, "(kept out of the inventory until drunk)")
                    break
                end
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
        -- Mercy's own potions first: the engine's AI may drink the carried ones anyway
        if potionsLeft > 0 then
            potionsLeft = potionsLeft - 1
            log("drinking a given", potionId, "with", math.floor(types.Actor.stats.dynamic.magicka(actor).current),
                "magicka,", potionsLeft, "left")
            core.sendGlobalEvent(DRINK_EVENT, { actor = actor, potionId = potionId })
            nextCheckAt = now + DRINK_COOLDOWN
            return
        end
        local potion = bestCarriedPotion(actor)
        if potion then
            log("drinking a carried", potion.recordId, "with", math.floor(types.Actor.stats.dynamic.magicka(actor).current),
                "magicka")
            core.sendGlobalEvent("UseItem", { object = potion, actor = actor })
            nextCheckAt = now + DRINK_COOLDOWN
        else
            -- It had one when the drink was scheduled: most likely the engine's AI drank it meanwhile
            log("no potion left at drinking time - probably drunk by the engine's AI")
        end
        return
    end
    if now < nextCheckAt then return end
    nextCheckAt = now + CHECK_PERIOD
    if types.Actor.stats.dynamic.magicka(actor).current >= cheapestCost then return end
    if not hasPotion(actor) then
        nextCheckAt = now + NO_POTION_CHECK_PERIOD
        return
    end
    drinkAt = now + DRINK_DELAY_MIN + math.random() * (DRINK_DELAY_MAX - DRINK_DELAY_MIN)
    log("out of magicka for spells costing", cheapestCost, "- drinking in", string.format("%.1f", drinkAt - now), "s")
end

-- When the caster dies: the potions it didn't drink go into its inventory, to be looted
function module.onDied(actor, manaPotionLootChance)
    if potionsLeft <= 0 or not potionId then return end
    if math.random() <= manaPotionLootChance then
        log("died with", potionsLeft, "x", potionId, "- putting them in the inventory")
        core.sendGlobalEvent(GIVE_EVENT, { actor = actor, potionId = potionId, count = potionsLeft })
    end    
    potionsLeft = 0
end

function module.save()
    return { potionId = potionId, potionsLeft = potionsLeft }
end

function module.load(data)
    if not data then return end
    potionId = data.potionId
    potionsLeft = data.potionsLeft or 0
end

-- Global script -----------------------------------------------------------------------------------------------------
module.globalEventHandlers = {
    [GIVE_EVENT] = function(data)
        local world = require('openmw.world')
        if not data.actor:isValid() or not types.Potion.records[data.potionId] then return end
        world.createObject(data.potionId, data.count or 1):moveInto(types.Actor.inventory(data.actor))
    end,
    -- Created in the inventory and drunk right away (through the usual item use, so e.g. drinking animations play)
    [DRINK_EVENT] = function(data)
        local world = require('openmw.world')
        if not data.actor:isValid() or not types.Potion.records[data.potionId] then return end
        local potion = world.createObject(data.potionId, 1)
        potion:moveInto(types.Actor.inventory(data.actor))
        core.sendGlobalEvent("UseItem", { object = potion, actor = data.actor })
    end,
}

return module
