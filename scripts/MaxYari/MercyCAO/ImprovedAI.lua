mp = "scripts/MaxYari/MercyCAO/"

-- Mod files
local gutils = require(mp .. "scripts/gutils")
local moveutils = require(mp .. "scripts/movementutils")
local itemutil = require(mp .. "scripts/item_util")
local enums = require(mp .. "scripts/enums")
local animManager = require(mp .. "scripts/anim_manager")
local voiceManager = require(mp .. "scripts/voice_manager")
local EventsManager = require(mp .. "scripts/events_manager")

-- OpenMW libs
local omwself = require('openmw.self')
local selfActor = gutils.Actor:new(omwself)
local core = require('openmw.core')
local nearby = require("openmw.nearby")
local AI = require('openmw.interfaces').AI
local vfs = require('openmw.vfs')
local util = require('openmw.util')
local types = require('openmw.types')
local I = require('openmw.interfaces')

-- 3rd party libs
-- Setup important global functions for the behaviourtree 2e module to use--
_BehaviourTreeImports = {
   loadCodeInScope = util.loadCode,
   clock = core.getRealTime
}
local BT = require('scripts.behaviourtreelua2e.lib.behaviour_tree')
local json = require(mp .. "libs/json")
local luaRandom = require(mp .. "libs/randomlua")
----------------------------------------------------------------------------

--- To be or not to be!? ---
DebugLevel = 0
----------------------------

Events = EventsManager:new()

--- Init custom behaviour nodes
require(mp .. "scripts/behavior_nodes")

-- GSMTs
local fCombatDistance = core.getGMST("fCombatDistance")
local fHandToHandReach = core.getGMST("fHandToHandReach")

local NavigationService = require(mp .. "scripts/navservice")
local navService = NavigationService({
   cacheDuration = 1,
   targetPosDeadzone = 50,
   pathingDeadzone = 35
})


if core.API_REVISION < 64 then
   error(
      "Can not start Mercy: CAO, newer version of lua API is required. Please update OpenMW.")
end

-- Checking for some common placeholder npcs and not using mercy on them
if omwself.recordId == "ab01alsonar" then return end

-- And the story begins!
-- if omwself.recordId ~= "tanisie verethi" then return end
-- gutils.print(omwself.recordId .. ": Mercy: CAO BETA Improved AI is ON", 0)




-- State object is an object to which behavior tree has access
local state = {
   -- Persistent state fields
   COMBAT_STATE = enums.COMBAT_STATE,
   attackState = enums.ATTACK_STATE.NO_STATE,
   combatState = enums.COMBAT_STATE.NO_STATE,
   navService = navService,
   attackGroup = nil,
   staggerGroup = nil,
   dt = 0,
   reach = 140,
   locomotion = nil,
   engageRange = 600,
   slowSpeed = 10,

   -- Inclinations are used directly within a tree
   goHamHeat = 0,
   rootedAttackInc = 50,
   nearStopInc = 50,
   nearStrafeInc = 50,
   nearBackInc = 50,
   midStrafeInc = 50,
   midChaseInc = 50,
   midAttackInc = 50,
   midStopInc = 50,
   jumpInc = 0,
   zoomiesInc = 0,

   clear = function(self)
      -- Fields below will be reset every frame
      self.vanillaBehavior = false
      self.stance = types.Actor.STANCE.Weapon
      self.run = true
      self.jump = false
      self.attack = 0
      self.movement = 0
      self.sideMovement = 0
      self.lookDirection = nil
      self.range = 1e42
   end,

   -- Functions to be used in the editor
   r = function(min, max)
      if min == nil then
         return math.random()
      else
         return min + math.random() * (max - min)
      end
   end,
   rSlowSpeed = function(self)
      return gutils.lerp(self.slowSpeed, self.slowSpeed * 2, math.random())
   end,
   rint = function(m, n)
      return math.random(m, n)
   end,
   isHoldingAttack = function(self)
      return self.attackState == enums.ATTACK_STATE.WINDUP_MIN or self.attackState == enums.ATTACK_STATE.WINDUP_MAX
   end,
   attacksFromSkill = function(self)
      if not self.weaponSkill then return math.random(1, 2) end
      local skill = self.weaponSkill
      local n = 1
      if skill >= 75 then
         n = math.random(2, 4)
      elseif skill >= 50 then
         n = math.random(1, 3)
      else
         n = math.random(1, 2)
      end
      if self.inHamMode then n = n * 2 + 1 end
      return n
   end,
   attPauseFromSkill = function(self)
      if not self.weaponSkill then return 0 end

      local skill = self.weaponSkill
      local duration = util.clamp(util.remap(skill, 0, 75, 0.6, 0), 0, 0.6)
      if duration < 0 then duration = 0 end

      return duration
   end,
   CSIs = function(self, stateString)
      return self.combatState == self.COMBAT_STATE[stateString]
   end
}






