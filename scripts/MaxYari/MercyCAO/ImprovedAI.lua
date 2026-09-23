mp = "scripts/MaxYari/MercyCAO/"

-- Mod files
local gutils = require(mp .. "scripts/gutils")
local moveutils = require(mp .. "scripts/movementutils")
local itemutil = require(mp .. "scripts/item_util")
local enums = require(mp .. "scripts/enums")
local animManager = require(mp .. "scripts/anim_manager")
local voiceManager = require(mp .. "scripts/voice_manager")
local EventsManager = require(mp .. "scripts/events_manager")
local magicUtil = require(mp .. "scripts/magic_util")
local manaPotions = require(mp .. "scripts/mana_potions")

-- OpenMW libs
local omwself = require('openmw.self')
local selfActor = gutils.Actor:new(omwself)
local core = require('openmw.core')
local AI = require('openmw.interfaces').AI
local util = require('openmw.util')
local types = require('openmw.types')
local I = require('openmw.interfaces')
local storage = require('openmw.storage')

-- OpenMW API Version check
if core.API_REVISION < 64 then
   error(
      "Can not start Mercy: CAO, newer version of lua API is required. Please update OpenMW.")
end

-- 3rd party libs
-- Setup important global functions for the behaviourtree 2e module to use--
_BehaviourTreeImports = {
   loadCodeInScope = util.loadCode,
   -- Simulation time doesn't advance while the game is paused
   clock = core.getSimulationTime
}
local BT = require(mp .. "libs/behaviourtreelua2e/lib/behaviour_tree")
local luaRandom = require(mp .. "libs/randomlua")
----------------------------------------------------------------------------



--- To be or not to be!? ---
DebugLevel = 0
----------------------------

--- Init custom behaviour nodes
require(mp .. "scripts/behavior_nodes")

-- Event bus
Events = EventsManager:new()

