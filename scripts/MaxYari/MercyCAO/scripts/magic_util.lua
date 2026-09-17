-- Magic helpers: what magic an actor can use, and Mercy's own (custom) spells.
-- Nothing here runs by itself: scans are meant for combat start, checks for moments a tree node asks.

local core = require('openmw.core')
local types = require('openmw.types')
-- Only available in local scripts, the global script uses this module for the custom spell definitions only
local animationOk, animation = pcall(require, 'openmw.animation')
local selfOk, omwself = pcall(require, 'openmw.self')

local module = {}

-- Debug logging ---------------------------------------------------------------------------------------------------
-- Debug logging of Mercy's magic, hiding and detection decisions
module.DEBUG_LOGGING = true

function module.log(...)
    if not module.DEBUG_LOGGING then return end
    local count = select("#", ...)
    local args = { ... }
    local parts = {}
    for i = 1, count do parts[i] = tostring(args[i]) end
    local who = selfOk and omwself.recordId or "global"
    print("[Mercy][magic][" .. who .. "]: " .. table.concat(parts, " "))
end

-- Effect filters --------------------------------------------------------------------------------------------------
local function toSet(names)
    local set = {}
    for _, name in ipairs(names) do set[string.lower(name)] = true end
    return set
end

-- Effects the engine's combat AI never casts, they are rated 0 in spellpriority.cpp
module.NEVER_CAST_EFFECTS = toSet({
    "Soultrap", "AlmsiviIntervention", "DivineIntervention", "CalmHumanoid", "CalmCreature", "FrenzyHumanoid",
    "FrenzyCreature", "DemoralizeHumanoid", "DemoralizeCreature", "RallyHumanoid", "RallyCreature", "Charm",
    "DetectAnimal", "DetectEnchantment", "DetectKey", "Telekinesis", "Mark", "Recall", "Jump", "WaterBreathing",
    "SwiftSwim", "WaterWalking", "SlowFall", "Light", "Lock", "Open", "TurnUndead", "WeaknessToCommonDisease",
    "WeaknessToBlightDisease", "WeaknessToCorprusDisease", "CureCommonDisease", "CureBlightDisease",
    "CureCorprusDisease", "ResistBlightDisease", "ResistCommonDisease", "ResistCorprusDisease", "Invisibility",
    "Chameleon", "NightEye", "Vampirism", "StuntedMagicka", "ExtraSpell", "RemoveCurse", "CommandCreature",
    "CommandHumanoid", "RestoreAttribute", "RestoreSkill", "ResistFire", "ResistFrost", "ResistMagicka",
    "ResistNormalWeapons", "ResistParalysis", "ResistPoison", "ResistShock", "SpellAbsorption", "Reflect",
    "FortifyAttribute", "FortifyHealth", "FortifyMagicka", "FortifyFatigue", "FortifySkill", "FortifyMaximumMagicka",
    "FortifyAttack", "Levitate",
})

-- Healing is left to Fair Care
module.LEFT_TO_FAIR_CARE = toSet({ "RestoreHealth", "RestoreFatigue", "RestoreMagicka" })

-- An effect the engine might decide to cast in combat
function module.isUsefulEffect(effect)
    local id = string.lower(effect.id)
    return not module.NEVER_CAST_EFFECTS[id] and not module.LEFT_TO_FAIR_CARE[id]
end

function module.hasUsefulEffect(effects)
    for i = 1, #effects do
        if module.isUsefulEffect(effects[i]) then return true end
    end
    return false
end

-- Castables -------------------------------------------------------------------------------------------------------
local function racialSpells(actor)
    local set = {}
    if not types.NPC.objectIsInstance(actor) then return set end
    local race = types.NPC.races.record(types.NPC.record(actor).race)
    if race then
        for i = 1, #race.spells do set[race.spells[i]] = true end
    end
    return set
end

local function isUsefulEnchantment(enchantId, wantedType)
    if not enchantId or enchantId == "" then return false end
    local enchantment = core.magic.enchantments.records[enchantId]
    return enchantment ~= nil and enchantment.type == wantedType and module.hasUsefulEffect(enchantment.effects)
end

local function hasUsableMagicItems(actor)
    local ENCHANTMENT_TYPE = core.magic.ENCHANTMENT_TYPE
    -- Scrolls are used straight from the inventory
    for _, book in ipairs(types.Actor.inventory(actor):getAll(types.Book)) do
        if isUsefulEnchantment(types.Book.record(book).enchant, ENCHANTMENT_TYPE.CastOnce) then return true end
    end
    -- Cast when used items only count when equipped. Their charge isn't checked, this is a rough check.
    for _, item in pairs(types.Actor.getEquipment(actor)) do
        if types.Weapon.objectIsInstance(item) or types.Armor.objectIsInstance(item) or types.Clothing.objectIsInstance(item) then
            if isUsefulEnchantment(item.type.record(item).enchant, ENCHANTMENT_TYPE.CastOnUse) then return true end
        end
    end
    return false
