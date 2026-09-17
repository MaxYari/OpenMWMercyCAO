-- Mercy's custom spells, one file each. To add a spell, add its file to this list. Fields a spell file returns:
--   key            Unique name, used by the tree ($:canCastCustom("key")) and the "luamercy" console command
--   version        Bump after changing 'record', so saved games get the new record
--   bundle         "normal", "aux" or "exotic", see magic_util.rollCustomSpells
--   weight         Pick weight within the bundle
--   minLevel       Lowest NPC level that can get the spell from the distribution (optional)
--   playerTargetOnly  Only ever cast at the player, not at NPCs or creatures (optional)
--   character_type Which character types get it from the distribution: CHARACTER_TYPE.All, or a list such as
--                  { CHARACTER_TYPE.Spellcaster, CHARACTER_TYPE.Marksman } (see enums.lua)
--   cooldown       Seconds (optional, magic_util.CUSTOM_SPELL_DEFAULT_COOLDOWN otherwise)
--   prewarm        Seconds a spell stays unused after a fight starts (optional)
--   available()    Whether the spell can be used in this game, e.g. a mod it needs is installed (optional)
--   incompatibleWith  Keys of spells this one isn't picked together with (optional)
--   record         Spell record fields for core.magic.spells.createRecordDraft
--   onCast(caster, target, state)  Optional, runs in the caster's local script when Mercy releases the spell
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
-- openmw.nearby and so on) inside their functions only. Shared helpers for spells, such as timed_objects.lua, live in
-- this folder too but aren't listed below.
local mp = "scripts/MaxYari/MercyCAO/"

return {
    require(mp .. "scripts/spells/levitate_bolt"),
    require(mp .. "scripts/spells/invisibility"),
    require(mp .. "scripts/spells/chameleon"),
    require(mp .. "scripts/spells/light_bearer"),
    require(mp .. "scripts/spells/speed_boost"),
    require(mp .. "scripts/spells/skeleton_jail"),
    require(mp .. "scripts/spells/blink"),
    require(mp .. "scripts/spells/pillow_shot"),
    require(mp .. "scripts/spells/blindness"),
    require(mp .. "scripts/spells/confusion"),
    -- Not in use: require(mp .. "scripts/spells/box_prison"),
}