-- GSMTs
local fCombatDistance = core.getGMST("fCombatDistance")
local fHandToHandReach = core.getGMST("fHandToHandReach")
-- Ranges the engine attacks from: marksman weapons and ranged spells (see aicombataction.cpp)
local fProjectileMaxSpeed = core.getGMST("fProjectileMaxSpeed")
local spellCombatRange = fCombatDistance * math.max(2, fHandToHandReach) * 4
-- Being spotted while sneaking or hiding (state:spotted): the enemy has to face the NPC within this angle (degrees).
-- A watched NPC reacts after a random delay in these ranges (seconds): with the enemy in front of it, or behind it (it
-- doesn't see the enemy well).
local SPOTTED_ANGLE = 45
local SPOTTED_FRONT_DELAY_MIN, SPOTTED_FRONT_DELAY_MAX = 0.5, 1.5
local SPOTTED_BEHIND_DELAY_MIN, SPOTTED_BEHIND_DELAY_MAX = 1.0, 2.0
-- Within this distance (4 m) the NPC reacts after SPOTTED_CLOSE_DELAY instead, whichever way it faces
local SPOTTED_CLOSE_DISTANCE = 4 * 69.99
local SPOTTED_CLOSE_DELAY = 0.3
-- A hiding NPC that sees its enemy swing a weapon at it from within reach comes out this many seconds later, even when
-- it's still invisible
local HIDE_THREAT_DELAY = 0.5
-- While on the move after Vanish (repositioning, running to a hiding spot), only a hit of at least this share of
-- base health interrupts it, so damage over time doesn't
local MOVING_DAMAGE_THRESHOLD = 0.05
-- Scaredness (state:scaredness): an NPC's inclination to run away from its enemy, from the level gap alone: 1 for the
-- same level, doubling for an NPC SCARED_LEVEL_RANGE or more levels below its enemy and halving for one that many levels
-- above, smoothly in between (2 ^ (gap / range)). Chances scaled by it are kept between SCARED_MIN_CHANCE and
-- SCARED_MAX_CHANCE.
local SCARED_LEVEL_RANGE = 10
local SCARED_MIN_CHANCE, SCARED_MAX_CHANCE = 0.1, 0.9
-- Base chances of running off to hide (see state:hideChance): after Vanish rather than repositioning (scaled by
-- scaredness too), and when retreating rather than retreating towards friends
local VANISH_HIDE_BASE_CHANCE = 0.5
local RETREAT_HIDE_BASE_CHANCE = 0.5
-- Base chance of getting scared (retreat or surrender) from a big enough hit while badly hurt, for an even match
local SCARED_BASE_CHANCE = 0.2
-- A hiding NPC isn't spotted by enemies further away than this: the engine's sneak check range, but at least 1000
local HIDE_NOTICE_RANGE = math.max(1000, core.getGMST("fSneakUseDist"))

-- Navigation service
local NavigationService = require(mp .. "scripts/navservice")
local navService = NavigationService({
   cacheDuration = 1,
   targetPosDeadzone = 50,
   pathingDeadzone = 35
})

-- Actor type variables
local spellCastersAreVanilla = true
local isGuard = selfActor:isAGuard()
-- Casts by class (a casting major skill, or a vampire). Only these and the NPCs Mercy upgrades get engine magic
-- windows, see prepareMagic.
local isSpellCaster = selfActor:isSpellCaster()
-- Data containers
local bTrees = nil
local blacklist = nil


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

   -- Warning (STAND_GROUND) fields, updated by the main loop
   warnsLeft = nil,         -- Patience: how many more times this NPC will warn instead of fighting. Rolled once and saved.
   warnRequested = false,   -- Set when the enemy is seen again and the NPC warns again, cleared by the tree
   enemyLostFor = 0,        -- Seconds since the enemy was last in line of sight
   lostSightTime = 2,       -- Out of sight for this long counts as lost
   lastSeenPos = nil,
   standGroundOrigin = nil, -- Where the NPC stood when it warned, it walks back here after looking around
   investigateProb = 40,    -- 0-100 chance to come looking where the enemy was last seen, set from settings
   sneakUpProb = 20,        -- 0-100 chance to sneak up on the enemy instead, rolled first
   sneakingUp = false,      -- Set by the tree while sneaking up on the enemy
   caught = false,          -- Set by the tree once the enemy noticed the sneaking NPC
   ambushAttack = false,    -- Sneaking up ended in melee range: the Combat tree does one attack right away
   enemyInSight = false,    -- Result of the last line of sight check while warning

   -- Set by the tree while it is committed to an attack: from the moment it decides to swing until the whole burst is
   -- over, including the gaps between swings where no attack animation is playing (state.attackState is read off the
   -- animation, so it reads NO_STATE there). Mercy's own spells don't need it - they're a branch the tree only
   -- reaches after the attacks - but OSSC casts on its own schedule and writes the attack control itself, so it's held
   -- back while this is set (see updateOSSCHold).
   inAttackSequence = false,
   -- PeriodicCondition node title -> simulation time it may let its child run again. Shared by every copy of a node.
   periodicDueAt = {},

   -- Magic fields
   castables = nil,         -- What magic the engine might cast, scanned on combat start (magic_util.scanCastables)
   customSpells = {},       -- Record ids of Mercy's own spells by key, sent by the global script
   knownCustomSpells = {},  -- Custom spell keys this actor knows, updated on combat start
   magicBusy = false,       -- A magic action is in progress: Mercy casting, or a handover window to the engine
   castingCustom = false,   -- Mercy is casting a custom spell right now
   pitchTarget = nil,       -- Pitch Mercy steers towards while aiming (radians, positive looks down)
   aimDirection = nil,      -- Horizontal direction Mercy turns to while aiming, wins over lookDirection
   customSpellCooldowns = {}, -- Custom spell key -> simulation time its cooldown ends
   customSpellMisses = {},    -- Custom spell key -> misses in a row since its last cooldown
   customSpellMissedAt = {},  -- Custom spell key -> simulation time of its last miss
   enemyDispelWorth = 0,      -- Spells on the enemy worth a Dispel, refreshed twice a second (spells/dispel.lua)
   selfNeedsMending = false,  -- An attribute is far enough below its base to be worth restoring (spells/restore_self.lua)
   repositioning = false,     -- Moving to repositionPoint (e.g. while invisible), set by the tree
   repositionPoint = nil,     -- Where to reposition to, picked by PickRepositionPoint
   hideSpotReady = false,     -- The HIDE state starts with a hiding spot already picked in repositionPoint
   hideModifier = 1,          -- Scales every chance to run off and hide (see hideChance), set from settings
   isCompanion = false,       -- Follows or escorts the player, updated with the combat targets

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
      self.turnRate = nil
      self.range = 1e42
      self.sneak = false
   end,

   -- Close enough to strike from where the NPC is sneaking: melee reach, or with the enemy in sight, the range the
   -- engine attacks from with marksman weapons and ranged spells
   inStrikingRange = function(self)
      local stance = self.detStance
      if stance == gutils.Actor.DET_STANCE.Melee then return self.range <= self.reach end
      if not self.enemyInSight then return false end
      if stance == gutils.Actor.DET_STANCE.Marksman then return self.range <= fProjectileMaxSpeed end
      if stance == gutils.Actor.DET_STANCE.Spell then return self.range <= spellCombatRange end
      return false
   end,
   isMelee = function(self)
      return self.detStance == gutils.Actor.DET_STANCE.Melee
   end,

   -- Hand the actor to the engine for a moment so it can pick a spell: only if it has magic it could cast right now,
   -- isn't attacking or staggered, and is out of melee reach (the engine would swing or turn to face first otherwise).
   -- Checked by the Magic Window branch, which the tree only reaches between attacks.
   canHandOverForMagic = function(self)
      -- With OSSC installed there's nothing to hand over for: OSSC picks and casts the actor's own spells itself,
      -- and Mercy holds and releases it instead (see updateOSSCHold). Target switching still goes to the engine.
      -- Checked by install, not by OSSC's caster script being on the actor: that attaches a moment into the fight,
      -- and a window opened before it let the engine ready a spell in the full casting stance.
      if magicUtil.osscInstalled() then return false end
      if not spellCastersAreVanilla or self.magicBusy or self.repositioning
         or not self.castables or not self.castables.canUseMagic then
         return false
      end
      -- Only while actually fighting. Warning, investigating, sneaking up, hiding, retreating and surrendering are
      -- routines of their own: handing the actor to the engine in the middle of one derails it.
      if self.combatState ~= enums.COMBAT_STATE.FIGHT then return false end
      -- A burst's follow-through can still be playing when the tree gets here
      if self.attackState ~= enums.ATTACK_STATE.NO_STATE or self.staggerGroup or self.range <= self.reach then
         return false
      end
      return magicUtil.canAttemptCastNow(omwself, self.castables)
   end,
   -- Whether Mercy can cast one of its custom spells (by key, e.g. "levitateBolt") right now. When it can't, the reason
   -- is left in castBlockReason for debug logging (see PeriodicCondition).
   canCastCustom = function(self, key)
      local spellId = self.customSpells[key]
      local reason = nil
      if not spellId or not self.knownCustomSpells[key] then reason = "doesn't know the spell"
      -- Learned in a game where a mod it needs (e.g. Lua Physics) was installed, but isn't anymore
      elseif not magicUtil.isAvailable(key) then reason = "not available in this game"
      elseif self.magicBusy then reason = "busy with other magic"
      elseif self.repositioning then reason = "repositioning"
      elseif self.combatState == enums.COMBAT_STATE.HIDE then reason = "hiding"
      elseif not self.enemyActor then reason = "no enemy"
      elseif magicUtil.CUSTOM_SPELLS[key].playerTargetOnly and not types.Player.objectIsInstance(self.enemyActor) then
         reason = "only cast at the player"
      elseif (self.customSpellRestUntil or 0) > core.getSimulationTime() then reason = "resting after spells back to back"
      elseif (self.customSpellCooldowns[key] or 0) > core.getSimulationTime() then reason = "on cooldown"
      -- The Spells branch only runs between attacks, but a burst's follow-through (or the engine's own swing, in a
      -- marksman or spell stance window) can still be playing when it gets here
      elseif self.attackState ~= enums.ATTACK_STATE.NO_STATE or self.staggerGroup then reason = "attacking or staggered"
      elseif magicUtil.isCasting(omwself) then reason = "already casting"
      elseif magicUtil.isSilenced(omwself) then reason = "silenced"
      elseif not magicUtil.canAfford(omwself, spellId) then reason = "not enough magicka"
      end
      self.castBlockReason = reason
      return reason == nil
   end,
   enemyHasEffect = function(self, effectId)
      return self.enemyActor ~= nil and gutils.actorHasEffect(self.enemyActor, effectId)
   end,
   enemyInLineOfSight = function(self)
      return self.enemyActor ~= nil and gutils.hasLineOfSight(omwself, self.enemyActor)
   end,
   selfHasEffect = function(self, effectId)
      return gutils.actorHasEffect(omwself, effectId)
   end,
   -- One of Mercy's custom spells, cast by this actor, is active on it
   customSpellActive = function(self, key)
      local spellId = self.customSpells[key]
      return spellId ~= nil and magicUtil.hasActiveSpellFrom(omwself, spellId, omwself.object)
   end,
   -- Dark enough for a light: any interior, or outside at night
   isDark = function(self)
      local cell = omwself.cell
      if not cell.isExterior and not cell:hasTag("QuasiExterior") then return true end
      local hour = (core.getGameTime() / 3600) % 24
      return hour >= 20 or hour < 6
   end,
   -- Whether the enemy has spotted this sneaking or hiding NPC. The enemy has to be able to see it: within maxDistance,
   -- with it in line of sight, and facing it (within SPOTTED_ANGLE). An enemy looking elsewhere is assumed not to see
   -- it, and an NPC that's still invisible assumes it can't be seen. Being watched, the NPC reacts after a random
   -- SPOTTED_FRONT_DELAY, or SPOTTED_BEHIND_DELAY with the enemy behind it, or SPOTTED_CLOSE_DELAY within
   -- SPOTTED_CLOSE_DISTANCE. The enemy looking away starts that over. While being watched noticingSince is set. Checked at most every 0.25 s.
   spotted = function(self, maxDistance)
      local enemy = self.enemyActor
      if not enemy then return false end
      local now = core.getSimulationTime()
      if now < (self.spottedCheckAt or 0) then return false end
      self.spottedCheckAt = now + 0.25

      local toMe = omwself.position - enemy.position
      local enemyForward = enemy.rotation:apply(util.vector3(0, 1, 0))
      local watched = toMe:length() <= maxDistance
         and enemyForward:normalize():dot(toMe:normalize()) > math.cos(math.rad(SPOTTED_ANGLE))
         and not gutils.actorHasEffect(omwself, "invisibility")
         and gutils.hasLineOfSight(omwself, enemy)
      if not watched then
         if self.noticingSince then
            magicUtil.log("Spotted check: no longer watched after", string.format("%.1f", now - self.noticingSince),
               "s, distance", math.floor(toMe:length()))
         end
         self.noticingSince = nil
         return false
      end

      local myForward = omwself.rotation:apply(util.vector3(0, 1, 0))
      local enemyInFront = util.vector2(myForward.x, myForward.y):dot(util.vector2(-toMe.x, -toMe.y)) > 0
      if not self.noticingSince then
         self.noticingSince = now
         self.noticeFrontDelay = SPOTTED_FRONT_DELAY_MIN + math.random() * (SPOTTED_FRONT_DELAY_MAX - SPOTTED_FRONT_DELAY_MIN)
         self.noticeBehindDelay = SPOTTED_BEHIND_DELAY_MIN + math.random() * (SPOTTED_BEHIND_DELAY_MAX - SPOTTED_BEHIND_DELAY_MIN)
      end
      local close = toMe:length() <= SPOTTED_CLOSE_DISTANCE
      local delay = close and SPOTTED_CLOSE_DELAY or (enemyInFront and self.noticeFrontDelay or self.noticeBehindDelay)
      if now == self.noticingSince then
         magicUtil.log("Spotted check: enemy is watching, distance", math.floor(toMe:length()), "- enemy",
            close and "close" or (enemyInFront and "in front" or "behind"), "- reacting in", string.format("%.1f", delay),
            "s if it keeps watching")
      end
      if now - self.noticingSince < delay then return false end
      magicUtil.log("Spotted: watched for", string.format("%.1f", now - self.noticingSince), "s with the enemy",
         enemyInFront and "in front" or "behind")
      return true
   end,
   -- The NPC's inclination to run away from its enemy, see SCARED_LEVEL_RANGE
   scaredness = function(self)
      local enemy = self.enemyActor
      if not enemy then return 1 end
      local levelGap = types.Actor.stats.level(enemy).current - selfActor:levelStat().current
      return 2 ^ (util.clamp(levelGap, -SCARED_LEVEL_RANGE, SCARED_LEVEL_RANGE) / SCARED_LEVEL_RANGE)
   end,
   -- A base chance (for an even match) scaled by scaredness and the Scared Probability Modifier setting, kept between
   -- SCARED_MIN_CHANCE and SCARED_MAX_CHANCE. Always 0 when the modifier is 0 (guards and NPCs blacklisted from
   -- surrendering).
   scaredChance = function(self, baseChance)
      if ScaredProbModifier <= 0 then return 0 end
      return util.clamp(baseChance * self:scaredness() * ScaredProbModifier, SCARED_MIN_CHANCE, SCARED_MAX_CHANCE)
   end,
   -- A base chance of running off to hide scaled by the Hide Modifier setting (0 to 1). Every hiding decision goes
   -- through it. The player's companions never hide.
   hideChance = function(self, baseChance)
      if self.isCompanion then return 0 end
      return util.clamp(baseChance * self.hideModifier, 0, 1)
   end,
   -- Chance to hide after Vanish rather than reposition: also scaled by scaredness
   vanishHideChance = function(self)
      local chance = 0
      if self.hideModifier > 0 and not self.isCompanion then
         -- The Hide Modifier goes last, so high values do force hiding
         chance = self:hideChance(self:scaredChance(VANISH_HIDE_BASE_CHANCE))
      end
      self:logHideChance("Vanish", chance)
      return chance
   end,
   -- Chance to hide when retreating rather than retreat towards friends
   retreatHideChance = function(self)
      local chance = self:hideChance(RETREAT_HIDE_BASE_CHANCE)
      self:logHideChance("Retreat", chance)
      return chance
   end,
   -- Debug log of a hiding decision's chance, once per frame (a weighted choice reads it for each of its options)
   logHideChance = function(self, what, chance)
      local now = core.getSimulationTime()
      if self.hideChanceLoggedAt == now then return end
      self.hideChanceLoggedAt = now
      magicUtil.log(what, string.format("hide chance %.0f%% (Hide Modifier %s, scaredness %.2f%s)", chance * 100,
         tostring(self.hideModifier), self:scaredness(), self.isCompanion and ", companion: never hides" or ""))
   end,
   -- Rolls whether to leave the fight and run away (RETREAT: to friends, or off to hide), e.g. after trapping the enemy.
   -- 'baseChance' is for an even match, see scaredChance. Only from FIGHT. 'reason' is for debug logging.
   rollRunAway = function(self, baseChance, reason)
      -- The player's companions don't run off
      if self.combatState ~= enums.COMBAT_STATE.FIGHT or self.isCompanion then return false end
      local chance = self:scaredChance(baseChance)
      local roll = math.random()
      local runs = roll < chance
      magicUtil.log("Run away roll after", reason, string.format("- scaredness %.2f, chance %.0f%%, rolled %.0f%%",
         self:scaredness(), chance * 100, roll * 100), runs and "- running away" or "- keeps fighting")
      if runs then self.combatState = enums.COMBAT_STATE.RETREAT end
      return runs
   end,
   -- While hiding: found out once damaged or spotted
   foundOut = function(self)
      if self.hideDamaged then
         magicUtil.log("Found out while hiding: took damage")
         return true
      end
      if self.hideThreatenedAt then
         if core.getSimulationTime() - self.hideThreatenedAt < HIDE_THREAT_DELAY then return false end
         magicUtil.log("Found out while hiding: the enemy swung a weapon at it")
         return true
      end
      return self:spotted(HIDE_NOTICE_RANGE)
   end,

   -- Functions to be used in the editor
   r = function(min, max)
      if min == nil then
         return math.random()
      else
         return min + math.random() * (max - min)
      end
   end,
   -- A pause or cooldown in seconds, divided by the Combat Intensity setting: intense NPCs wait less between attacks
   -- and between moves. Used by the tree wherever a duration should follow intensity ($:pause(1,2) instead of $r(1,2)).
   pause = function(self, min, max)
      return self.r(min, max) / CombatIntensity
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
      -- Longer bursts at higher Combat Intensity
      n = math.floor(n * CombatIntensity + 0.5)
      return math.max(1, n)
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
local function isBlacklisted(blist)
   return (blist.recordIdsMap[omwself.recordId] or blist.cellIdsMap[omwself.cell.id])