end

-- What magic this actor has, for deciding whether handing it to the engine can end in a cast. Rough on purpose, the
-- engine does its own rating. Meant to run once per combat start.
-- knownSpellCount: every normal spell, combatSpellCount: the ones with an effect the engine might cast.
-- ignoredSpellIds (a set, optional): spells left out of the scan, e.g. Mercy's custom spells.
function module.scanCastables(actor, ignoredSpellIds)
    local castables = { knownSpellCount = 0, combatSpellCount = 0, cheapestSpellCost = nil, hasItems = false }
    local racial = racialSpells(actor)
    local spells = types.Actor.spells(actor)
    for i = 1, #spells do
        local spell = spells[i]
        if spell.type == core.magic.SPELL_TYPE.Spell and not racial[spell.id]
            and not (ignoredSpellIds and ignoredSpellIds[spell.id]) then
            castables.knownSpellCount = castables.knownSpellCount + 1
            if module.hasUsefulEffect(spell.effects) then
                castables.combatSpellCount = castables.combatSpellCount + 1
                if not castables.cheapestSpellCost or spell.cost < castables.cheapestSpellCost then
                    castables.cheapestSpellCost = spell.cost
                end
            end
        end
    end
    castables.hasItems = hasUsableMagicItems(actor)
    castables.canUseMagic = castables.combatSpellCount > 0 or castables.hasItems

    module.log("Castables: known spells", castables.knownSpellCount, "combat spells", castables.combatSpellCount,
        "cheapest cost", castables.cheapestSpellCost, "usable items", castables.hasItems)
    return castables
end

function module.isSilenced(actor)
    local silence = types.Actor.activeEffects(actor):getEffect("silence")
    return silence ~= nil and silence.magnitude > 0
end

-- Whether the engine could cast something right now: a usable item, or magicka for the cheapest combat spell
function module.canAttemptCastNow(actor, castables)
    if castables.hasItems then return true end
    if castables.combatSpellCount == 0 or module.isSilenced(actor) then return false end
    return types.Actor.stats.dynamic.magicka(actor).current >= castables.cheapestSpellCost
end

function module.knowsSpell(actor, spellId)
    return types.Actor.spells(actor)[spellId] ~= nil
end

function module.canAfford(actor, spellId)
    local spell = core.magic.spells.records[spellId]
    return spell ~= nil and types.Actor.stats.dynamic.magicka(actor).current >= spell.cost
end

-- The target has this spell active on it, cast by 'caster'
function module.hasActiveSpellFrom(target, spellId, caster)
    for _, activeSpell in pairs(types.Actor.activeSpells(target)) do
        if activeSpell.id == spellId and activeSpell.caster == caster then return true end
    end
    return false
end

-- The engine or Mercy is casting (or readying spells)
function module.isCasting(actor)
    return animationOk and animation.isPlaying(actor, "spellcast")
end

