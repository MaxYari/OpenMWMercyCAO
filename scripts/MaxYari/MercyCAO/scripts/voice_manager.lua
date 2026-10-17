-- All available vanilla dialog voice record types:
-- Alarm
-- Attack
-- Flee
-- Hello
-- Hit
-- Idle
-- Intruder
-- Thief

local gutils = require(mp .. "scripts/gutils")
local customVoiceRecords = require(mp .. "scripts/custom_voice_records")

local types = require("openmw.types")
local core = require("openmw.core")
local omwself = require("openmw.self")
local storage = require("openmw.storage")

local soundSettings = storage.globalSection('MercyCAOAudioSettings')
local useAIVoicelines = soundSettings:get("AIVoicelines")
local showSubtitles = soundSettings:get("ShowSubtitles")

local module = {}

-- The voice_disable config section (record and cell id maps), arrives from Global with Mercy's startup data
local voiceBlacklist = nil

module.setBlacklist = function(blist)
    voiceBlacklist = blist
end

-- Whether this NPC is in werewolf form, set by ImprovedAI once on combat start
local speakerIsWerewolf = false

module.setWerewolf = function(isWerewolf)
    speakerIsWerewolf = isWerewolf
end

-- Other mods' voice records (see the README), merged into custom_voice_records' own. A voice type it doesn't have yet
-- is added.
local addVoiceRecords = function(records)
    for recordType, recs in pairs(records) do
        customVoiceRecords.records[recordType] = customVoiceRecords.records[recordType] or {}
        for _, record in ipairs(recs) do
            table.insert(customVoiceRecords.records[recordType], record)
        end
    end
end

module.addVoiceRecords = addVoiceRecords

local function noSpecificFilters(info)
    -- I probably can check the disposition as well for the "filterActorDisposition"
    local specificFilters = { "filterActorClass", "filterActorFaction", "filterPlayerCell", "filterPlayerFaction",
        "isQuestFinished", "isQuestName", "isQuestRestart", "questStage" }
    local noFilters = true
    for _, filter in ipairs(specificFilters) do
        if info[filter] then
            noFilters = false
            break
        end
    end
    return noFilters
end

local function beastCheck(info, isBeast)
    -- Author: Mostly ChatGPT 2024
    local fileName = info.sound:match("[^/]+$")
    return isBeast or not fileName:match("^b")
end

local function vampireCheck(info, isVampire)
    return isVampire or not string.find(info.sound,"/vo/v/")
end

local CONDITION_TYPE = core.dialogue.CONDITION_TYPE
local CONDITION_OPERATOR = core.dialogue.CONDITION_OPERATOR

local function compare(operator, a, b)
    if operator == CONDITION_OPERATOR.Equal then return a == b end
    if operator == CONDITION_OPERATOR.NotEqual then return a ~= b end
    if operator == CONDITION_OPERATOR.Greater then return a > b end
    if operator == CONDITION_OPERATOR.GreaterEqual then return a >= b end
    if operator == CONDITION_OPERATOR.Less then return a < b end
    if operator == CONDITION_OPERATOR.LessEqual then return a <= b end
    return false
end

-- The Werewolf condition, which Bloodmoon puts on its werewolf growls: whether a line's Werewolf conditions all pass
-- for the speaker, and whether it has any
local function werewolfCheck(info, isWerewolf)
    local value = isWerewolf and 1 or 0
    local hasCondition = false
    for _, condition in ipairs(info.conditions) do
        if condition.type == CONDITION_TYPE.Werewolf then
            if not compare(condition.operator, value, condition.value) then return false, true end
            hasCondition = true
        end
    end
    return true, hasCondition
end

-- Voice type -> the vanilla lines that fit this NPC, gathered on first use. Kept apart by werewolf form and vampirism,
-- the only things filtered on that can change.
local vanillaInfos = {}