end

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

   -- Combat Intensity, applied last so it shifts whatever personality was rolled above rather than replacing it.
   -- The weights (nearStop/nearBack/midStop/midChase) are picked between by RunRandom, which normalises by their
   -- total, so they need no upper bound. rootedAttackInc and midAttackInc are 0-100 probabilities for RandomThrough,
   -- so those stay clamped. The strafe weights are left alone: strafing isn't hanging back, and it's what Mercy's
   -- movement looks like.
   if CombatIntensity ~= 1 then
      state.nearStopInc = state.nearStopInc / CombatIntensity
      state.nearBackInc = state.nearBackInc / CombatIntensity
      state.midStopInc = state.midStopInc / CombatIntensity
      state.midChaseInc = state.midChaseInc * CombatIntensity
      state.rootedAttackInc = util.clamp(state.rootedAttackInc * CombatIntensity, 0, 100)
      state.midAttackInc = util.clamp(state.midAttackInc * CombatIntensity, 0, 100)
   end

   -- Print the modified state for verification
   -- gutils.print(gutils.tableToString(state))
end


-- Functions to determine if its time to retreat/ask for mercy
-- Function to calculate if the character is scared
local function isSelfScared(damageValue)
   -- Author: Mostly ChatGPT 2024

   -- Get current health   
   local baseHealth = selfActor:healthStat().base
   local currentHealth = selfActor:healthStat().current


   -- Proceed only if there was actual damage
   if damageValue > 0 then
      local healthFraction = currentHealth / baseHealth
      --print("DAMAGE VALUE", damageValue)
      --print("Health fraction", healthFraction)
      -- Check if health is below 33%
      if healthFraction <= SurrenderHealthFraction then
         -- Calculate the damage-based factor
         local damageFactor = damageValue / baseHealth

         -- Scaredness-adjusted probability, scaled down for small hits
         local adjustedProbability = state:scaredChance(SCARED_BASE_CHANCE) * math.min(damageFactor / 0.05, 1)

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
----------------------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------------------

