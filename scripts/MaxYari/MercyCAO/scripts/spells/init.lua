-- Mercy's custom spells, one file each: every .lua file right in this folder is a spell (this one aside). Other mods add
-- spells by putting their file here too, under a name of their own (e.g. "<mod>_<spell>.lua") so two mods don't replace
-- each other's. Subfolders aren't loaded: helpers shared by spells live in lib/, spells not in use in ../spells_unused.
--
-- A spell is either Mercy's own, made from 'record', or an existing spell record (e.g. another mod's) cast as it is,
-- named by 'recordId'. Both go through Mercy's distribution, cooldowns and magicka checks the same way. A spell with no
-- branch of its own in the tree's Spells subtree gets one made from 'cast' (see addSpellBranches in ImprovedAIGlobal).
--
-- A spell that can't work in this game is left out here, before anything can roll or create it: a 'recordId' that
-- doesn't exist, an effect in 'record' that doesn't exist (e.g. a custom effect from a mod that isn't installed), or
-- available() saying no. So is a file that fails to load, or has a mistake that would break Mercy for every NPC (an
-- invalid record, a 'cast' condition that doesn't compile, a bundle without a weight). What was left out and why goes
-- to 'skipped', which the global script logs.
--
-- Fields a spell file returns:
--   key            Unique name, used by the tree ($:canCastCustom("key")) and the "luamercy" console command
--   record         Spell record fields for core.magic.spells.createRecordDraft. The global script creates the record.
--   recordId       Instead of 'record': the id of an existing spell record, cast unchanged (its own cost and effects).
--                  An NPC that knew it already keeps it when Mercy takes its spells back.
--   version        Bump after changing 'record', so saved games get the new record (not used with 'recordId')
--   bundle         "normal", "exotic" or "counter", see magic_util.rollCustomSpells. Without one the spell is only given
--                  through the console.
--   weight         Pick weight within the bundle, needed with a bundle
--   minLevel       Lowest NPC level that can get the spell from the distribution (optional)
--   playerTargetOnly  Only ever cast at the player, not at NPCs or creatures (optional)
--   character_type Which character types get it from the distribution: CHARACTER_TYPE.All, or a list such as
--                  { CHARACTER_TYPE.Spellcaster, CHARACTER_TYPE.Marksman } (see enums.lua)
--   cooldown       Seconds (optional, magic_util.CUSTOM_SPELL_DEFAULT_COOLDOWN otherwise)
--   prewarm        Seconds a spell stays unused after a fight starts (optional)
--   available()    Whether the spell can be used in this game, e.g. a mod it needs is installed (optional). Missing
--                  records and effects are already checked, see above.
--   incompatibleWith  Keys of spells this one isn't picked together with (optional)
--   cast           How the tree casts a spell that has no branch of its own (optional, every part has a default):
--                    condition  Checked after $:canCastCustom("key"), written like the conditions in OpenMW AI.b3.
--                               Default "$range < 2000 and $:enemyInLineOfSight()".
--                    period     { min, max } seconds between tries, default { 4, 7 }
--                    aim        Turn and pitch at the enemy before casting, default true. false for self spells.
--   osscUserData   Optional, a table handed to Spell Framework Plus as the cast's userData when Mercy casts through OSSC,
--                  e.g. { suppressImpactVfx = true }
--   onCast(caster, target, state)  Optional, runs in the caster's local script when Mercy releases the spell
--   landed(caster, target, state)  Optional, replaces the usual hit check (the spell showing up among the target's
--                                  active spells) for a target spell that leaves nothing there to find, e.g. an
--                                  instant effect; checked every frame of the hit window, returns true once it landed
--   onHit(caster, target, state)   Optional, runs in the caster's local script when a target spell is seen landing
--                                  'state' is the caster's behaviour tree state: setting state.combatState switches it
--                                  to another behaviour, e.g. RETREAT or HIDE
--   combatUpdate(state)            Optional, runs every combat frame in the local script of an actor knowing the spell;
--                                  keep it cheap, return right away when there's nothing to do
--   localEventHandlers      Optional, { eventName = function(state, data) } added to the caster's local script
--   targetEventHandlers     Optional, { eventName = function(data) } added to every NPC's and the player's local script
--   playerFrame()           Optional, runs every frame in the player script (after the built-in controls); keep it cheap
--   global         Optional global script side: eventHandlers, onUpdate(), onSave() and onLoad(data)
-- Spell files are loaded by both local and global scripts, so they require context specific packages (openmw.world,
-- openmw.nearby and so on) inside their functions only.
local core = require('openmw.core')
local vfs = require('openmw.vfs')

-- Lower case, as vfs lists paths
local SPELLS_FOLDER = "scripts/maxyari/mercycao/scripts/spells/"

local spells = {}
local skipped = {}
local fileByKey = {}

local function exists(records, id)
    local ok, record = pcall(function() return records[id] end)
    return ok and record ~= nil
end

-- What's wrong with a spell's 'cast', nil when nothing. Its condition is compiled here the way the tree's parser does it
-- (behavior3_parser.lua, ParsePropertyValue): one that doesn't compile would fail building the tree for every NPC.
local function castProblem(cast)
    if cast == nil then return nil end
    if type(cast) ~= "table" then return "'cast' isn't a table" end
    if cast.period ~= nil and (type(cast.period) ~= "table" or type(cast.period[1]) ~= "number"
            or type(cast.period[2]) ~= "number") then
        return "'cast.period' isn't { min, max } seconds"
    end
    if cast.condition ~= nil then
        if type(cast.condition) ~= "string" then return "'cast.condition' isn't a string" end
        local code = cast.condition:gsub("%$:", "_s:"):gsub("%$%.", "_s."):gsub("%$(%a)", "_s.%1")
        local ok, err = pcall(require('openmw.util').loadCode, "return " .. code, {})
        if not ok then return "'cast.condition' doesn't compile: " .. tostring(err) end
    end
    return nil
end

-- Why a loaded spell file can't be used in this game, nil when it can
local function unusableReason(spell)
    if type(spell) ~= "table" or type(spell.key) ~= "string" then return "doesn't return a spell with a key" end
    if fileByKey[spell.key] then return "key " .. spell.key .. " is already taken by " .. fileByKey[spell.key] end
    if spell.bundle ~= nil and type(spell.weight) ~= "number" then return "has a bundle but no weight" end
    local problem = castProblem(spell.cast)
    if problem then return problem end
    if spell.recordId then
        if not exists(core.magic.spells.records, spell.recordId) then
            return "spell record " .. tostring(spell.recordId) .. " doesn't exist"
        end
    elseif type(spell.record) == "table" then
        for _, effect in ipairs(spell.record.effects or {}) do
            if not exists(core.magic.effects.records, effect.id) then
                return "magic effect " .. tostring(effect.id) .. " doesn't exist"
            end
        end
        -- Anything else wrong with the record (its type, an effect's range...) would stop the global script creating it
        local ok, err = pcall(core.magic.spells.createRecordDraft, spell.record)
        if not ok then return "its record is invalid: " .. tostring(err) end
    else
        return "has neither record nor recordId"
    end
    if spell.available then
        local ok, available = pcall(spell.available)
        if not ok then return "available() failed: " .. tostring(available) end
        if not available then return "available() says it can't be used in this game" end
    end
    return nil
end

for path in vfs.pathsWithPrefix(SPELLS_FOLDER) do
    local file = path:sub(#SPELLS_FOLDER + 1)
    if file:match("^[^/]+%.lua$") and file ~= "init.lua" then
        local ok, spell = pcall(require, path:sub(1, -5))
        local reason = nil
        if ok then reason = unusableReason(spell) else reason = "failed to load: " .. tostring(spell) end
        if reason then
            skipped[#skipped + 1] = { file = file, reason = reason }
        else
            fileByKey[spell.key] = file
            spells[#spells + 1] = spell
        end
    end
end

return { spells = spells, skipped = skipped }
