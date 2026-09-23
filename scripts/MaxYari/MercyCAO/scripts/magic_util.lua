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
module.DEBUG_LOGGING = false

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

-- Magic worth a Dispel when an enemy has it: things an NPC could plausibly SEE on its enemy. Resistances, spell
-- absorption, reflect and the fortify effects are left out on purpose - they are stronger to strip, but the NPC has
-- no way of knowing they're there, and stripping them would be reading the player's sheet.
-- Note the engine's Dispel only removes temporary, normal-spell effects (not potions, enchantments, abilities or
-- powers), and it removes whole spells at once, so this list is only used to decide whether casting is worth it.
module.DISPEL_WORTHY_EFFECTS = toSet({
    -- Shields, the glow is visible
    "Shield", "FireShield", "LightningShield", "FrostShield",
    -- Concealment
    "Invisibility", "Chameleon", "Sanctuary",
    -- Mobility
    "Levitate", "SlowFall",
    -- Conjured gear
    "BoundDagger", "BoundLongsword", "BoundMace", "BoundBattleAxe", "BoundSpear", "BoundLongbow",
    "BoundCuirass", "BoundHelm", "BoundBoots", "BoundShield", "BoundGloves",
    -- Summons: dispelling the summoner unsummons them
    "SummonScamp", "SummonClannfear", "SummonDaedroth", "SummonDremora", "SummonAncestralGhost",
    "SummonSkeletalMinion", "SummonBonewalker", "SummonGreaterBonewalker", "SummonBonelord",
    "SummonWingedTwilight", "SummonHunger", "SummonGoldenSaint", "SummonFlameAtronach",
    "SummonFrostAtronach", "SummonStormAtronach", "SummonCenturionSphere", "SummonFabricant",
    "SummonWolf", "SummonBear", "SummonBonewolf", "SummonCreature04", "SummonCreature05",
})

-- An effect with this little time left isn't worth a cast (the engine's own Dispel rating uses the same cut-off, on
-- the total duration)
local DISPEL_MIN_REMAINING = 3

-- How many of the target's spells a Dispel would be worth removing. Counts whole spells rather than effects, because
-- one Dispel roll removes a whole spell: an enemy carrying a single five-effect buff is one spell's worth, not five.
-- Only counts what Dispel can actually take: temporary effects from normal spells (activeSpell.temporary rules out
-- abilities, powers, diseases and constant effects; fromEquipment rules out worn enchantments).
function module.dispelWorthyCount(target)
    local count = 0
    for _, activeSpell in pairs(types.Actor.activeSpells(target)) do
        if activeSpell.temporary and not activeSpell.fromEquipment then
            local record = core.magic.spells.records[activeSpell.id]
            if record and record.type == core.magic.SPELL_TYPE.Spell then
                for _, effect in pairs(activeSpell.effects) do
                    if module.DISPEL_WORTHY_EFFECTS[string.lower(effect.id)]
                        and (effect.durationLeft or 0) > DISPEL_MIN_REMAINING then
                        count = count + 1
                        break
                    end
                end
            end
        end
    end
    return count
end

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