-- Interface ----------------------------------------------------------------
-----------------------------------------------------------------------------
local interface = {
   version = 1.5,
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



-- Main Logic -----------------------------------------------------
-------------------------------------------------------------------------------
local settings = storage.globalSection('SettingsMercyCAOBehavior')
-- Defining variables used by the main update functions
CompanionMercyProb = settings:get("CompanionMercyProb")
StandGroundProbModifier = settings:get("StandGroundProbModifier")
ScaredProbModifier = settings:get("ScaredProbModifier")
SurrenderHealthFraction = settings:get("SurrenderHealthFraction")
state.investigateProb = settings:get("InvestigateProb") * 100
state.hideModifier = settings:get("HideModifier") or 1
-- How hard NPCs press an attack, see randomiseInclinations and state:pause. Read once: the inclinations it scales are
-- rolled once at startup, so changing it takes effect on a save reload.
CombatIntensity = math.max(0.1, settings:get("CombatIntensity") or 1)
-- Shares of spellcasters, and of NPCs knowing no spells, that get Mercy's custom spells on their first fight
local magicSettings = storage.globalSection('SettingsMercyCAOMagic')
local casterCustomSpellsChance = magicSettings:get("CasterCustomSpellsChance") or 0
local nonCasterCustomSpellsChance = magicSettings:get("SpellcasterUpgradeChance") or 0
local extraSpellsForHighLevelCasters = magicSettings:get("ExtraSpellsForHighLevelCasters") ~= false
-- Share of spellcasters that get a magicka potion on their first fight
local manaPotionChance = magicSettings:get("ManaPotionChance") or 0
local manaPotionLootChance = magicSettings:get("ManaPotionLootChance") or 0

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
local lastHealth = selfActor:healthStat().current
local lastDeadState = nil
local lastCombatState = nil
local lastGoHamCheck = 0
local retreatedOnce = false
local askedForMercyOnce = false
-- Custom spells rolled on the first fight: key -> learned spell record id, or false. nil until rolled. Saved.
local learnedCustomSpells = nil
-- This NPC knew no spells and Mercy made a caster of it on its first fight. Saved, so it keeps its magic windows.
local upgradedToCaster = false
local pitchSteered = false -- Pitch was changed while aiming and may still need levelling
-- Debug logging of who drives the actor in combat and its stance, logged only when they change
local lastControlOwner = nil
local lastLoggedStance = nil
local function noteControlOwner(owner, stance)
   if owner ~= lastControlOwner then
      magicUtil.log("Control:", lastControlOwner or "-", "->", owner, "| stance", stance)
      lastControlOwner = owner
   end
end

-- Custom spell hit tracking. A cast puts the spell on cooldown right away, so it isn't cast again while waiting to see
-- whether it lands. Nothing waits for the answer: the tree carries on attacking as soon as the cast is done, and each
-- released target spell leaves a pending check in pendingSpellHits that the main loop resolves (checkCustomSpellHits).
-- The wait starts when the spell is released (onCustomSpellCast runs on the release key, or right away for a cast
-- through OSSC) and lasts HIT_WINDOW, without working out the flight time. Not landing by then is a miss: a miss lifts
-- the cooldown, so the next time the tree reaches the spell it can cast it again - unless it's the
-- CUSTOM_SPELL_MISSES_BEFORE_COOLDOWN'th miss in a row. A miss is forgotten once a full cooldown has passed since it.
local HIT_WINDOW = 2
-- Spell key -> { spellId, target, deadline }. One per spell, so a second spell cast inside the window doesn't lose
-- the first one's check.
local pendingSpellHits = {}

state.onCustomSpellCast = function(self, key, target)
   local spellId = self.customSpells[key]
   local spell = spellId and core.magic.spells.records[spellId]
   if not spell then return end
   local now = core.getSimulationTime()
   local definition = magicUtil.CUSTOM_SPELLS[key]
   local cooldown = definition.cooldown or magicUtil.CUSTOM_SPELL_DEFAULT_COOLDOWN
   self.customSpellCooldowns[key] = now + cooldown
   -- The spell's own effect code, from its file in scripts/spells
   if definition.onCast and target then
      definition.onCast(omwself.object, target, self)
      magicUtil.log(key, "cast effect triggered on", target.recordId)
   end
   -- Self spells always land, nothing to check
   if spell.effects[1] and spell.effects[1].range == core.magic.RANGE.Self then
      self.customSpellMisses[key] = 0
      magicUtil.log(key, "cast on self - on cooldown")
      return
   end
   if not target then return end
   if (self.customSpellMisses[key] or 0) > 0 and now - (self.customSpellMissedAt[key] or 0) >= cooldown then
      self.customSpellMisses[key] = 0
   end
   pendingSpellHits[key] = { spellId = spellId, target = target, deadline = now + HIT_WINDOW }
end

-- Resolves one pending check. Returns true once it's settled (hit or miss), false while it's still waiting.
local function resolveSpellHit(key, pending, now)
   local definition = magicUtil.CUSTOM_SPELLS[key]
   -- Only within the window: a check left pending when a fight ended mustn't trigger the spell's effect much later
   local hit = false
   if now <= pending.deadline and pending.target:isValid() then
      if definition.landed then
         -- The spell file knows better, e.g. an instant effect that leaves nothing on the target to find
         hit = definition.landed(omwself.object, pending.target, state)
      else
         hit = magicUtil.hasActiveSpellFrom(pending.target, pending.spellId, omwself.object)
            or magicUtil.hasActiveSpell(pending.target, pending.spellId)
      end
   end
   if not hit and now < pending.deadline then return false end

   if hit then
      state.customSpellMisses[key] = 0
      magicUtil.log(key, "hit - stays on cooldown")
      -- The spell's own effect code, from its file in scripts/spells
      if definition.onHit then definition.onHit(omwself.object, pending.target, state) end
      return true
   end

   local misses = (state.customSpellMisses[key] or 0) + 1
   if misses < magicUtil.CUSTOM_SPELL_MISSES_BEFORE_COOLDOWN then
      state.customSpellCooldowns[key] = 0
      state.customSpellMisses[key] = misses
      state.customSpellMissedAt[key] = now
      magicUtil.log(key, "missed", misses, "time(s) in a row - cooldown lifted")
   else
      state.customSpellMisses[key] = 0
      magicUtil.log(key, "missed", misses, "times in a row - stays on cooldown")
   end
   return true
end

local function checkCustomSpellHits(now)
   for key, pending in pairs(pendingSpellHits) do
      -- Clearing a field of the table being traversed is allowed in Lua
      if resolveSpellHit(key, pending, now) then pendingSpellHits[key] = nil end
   end
end
-- With OSSC installed, casting the actor's own spells is OSSC's job rather than the engine's: Mercy doesn't hand the
-- actor over for magic at all (see canHandOverForMagic) and instead holds OSSC back at the moments a cast would ruin
-- what Mercy is doing - mid attack burst, while Mercy casts one of its own spells, while repositioning, and during
-- every routine that isn't a straight fight (warning, investigating, sneaking up, hiding, retreating, surrendering).
local function updateOSSCHold()
   local hold = state.combatState ~= enums.COMBAT_STATE.FIGHT
      or state.inAttackSequence or state.magicBusy or state.castingCustom or state.repositioning
   magicUtil.osscSetPaused(hold)
end

-- While warning (STAND_GROUND): when the enemy was last in line of sight, and when it was last checked
local lastSeenAt = 0
local lastSightCheck = -1e42
local SIGHT_CHECK_PERIOD = 0.25
local GIVE_UP_TIME = 30 -- Out of sight for this long, a warning NPC leaves combat
local SNEAK_GIVE_UP_TIME = 300 -- The same while sneaking up on the enemy

-- Add variables for timing
local lastAiPackageCheck = core.getSimulationTime() - math.random() * 0.5
local activeAiPackage = { type = nil } -- Due to employed optimisation hack the type will always be either "Combat" or nil, it will never reflect Follow, Wander etc. package states
local combatTargets = {}
local escortTargets = {}
local followTargets = {}
local imACompanion = false
local aiEnabled = true
local sneakControlSet = false -- Mercy made the NPC sneak, the engine keeps the control until it's changed
local enableAI = function (state)
   if not aiEnabled == state then
      aiEnabled = state
      omwself:enableAI(state)
      -- Clear sneak flag upon handing back the control to vanilla AI
      if state and sneakControlSet then
         omwself.controls.sneak = false
         sneakControlSet = false
      end
   end
end

interface.setEnabled = function(state)
   interface.enabled = state
   enableAI(state)
end

local lastFleeValue = selfActor:aiFleeStat().modified

-- Rolls whether to warn the enemy (STAND_GROUND) rather than fight, only while the NPC still has patience left
local function rollWarn(enemyActor, damageValue)
   if state.warnsLeft <= 0 or isGuard or damageValue > 0 then return false end
   local fightValue = selfActor:aiFightStat().modified + gutils.getFightDispositionBias(omwself, enemyActor)
   -- 90% at fight value 85 or less, down to 20% at 97 and above, scaled by the Stand Back Modifier setting
   local standGroundProb = util.clamp(util.remap(fightValue, 85, 100, 0.9, 0), 0.2, 0.9) * StandGroundProbModifier
   return luaRandom:random() <= standGroundProb
end

-- Every warning uses up one point of patience
local function startWarning(enemyActor)
   state.warnsLeft = state.warnsLeft - 1
   state.combatState = enums.COMBAT_STATE.STAND_GROUND
   state.standGroundOrigin = omwself.position
   state.lastSeenPos = enemyActor.position
   state.enemyLostFor = 0
   state.staringProgress = 0
   lastSeenAt = core.getSimulationTime()
   -- Trees stop running when combat ends, so a sneak-up branch can be left mid-way. With these false it
   -- aborts itself (Lost Sight's condition turns false) and clears the rest of its state.
   state.sneakingUp = false
   state.caught = false
end

-- Leaves combat with an enemy that was out of sight for too long. Fight isn't lowered, so the engine
-- starts combat again once it spots them.
local function giveUp(enemyActor)
   gutils.print("Lost sight of ", enemyActor.recordId, " for too long, leaving combat", 1)
   AI.filterPackages(function(package)
      return not (package.type == "Combat" and package.target == enemyActor)
   end)
   activeAiPackage = { type = nil }
   lastAiPackage = activeAiPackage
   combatTargets = {}
   state.combatState = enums.COMBAT_STATE.NO_STATE
   enableAI(true)
   selfActor:setStance(types.Actor.STANCE.Nothing)
end

-- Testing: spells from the player's "luamercy" console command, waiting to be learned. 'next' means they go to the next
-- spellcaster that starts a fight rather than to this actor in particular.
local pendingConsoleSpells = nil

-- Per-frame combat work of the custom spells this actor knows (their 'combatUpdate'), run by the main loop in combat
local spellCombatUpdates = {}
local function updateSpellCombatUpdates()
   spellCombatUpdates = {}
   for key, known in pairs(state.knownCustomSpells) do
      local definition = magicUtil.CUSTOM_SPELLS[key]
      if known and definition and definition.combatUpdate then
         spellCombatUpdates[#spellCombatUpdates + 1] = definition.combatUpdate
      end
   end
end

-- Replaces all of Mercy's custom spells this actor knows with the given keys, ready to cast
local function learnCustomSpells(keys)
   local actorSpells = types.Actor.spells(omwself)
   for _, learnedId in pairs(learnedCustomSpells or {}) do
      if learnedId then pcall(function() actorSpells:remove(learnedId) end) end
   end
   for _, spellId in pairs(state.customSpells) do
      pcall(function() actorSpells:remove(spellId) end)
   end
   pendingSpellHits = {}
   learnedCustomSpells = {}
   for _, key in ipairs(keys) do
      local spellId = state.customSpells[key]
      if not magicUtil.isAvailable(key) then
         magicUtil.log("Custom spell", key, "isn't available in this game, not learned")
      elseif spellId then
         actorSpells:add(spellId)
         learnedCustomSpells[key] = spellId
         state.customSpellCooldowns[key] = 0
         state.customSpellMisses[key] = 0
         magicUtil.log("Learned custom spell", key)
      end
   end
   for key, spellId in pairs(state.customSpells) do
      state.knownCustomSpells[key] = learnedCustomSpells[key] == spellId
   end
   updateSpellCombatUpdates()
end

local function learnConsoleSpells()
   local request = pendingConsoleSpells
   pendingConsoleSpells = nil
   learnCustomSpells(request.keys)
   local text = "Mercy: " .. omwself.recordId .. " now knows " .. table.concat(request.keys, ", ")
   if request.player and request.player:isValid() then
      request.player:sendEvent("Mercy_ConsoleSpellsLearned", { actor = omwself.object, next = request.next, text = text })
   end
end

-- The actor's own spells as Mercy last saw them in full (magic_util.scanCastables), for what they cost: the Magic
-- Window checks it can afford one, mana potions are drunk when it can't. OSSC strips an actor's spells from its list
-- while it runs the actor's casting in a fight, so a scan at combat start can come back empty for a mage. The richest
-- scan of the session is kept instead, starting with one made when Mercy starts on the actor (almost always out of
-- combat, before OSSC can have stripped anything). Whether the actor is a spellcaster doesn't come from here at all:
-- that's its class (isSpellCaster), which nothing can strip.
local spellScan = nil
local function scanOwnMagic()
   -- Mercy's own spells don't count, old records of them (from before a version bump) included
   local ignored = {}
   for _, spellId in pairs(state.customSpells) do ignored[spellId] = true end
   for _, spellId in pairs(learnedCustomSpells or {}) do
      if spellId then ignored[spellId] = true end
   end
   local scan = magicUtil.scanCastables(omwself, ignored)
   if not spellScan or scan.combatSpellCount > spellScan.combatSpellCount then spellScan = scan end
   -- Items aren't touched by OSSC and can change between fights: those always come from the fresh scan
   state.castables = {
      knownSpellCount = spellScan.knownSpellCount,
      combatSpellCount = spellScan.combatSpellCount,
      cheapestSpellCost = spellScan.cheapestSpellCost,
      hasItems = scan.hasItems,
      canUseMagic = spellScan.combatSpellCount > 0 or scan.hasItems,
   }
end

-- On combat start: work out what magic the actor has, and on its first fight let a spellcaster - by class, see
-- isSpellCaster - learn Mercy's custom spells, or upgrade a non-caster into one
local function prepareMagic()
   lastControlOwner = nil
   pendingSpellHits = {}
   -- The trees just stop being run when a fight ends, so a branch can be left part way through with the flag set.
   -- Clearing it here means a new fight never starts with magic locked out.
   state.inAttackSequence = false
   magicUtil.osscResetHold()
   scanOwnMagic()

   local actorSpells = types.Actor.spells(omwself)
   local firstFightCaster = false
   -- For the custom spell distribution: its level and what kind of character it is
   local function distributionNpc()
      local characterType = enums.CHARACTER_TYPE.Melee
      if isSpellCaster then
         characterType = enums.CHARACTER_TYPE.Spellcaster
      else
         for _, weapon in ipairs(types.Actor.inventory(omwself):getAll(types.Weapon)) do
            if gutils.isMarksmanWeapon(weapon) then
               characterType = enums.CHARACTER_TYPE.Marksman
               break
            end
         end
      end
      magicUtil.log("Custom spell distribution: level", selfActor:levelStat().current, characterType)
      return { level = selfActor:levelStat().current, characterType = characterType,
         extraSpellRolls = extraSpellsForHighLevelCasters,
         -- Seeded from the record id, so which spells this NPC gets is the same in every playthrough
         rng = function() return luaRandom:random() end }
   end
   if pendingConsoleSpells and (not pendingConsoleSpells.next or isSpellCaster) then
      learnConsoleSpells()
   elseif not learnedCustomSpells then
      if isSpellCaster then
         firstFightCaster = true
         if luaRandom:random() < casterCustomSpellsChance then
            learnCustomSpells(magicUtil.rollCustomSpells(distributionNpc()))
         else
            learnCustomSpells({})
            magicUtil.log("Spellcaster not picked for custom spells")
         end
      elseif luaRandom:random() < nonCasterCustomSpellsChance then
         firstFightCaster = true
         upgradedToCaster = true
         magicUtil.log("Not a spellcaster by class, upgraded to one")
         learnCustomSpells(magicUtil.rollCustomSpells(distributionNpc()))
      else
         learnedCustomSpells = {}
         magicUtil.log("Not a spellcaster by class, gets no custom spells")
      end
   else
      -- The global script recreates a custom spell when its definition changes: swap the old record for the new one
      for key, learnedId in pairs(learnedCustomSpells) do
         local currentId = state.customSpells[key]
         if learnedId and currentId and learnedId ~= currentId then
            pcall(function() actorSpells:remove(learnedId) end)
            actorSpells:add(currentId)
            learnedCustomSpells[key] = currentId
            magicUtil.log("Updated custom spell", key, learnedId, "->", currentId)
         end
      end
   end
   for key, spellId in pairs(state.customSpells) do
      state.knownCustomSpells[key] = learnedCustomSpells[key] == spellId
   end
   updateSpellCombatUpdates()

   -- Handing the actor to the engine to pick a spell (the Magic Window) is only for spellcasters: NPCs whose class
   -- casts, and the ones Mercy upgraded into casters. Knowing a single combat spell doesn't make a bandit a mage, and
   -- the handover cost it its melee rhythm. Decided after the upgrade roll above, so a fresh upgrade counts.
   if not isSpellCaster and not upgradedToCaster and state.castables.canUseMagic then
      magicUtil.log("Not a spellcaster by class: no engine magic windows")
      state.castables.canUseMagic = false
   end

   local knownCustomSpellIds = {}
   for key, known in pairs(state.knownCustomSpells) do
      if known and magicUtil.isAvailable(key) then knownCustomSpellIds[#knownCustomSpellIds + 1] = state.customSpells[key] end
   end
   manaPotions.onCombatStart(omwself.object, manaPotionChance, firstFightCaster, state.castables.cheapestSpellCost,
      knownCustomSpellIds, function() return luaRandom:random() end)

   -- Some spells stay unused for a while after a fight starts
   local now = core.getSimulationTime()
   for key, definition in pairs(magicUtil.CUSTOM_SPELLS) do
      if (definition.prewarm or 0) > 0 then
         state.customSpellCooldowns[key] = math.max(state.customSpellCooldowns[key] or 0, now + definition.prewarm)
      end
   end
end




----------------------------------------------------------------
-- Ask Global script to provide all the necessary json and config data, its response will trigger a STARTEVERYTHING method below
core.sendGlobalEvent("HiImMercyActor",{source = omwself})
----------------------------------------------------------------
----------------------------------------------------------------


-- A function that will initialise all behavior trees on a first update. Done on a first update so other mods have a chance to provide extensions
-- via the interface
local function STARTEVERYTHING(BTJsonData)
   if isBlacklisted(blacklist.full_disable) then
      gutils.print(omwself.recordId," is BLACKLISTED from starting Mercy:CAO, Mercy will not start", 1)
      return
   end

   gutils.print(omwself.recordId," Passed a blacklist check - starting", 1)
   
   -- STARTING EVERYTHING -------------------
   -- Initialise behaviour trees ----------------------------------------------
   bTrees = BT.LoadBehavior3Project(BTJsonData, state, function(nodeConfig, treeData)
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
   -- What the actor's own spells cost, read now while no fight is on (see scanOwnMagic)
   scanOwnMagic()

   -- Patience is rolled once, a loaded game keeps the saved one
   if state.warnsLeft == nil then state.warnsLeft = math.random(1, 3) end

   if isBlacklisted(blacklist.surrender_disable) or isGuard then
      gutils.print(omwself.recordId," Is BLACKLISTED from surrendering (blacklist match or is a guard).", 1)
      ScaredProbModifier = 0
   end
end





-- Main update function (finally) --
------------------------------------
local function onUpdate(dt)
   if dt <= 0 then return end

   -- Mercy is taking a rest if another mod disabled it
   if interface.enabled == false then return end

   if not bTrees then return end

   --print(omwself.recordId)
   --print(selfActor:getDetailedStance())
   --print(selfActor:getEquipment(types.Actor.EQUIPMENT_SLOT.CarriedRight))

   -- Only modify AI if it's in combat!
   
   -- This is now replaced by a hack of retransmitting target update events from music event emitted to player
   -- Check AI package only once every 0.5 seconds
   --[[ local now = core.getRealTime()
   if now - lastAiPackageCheck >= 0.5 then  
      combatTargets = AI.getTargets("Combat")   
      if not combatTargets then combatTargets = {} end
      if #combatTargets > 0 then
         activeAiPackage = {type = "Combat"}
      end
      --activeAiPackage = AI.getActivePackage()
      lastAiPackageCheck = now
   end ]]

   

   -- Short circuit out of here if not in Combat state, this is done for the sake of optimisation since currently any access to
   -- lua API is prone to excessive memory allocations.
   if activeAiPackage.type ~= "Combat" then
      state.combatState = enums.COMBAT_STATE.NO_STATE
      lastAiPackage = activeAiPackage
      enableAI(true)
      return
   end
   
   local enemyActor = combatTargets[1]

   -- Always track HP, for damage events   
   local currentHealth = selfActor:healthStat().current
   local damageValue = lastHealth - currentHealth
   state.damageValue = damageValue
   lastHealth = currentHealth

   -- Damage ends invisibility tricks: a repositioning actor stops, a hiding one is found out. On the move only a hit of
   -- at least MOVING_DAMAGE_THRESHOLD of base health counts, once sitting in the hiding spot any damage does.
   local hidingNow = state.combatState == enums.COMBAT_STATE.HIDE
   if damageValue > 0 and (state.repositioning or hidingNow) then
      local bigHit = damageValue >= selfActor:healthStat().base * MOVING_DAMAGE_THRESHOLD
      if state.repositioning and bigHit then
         state.repositioning = false
         magicUtil.log("Repositioning stopped: took", damageValue, "damage")
      end
      if hidingNow and not state.hideDamaged and (state.hideAtSpot or bigHit) then
         state.hideDamaged = true
         magicUtil.log("Took", damageValue, "damage while hiding", state.hideAtSpot and "in the spot" or "on the way")
      end
   end

   -- Time
   local now = core.getSimulationTime()

   if next(pendingSpellHits) then checkCustomSpellHits(now) end
   for i = 1, #spellCombatUpdates do spellCombatUpdates[i](state) end
   manaPotions.combatUpdate(omwself.object, now)
   updateOSSCHold()


   -- Storing combat targets in history
   gutils.addTargetsToHistory(combatTargets)

   

   -- Should we control character with Mercy?
   -- If we are not in a combat state - the engine will handle AI
   local shouldOverrideAI = true
   local detStance = selfActor:getDetailedStance()
   if detStance ~= lastLoggedStance then
      magicUtil.log("Stance:", lastLoggedStance or "-", "->", detStance)
      lastLoggedStance = detStance
   end
   if activeAiPackage.type ~= "Combat" or not enemyActor or types.Actor.isDead(enemyActor) or selfActor:isDead() then
      shouldOverrideAI = false
   end
   -- Spellcasters are handed to the engine in short windows from the tree (Magic Window, see canHandOverForMagic)
   -- A small grace period when an empty target is detected in a cobat package. Allows engine to clean up.
   if not notargetDetectedAt then
      for _, target in ipairs(combatTargets) do
         if not target or not target:isValid() then
            notargetDetectedAt = now
         end
      end
   end
   
   --[[ AI.forEachPackage(function(package)
      if package.type == "Combat" and not package.target and not notargetDetectedAt then
         notargetDetectedAt = now
      end
   end) ]]
   if notargetDetectedAt and now - notargetDetectedAt <= notargetGracePeriod then
      shouldOverrideAI = false
   else
      notargetDetectedAt = nil
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
      prepareMagic()
      -- Initialising combat state
      if enemyActor then                 
         if rollWarn(enemyActor, damageValue) then
            core.sound.stopSay(omwself);
            startWarning(enemyActor)
         else
            state.combatState = enums.COMBAT_STATE.FIGHT
         end
      else
         state.combatState = enums.COMBAT_STATE.FIGHT
      end
   end

   -- While warning, track whether the enemy is in line of sight. Seen again after being lost - the warning is rolled
   -- again, out of sight for too long - leave combat. Done before any fallback to vanilla AI, so it always runs.
   if state.combatState == enums.COMBAT_STATE.STAND_GROUND and enemyActor then
      local simNow = core.getSimulationTime()
      if simNow - lastSightCheck >= SIGHT_CHECK_PERIOD then
         lastSightCheck = simNow
         state.enemyInSight = gutils.hasLineOfSight(omwself, enemyActor)
         if state.enemyInSight then
            -- Not while sneaking up, the tree carries on with that
            if simNow - lastSeenAt >= state.lostSightTime and not state.sneakingUp then
               if rollWarn(enemyActor, damageValue) then
                  startWarning(enemyActor)
                  state.warnRequested = true
               else
                  state.combatState = enums.COMBAT_STATE.FIGHT
               end
            end
            lastSeenAt = simNow
            state.lastSeenPos = enemyActor.position
         end
      end
      state.enemyLostFor = simNow - lastSeenAt

      local giveUpTime = state.sneakingUp and SNEAK_GIVE_UP_TIME or GIVE_UP_TIME
      if state.combatState == enums.COMBAT_STATE.STAND_GROUND and state.enemyLostFor >= giveUpTime then
         giveUp(enemyActor)
         return
      end
   end

   -- Check for retreating/mercy, both based on internal Mercy flee factors as well as in-game flee value
   local mercyScared = false   
   local fleeValue = selfActor:aiFleeStat().modified
   if (state.combatState == enums.COMBAT_STATE.FIGHT or state.combatState == enums.COMBAT_STATE.STAND_GROUND) then
      mercyScared = isSelfScared(damageValue)
      if fleeValue ~= lastFleeValue and lastFleeValue < 100 and fleeValue >= 100 and luaRandom:random() <= MercyScaredOnFleeValProb then mercyScared = true end
   end
   lastFleeValue = fleeValue

   local fightingACreature
   for _, target in ipairs(combatTargets) do
      if types.Creature.objectIsInstance(target) then
         fightingACreature = true
         break
      end
   end
   if mercyScared then
      local potentialStates = {}
      if not retreatedOnce then table.insert(potentialStates, enums.COMBAT_STATE.RETREAT) end
      if not askedForMercyOnce and not fightingACreature then table.insert(potentialStates, enums.COMBAT_STATE.MERCY) end
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

   -- if we can't find a nav path to enemy - fallback to vanilla behaviour. Not while warning or hiding: those don't chase,
   -- and vanilla AI would charge or drop combat instead.
   if enemyActor then
      state.navService:setTargetPos(enemyActor.position)
      if state.combatState ~= enums.COMBAT_STATE.STAND_GROUND and state.combatState ~= enums.COMBAT_STATE.HIDE and (#state.navService.path == 0 or (state.range and (state.navService.path[#state.navService.path] - enemyActor.position):length() > state.range)) then
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
   enableAI(not shouldOverrideAI)
   if not shouldOverrideAI then
      noteControlOwner("vanilla (fallback)", detStance)
      return
   end


   -- Provide Behaviour Tree state with the necessary info --------------
   ----------------------------------------------------------------------
   state:clear()

   state.dt = dt

   if state.enemyActor ~= enemyActor then
      if enemyActor then state.enemyActorAux = gutils.Actor:new(enemyActor) else
      state.enemyActorAux = nil end
   end
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
   -- Lockpicks and probes also go into CarriedRight; treat them as hand-to-hand
   if weaponObj and types.Weapon.objectIsInstance(weaponObj) then weaponRecord = types.Weapon.record(weaponObj.recordId) end

   if weaponRecord.id ~= lastWeaponRecord.id then
      if weaponRecord.id then
         state.weaponAttacks = gutils.getSortedAttackTypes(weaponRecord)         
         state.weaponSkill = itemutil.getSkillStatForEquipment(selfActor, weaponObj).modified
         state.reach = weaponRecord.reach * fCombatDistance * 0.95
      else
         -- We are using hand-to-hand
         state.weaponAttacks = gutils.getSortedAttackTypes(nil)         
         state.weaponSkill = selfActor:getSkillStat("handtohand").modified
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


   -- While Mercy casts a custom spell it drives the actor, even if a stance branch wants to hand it to the engine,
   -- and it stands still while casting
   if state.castingCustom then
      state.vanillaBehavior = false
      state.movement = 0
      state.sideMovement = 0
      if state.aimDirection then state.lookDirection = state.aimDirection end
   end

   -- While repositioning or hiding Mercy drives the actor whatever its stance, and keeps the stance it has (spell or
   -- weapon ready, so it doesn't lose time drawing it when it comes out). With nothing drawn it readies its weapon.
   if state.repositioning or state.combatState == enums.COMBAT_STATE.HIDE then
      state.vanillaBehavior = false
      state.stance = selfActor:getStance()
      if state.stance == types.Actor.STANCE.Nothing then state.stance = types.Actor.STANCE.Weapon end
   end

   -- Apply state properties modified by behavior trees to actor controls ----
   if state.vanillaBehavior then
      enableAI(true)
      noteControlOwner("vanilla (tree)", detStance)
      return
   else
      noteControlOwner("mercy", detStance)
      if state.stance ~= selfActor:getStance() then
         selfActor:setStance(state.stance)
      end
      omwself.controls.run = state.run
      omwself.controls.movement = state.movement
      omwself.controls.sideMovement = state.sideMovement
      omwself.controls.use = state.attack      
      omwself.controls.jump = state.jump
      omwself.controls.sneak = state.sneak
      sneakControlSet = state.sneak

      -- If no lookDirection provided - default behaviour is to stare at the enemy
      -- If an attack is in progress - force look at enemyActor
      local lookDirection
      if state.attackState == enums.ATTACK_STATE.NO_STATE then
         lookDirection = state.lookDirection
      end
      -- Not while hiding: a hiding actor keeps its facing, so an enemy can come up behind it
      if not lookDirection and state.enemyActor and state.combatState ~= enums.COMBAT_STATE.HIDE then
         lookDirection = state.enemyActor.position - omwself.position
      end
      if lookDirection then
         -- Actual rotation is changed somewhat gradually
         omwself.controls.yawChange = gutils.lerpClamped(0,
            -moveutils.lookRotation(omwself, omwself.position + lookDirection), dt * (state.turnRate or 3))
      end

      -- Pitch is only steered while a node aims (pitchTarget), then levelled back once
      if state.pitchTarget or pitchSteered then
         local forward = omwself.rotation:apply(util.vector3(0, 1, 0))
         local pitch = -math.asin(util.clamp(forward.z, -1, 1)) -- positive looks down, like the engine
         local pitchError = (state.pitchTarget or 0) - pitch
         if math.abs(pitchError) > 0.01 then
            omwself.controls.pitchChange = pitchError * math.min(1, dt * 8)
            pitchSteered = true
         else
            omwself.controls.pitchChange = 0
            pitchSteered = state.pitchTarget ~= nil
         end
      end
   end

   -- Just a silly hack to ensure that ai package is update on time after Pacify node
   if state.resetActiveAiPackage then
      state.resetActiveAiPackage = nil
      activeAiPackage = { type = nil }
      combatTargets = {}
   end

   -- Notify everyone on a combat state change
   if state.combatState ~= lastCombatState then
      magicUtil.log("Combat state:", lastCombatState or "-", "->", state.combatState)
      for _, target in ipairs(combatTargets) do
         target:sendEvent("Mercy_CombatStateChanged", { sender = omwself, combatState = state.combatState})
      end
      lastCombatState = state.combatState
   end   
end




-- Animation handlers -------------------------------------------------------------
-----------------------------------------------------------------------------------

-- Animation groups the Consuming Animated mod plays on NPCs (see its potionanim_shared.lua)
local CONSUMING_ANIMATED_GROUPS = { potionl = true, eatingr = true, bugmusk2 = true, drinkbone = true, smokepipe1 = true,
   skoomapipe = true, smoke1r = true }

I.AnimationController.addPlayBlendedAnimationHandler(function(groupname, options)
   --print("New animation started! " .. groupname .. " : " .. options.startkey .. " --> " .. options.stopkey)
   -- Detect being staggered
   if gutils.stringStartsWith(groupname, "hit") then
      state.staggerGroup = groupname
   end
   -- Debug: drinking and eating animations from Consuming Animated, to see whether they get in the way of casting
   if CONSUMING_ANIMATED_GROUPS[groupname] then
      state.consumeAnimStartedAt = core.getSimulationTime()
      magicUtil.log("Consuming animation started:", groupname, "| stance", selfActor:getDetailedStance(),
         "| combat state", state.combatState, "| casting custom", state.castingCustom)
   end
end)

-- While sitting in a hiding spot: the enemy swinging a melee weapon (or fists) towards the NPC from within its reach,
-- in front of the NPC and in its line of sight, gets it out of hiding after HIDE_THREAT_DELAY (see foundOut). The player
-- script sends PlayerUse to nearby NPCs, one per frame, while use is held.
Events:addEventHandler(function(e, data)
   if e ~= "PlayerUse" or state.combatState ~= enums.COMBAT_STATE.HIDE or not state.hideAtSpot or state.hideThreatenedAt then
      return
   end
   local enemy = state.enemyActor
   if not enemy or data.source ~= enemy or not data.use or data.use <= 0 then return end
   if types.Actor.getStance(enemy) ~= types.Actor.STANCE.Weapon then return end
   local weapon = types.Actor.getEquipment(enemy, types.Actor.EQUIPMENT_SLOT.CarriedRight)
   if gutils.isMarksmanWeapon(weapon) then return end
   local reach = fHandToHandReach * fCombatDistance
   if weapon and types.Weapon.objectIsInstance(weapon) then reach = types.Weapon.record(weapon).reach * fCombatDistance end
   if gutils.getDistanceToBounds(omwself, enemy) > reach then return end

   local toMe = omwself.position - enemy.position
   local enemyForward = enemy.rotation:apply(util.vector3(0, 1, 0))
   if enemyForward:normalize():dot(toMe:normalize()) < math.cos(math.rad(SPOTTED_ANGLE)) then return end
   local myForward = omwself.rotation:apply(util.vector3(0, 1, 0))
   if util.vector2(myForward.x, myForward.y):dot(util.vector2(-toMe.x, -toMe.y)) <= 0 then return end
   if not gutils.hasLineOfSight(omwself, enemy) then return end

   state.hideThreatenedAt = core.getSimulationTime()
   magicUtil.log("Hiding: the enemy swings a weapon at it, coming out in", HIDE_THREAT_DELAY, "s")
end)

-- While Mercy makes this NPC sneak, or it's invisible in combat, cut its footsteps short. The engine plays them from 'soundgen: left/right' keys
-- and Lua only hears about a key after the sound started, so roughly the first frame of each step still plays.
local FOOTSTEP_SOUNDS = {
   left = { "FootBareLeft", "footLightLeft", "FootMedLeft", "footHeavyLeft", "FootWaterLeft", "Swim Left" },
   right = { "FootBareRight", "footLightRight", "FootMedRight", "footHeavyRight", "FootWaterRight", "Swim Right" },
}
I.AnimationController.addTextKeyHandler("soundgen", function(groupname, key)
   if not sneakControlSet and not (activeAiPackage.type == "Combat" and gutils.actorHasEffect(omwself, "invisibility")) then
      return
   end
   -- The key can carry volume and pitch after the side, e.g. "left 0.5 1"
   local sounds = FOOTSTEP_SOUNDS[key:match("^%a+")]
   if not sounds then return end
   for _, soundId in ipairs(sounds) do
      core.sound.stopSound3d(soundId, omwself)
   end
end)

-- In the text key handler: Theres no way to know for which bonegroup the text key was triggered?
I.AnimationController.addTextKeyHandler(nil, function(groupname, key)
   --print("Animation text key! " .. groupname .. " : " .. key)
   -- "shoot start" is a bow, crossbow or thrown weapon: without it a draw only showed up once it reached "min attack"
   if string.find(key, "chop start") or string.find(key, "thrust start") or string.find(key, "slash start")
      or string.find(key, "shoot start") then
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
   if not bTrees then return end

   --gutils.print("Oh no, ", e.source.recordId, " got damaged!")
   gutils.print("Friend " .. e.source.recordId .. " was attacked", 1)
   if selfActor:isDead() then return end

   if state.combatState == enums.COMBAT_STATE.STAND_GROUND then
      state.combatState = enums.COMBAT_STATE.FIGHT
   end
   if lastAiPackage.type ~= "Combat" then
      if gutils.hasLineOfSight(omwself, e.source) then
         gutils.print("Friend " .. e.source.recordId .. " was attacked, starting a combat AI package", 1)
         AI.startPackage({ type = 'Combat', target = e.offender })
      else
         gutils.print("Friend " .. e.source.recordId .. " was attacked out of line of sight", 1)
      end
   end
end

local avengeSaid = false
local function onFriendDead(e)
   if not bTrees then return end

   gutils.print("Oh no, friend: ", e.source.recordId .. " is dead!", 1)
   if selfActor:isDead() then return end
   if state.combatState == enums.COMBAT_STATE.FIGHT and gutils.isMyFriend(e.source) and math.random() < AvengeShoutProb and not avengeSaid then
      voiceManager.say(omwself, nil, "FriendDead")
      avengeSaid = true
   end
end

local enemyCombatStates = {}
local function onEnemyCombatStateChanged(e)
   if not bTrees then return end

   gutils.print("Received a combat state update from ", e.sender, e.combatState, 1)
   enemyCombatStates[e.sender.id] = e.combatState
   if e.combatState == enums.COMBAT_STATE.MERCY and imACompanion and next(combatTargets) then
      -- This NPC surrenders, companions shall show mercy
      if math.random() <= CompanionMercyProb then
         gutils.print("Enemy ", e.sender.recordId, " is asking for mercy.", omwself.recordId .. " is a merciful companion.", 1)
         AI.filterPackages(function(package)
            return package.target ~= e.sender
         end)
      end
   end
end

local function isPlayerInTargets(targets)
   if not targets then return end
   for _, t in ipairs(targets) do
      if types.Player.objectIsInstance(t) then return true end
   end
   return false
end

local function onTargetsChanged(e)
   combatTargets = e.targets
   if not combatTargets then combatTargets = {} end

   if next(combatTargets) then
      -- Update ai package
      activeAiPackage = {type = "Combat"}
      -- Update follow and escort targets, updated only here for performance reasons
      followTargets = AI.getTargets("Follow")
      escortTargets = AI.getTargets("Escort")
      imACompanion = isPlayerInTargets(followTargets) or isPlayerInTargets(escortTargets)
      state.isCompanion = imACompanion      
   else
      activeAiPackage = {type = nil}
   end
end


-- Engine handlers ------------------------------------------------------------
-------------------------------------------------------------------------------
local eventHandlers = {
   -- Own combat targets, sent to this actor by Max Yari's Script Services (MSS) whenever they change
   MSS_CombatTargets = onTargetsChanged,
   Mercy_StartupData = function(e)
      gutils.print(omwself.recordId," Received startup data from Global", 1)
      blacklist = e.blacklist
      state.itemDumpExclusions = blacklist.item_dump_disable.recordIdsMap
      state.customSpells = e.customSpells or {}
      STARTEVERYTHING(e.b3projectJson)
      -- Combat targets otherwise only arrive when they change: an NPC already fighting when Mercy starts on it (a save
      -- loaded mid-fight, or startup reaching it a few frames into a fight) would be left to vanilla AI for that fight
      if I.MSS and I.MSS.getCombatTargets then onTargetsChanged({ targets = I.MSS.getCombatTargets() }) end
   end,
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
   end,
   Mercy_CombatStateChanged = onEnemyCombatStateChanged,
   -- Mana potions Mercy kept for this caster go into its inventory, to be looted
   Died = function()
      manaPotions.onDied(omwself.object, manaPotionLootChance)
   end,
   -- Testing: custom spells from the player's "luamercy" console command. Given to this actor right away, or with 'next'
   -- kept until it starts a fight as a spellcaster. 'cancel' drops a 'next' request another actor already took.
   Mercy_ConsoleSpells = function(e)
      if e.cancel then
         if pendingConsoleSpells and pendingConsoleSpells.next then pendingConsoleSpells = nil end
         return
      end
      pendingConsoleSpells = e
      if not e.next and next(state.customSpells) then learnConsoleSpells() end
   end,
}
-- Custom spells' own local event handlers, from their files in scripts/spells: as the caster, and as a possible target
for _, spell in pairs(magicUtil.CUSTOM_SPELLS) do
   for name, handler in pairs(spell.localEventHandlers or {}) do
      eventHandlers[name] = function(data) handler(state, data) end
   end
   for name, handler in pairs(spell.targetEventHandlers or {}) do
      eventHandlers[name] = handler
   end
end

return {
   engineHandlers = {
      onUpdate = onUpdate,
      -- Debug: anything this NPC consumes (a potion drunk by Mercy or by the engine's AI)
      onConsume = function(item)
         state.consumedAt = core.getSimulationTime()
         magicUtil.log("Consumed", item.recordId, "| in combat", activeAiPackage.type == "Combat", "| AI by",
            aiEnabled and "engine" or "mercy", "| stance", selfActor:getDetailedStance())
      end,
      onSave = function()
         return { warnsLeft = state.warnsLeft, learnedCustomSpells = learnedCustomSpells,
            upgradedToCaster = upgradedToCaster, manaPotions = manaPotions.save() }
      end,
      onLoad = function(data)
         if data then
            state.warnsLeft = data.warnsLeft
            learnedCustomSpells = data.learnedCustomSpells
            upgradedToCaster = data.upgradedToCaster == true
            manaPotions.load(data.manaPotions)
         end
      end,
   },
   eventHandlers = eventHandlers,
   interfaceName = "MercyCAO",
   interface = interface
}