local function findRelevantInfos(recordType, race, gender, isWerewolf, isVampire)
    local key = recordType .. (isWerewolf and "|werewolf" or "") .. (isVampire and "|vampire" or "")
    local fittingInfos = vanillaInfos[key]
    if fittingInfos then return fittingInfos end
    fittingInfos = {}
    vanillaInfos[key] = fittingInfos
    local records = core.dialogue.voice.records[recordType]
    if not records then return fittingInfos end

    --print("Looking for ", recordType, " voice record type")

    for _, voiceInfo in pairs(records.infos) do
        -- TO DO: Probably should not check for omwself here in the future. This function kind of suppose to work on any actor, not only on self. For now it works only on self anyway though.
        if voiceInfo.sound and (not voiceInfo.filterActorId or voiceInfo.filterActorId == omwself.recordId) and noSpecificFilters(voiceInfo) then
            local fits = false
            if isWerewolf then
                -- Only lines meant for werewolves (Bloodmoon's growls), these have no race or gender of their own
                if (not voiceInfo.filterActorRace or voiceInfo.filterActorRace == race)
                    and (not voiceInfo.filterActorGender or voiceInfo.filterActorGender == gender) then
                    local passes, hasCondition = werewolfCheck(voiceInfo, true)
                    fits = passes and hasCondition
                end
            else
                fits = voiceInfo.filterActorRace == race and voiceInfo.filterActorGender == gender
                    and beastCheck(voiceInfo, isWerewolf) and vampireCheck(voiceInfo, isVampire)
                    and werewolfCheck(voiceInfo, false)
            end
            if fits then
                --print(gutils.dialogRecordInfoToString(voiceInfo))
                table.insert(fittingInfos, voiceInfo)
            end
        end
    end

    return fittingInfos
end

-- The speaker's race and gender, read on its first line (Mercy's NPCs only ever voice themselves)
local speakerRace = nil
local speakerGender = nil

local lastPickedIndices = {}


local function say(actor, targetActor, recordType, force)
    if not actor then
        error("Say was called without an actor")
    end
    -- Cell is checked on every line, the actor may have walked into or out of a listed cell since Mercy started
    if voiceBlacklist and (voiceBlacklist.recordIdsMap[actor.recordId] or (actor.cell and voiceBlacklist.cellIdsMap[actor.cell.id])) then
        return false
    end
    -- Debug: Mercy's own voice lines (a combat line with no such log entry came from the engine)
    require("scripts/MaxYari/MercyCAO/scripts/magic_util").log("Mercy voice line:", recordType, force and "(forced)" or "")

    if not types.NPC.objectIsInstance(actor) or types.Actor.isDead(actor) then return false end
    if not force and core.sound.isSayActive(actor) then return false end

    if not speakerRace then
        local npc = types.NPC.record(actor)
        speakerRace = npc.race
        speakerGender = npc.isMale and "male" or "female"
    end
    local race = speakerRace
    local gender = speakerGender
    local isWerewolf = speakerIsWerewolf
    -- A werewolf can't be a vampire as well
    local isVampire = not isWerewolf and gutils.Actor:new(actor):isVampire()
    local targetGender = nil

    if targetActor and types.NPC.objectIsInstance(targetActor) then
        if not types.NPC.record(targetActor).isMale then
            targetGender = "female"
        else
            targetGender = "male"
        end
    end

    local fittingInfos = {}
    -- Werewolf lines are vanilla growls rather than AI voices, so a werewolf gets them whatever the setting
    if useAIVoicelines or isWerewolf then
        fittingInfos = customVoiceRecords.findRelevantInfos(recordType, race, gender, isWerewolf)
    end
    if #fittingInfos == 0 then fittingInfos = findRelevantInfos(recordType, race, gender, isWerewolf, isVampire) end

    -- Pick random voice file ensuring that same line doesnt repeat twice
    -- print("Fitting amount of voicelines: ", #fittingInfos)
    local lastPickedIndex = lastPickedIndices[recordType]
    local availableIndices = {}
    for i, info in ipairs(fittingInfos) do
        local wrongGender = info.targetGender and info.targetGender ~= targetGender
        local justPlayed = i == lastPickedIndex and #fittingInfos > 1

        if not wrongGender and not justPlayed then table.insert(availableIndices, i) end
    end

    if #availableIndices == 0 then
        gutils.print(
            "WARNING: No voice records of type " ..
            recordType ..
            " were found to fit " .. tostring(race) .. " " .. tostring(gender) .. " character.", 1)
        -- Not saying is not that bad, just ignore it
        return false
    end

    -- Do something if available
    local pickedIndex = availableIndices[math.random(1, #availableIndices)]
    lastPickedIndices[recordType] = pickedIndex

    local voiceInfo = fittingInfos[pickedIndex]


    -- Finally say it!
    --print("Voiceline to use: ", voiceInfo.sound, voiceInfo.text, tostring(voiceInfo.filterActorId),voiceInfo.id)
    -- core.sound.say(voiceInfo.sound, actor, voiceInfo.text)
    -- say doesnt respect the subtitle setting for some reason, so rather force no subtitles here, since most of the voice lines have none anyway.
    if showSubtitles and voiceInfo.text and voiceInfo.text ~= "" then
        core.sound.say(voiceInfo.sound, actor, voiceInfo.text)
    else
        core.sound.say(voiceInfo.sound, actor)
    end
    return true
end

module.say = say

return module