-- The target has this spell active on it, cast by 'caster'. Ids are compared case insensitively: the engine hands
-- record ids back in whatever case it stored them, and a mismatch here used to read as a miss (which lifts the
-- spell's cooldown, so the spell came straight back).
function module.hasActiveSpellFrom(target, spellId, caster)
    local wanted = string.lower(spellId)
    for _, activeSpell in pairs(types.Actor.activeSpells(target)) do
        if string.lower(activeSpell.id) == wanted and activeSpell.caster == caster then return true end
    end
    return false
end

-- The target has this spell active on it whoever cast it. Used as a fallback when checking whether a cast landed:
-- the caster reference can be missing (a reflected or absorbed spell, a projectile the engine re-sourced), and
-- treating that as a miss lifts the cooldown and makes the NPC spam the spell.
function module.hasActiveSpell(target, spellId)
    local wanted = string.lower(spellId)
    for _, activeSpell in pairs(types.Actor.activeSpells(target)) do
        if string.lower(activeSpell.id) == wanted then return true end
    end
    return false
end

-- The engine or Mercy is casting (or readying spells)
function module.isCasting(actor)
    return animationOk and animation.isPlaying(actor, "spellcast")
end

-- OSSC ---------------------------------------------------------------------------------------------------------
-- Oblivion-Style Spell Casting. Whether it's installed is fixed for the session, but its per-actor caster script
-- isn't: OSSC attaches it on its own combat event (a moment after a fight starts) and detaches it after, so decisions
-- go by osscInstalled() and the per-actor interface is looked up each time it's used.
local interfacesOk, interfaces = pcall(require, 'openmw.interfaces')
local util = require('openmw.util')

local OSSC_CONTENT_FILE = "Oblivion Style Spell Casting OSSC.omwscripts"
local osscInstalled = nil
function module.osscInstalled()
    if osscInstalled == nil then osscInstalled = core.contentFiles.has(OSSC_CONTENT_FILE) end
    return osscInstalled
end

function module.osscCaster()
    local caster = interfacesOk and interfaces.OSSC_Caster
    if caster and type(caster.castSpellAtTarget) == "function" then return caster end
    return nil
end

-- Cast through OSSC: it works out the direction to the target itself and hands the spell to Spell Framework Plus, out
-- of any stance - no stance switch, no aiming, no use press. The spell is launched from its record, so it doesn't
-- matter that OSSC strips spells from the actor's list while it runs the actor's casting.
-- With OSSC's caster script on this actor the cast goes through it (it pays the magicka) and a refusal comes back as
-- ok=false. Without it (not attached yet at the start of a fight) OSSC's global route casts for any actor, with
-- Spell Framework Plus charging the magicka, but it can't answer: the cast counts as sent, and one that never
-- happened shows up as a miss. Returns ok, reason.
function module.osscCast(spellId, target)
    local caster = module.osscCaster()
    if caster then return caster.castSpellAtTarget({ spellId = spellId, target = target }) end
    local halfHeight = types.Actor.getPathfindingAgentBounds(omwself).halfExtents.z
    core.sendGlobalEvent("OSSC_CastSpellAtTarget", {
        caster = omwself.object, spellId = spellId, target = target,
        -- The global route starts at the caster's feet by default: chest height and a step ahead instead, as OSSC's
        -- own casts do
        startPos = omwself.position + util.vector3(0, 0, halfHeight * 1.5), spawnOffset = 80,
    })
    return true
end

-- Hold or release OSSC's own quick-casting for this actor. Mercy holds it under its own reason, so a hold another
-- mod is keeping isn't released by Mercy letting go of its own.
local osscPaused = false

-- At the start of a fight: let go of any hold left from the last one and forget it. Mercy only updates the hold during
-- a fight, so one it held when the last fight ended would otherwise read as still in place - while OSSC may have
-- attached a fresh, unheld caster script since, or kept the old one with Mercy's hold still on it.
function module.osscResetHold()
    local caster = module.osscCaster()
    if caster then caster.unpause("MercyCAO") end
    osscPaused = false
end

function module.osscSetPaused(paused)
    local caster = module.osscCaster()
    if not caster then
        -- OSSC detaches its caster script when a fight ends and attaches a fresh one for the next. That one starts
        -- with no holds, so forget ours rather than leaving it thinking the hold is still in place.
        osscPaused = false
        return
    end
    if paused == osscPaused then return end
    if paused then caster.pause("MercyCAO") else caster.unpause("MercyCAO") end
    osscPaused = paused
    module.log("OSSC quick-casting", paused and "held" or "released")
end

-- Custom spells ---------------------------------------------------------------------------------------------------
-- Mercy's own spells, each in its own file in scripts/spells. The global script creates a record for each once per game
-- (records are saved with the game)
-- and again whenever its 'version' changes; bump 'version' after changing a record. Spellcasters (by class) get some of
-- them on their first fight, and some other NPCs too, becoming spellcasters (see rollCustomSpells); they swap to newer
-- records later.
--
-- A custom spell goes on its cooldown ('cooldown', or CUSTOM_SPELL_DEFAULT_COOLDOWN) when cast. A miss (a target spell
-- not landing within the main loop's hit window) lifts the cooldown, unless it's CUSTOM_SPELL_MISSES_BEFORE_COOLDOWN
-- misses in a row. Self spells always count as landed. 'prewarm' keeps a spell unused for that many seconds after a
-- fight starts.
--
-- The engine's AI rates most of these effects 0 and doesn't cast them on its own (Skeleton Jail's Detect Animal
-- stand-in included). Exceptions, which it can cast by itself in an engine window when OSSC isn't installed: Blind (Veil
-- of Darkness), Drain Attribute (Levitate Bolt) and Dispel (Unweaving).
module.CUSTOM_SPELL_DEFAULT_COOLDOWN = 20
module.CUSTOM_SPELL_MISSES_BEFORE_COOLDOWN = 2

-- Distribution: whether an NPC takes part at all is rolled by the NPC script, with separate settings for spellcasters by
-- class and for other NPCs (see rollCustomSpells). A taking part NPC rolls the exotic bundle (EXOTIC_BUNDLE_CHANCE). With
-- MAGIC_AND_EXOTIC_COMBO_CHANCE it gets a spell from the normal bundle, plus one from the exotic bundle if that roll
-- succeeded; otherwise it gets a spell from the exotic bundle if that roll succeeded, or else from the normal bundle. An
-- exotic roll counts as failed when the NPC can't get any exotic spell.
-- Then one from the aux bundle (AUX_BUNDLE_CHANCE), and one from the counterspell bundle (COUNTER_BUNDLE_CHANCE), each
-- rolled on its own. Within a bundle a spell is picked by
-- 'weight': weights summing above 1 are scaled down to 1, below 1 the rest is the chance of picking nothing. A spell isn't
-- picked if the NPC is below its 'minLevel', if the NPC's character type isn't among its 'character_type', if a spell in
-- its 'incompatibleWith' list is already picked, or if its 'available' function says it can't be used in this game (e.g.
-- a mod it needs isn't installed).
module.EXOTIC_BUNDLE_CHANCE = 0.33
module.MAGIC_AND_EXOTIC_COMBO_CHANCE = 0.25
module.AUX_BUNDLE_CHANCE = 0.33
-- The counterspell bundle is rolled separately from the rest, see rollCustomSpells
module.COUNTER_BUNDLE_CHANCE = 0.33
-- Spellcasters of this level and above roll the normal / exotic spells twice (aux still once)
module.EXTRA_SPELL_ROLL_LEVEL = 16 -- (when npc.extraSpellRolls, from the settings)

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
local function isPicked(key, picked)
    for _, pickedKey in ipairs(picked) do
        if pickedKey == key then return true end
    end
    return false
end

local function bundleCandidates(bundle, picked, npc)
    local candidates, totalWeight = {}, 0
    for _, key in ipairs(sortedKeys(module.CUSTOM_SPELLS)) do
        local spell = module.CUSTOM_SPELLS[key]
        if spell.bundle == bundle and npc.level >= (spell.minLevel or 0) and module.isForCharacter(key, npc.characterType)
            and module.isAvailable(key)
            and not isPicked(key, picked) and not isIncompatible(spell, picked) then
            candidates[#candidates + 1] = key
            totalWeight = totalWeight + spell.weight
        end
    end
    return candidates, totalWeight
end

local function pickFromBundle(bundle, picked, npc)
    local candidates, totalWeight = bundleCandidates(bundle, picked, npc)
    local scale = totalWeight > 1 and 1 / totalWeight or 1
    local roll = npc.rng()
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
    -- Every roll goes through npc.rng, which the NPC script seeds from its record id, so an NPC's spells are the same
    -- in every playthrough, the way its inclinations are. Falls back to the global roller if a caller passes none.
    npc.rng = npc.rng or math.random
    local picked = {}
    local function pickFrom(bundle)
        local key = pickFromBundle(bundle, picked, npc)
        module.log("Bundle", bundle, "gave", key or "nothing")
        if key then picked[#picked + 1] = key end
    end
    -- Experienced spellcasters roll the normal / exotic spells twice
    local rolls = 1
    if npc.extraSpellRolls and npc.characterType == "Spellcaster" and npc.level >= module.EXTRA_SPELL_ROLL_LEVEL then
        rolls = 2
    end
    for _ = 1, rolls do
        local exotic = npc.rng() < module.EXOTIC_BUNDLE_CHANCE
        -- No exotic spell this NPC can get (level, caster or ranged limits, or all picked): the roll counts as normal
        if exotic and #bundleCandidates("exotic", picked, npc) == 0 then
            module.log("No exotic spells for this NPC, rolling normal instead")
            exotic = false
        end
        if npc.rng() < module.MAGIC_AND_EXOTIC_COMBO_CHANCE then
            pickFrom("normal")
            if exotic then pickFrom("exotic") end
        else
            pickFrom(exotic and "exotic" or "normal")
        end
    end
    if npc.rng() < module.AUX_BUNDLE_CHANCE then pickFrom("aux") end
    -- Counterspells are rolled on their own, so an NPC can get one whatever else it ended up with
    if npc.rng() < module.COUNTER_BUNDLE_CHANCE then pickFrom("counter") end
    return picked
end

return module