-- Helper functions ---------------------------------------------------------------
-----------------------------------------------------------------------------------
local function randomiseInclinations()
   local standartInclinations = { "rootedAttackInc", "nearStopInc", "nearStrafeInc", "nearBackInc", "midStrafeInc",
      "midChaseInc", "midAttackInc", "midStopInc" }
   local weirdInclinations = { "jumpInc", "zoomiesInc" }

   state.slowSpeedFactor = luaRandom:random(0, 1)

   local spreadBracket = luaRandom:random()

   for _, param in ipairs(standartInclinations) do
      local possibleChange = { -1, 1 }
      local increment = 30
      state.randomisationStatus = "significant"
      if spreadBracket < 0.5 then
         state.randomisationStatus = "minor"
         increment = 15
         table.insert(possibleChange, 0)
      end
      local change = possibleChange[math.random(1, #possibleChange)]
      state[param] = util.clamp(state[param] + increment * change, 0, 100)
   end


   local weirdness = luaRandom:random()

   if weirdness >= 0.9 then
      state.weirdnessStatus = "oh, it's weird!"
      for _, param in ipairs(weirdInclinations) do
         if luaRandom:random() < 0.5 then
            state[param] = util.clamp(state[param] + 75, 0, 100) -- Increase by 75 or stay the same
         end
      end
   else
      state.weirdnessStatus = "completely normal, not weird at all."
   end

   local anger = luaRandom:random()
   if anger < CanGoHamProb then
      state.canGoHam = true
   end

   -- Print the modified state for verification
   -- gutils.print(gutils.tableToString(state))
end


-- Functions to determine if its time to retreat/ask for mercy
-- Function to interpolate probability based on level difference
local function levelBasedScaredProb()
   -- Author: Mostly ChatGPT 2024
   -- Directly assign numerical values for configuration
   local minLevelDif = -10
   local maxLevelDif = 10
   local minProb = 0.05
   local maxProb = 0.25

   -- Get levels
   local characterLevel = types.Actor.stats.level(omwself).current
   local enemyLevel = types.Actor.stats.level(state.enemyActor).current

   -- Calculate level difference
   local levelDifference = characterLevel - enemyLevel

   -- Clamp levelDifference within the min and max level range
   local clampedLevelDifference = util.clamp(levelDifference, minLevelDif, maxLevelDif)

   -- Normalize level difference within the range
   local normalizedLevelDifference = (clampedLevelDifference - minLevelDif) / (maxLevelDif - minLevelDif)

   -- Interpolate the probability
   local probability = gutils.lerp(minProb, maxProb, normalizedLevelDifference)

   return probability
end

-- Function to calculate if the character is scared
local function isSelfScared(damageValue)
   -- Author: Mostly ChatGPT 2024

   -- Get current health
   local baseHealth = selfActor.stats.dynamic:health().base
   local currentHealth = selfActor.stats.dynamic:health().current


   -- Proceed only if there was actual damage
   if damageValue > 0 then
      local healthFraction = currentHealth / baseHealth
      --print("DAMAGE VALUE", damageValue)
      --print("Health fraction", healthFraction)
      -- Check if health is below 33%
      if healthFraction < 0.33 then
         -- Determine base probability based on level difference
         local baseProbability = levelBasedScaredProb()

         -- Calculate the damage-based factor
         local damageFactor = damageValue / baseHealth

         -- Adjust the probability based on the damage factor
         local adjustedProbability = baseProbability * math.min(damageFactor / 0.05, 1)
         local adjustedProbability = adjustedProbability * ScaredProbModifier

         -- Roll a random number to determine if the character is scared
         local roll = math.random()

         -- If the roll is less than the adjusted probability, character is scared
         -- print("CHANCE TO GET SCARED:", adjustedProbability)
         if roll < adjustedProbability then
            return true
         end
      end
   end

   -- If no damage was taken, health is above 33%, or roll is higher than probability, character is not scared
   return false
end
----------------------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------------------





-- Initialising behaviour trees----------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------------------------------

-- Parsing JSON behaviourtree -----
gutils.print("Reading Behavior3 project", 2)
-- Read the behaviour tree JSON file exported from the editor---------------
local file = vfs.open("scripts/MaxYari/MercyCAO/OpenMW AI.b3")
if not file then error("Failed opening behaviour tree file.") end
-- Decode it
local projectJsonTable = json.decode(file:read("*a"))
-- And close it
file:close()
----------------------------------------------------------------------------


-- Handling extensions made by other mods ---------
local extensions = {}

local extensionWrapperNode = function(config)
   return BT.Task:new(config)
end

-- This function checks if an extension should be added to a node, and if so - adds it.
local function maybeInjectExtensions(node, treeName)
   if node.properties.extensionPoint and node.properties.extensionPoint() then
      if not node.childNodes then
         error(
            "Non-composite node is marked as an extension (extensionPoint property). This should never happen. If you are using an 'extensionPoint' property on your node - don't, it's reserved.")
      end
      local extensionPoint = node.properties.extensionPoint()
      local extensionUsed = false
      if extensions[treeName] and extensions[treeName][extensionPoint] then
         local extensionObjs = extensions[treeName][extensionPoint]
         for _, extensionObj in ipairs(extensionObjs) do
            extensionObj.isUsed = true
            gutils.print("Found an extension", extensionObj.name, "for an extension point", treeName, extensionPoint, 1)
            extensionUsed = true
            table.insert(node.childNodes, 1, extensionWrapperNode(extensionObj))
         end
      end
      -- Removing all the nodes that need to be removed upon extension
      if extensionUsed then
         for i = #node.childNodes, 1, -1 do
            local child = node.childNodes[i]
            if child.properties.delOnExtension and child.properties.delOnExtension() then
               table.remove(node.childNodes, i)
            end
         end
      end
   end
end

local function checkExtensionsWarning()
   -- Check if all extensions been used, shout warning if not
   for treeName, tagObj in pairs(extensions) do
      for tagName, extensionObjs in pairs(tagObj) do
         for _, extensionObj in ipairs(extensionObjs) do
            if not extensionObj.isUsed then
               gutils.print("WARNING: extension", extensionObj.name, "was not used since an extension point", treeName,
                  tagName,
                  "is no present in the behaviour tree. Make sure that you use the correct tree and extension point names.")
            end
         end
      end
   end
end


-- A function that will initialise all behavior trees on a first update. Done on a first update so other mods have a chance to provide extensions
-- via the interface
local bTrees = nil

local function STARTEVERYTHING()
   -- STARTING EVERYTHING -------------------
   -- Initialise behaviour trees ----------------------------------------------
   bTrees = BT.LoadBehavior3Project(projectJsonTable, state, function(nodeConfig, treeData)
      -- Inject extensions (child nodes) into parent node's initialisation data if need be
      maybeInjectExtensions(nodeConfig, treeData.title)
   end)

   checkExtensionsWarning()

   bTrees.Combat:setDebugLevel(0)
   bTrees.CombatAux:setDebugLevel(0)
   bTrees.Locomotion:setDebugLevel(0)
   -- Ready to use! -----------------------------------------------------------

   -- Rndomising key npc factors
   luaRandom:randomseed(gutils.stringToHash(omwself.recordId))
   randomiseInclinations()
end

----------------------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------------------

-- Interface ----------------------------------------------------------------
-----------------------------------------------------------------------------
local interface = {
   version = 1.2,
   enabled = true,
   state = state,
   addExtension = function(treeName, combatState, stance, extensionConfig)
      local extensionPoint = combatState .. "_" .. stance
      if not extensions[treeName] then extensions[treeName] = {} end
      if not extensions[treeName][extensionPoint] then extensions[treeName][extensionPoint] = {} end
      table.insert(extensions[treeName][extensionPoint], extensionConfig)
   end,
   setSpellCastersAreVanilla = function(state)
      if state == true then error("You are not allowed to set spellCastersAreVanilla to true, only to false.") end
      spellCastersAreVanilla = state
   end,
   addVoiceRecords = voiceManager.addVoiceRecords,
   Events = Events
}

-- Main Update Loop Below -----------------------------------------------------
-------------------------------------------------------------------------------

local spellCastersAreVanilla = true
local isSpellCaster = selfActor:isSpellCaster()

-- Defining variables used by the main update functions
StandGroundProbModifier = 1
ScaredProbModifier = 1
CanGoHamProb = 0.5
BaseFriendFightVal = 80
AvengeShoutProb = 0.5
MercyScaredOnFleeValProb = 0.33
MercyRetreatOnInvisProb = 0.5
-- TO DO: Comment this out for production
-- StandGroundProbModifier = 1e42
-- ScaredProbModifier = 1e42
-- CanGoHamProb = 1
-- BaseFriendFightVal = 30
-- AvengeShoutProb = 1
local notargetGracePeriod = 0.25
local notargetDetectedAt = nil
local lastWeaponRecord = { id = "_" }
local lastAiPackage = { type = nil }
local lastHealth = selfActor.stats.dynamic:health().current
local lastDeadState = nil
local lastGoHamCheck = 0
local retreatedOnce = false
local askedForMercyOnce = false
local stoodGroundOnce = false

local lastFleeValue = selfActor.stats.ai.flee().modified

local firstUpdate = true

-- Main update function (finally) --
------------------------------------
local function onUpdate(dt)
   -- Mercy is taking a rest if another mod disabled it
   if interface.enabled == false then return end

   if firstUpdate then
      STARTEVERYTHING()
      firstUpdate = false
   end

   -- Only modify AI if it's in combat!
   local activeAiPackage = AI.getActivePackage()
   if not activeAiPackage then activeAiPackage = { type = nil } end

   -- Short circuit out of here if not in Combat state, this is done for the sake of optimisation since currently any access to
   -- lua API is prone to excessive memory allocations.
   if activeAiPackage.type ~= "Combat" then
      state.combatState = enums.COMBAT_STATE.NO_STATE
      lastAiPackage = activeAiPackage
      omwself:enableAI(true)
      return
   end

   local enemyActor = AI.getActiveTarget("Combat")
   state.enemyActor = enemyActor

   -- Always track HP, for damage events
   local currentHealth = types.Actor.stats.dynamic.health(omwself).current
   local damageValue = lastHealth - currentHealth
   state.damageValue = damageValue
   lastHealth = currentHealth

   -- Time
   local now = core.getRealTime()


   -- Storing combat targets in history
   gutils.addTargetsToHistory(I.AI.getTargets("Combat"))

   -- Should we control character with Mercy?
   -- If we are not in a combat state - the engine will handle AI
   local shouldOverrideAI = true
   local detStance = selfActor:getDetailedStance()
   if activeAiPackage.type ~= "Combat" or not enemyActor or types.Actor.isDead(enemyActor) or selfActor:isDead() then
      shouldOverrideAI = false
   end
   -- Short circuit for mages in combat - temporary.
   if state.combatState == enums.COMBAT_STATE.FIGHT and isSpellCaster and spellCastersAreVanilla then
      shouldOverrideAI = false
   end
   -- A small grace period when an empty target is detected in a cobat package. Allows engine to clean up.
   AI.forEachPackage(function(package)
      if package.type == "Combat" and not package.target and not notargetDetectedAt then
         notargetDetectedAt = now
      end
   end)
   if notargetDetectedAt and now - notargetDetectedAt <= notargetGracePeriod then
      notargetDetectedAt = nil
      shouldOverrideAI = false
   end



   -- Sending on Damaged events
   if damageValue > 0 and enemyActor then
      gutils.forEachNearbyActor(2000, function(actor)
         if gutils.isMyFriend(actor) then
            actor:sendEvent('FriendDamaged', { source = omwself.object, offender = enemyActor })
         end
      end)
   end

   -- Sending FriendDead events
   local deathState = selfActor:isDead()
   if lastDeadState ~= nil and lastDeadState ~= deathState then
      if deathState then
         gutils.forEachNearbyActor(1000, function(actor)
            if gutils.isMyFriend(actor) then
               actor:sendEvent('FriendDead', { source = omwself.object, offender = enemyActor })
            end
         end)
      end
   end


   -- When we switch to combat - determine if we want to be hesitant (stand ground) or engage right away
   if lastAiPackage.type ~= activeAiPackage.type and activeAiPackage.type == "Combat" then
      -- Initialising combat state
      if enemyActor then
         local isGuard = gutils.imAGuard()
         local fightBias = types.Actor.stats.ai.fight(omwself).modified
         local dispBias = gutils.getFightDispositionBias(omwself, enemyActor)
         local fightValue = fightBias + dispBias
         local standGroundProb = util.clamp(util.remap(fightValue, 85, 100, 0.9, 0), 0, 0.9)
         standGroundProb = standGroundProb * StandGroundProbModifier
         -- gutils.print("STAND GROUND PROBABILITY", standGroundProb, " Fight val: ", fightBias, dispBias, 1)
         if luaRandom:random() <= standGroundProb and not stoodGroundOnce and not isGuard and damageValue <= 0 then
            core.sound.stopSay(omwself);
            state.combatState = enums.COMBAT_STATE.STAND_GROUND
            stoodGroundOnce = true
         else
            state.combatState = enums.COMBAT_STATE.FIGHT
         end
      else
         state.combatState = enums.COMBAT_STATE.FIGHT
      end
   end

   -- Check for retreating/mercy, both based on internal Mercy flee factors as well as in-game flee value
   local mercyScared = false
   local fleeValue = selfActor.stats.ai.flee().modified
   if (state.combatState == enums.COMBAT_STATE.FIGHT or state.combatState == enums.COMBAT_STATE.STAND_GROUND) then
      mercyScared = isSelfScared(damageValue)
      if fleeValue ~= lastFleeValue and lastFleeValue < 100 and fleeValue >= 100 and luaRandom:random() <= MercyScaredOnFleeValProb then mercyScared = true end
   end
   lastFleeValue = fleeValue

   if mercyScared then
      local potentialStates = {}
      if not retreatedOnce then table.insert(potentialStates, enums.COMBAT_STATE.RETREAT) end
      if not askedForMercyOnce then table.insert(potentialStates, enums.COMBAT_STATE.MERCY) end
      if #potentialStates > 0 then
         local newState = potentialStates[math.random(1, #potentialStates)]
         state.combatState = newState
         if state.combatState == enums.COMBAT_STATE.RETREAT then retreatedOnce = true end
         if state.combatState == enums.COMBAT_STATE.MERCY then askedForMercyOnce = true end
      end
   end

   -- if we are not doing Mercy-style fleeing/surrender, but the flee value is >= 100 - then fallback to vanilla flee
   if state.combatState ~= enums.COMBAT_STATE.RETREAT and state.combatState ~= enums.COMBAT_STATE.MERCY and fleeValue >= 100 then
      shouldOverrideAI = false
   end

   -- if we can't find a nav path to enemy - fallback to vanilla behaviour
   if enemyActor then
      state.navService:setTargetPos(enemyActor.position)
      if #state.navService.path == 0 or (state.range and (state.navService.path[#state.navService.path] - enemyActor.position):length() > state.range) then
         shouldOverrideAI = false
      end
   end

   -- if enemy is invisible switch to Mercy fleeing behaviour with some probability. If not switching to mercy flee - do vanilla flee.
   if enemyActor and gutils.actorHasEffect(enemyActor, "invisibility") then
      if luaRandom:random() <= MercyRetreatOnInvisProb and not retreatedOnce then
         state.combatState = enums.COMBAT_STATE.RETREAT
         retreatedOnce = true
      end
      -- if we are not doing mercy-style retreat - fallback to vanilla behaviour
      if state.combatState == enums.COMBAT_STATE.FIGHT then
         shouldOverrideAI = false
      end
   end


   lastAiPackage = activeAiPackage
   lastDeadState = deathState

   -- Disabling AI so everything can be controlled by ~Mercy~
   omwself:enableAI(not shouldOverrideAI)
   if not shouldOverrideAI then return end


   -- Provide Behaviour Tree state with the necessary info --------------
   ----------------------------------------------------------------------
   state:clear()

   state.dt = dt
   state.enemyActor = enemyActor
   if state.enemyActor then
      state.range = gutils.getDistanceToBounds(omwself, state.enemyActor)
   else
      state.range = 1e42
   end

   state.detStance = detStance

   -- Get weapon stats
   local weaponObj = selfActor:getEquipment(types.Actor.EQUIPMENT_SLOT.CarriedRight)
   local weaponRecord = { id = nil }
   if weaponObj then weaponRecord = types.Weapon.record(weaponObj.recordId) end

   if weaponRecord.id ~= lastWeaponRecord.id then
      if weaponRecord.id then
         state.weaponAttacks = gutils.getSortedAttackTypes(weaponRecord)
         state.weaponSkill = itemutil.getSkillStatForEquipment(omwself, weaponObj).modified
         state.reach = weaponRecord.reach * fCombatDistance * 0.95
      else
         -- We are using hand-to-hand
         state.weaponAttacks = gutils.getSortedAttackTypes(nil)
         state.weaponSkill = types.NPC.stats.skills.handtohand(omwself).modified
         state.reach = fHandToHandReach * fCombatDistance * 0.95
      end
      lastWeaponRecord = weaponRecord
   end

   -- Determine movement speed
   -- Initial idea was to have 2 different degrees of slow speed, but at the end it turned out to be unnecessary
   state.slowSpeed = 85 + 25 * state.slowSpeedFactor
   state.menaceSpeed = state.slowSpeed

   -- Track and cleanup the current attack state. If attack group is not playing - it was interrupted.
   if state.attackGroup and not animManager.isPlaying(state.attackGroup) then
      state.attackGroup = nil
      state.attackState = enums.ATTACK_STATE.NO_STATE
   end

   -- And the same for stagger state
   if state.staggerGroup and not animManager.isPlaying(state.staggerGroup) then
      state.staggerGroup = nil
   end

   -- Check for going ham. I.e spamming attack in response to player's attack spam.
   if state.combatState == enums.COMBAT_STATE.FIGHT and state.canGoHam and not state.goingHam then
      -- Whenever we are damaged, but not more frequent than once 0.25 sec
      if damageValue > 0 and now - lastGoHamCheck >= 0.25 then
         -- And if we are damaged more frequently than once a second
         if now - lastGoHamCheck < 1 then
            state.goHamHeat = state.goHamHeat + 0.2
            state.goingHam = math.random() < state.goHamHeat
         end
         lastGoHamCheck = now
      end
   end

   -- Reduce goHamHeat overtime
   state.goHamHeat = state.goHamHeat - 0.1 * dt
   if state.goHamHeat < 0 then
      state.goHamHeat = 0
      state.goingHam = false
   end

   -- Running behaviour trees! -----------------------------
   ---------------------------------------------------------
   if bTrees == nil then return error("Behaviour trees are nil, something went wrong on initialisation.") end
   bTrees["Combat"]:run()
   bTrees["CombatAux"]:run()
   bTrees["Locomotion"]:run()


   -- Apply state properties modified by behavior trees to actor controls ----
   if state.vanillaBehavior then
      omwself:enableAI(true)
      return
   else
      if state.stance ~= selfActor:getStance() then
         selfActor:setStance(state.stance)
      end
      omwself.controls.run = state.run
      omwself.controls.movement = state.movement
      omwself.controls.sideMovement = state.sideMovement
      omwself.controls.use = state.attack
      omwself.controls.jump = state.jump

      -- If no lookDirection provided - default behaviour is to stare at the enemy
      -- If an attack is in progress - force look at enemyActor
      local lookDirection
      if state.attackState == enums.ATTACK_STATE.NO_STATE then
         lookDirection = state.lookDirection
      end
      if not lookDirection and state.enemyActor then
         lookDirection = state.enemyActor.position - omwself.position
      end
      if lookDirection then
         -- Actual rotation is changed somewhat gradually
         omwself.controls.yawChange = gutils.lerpClamped(0,
            -moveutils.lookRotation(omwself, omwself.position + lookDirection), dt * 3)
      end
   end
end




-- Animation handlers -------------------------------------------------------------
-----------------------------------------------------------------------------------

I.AnimationController.addPlayBlendedAnimationHandler(function(groupname, options)
   --print("New animation started! " .. groupname .. " : " .. options.startkey .. " --> " .. options.stopkey)
   -- Detect being staggered
   if gutils.stringStartsWith(groupname, "hit") then
      state.staggerGroup = groupname
   end
end)

-- In the text key handler: Theres no way to know for which bonegroup the text key was triggered?
I.AnimationController.addTextKeyHandler(nil, function(groupname, key)
   --print("Animation text key! " .. groupname .. " : " .. key)
   if string.find(key, "chop start") or string.find(key, "thrust start") or string.find(key, "slash start") then
      state.attackState = enums.ATTACK_STATE.WINDUP_START
      state.attackGroup = groupname
   end

   -- Animation compilation has min and max attack on a same keyframe due to which they might arrive out of order. So avoid setting MIN state
   -- if higher state is already set
   if string.find(key, "min attack") and state.attackState < enums.ATTACK_STATE.WINDUP_MIN then
      state.attackState = enums.ATTACK_STATE.WINDUP_MIN
   end

   if string.find(key, "max attack") then
      -- Attack is being held here, but this event will also trigger at the beginning of release
      state.attackState = enums.ATTACK_STATE.WINDUP_MAX
   end

   if string.find(key, "min hit") then
      --Changing state to release on min hit is good enough
      state.attackState = enums.ATTACK_STATE.RELEASE_START
   elseif string.find(key, "hit") then
      state.attackState = enums.ATTACK_STATE.RELEASE_HIT
   end

   if string.find(key, "follow start") then
      state.attackState = enums.ATTACK_STATE.FOLLOW_START
   end

   if string.find(key, "follow stop") then
      state.attackState = enums.ATTACK_STATE.NO_STATE
      state.attackGroup = nil
   end
end)



-- Events from other actors -------------------------------------------------------
-----------------------------------------------------------------------------------

-- Also if you miss with ranged - theyll ignore that as well
local function onFriendDamaged(e)
   --gutils.print("Oh no, ", e.source.recordId, " got damaged!")
   gutils.print("Friend " .. e.source.recordId .. " was attacked", 1)
   if selfActor:isDead() then return end

   if state.combatState == enums.COMBAT_STATE.STAND_GROUND then
      state.combatState = enums.COMBAT_STATE.FIGHT
   end
   if lastAiPackage.type ~= "Combat" then
      local raycast = nearby.castRay(gutils.getActorLookRayPos(omwself),
         gutils.getActorLookRayPos(e.source),
         { collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.Door + nearby.COLLISION_TYPE.HeightMap })

      if not raycast.hitObject then
         gutils.print("Friend " .. e.source.recordId .. " was attacked, starting a combat AI package", 1)
         AI.startPackage({ type = 'Combat', target = e.offender })
      else
         gutils.print("Line of sight check hit " .. raycast.hitObject.recordId, 1)
      end
   end
end

local avengeSaid = false
local function onFriendDead(e)
   gutils.print("Oh no, friend: ", e.source.recordId, " is dead!", 1)
   if selfActor:isDead() then return end
   if state.combatState == enums.COMBAT_STATE.FIGHT and gutils.isMyFriend(e.source) and math.random() < AvengeShoutProb and not avengeSaid then
      voiceManager.say(omwself, nil, "FriendDead")
      avengeSaid = true
   end
end


-- Engine handlers ------------------------------------------------------------
-------------------------------------------------------------------------------
return {
   engineHandlers = {
      onUpdate = onUpdate,
   },
   eventHandlers = {
      FriendDamaged = function(...)
         Events:emit("FriendDamaged", ...)
         onFriendDamaged(...)
      end,
      FriendDead = function(...)
         Events:emit("FriendDead", ...)
         onFriendDead(...)
      end,
      PlayerUse = function(...)
         Events:emit("PlayerUse", ...)
      end
   },
   interfaceName = "MercyCAO",
   interface = interface
}
