local ATTACK_STATE = {
    NO_STATE = 0,
    WINDUP_START = 1,
    WINDUP_MIN = 2,
    WINDUP_MAX = 3,
    RELEASE_START = 4,
    RELEASE_HIT = 5,
    FOLLOW_START = 6
}

local COMBAT_STATE = {
    NO_STATE = "NO_STATE",
    STAND_GROUND = "STAND_GROUND",
    FIGHT = "FIGHT",
    RETREAT = "RETREAT",
    MERCY = "MERCY",
    -- Runs off to a hiding spot and sneaks there until found out, then fights. Entered from other states' behaviours.
    HIDE = "HIDE"
}

-- What kind of character an NPC is, e.g. for who gets which of Mercy's custom spells. All matches any of them.
local CHARACTER_TYPE = {
    Spellcaster = "Spellcaster", -- A spellcaster by class (gutils Actor:isSpellCaster)
    Marksman = "Marksman",       -- Not a spellcaster by class, carries a marksman weapon
    Melee = "Melee",             -- Not a spellcaster by class, no marksman weapon
    All = "All"
}

return {
    ATTACK_STATE = ATTACK_STATE,
    COMBAT_STATE = COMBAT_STATE,
    CHARACTER_TYPE = CHARACTER_TYPE
}
