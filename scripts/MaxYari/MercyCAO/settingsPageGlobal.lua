local storage = require('openmw.storage')
local I = require('openmw.interfaces')

-- A settings-less group, only a warning shown between the general settings (above) and the behaviour ones (below)
I.Settings.registerGroup {
    key = 'SettingsMercyCAOSpoilerWarning',
    page = 'MercyCAOPage',
    l10n = 'MercyCAO',
    name = '!!! WARNING: READ THIS BEFORE SCROLLING DOWN !!!',
    order = 2,
    permanentStorage = true,
    description = "Below you can adjust the probabilities of many of Mercy's behaviours and spells, but their names and descriptions are spoilers: they tell you what NPCs can do.\n\nI STRONGLY recommend to just play the mod first and have a sense of wonder.",
    settings = {},
}

I.Settings.registerGroup {
    key = 'SettingsMercyCAOBehavior',
    page = 'MercyCAOPage',
    l10n = 'MercyCAO',
    name = 'Behavior Modifiers',
    order = 3,
    permanentStorage = true,
    description = "'Modifier' Values below function as probability multipliers and have no upper limit, set them to an arbitrary high value (e.g 10000) if you want to force the corresponding behaviour to always appear.",
    settings = {
        {
            key = 'StandGroundProbModifier',
            renderer = 'number',
            default = 1,
            argument = {
                min = 0,
                max = 100000,
            },
            name = 'Stand Back Modifier',
            description = 'Higher values make NPC more likely to hesitate and warn the player before engaging in combat.',
        },
        {
            key = 'CombatIntensity',
            renderer = 'number',
            default = 1,
            argument = {
                min = 0.1,
                max = 10,
            },
            name = 'Combat Intensity',
            description = 'How hard NPCs press an attack. Above 1 they pause and hang back less, close the distance more and attack more often; below 1 they are more careful. 1 is the default balance. Takes effect on a save reload.',
        },
        {
            key = 'InvestigateProb',
            renderer = 'number',
            default = 0.4,
            argument = {
                min = 0,
                max = 1,
            },
            name = 'Come Looking Probability',
            description = 'A probability (in 0 - 1 range) that an NPC who warned the player and then lost sight of them will come to where they last saw the player to look around.',
        },
        {
            key = 'HideModifier',
            renderer = 'number',
            default = 1,
            argument = {
                min = 0,
            },
            name = 'Hide Modifier',
            description = 'Scales every chance of an NPC running off to hide until found out: after turning invisible (rather than repositioning around the player), when retreating (rather than retreating towards friends) and after blinking the player out of sight. 0 disables hiding, higher values make it more likely.',
        },
        {
            key = 'ScaredProbModifier',
            renderer = 'number',
            default = 1,
            argument = {
                min = 0,
                max = 100000,
            },
            name = 'Scared Modifier',
            description = 'Higher values make NPC more likely to ask for mercy on run away.',
        },
        {
            key = 'SurrenderHealthFraction',
            renderer = 'number',
            default = 0.33,
            argument = {
                min = 0,
                max = 1,
            },
            name = 'Scared Health Fraction',
            description = 'A fraction of total health (in 0 - 1 range) below which NPC will consider asking for mercy or running away.',
        },
        {
            key = 'CompanionMercyProb',
            renderer = 'number',
            default = 0.9,
            argument = {
                min = 0,
                max = 1,
            },
            name = 'Companion Mercy Probability',
            description = 'A probability (in 0 - 1 range) that a companion will show mercy to surrendering foes.',
        }
    },
}

I.Settings.registerGroup {
    key = 'SettingsMercyCAOMagic',
    page = 'MercyCAOPage',
    l10n = 'MercyCAO',
    name = 'Magic',
    order = 4,
    permanentStorage = true,
    settings = {
        {
            key = 'CasterCustomSpellsChance',
            renderer = 'number',
            default = 0.666,
            argument = {
                min = 0,
                max = 1,
            },
            name = 'Spellcaster Custom Spells Chance',
            description = 'A probability (in 0 - 1 range) that a spellcasting NPC gets Mercy\'s custom spell.',
        },
        {
            key = 'SpellcasterUpgradeChance',
            renderer = 'number',
            default = 0.1,
            argument = {
                min = 0,
                max = 1,
            },
            name = 'Non-Caster Custom Spells Chance',
            description = 'A probability (in 0 - 1 range) that an NPC who knows no spells still gets Mercy\'s custom spell.',
        },
        {
            key = 'ExtraSpellsForHighLevelCasters',
            renderer = 'checkbox',
            default = false,
            name = 'More Spells For Experienced Spellcasters',
            description = 'Spellcasters of level 16 and above roll for Mercy\'s custom spells twice, so they get more of them.',
        },
        {
            key = 'ManaPotionChance',
            renderer = 'number',
            default = 0.5,
            argument = {
                min = 0,
                max = 1,
            },
            name = 'Mana Potion Chance',
            description = 'A probability (in 0 - 1 range) of a spellcaster NPC receiving a level appropriate Restore Magicka potion for each success (up to 3 potions). They are only allowed to chug them at most once in 10 seconds.',
        },
        {
            key = 'ManaPotionLootChance',
            renderer = 'number',
            default = 0,
            argument = {
                min = 0,
                max = 1,
            },
            name = 'Mana Potion Loot Chance',
            description = 'The probability (0 - 1 range) that someone of the extra mana potions from the setting above will be lootable from the body.',
        },
    },
}

I.Settings.registerGroup {
    key = 'MercyCAOAudioSettings',
    page = 'MercyCAOPage',
    l10n = 'MercyCAO',
    name = 'Audio',    
    order = 1,
    permanentStorage = true,
    settings = {        
        {
            key = "AIVoicelines",
            renderer = "checkbox",
            default = true,
            name = "AI Voicelines",
            description = "Use AI-generated NPC combat voicelines?"
        },
        {
            key = "ShowSubtitles",
            renderer = "checkbox",
            default = false,
            name = "Subtitles",
            description = "Show subtitles for additional voicelines? Only few voicelines currently have configured subtitles, so even if this setting is activated - most voicelines won't have subtitles (but some will)."
        }
    },
}

return {
    
}