-- Custom spells ---------------------------------------------------------------------------------------------------
-- Mercy's own spells, each in its own file in scripts/spells. The global script creates a record for each once per game
-- (records are saved with the game)
-- and again whenever its 'version' changes; bump 'version' after changing a record. Spellcasting NPCs get some of them
-- on their first fight (see rollCustomSpells) and swap to newer records later.
--
-- A custom spell goes on its cooldown ('cooldown', or CUSTOM_SPELL_DEFAULT_COOLDOWN) when cast. A miss (a target spell
-- not landing within the main loop's hit window) lifts the cooldown, unless it's CUSTOM_SPELL_MISSES_BEFORE_COOLDOWN
-- misses in a row. Self spells always count as landed. 'prewarm' keeps a spell unused for that many seconds after a
-- fight starts.
--
-- The engine's AI rates most of these effects 0 and doesn't cast them on its own (Skeleton Jail's Detect Animal
-- stand-in included). Exception: it can rate Drain Attribute on an enemy (Levitate Bolt).
module.CUSTOM_SPELL_DEFAULT_COOLDOWN = 20
module.CUSTOM_SPELL_MISSES_BEFORE_COOLDOWN = 2

-- Distribution: whether an NPC takes part at all is rolled by the NPC script, with separate settings for spellcasters and
-- NPCs who know no spells (see rollCustomSpells). A taking part NPC rolls the exotic bundle (EXOTIC_BUNDLE_CHANCE). With
-- MAGIC_AND_EXOTIC_COMBO_CHANCE it gets a spell from the normal bundle, plus one from the exotic bundle if that roll
-- succeeded; otherwise it gets a spell from the exotic bundle if that roll succeeded, or else from the normal bundle. An
-- exotic roll counts as failed when the NPC can't get any exotic spell.
-- Then one from the aux bundle (AUX_BUNDLE_CHANCE). Within a bundle a spell is picked by
-- 'weight': weights summing above 1 are scaled down to 1, below 1 the rest is the chance of picking nothing. A spell isn't
-- picked if the NPC is below its 'minLevel', if the NPC's character type isn't among its 'character_type', if a spell in
-- its 'incompatibleWith' list is already picked, or if its 'available' function says it can't be used in this game (e.g.
-- a mod it needs isn't installed).
module.EXOTIC_BUNDLE_CHANCE = 0.33
module.MAGIC_AND_EXOTIC_COMBO_CHANCE = 0.25
module.AUX_BUNDLE_CHANCE = 0.33

-- Spell definitions live in scripts/spells, one file each (see scripts/spells/init.lua for their fields)
local mp = "scripts/MaxYari/MercyCAO/"
module.CUSTOM_SPELLS = {}
for _, spell in ipairs(require(mp .. "scripts/spells/init")) do
    module.CUSTOM_SPELLS[spell.key] = spell
end

local function sortedKeys(t)
    local keys = {}
    for key in pairs(t) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function isIncompatible(spell, picked)
    for _, other in ipairs(spell.incompatibleWith or {}) do
        for _, key in ipairs(picked) do
            if key == other then return true end
        end
    end
    return false
end

-- Whether a custom spell is meant for this kind of character (enums.CHARACTER_TYPE)
function module.isForCharacter(key, characterType)
    local ALL = require("scripts/MaxYari/MercyCAO/scripts/enums").CHARACTER_TYPE.All
    local characterTypes = module.CUSTOM_SPELLS[key].character_type
    if not characterTypes or characterTypes == ALL then return true end
    for _, allowed in ipairs(characterTypes) do
        if allowed == ALL or allowed == characterType then return true end
    end
    return false
end

-- Whether a custom spell can be used in this game
function module.isAvailable(key)
    local spell = module.CUSTOM_SPELLS[key]
    return spell ~= nil and (not spell.available or spell.available())
end

-- The spells of a bundle this NPC can get, given what it already picked
local function bundleCandidates(bundle, picked, npc)
    local candidates, totalWeight = {}, 0
    for _, key in ipairs(sortedKeys(module.CUSTOM_SPELLS)) do
        local spell = module.CUSTOM_SPELLS[key]
        if spell.bundle == bundle and npc.level >= (spell.minLevel or 0) and module.isForCharacter(key, npc.characterType)
            and module.isAvailable(key)
            and not isIncompatible(spell, picked) then
            candidates[#candidates + 1] = key
            totalWeight = totalWeight + spell.weight
        end
    end
    return candidates, totalWeight
end

local function pickFromBundle(bundle, picked, npc)
    local candidates, totalWeight = bundleCandidates(bundle, picked, npc)
    local scale = totalWeight > 1 and 1 / totalWeight or 1
    local roll = math.random()
    local cumulative = 0
    for _, key in ipairs(candidates) do
        cumulative = cumulative + module.CUSTOM_SPELLS[key].weight * scale
        if roll < cumulative then return key end
    end
    return nil
end

-- Which custom spells an NPC taking part in the distribution gets, as a list of keys. 'npc' describes it: level and
-- characterType (enums.CHARACTER_TYPE). For testing, the "luamercy" console command gives specific spells instead
-- (ignoring these limits).
function module.rollCustomSpells(npc)
    local picked = {}
    local function pickFrom(bundle)
        local key = pickFromBundle(bundle, picked, npc)
        module.log("Bundle", bundle, "gave", key or "nothing")
        if key then picked[#picked + 1] = key end
    end
    local exotic = math.random() < module.EXOTIC_BUNDLE_CHANCE
    -- No exotic spell this NPC can get (level, caster or ranged limits): a successful exotic roll counts as normal
    if exotic and #bundleCandidates("exotic", picked, npc) == 0 then
        module.log("No exotic spells for this NPC, rolling normal instead")
        exotic = false
    end
    if math.random() < module.MAGIC_AND_EXOTIC_COMBO_CHANCE then
        pickFrom("normal")
        if exotic then pickFrom("exotic") end
    else
        pickFrom(exotic and "exotic" or "normal")
    end
    if math.random() < module.AUX_BUNDLE_CHANCE then pickFrom("aux") end
    return picked
end

return module
