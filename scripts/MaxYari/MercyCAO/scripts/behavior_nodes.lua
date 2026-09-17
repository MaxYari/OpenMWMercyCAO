local mp = "scripts/MaxYari/MercyCAO/"

-- Mod files
local gutils = require(mp .. "scripts/gutils")
local moveutils = require(mp .. "scripts/movementutils")

local voiceManager = require(mp .. "scripts/voice_manager")
local animManager = require(mp .. "scripts/anim_manager")
local enums = require(mp .. "scripts/enums")

-- OpenMW libs
local omwself = require('openmw.self')
local selfActor = gutils.Actor:new(omwself)
local core = require('openmw.core')
local AI = require('openmw.interfaces').AI
local util = require('openmw.util')
local types = require('openmw.types')
local nearby = require('openmw.nearby')
local animation = require('openmw.animation')
local I = require('openmw.interfaces')


if not Events and I.MercyCAO then Events = I.MercyCAO.Events end


local BT = require(mp .. "libs/behaviourtreelua2e/lib/behaviour_tree")

local NavigationService = require(mp .. "scripts/navservice")
local navService = NavigationService({
    cacheDuration = 1,
    targetPosDeadzone = 50,
    pathingDeadzone = 35
})


local magicUtil = require(mp .. "scripts/magic_util")


-- Custom behaviours ------------------
---------------------------------------

-- Hands the actor to the engine's AI. Runs forever by default. With 'duration' it ends after that many seconds, and
-- with 'endOnStance' (e.g. "Spell") it ends as soon as the engine puts the actor in that stance.
local function VanillaBehavior(config)
    local p = config.properties

    config.start = function(task, state)
        state.vanillaBehavior = true
        task.endsAt = nil
        if p.duration then
            task.endsAt = core.getSimulationTime() + p.duration()
            magicUtil.log(config.name, "handing over to the engine for", p.duration(), "s")
        end
    end

    config.run = function(task, state)
        state.vanillaBehavior = true
        -- A custom spell is waiting (see PeriodicInterrupt): once the engine's current cast is over, hold the spell
        -- stance for Mercy instead of letting the engine start another cast or draw a weapon
        if not task.endsAt and (state.customSpellReservedUntil or 0) > core.getSimulationTime()
            and types.Actor.getStance(omwself) == types.Actor.STANCE.Spell and not magicUtil.isCasting(omwself) then
            state.vanillaBehavior = false
            state.stance = types.Actor.STANCE.Spell
            return task:running()
        end
        if task.endsAt then
            if p.endOnStance and state.detStance == p.endOnStance() then
                -- Still vanilla for this frame, so Mercy doesn't put the stance it picked back
                magicUtil.log(config.name, "the engine switched to", state.detStance, "stance")
                return task:success()
            end
            if core.getSimulationTime() >= task.endsAt then
                magicUtil.log(config.name, "window over, the engine kept", state.detStance, "stance")
                state.vanillaBehavior = false
                return task:success()
            end
        end
        task:running()
    end

    return BT.Task:new(config)
end

BT.register("VanillaBehavior", VanillaBehavior)


local function ContinuousCondition(config)
    config.isStealthy = false

    config.shouldRun = function(task, state)
        if not task.started then return false end
        -- Only interrupt itself, and only when condition is false
        return config.condition(task, state)
    end

    config.start = function(task, state)
        if not config.condition(task, state) then
            task:fail()
        else
            task.started = true
        end
    end

    config.finish = function(task, state)
        task.started = false
    end

    return BT.InterruptDecorator:new(config)
end

local function InMarksmanStance(config)
    config.condition = function(task, state)
        return state.detStance == gutils.Actor.DET_STANCE.Marksman
    end

    return ContinuousCondition(config)
end

BT.register("InMarksmanStance", InMarksmanStance)

local function InMeleeStance(config)
    config.condition = function(task, state)
        return state.detStance == gutils.Actor.DET_STANCE.Melee
    end

    return ContinuousCondition(config)
end

BT.register("InMeleeStance", InMeleeStance)

local function InSpellStance(config)
    config.condition = function(task, state)
        return state.detStance == gutils.Actor.DET_STANCE.Spell
    end

    return ContinuousCondition(config)
end

BT.register("InSpellStance", InSpellStance)


local function ChaseTarget(config)
    local props = config.properties

    config.start = function(task, state)
        config.findTargetActor(task, state)
        task.desiredSpeed = -1
        if props.speed then task.desiredSpeed = props.speed() end
    end

    config.run = function(task, state)
        config.findTargetActor(task, state)
        if not task.targetActor or types.Actor.isDead(task.targetActor) then
            return task:fail()
        end

        local nav
        if task.targetActor == state.enemyActor then
            -- If target is the same as enemyActor - navigation was already calculated in the main loop - use that
            nav = state.navService
        else
            nav = navService
            nav:setTargetPos(task.targetActor.position)
        end
        
        local movement, sideMovement, run, lookDirection = nav:run({
            desiredSpeed = task.desiredSpeed,
            ignoredObstacleObject = task
                .targetActor
        })
        if nav.doorStuck then
            gutils.print("Chase Target aborted due to the actor being stuck on a door.", 1)
            magicUtil.log(config.name, "aborted: stuck on a door")
            return task:fail()
        end

        if #nav.path == 0 then
            gutils.print("Chase Target aborted due to unable to calculate a path.", 1)
            magicUtil.log(config.name, "aborted: no path to", task.targetActor.recordId)
            return task:fail()
        end

        local proximity = 0
        local distance = gutils.getDistanceToBounds(task.targetActor, omwself)
        if props.proximity then proximity = props.proximity() end
        if distance <= proximity or nav:isPathCompleted() then
            return task:success()
        end


        state.movement, state.sideMovement, state.run, state.lookDirection = movement, sideMovement, run, lookDirection
        if config.getLookDirection and config.getLookDirection(task, state) then
            state.lookDirection = config
                .getLookDirection(task, state)
        end

        return task:running()
    end

    return BT.Task:new(config)
end

function MoveInDirection(config)
    -- Directions are relative to the direction from actor to its target, i.e closer to target, further, strafe around to the right and to the left.
    local props = config.properties

    config.name = config.name .. " " .. tostring(props.direction())

    config.start = function(self, state)
        self.lastPos = omwself.position
        self.coveredDistance = 0
        self.startedAt = core.getSimulationTime()
        self.foo = self.barbar
        self.runSpeed = selfActor:getRunSpeed()
        self.walkSpeed = selfActor:getWalkSpeed()
        self.desiredSpeed = props.speed()
        if self.desiredSpeed == -1 then self.desiredSpeed = self.runSpeed end
        self.desiredDistance = props.distance()
        if props.lookAt then self.lookAt = props.lookAt() end
        self.bounds = selfActor:getPathfindingAgentBounds()
        self.timeLimit = self.desiredDistance / self.desiredSpeed + 1.5

        config.run(self, state)
    end

    config.run = function(self, state)
        if not state.enemyActor then
            return self:fail()
        end

        local now = core.getSimulationTime()
        local currentPos = omwself.position
        self.coveredDistance = self.coveredDistance + (currentPos - self.lastPos):length()

        -- Vector magic to calculate a run direction
        local dirToEnemy = (state.enemyActor.position - omwself.object.position):normalize()
        local moveDir = moveutils.directionRelativeToVec(dirToEnemy, props.direction())

        local canMove, reason = state.navService:canMoveInDirection(moveDir)

        local shouldAbort = false

        if not canMove then
            --gutils.print("Move finished due to: " .. reason,2)
            shouldAbort = true
        end

        -- Measure time passed and abort if more than distance/speed + 1.5 have passed
        if now - self.startedAt >= self.timeLimit then
            --gutils.print("Move finished due to time limit of " .. self.timeLimit .. " have been reached.",2)
            shouldAbort = true
        end

        -- Abort if should
        if shouldAbort then
            if self.coveredDistance > self.desiredDistance * 0.33 then
                -- Atleast we moved some distance, consider it a success
                return self:success()
            else
                -- We barely moved, its a fail
                return self:fail()
            end
        end

        -- Done if we covered required distance
        if self.coveredDistance > self.desiredDistance then
            --gutils.print("Move success since distance was covered", 2)
            return self:success()
        end

        -- Calculating speed
        local speedMult, shouldRun = moveutils.calcSpeedMult(self.desiredSpeed, self.walkSpeed, self.runSpeed)
        state.run = shouldRun

        -- And movement values!
        local movement, sideMovement = moveutils.calculateMovement(omwself.object,
            moveDir)
        state.movement, state.sideMovement = movement * speedMult, sideMovement * speedMult
        if self.lookAt == "ahead" then
            state.lookDirection = moveDir
        end


        self.lastPos = currentPos

        if self["running"] then return self:running() end
        -- we are also running this run() method on start() to avoid having gaps between movements on repeated tasks
        -- but on start() we won't have running status reporter available, so just ignore if thats the case
    end

    return BT.Task:new(config)
end

BT.register('MoveInDirection', MoveInDirection)


function JumpInDirection(config)
    local props = config.properties

    config.start = function(self, state)
        self.startedAt = core.getSimulationTime()
        self.warmupTime = 0.5
        self.justStarted = true
        -- Here we only start moving
        config.run(self, state)
    end

    config.run = function(self, state)
        if not state.enemyActor then
            return self:fail()
        end

        local now = core.getSimulationTime()

        -- Vector magic to calculate a run direction
        local dirToEnemy = (state.enemyActor.position - omwself.object.position):normalize()
        local moveDir = moveutils.directionRelativeToVec(dirToEnemy, props.direction())

        local canMove, reason = state.navService:canMoveInDirection(moveDir, types.Actor.getRunSpeed(omwself))

        if not canMove then
            gutils.print("Jump aborted due to: " .. reason)
            return self:fail()
        end

        if now - self.startedAt >= self.warmupTime and selfActor:isOnGround() then
            gutils.print("Jump is finished since actor is on ground")
            return self:success()
        end

        local movement, sideMovement = moveutils.calculateMovement(omwself.object,
            moveDir)
        state.movement, state.sideMovement = movement, sideMovement
        if self.justStarted then
            self.justStarted = false
        else
            -- Trigger jump on the 2nd frame
            state.jump = true
        end

        if self["running"] then return self:running() end
    end

    return BT.Task:new(config)
end

BT.register('JumpInDirection', JumpInDirection)

function StartAttack(config)
    config.start = function(self, state)
        self.frame = 0
        -- Pick the best attack type accounting for the weapon skill and some randomness

        -- If weaponRecord is nil - this will assume its hand-to-hand
        local attacks = state.weaponAttacks
        local goodAttacks = gutils.getGoodAttacks(attacks)
        -- print("Good attacks: ", #goodAttacks)
        -- for index, value in ipairs(goodAttacks) do
        --    print("Good attack: ", value.type, " avgDmg: ", value.averageDamage)
        -- end
        local attack

        local skill = state.weaponSkill
        local prob = util.clamp(util.remap(skill, 0, 75, 0, 100), 0, 90)

        if math.random() * 100 < prob then
            -- if random less than weapon skill (rescale to 0-75 skill, and clamp chance to 0-90)
            attack = gutils.pickWeightedRandomAttackType(goodAttacks)
        else
            -- otherwise pure random
            attack = attacks[math.random(1, #attacks)]
        end

        -- self.attack_type = 5 -- for testing
        self.attack_type = omwself.ATTACK_TYPE[attack.type]

        state.attack = self.attack_type
    end

    config.run = function(self, state)
        -- TO DO: Currently stagger is read on a full body, it does create an interesting effect that enemies dont attack during stagger at all, but maybe it should be changed
        -- print(state.attackState, config.successAttackState, enums.ATTACK_STATE.WINDUP_MAX)
        if not state.staggerGroup then
            self.frame = self.frame + 1
            -- print("CURRENT ATTACK FRAME: ", self.frame, " STATE: ", gutils.findField(ATTACK_STATE, state.attackState))
            if self.frame > 3 and state.attackState == enums.ATTACK_STATE.NO_STATE then
                return self:fail()
            end

            if state.attackState >= config.successAttackState then
                return self:success()
            end

            if state.attackState >= enums.ATTACK_STATE.WINDUP_MAX then
                return self:success()
            end
        end

        state.attack = self.attack_type

        return self:running()
    end

    return BT.Task:new(config)
end

function StartSmallAttack(config)
    config.successAttackState = enums.ATTACK_STATE.WINDUP_MIN
    return StartAttack(config)
end

function StartFullAttack(config)
    config.successAttackState = enums.ATTACK_STATE.WINDUP_MAX
    return StartAttack(config)
end

BT.register('StartSmallAttack', StartSmallAttack)
BT.register('StartFullAttack', StartFullAttack)

function HoldAttack(config)
    local hodl = function(self, state)
        if state.attackState ~= enums.ATTACK_STATE.WINDUP_MAX then
            return self:fail()
        else
            state.attack = 1
        end
    end

    config.start = hodl
    config.run = hodl

    return BT.Task:new(config)
end

BT.register('HoldAttack', HoldAttack)

function AttackHoldTimeout(config)
    local p = config.properties
    local duration
    local heldFrom

    config.isStealthy = true

    config.registered = function(self, state)
        duration = p.duration()
        heldFrom = nil
    end

    config.shouldRun = function(self, state)
        local now = core.getSimulationTime()
        if state.attackState == enums.ATTACK_STATE.WINDUP_MAX then
            if not heldFrom then
                heldFrom = now
            end
        else
            heldFrom = nil
        end

        if heldFrom and now - heldFrom > duration then
            return true
        end

        return false
    end

    return BT.InterruptDecorator:new(config)
end

BT.register("AttackHoldTimeout", AttackHoldTimeout)

function ReleaseAttack(config)
    config.run = function(self, state)
        state.attack = 0
        if state.attackState == enums.ATTACK_STATE.NO_STATE then
            return self:success()
        end
    end

    return BT.Task:new(config)
end

BT.register('ReleaseAttack', ReleaseAttack)

function ChaseEnemy(config)
    config.findTargetActor = function(task, state)
        task.targetActor = state.enemyActor
    end

    config.getLookDirection = function(task, state)
        if state.enemyActor then
            local distanceVec = state.enemyActor.position - omwself.position
            if distanceVec:length() < state.engageRange then
                return distanceVec:normalize()
            end
        end
    end

    return ChaseTarget(config)
end

BT.register('ChaseEnemy', ChaseEnemy)



function FriendsNearby(config)
    local p = config.properties

    config.start = function(task, state)
        local distThreshold = p.distance()
        for _, actor in ipairs(nearby.actors) do
            if (omwself.position - actor.position):length() <= distThreshold and gutils.isMyFriend(actor) and not types.Actor.isDead(actor) then return end
        end
        return task:fail()
    end

    return BT.Decorator:new(config)
end

BT.register("FriendsNearby", FriendsNearby)



function RetreatToFriend(config)
    config.findTargetActor = function(task, state)
        if task.targetActor then return end

        local closestFriend = nil
        local closestFriendDist = nil

        for index, actor in ipairs(nearby.actors) do
            local dist = gutils.getDistanceToBounds(omwself, actor)
            if gutils.isMyFriend(actor) and not types.Actor.isDead(actor) and (not closestFriend or (dist > 350 and dist < closestFriendDist)) then
                closestFriend = actor
                closestFriendDist = dist
            end
        end

        if closestFriend then
            gutils.print("Found a fight-ready NPC, seeking their help! Actor is: " .. closestFriend.recordId)
            task.targetActor = closestFriend
            local enemyDistance = state.enemyActor and math.floor(gutils.getDistanceToBounds(closestFriend, state.enemyActor))
            magicUtil.log(config.name, "running to friend", closestFriend.recordId, "- distance",
                math.floor(closestFriendDist), "- friend's distance to the enemy", enemyDistance or "?")
        else
            magicUtil.log(config.name, "found no friend nearby")
        end
    end

    return ChaseTarget(config)
end

BT.register("RetreatToFriend", RetreatToFriend)

-- Walks to a position rather than an actor. Fails right away if there's no path ending near that position. On arrival
-- leaves in state.cameFrom a point on its way there, roughly 50 to 200 units back, e.g. to face the way it came.
local TRAIL_STEP = 150
function GoToPosition(config)
    local p = config.properties

    config.start = function(task, state)
        task.targetPos = p.position()
        if not task.targetPos then return task:fail() end
        task.proximity = p.proximity()
        task.trail, task.olderTrail = omwself.position, omwself.position
        task.desiredSpeed = -1
        if p.speed then task.desiredSpeed = p.speed() end

        if (task.targetPos - omwself.position):length() <= task.proximity then return task:success() end

        -- Always a fresh path: the service only re-paths when the target moves further than its deadzone
        navService.targetPos = nil
        navService:setTargetPos(task.targetPos)
        local path = navService.path
        if not path or #path == 0 or (path[#path] - task.targetPos):length() > task.proximity then
            gutils.print("Go To Position aborted, position is unreachable.", 1)
            magicUtil.log(config.name, "aborted: position is unreachable")
            return task:fail()
        end
        magicUtil.log(config.name, "started, distance", math.floor((task.targetPos - omwself.position):length()))
    end

    config.run = function(task, state)
        -- Follow the position when it changes, e.g. the last seen position of an enemy that's in sight
        local pos = p.position()
        if pos and pos ~= task.targetPos then
            task.targetPos = pos
            navService:setTargetPos(pos)
        end

        local movement, sideMovement, run, lookDirection = navService:run({ desiredSpeed = task.desiredSpeed })
        if navService.doorStuck or #navService.path == 0 then
            magicUtil.log(config.name, "aborted:", navService.doorStuck and "stuck on a door" or "lost the path")
            return task:fail()
        end

        local position = omwself.position
        if (position - task.trail):length() > TRAIL_STEP then
            task.olderTrail, task.trail = task.trail, position
        end

        if (task.targetPos - position):length() <= task.proximity or navService:isPathCompleted() then
            magicUtil.log(config.name, "arrived")
            state.cameFrom = (position - task.trail):length() >= 50 and task.trail or task.olderTrail
            return task:success()
        end

        state.movement, state.sideMovement, state.run, state.lookDirection = movement, sideMovement, run, lookDirection
        return task:running()
    end

    return BT.Task:new(config)
end

BT.register("GoToPosition", GoToPosition)

-- Like SetState, but keeps writing its properties to the state every frame while running, since the main loop
-- clears some state fields every frame (e.g. sneak)
function KeepState(config)
    local p = config.properties

    local function keep(task, state)
        for key, val in pairs(p) do
            state[key] = val()
        end
    end

    config.start = keep
    config.run = function(task, state)
        keep(task, state)
        task:running()
    end

    return BT.Task:new(config)
end

BT.register("KeepState", KeepState)

-- Turns the actor to face a position ('position', or the enemy when it's nil or the actor is already there), succeeding
-- once it faces it. Turns much faster than the usual look steering: half a turn takes about a quarter of a second.
-- TIMEOUT is only a safety net for an actor that can't turn (e.g. knocked down), so the node can't hang.
function TurnTowards(config)
    local p = config.properties
    local TOLERANCE = 0.2 -- radians
    local TIMEOUT = 1
    local TURN_RATE = 10  -- Share of the remaining turn per second (the main loop's default is 3)

    config.start = function(task, state)
        task.startedAt = core.getSimulationTime()
        task.target = p.position and p.position()
        if not task.target or (task.target - omwself.position):length() < 1 then
            task.target = state.enemyActor and state.enemyActor.position
        end
        if not task.target then return task:fail() end
    end

    config.run = function(task, state)
        state.lookDirection = task.target - omwself.position
        state.turnRate = TURN_RATE
        if math.abs(moveutils.lookRotation(omwself, task.target)) < TOLERANCE
            or core.getSimulationTime() - task.startedAt > TIMEOUT then
            return task:success()
        end
        task:running()
    end

    return BT.Task:new(config)
end

BT.register("TurnTowards", TurnTowards)

-- Keeps running until its condition is true
function WaitUntil(config)
    local p = config.properties

    config.run = function(task, state)
        if p.condition() then return task:success() end
        task:running()
    end

    return BT.Task:new(config)
end

BT.register("WaitUntil", WaitUntil)

-- Triggers when its condition is true and, unlike StateInterrupt, stays triggered until its child is done even if the
-- condition turns false meanwhile
function LatchedInterrupt(config)
    local p = config.properties

    config.shouldRun = function(task, state)
        if task.started then return true end
        return p.condition()
    end

    config.start = function(task, state)
        task.started = true
    end

    config.finish = function(task, state)
        task.started = false
    end

    return BT.InterruptDecorator:new(config)
end

BT.register("LatchedInterrupt", LatchedInterrupt)

function RetreatBreaker(config)
    -- Mostly written by ChatGPT 2024
    local p = config.properties
    local registeredTime
    local warmupTime
    local dmgProbability
    local onlyMeleeDamage
    local warmupComplete

    local function resetVars()
        registeredTime = core.getSimulationTime()
        warmupTime = p.warmup()
        dmgProbability = p.dmgProbability()
        onlyMeleeDamage = p.onlyMeleeDamage()
        warmupComplete = false
    end

    config.registered = resetVars

    config.shouldRun = function(task, state)
        if task.started then return true end
        -- Check if warmup period has passed and mark it as complete
        local now = core.getSimulationTime()
        if (now - registeredTime) >= warmupTime then
            warmupComplete = true
        end

        local baseHealth = selfActor:healthStat().base

        -- Check if enough damage was taken
        if warmupComplete and state.damageValue > 0 then
            -- Calculate damage threshold percentage
            local damagePercentage = state.damageValue / baseHealth * 100

            -- Calculate adjusted probability based on damage percentage and dmgProbability range
            local baseProbability = dmgProbability
            local adjustedProbability = util.clamp(baseProbability * (damagePercentage / 10), 0, baseProbability)

            -- Convert dmgProbability from 0-100 range to 0-1 range and clamp it
            adjustedProbability = adjustedProbability / 100

            -- Check if enemy is close enough
            local distance = gutils.getDistanceToBounds(omwself, state.enemyActor)
            local closeEnough = true
            if onlyMeleeDamage then closeEnough = distance <= 300 end

            -- Check if interrupt conditions are met
            local triggered = closeEnough and math.random() <= adjustedProbability
            magicUtil.log(config.name, "took", string.format("%.1f%%", damagePercentage), "damage while retreating,",
                "enemy distance", math.floor(distance), "- turn back chance", string.format("%.0f%%", adjustedProbability * 100),
                triggered and "- turning back to fight" or "- keeps retreating")
            return triggered
        end

        return false
    end
    config.start = function(task, state)
        task.started = true
    end
    config.finish = function(task, state)
        task.started = false
        resetVars()
    end

    return BT.InterruptDecorator:new(config)
end

BT.register("RetreatBreaker", RetreatBreaker)

function PlayerInsolence(config)
    local p = config.properties

    local triggerStarteAt = nil

    local onPlayerUse = function(e, data)
        if e ~= "PlayerUse" then return end

        if data.use > 0 and gutils.listContains(I.AI.getTargets("Combat"), data.source) and not triggerStarteAt then
            -- This player is one of our targets - get triggered
            triggerStarteAt = core.getSimulationTime()
        end
    end

    config.registered = function(task, state)
        triggerStarteAt = nil

        -- Register event that will catch the player's use
        Events:addEventHandler(onPlayerUse)
    end

    config.shouldRun = function(task, state)
        if task.started then return true end

        if not state.staringProgress then state.staringProgress = 0 end

        local now = core.getSimulationTime()
        local distance = gutils.getDistanceToBounds(omwself, state.enemyActor)
        local inSight = gutils.hasLineOfSight(omwself, state.enemyActor)

        if inSight then
            state.staringProgress = state.staringProgress + state.dt
        end

        -- With proximityNeedsSight, an enemy close by but behind a wall isn't too close
        local needsSight = p.proximityNeedsSight and p.proximityNeedsSight()
        local tooClose = distance <= p.proximity() and (inSight or not needsSight)
        if tooClose or state.staringProgress >= p.presenceTime() then
            magicUtil.log(config.name, "triggered:", tooClose and ("enemy too close, distance " .. math.floor(distance))
                or ("enemy in sight for " .. string.format("%.1f", state.staringProgress) .. " s"))
            return true
        end

        -- Check if triggered by enemy damage
        if p.triggerOnDamage() and state.damageValue > 0 then
            triggerStarteAt = now
        end

        if triggerStarteAt and now - triggerStarteAt >= p.reactionTime() then
            magicUtil.log(config.name, "triggered: enemy attacked or swung")
            return true
        end

        return false
    end

    config.start = function(task, state)
        task.started = true
    end

    config.finish = function(task, state)
        task.started = false
    end

    config.deregistered = function(task, state)
        -- deregister that event
        Events:removeEventHandler(onPlayerUse)
    end

    return BT.InterruptDecorator:new(config)
end

BT.register("PlayerInsolence", PlayerInsolence)

function EnemyIsRanged(config)
    -- Mostly written by ChatGPT 2024
    local p = config.properties
    local reactionTime

    config.registered = function(task, state)
        reactionTime = p.reactionTime()
    end

    config.shouldRun = function(task, state)
        if task.started then return true end

        if not state.enemyActor then
            return false
        end

        -- Check if enemy actor is ranged
        local enemyActor = gutils.Actor:new(state.enemyActor)
        local detStance = enemyActor:getDetailedStance()
        local enemyIsRanged = detStance == gutils.Actor.DET_STANCE.Spell or detStance == gutils.Actor.DET_STANCE
            .Marksman

        if enemyIsRanged then
            task.rangedDetectedTime = task.rangedDetectedTime or core.getSimulationTime()
        else
            -- Reset ranged detected time if not ranged
            task.rangedDetectedTime = nil
        end

        -- Check if enough reaction time has passed
        if task.rangedDetectedTime then
            local currentTime = core.getSimulationTime()
            if (currentTime - task.rangedDetectedTime) >= reactionTime then
                return true
            end
        end

        return false
    end

    config.start = function(task, state)
        task.started = true
    end

    config.finish = function(task, state)
        task.started = false
    end

    return BT.InterruptDecorator:new(config)
end

BT.register("EnemyIsRanged", EnemyIsRanged)

function LookAround(config)
    local p = config.properties

    config.start = function(task, state)
        task.lastLookChange = 0
        task.period = p.period()
    end

    config.run = function(task, state)
        local now = core.getSimulationTime()

        if now - task.lastLookChange > task.period then
            task.lastLookChange = now
            task.period = p.period()
            task.lookDirection = gutils.randomDirection()
        end

        state.lookDirection = task.lookDirection
        task:running()
    end

    return BT.Task:new(config)
end

BT.register("LookAround", LookAround)

function SetCombatState(config)
    local p = config.properties

    config.start = function(task, state)
        local stateString = p.state()
        if not enums.COMBAT_STATE[stateString] then
            error("Wrong combat state provided to combat state set.")
        end
        state.combatState = enums.COMBAT_STATE[stateString]
        return task:success()
    end

    return BT.Task:new(config)
end

BT.register("SetCombatState", SetCombatState)

function SetStateWhenOver(config)
    local p = config.properties
    config.finish = function(task, state)
        for key, val in pairs(p) do
            state[key] = val()
        end
    end

    return BT.Decorator:new(config)
end

BT.register("SetStateWhenOver", SetStateWhenOver)

function OverrideStance(config)
    local p = config.properties

    config.start = function(task, state)
        task.stance = p.stance()
        if not types.Actor.STANCE[task.stance] then
            error("Stance of type " .. tostring(task.stance) .. " doesn't exist.")
        end
    end

    config.run = function(task, state)
        state.stance = types.Actor.STANCE[task.stance]
        return task:running()
    end

    return BT.Task:new(config)
end

BT.register("OverrideStance", OverrideStance)

function OnAnimationKey(config)
    local p = config.properties
    local configId = p.animation()
    local animConfig = assert(animManager.animationConfigs[configId],
        "No animation config " .. tostring(configId) .. " found.")
    local groupname

    local shouldStart = false

    local function onKeyHandler(groupname, key)
        if groupname == animConfig.groupname and key == p.key() then
            shouldStart = true
        end
    end

    config.registered = function(task, state)
        shouldStart = false
        groupname = animConfig.groupname
        if type(groupname) == "table" then
            error("List animation groupnames are not supported in a " ..
                config.name .. " node.")
        end
        animManager.addOnKeyHandler(onKeyHandler)
    end

    config.shouldRun = function(task, state)
        if shouldStart then return true end
    end

    config.finish = function(task, state)
        shouldStart = false
    end

    config.deregistered = function(task, state)
        animManager.removeOnKeyHandler(onKeyHandler)
    end

    return BT.InterruptDecorator:new(config)
end

BT.register("OnAnimationKey", OnAnimationKey)


function PlayAnimation(config)
    local p = config.properties
    local configId = p.animation()
    local animConfig = assert(animManager.animationConfigs[configId],
        "No animation config " .. tostring(configId) .. " found.")
    local groupname

    local lastCompletion = nil

    config.start = function(task, state)
        groupname = animConfig.groupname
        if type(groupname) == "table" then groupname = groupname[math.random(1, #groupname)] end
        task.anim = animManager.Animation:play(groupname, animConfig)
        task.anim:addOnKeyHandler(function(key)
            if key == animConfig.stopkey then task.shouldSucceed = true end
        end)
    end

    config.run = function(task, state)
        if task.shouldSucceed then return task:success() end

        -- Often event arrives too late and in breaks with completion clause
        local completion = animation.getCompletion(omwself, groupname)
        if lastCompletion ~= nil and completion == nil then
            if lastCompletion > 0.9 then
                -- Completion status will be different at different framerates, an edgecase where this be considered
                -- a fail although it properly completed - is quite possible
                return task:success()
            else
                return task:fail()
            end
        end
        lastCompletion = completion

        return task:running()
    end

    config.finish = function(task, state)
        if task.anim then         
            task.anim:cancel()
            task.anim:removeOnKeyHandler()  
        else
            gutils.print("WARNING: PlayAnimation finished with no task.anim. Why?", 0)
        end
    end

    return BT.Task:new(config)
end

BT.register("PlayAnimation", PlayAnimation)


function DumpInventory(config)
    config.start = function(task)
        core.sendGlobalEvent("dumpInventory", { actorObject = omwself, position = omwself.position })
        return task:success()
    end

    return BT.Task:new(config)
end

BT.register("DumpInventory", DumpInventory)


function HasDumpableItems(config)
    config.start = function(task, state)
        if #selfActor:getDumpableInventoryItems(state.itemDumpExclusions) <= 0 then
            return task:fail()
        end
    end

    return BT.Decorator:new(config)
end

BT.register("HasDumpableItems", HasDumpableItems)

function Pacify(config)
    config.start = function(task, state)
        AI.removePackages("Combat") -- As of right now this makes actors stuck in an Unknown package
        selfActor:aiFightStat().base = 30    
        state.resetActiveAiPackage = true            

        task:success()
    end

    return BT.Task:new(config)
end

BT.register("Pacify", Pacify)


function Say(config)
    local p = config.properties

    config.start = function(task, state)
        voiceManager.say(omwself, state.enemyActor, p.recordType(), p.force())
        return task:success()
    end

    return BT.Task:new(config)
end

BT.register("Say", Say)

function SayGroup(config)
    local p = config.properties
    local voices = 0

    config.start = function(task, state)
        local maxVoices = p.maxVoices()
        local tooManyVoices = false

        gutils.forEachNearbyActor(700, function(actor)
            if core.sound.isSayActive(actor) then
                voices = voices + 1
                if voices > maxVoices then
                    tooManyVoices = true
                    return
                end
            end
        end)

        if tooManyVoices then
            return task:fail()
        else
            voiceManager.say(omwself, state.enemyActor, p.recordType(), p.force())
            return task:success()
        end
    end

    return BT.Task:new(config)
end

BT.register("SayGroup", SayGroup)


-- Triggers every 'period' seconds when 'condition' holds, then stays
-- triggered until its child is done. While the condition doesn't hold it's checked again at most every
-- RECHECK_PERIOD seconds. The timer survives the parent branch restarting, so a branch that restarts often doesn't
-- reset it.
-- A condition blocked only by a cast or attack in progress (castBlockTransient, see canCastCustom) is rechecked every
-- frame for up to RESERVE_TIME instead, and reserves the next opening (state.customSpellReservedUntil): no magic
-- handover to the engine meanwhile, and a vanilla spell stance is held for Mercy once the current cast ends.
function PeriodicInterrupt(config)
    local p = config.properties
    local RECHECK_PERIOD = 0.5
    local RESERVE_TIME = 1.5
    local nextCheckAt = 0
    local lastWaitReason = nil
    local reservedSince = nil

    config.shouldRun = function(task, state)
        if task.started then return true end
        local now = core.getSimulationTime()
        if now < nextCheckAt then return false end
        state.castBlockReason = nil
        state.castBlockTransient = false
        if not p.condition() then
            nextCheckAt = now + RECHECK_PERIOD
            if state.castBlockTransient and (not reservedSince or now - reservedSince < RESERVE_TIME) then
                reservedSince = reservedSince or now
                state.customSpellReservedUntil = reservedSince + RESERVE_TIME
                nextCheckAt = now
            elseif not state.castBlockTransient then
                -- Blocked for another reason now (range, sight, cooldown...): give the opening back
                if reservedSince then state.customSpellReservedUntil = nil end
                reservedSince = nil
            end
            -- The condition is rechecked often, so only log when the reason it fails changes. Condition helpers like
            -- canCastCustom leave a reason, other parts of the condition don't.
            local reason = state.castBlockReason or "another part of the condition"
            if reason ~= lastWaitReason then
                magicUtil.log(config.name, "is due, waiting:", reason)
                lastWaitReason = reason
            end
            return false
        end
        lastWaitReason = nil
        reservedSince = nil
        nextCheckAt = now + p.period()
        return true
    end

    config.start = function(task, state)
        task.started = true
        magicUtil.log(config.name, "triggered")
    end

    config.finish = function(task, state)
        task.started = false
    end

    return BT.InterruptDecorator:new(config)
end

BT.register("PeriodicInterrupt", PeriodicInterrupt)


local fTargetSpellMaxSpeed = core.getGMST("fTargetSpellMaxSpeed")

-- Direction from the caster's spell launch point to where a bolt should fly to meet the enemy.
-- A port of the engine's AimDirToMovingTarget (aicombat.cpp) for target spells.
local function spellAimDirection(task, state)
    local enemy = state.enemyActor
    local selfHalfExtents = types.Actor.getPathfindingAgentBounds(omwself).halfExtents
    local enemyHalfExtents = types.Actor.getPathfindingAgentBounds(enemy).halfExtents
    -- As World::aimToTarget: from the caster's torso to the target's center
    local from = omwself.position + util.vector3(0, 0, selfHalfExtents.z * 2 * 0.75)
    local enemyPos = enemy.position
    local dirToTarget = enemyPos + util.vector3(0, 0, enemyHalfExtents.z) - from

    -- The engine samples the target's movement every AI reaction, this runs every frame, so smooth it
    if task.lastEnemyPos and state.dt > 0 then
        local frameVelocity = (enemyPos - task.lastEnemyPos) / state.dt
        task.enemyVelocity = task.enemyVelocity and (task.enemyVelocity * 0.7 + frameVelocity * 0.3) or frameVelocity
    end
    task.lastEnemyPos = enemyPos
    local velocity = task.enemyVelocity
    if not velocity or velocity:length() < 1 then return dirToTarget end

    -- The bolt's and the target's velocity components perpendicular to the direction to target should be the same
    local distance = dirToTarget:length()
    local perpToDir = dirToTarget:cross(util.vector3(0, 0, 1)):normalize()
    local velPerp = velocity:dot(perpToDir)
    local velDir = velocity:dot(dirToTarget:normalize())
    local projVelDirSquared = fTargetSpellMaxSpeed * fTargetSpellMaxSpeed - velPerp * velPerp
    local timeToHit = 0
    if projVelDirSquared > 0 then
        local alongMove = dirToTarget:dot(velocity:normalize())
        local projDistDiff = math.sqrt(math.max(distance * distance - alongMove * alongMove, 0))
        local closingSpeed = math.sqrt(projVelDirSquared) - velDir
        if closingSpeed > 0 then timeToHit = projDistDiff / closingSpeed end
    end
    return dirToTarget + velocity * timeToHit
end

local CAST_START_KEYS = { ["self start"] = true, ["touch start"] = true, ["target start"] = true }
local CAST_RELEASE_KEYS = { ["self release"] = true, ["touch release"] = true, ["target release"] = true }
local CAST_STOP_KEYS = { ["self stop"] = true, ["touch stop"] = true, ["target stop"] = true }

-- Casts a spell the actor knows ('spell' is a spell record id, or 'customSpell' is the key of one of Mercy's custom
-- spells, e.g. "levitateBolt"), driving the actor itself: spell stance, selects the
-- spell, with 'aim' turns and pitches at the enemy leading a moving target, presses use and waits for the cast
-- animation to finish. The main loop keeps the actor still and in Mercy's hands while state.castingCustom is set.
-- Back to back custom spells: once MAX_BACK_TO_BACK different ones were cast in a row (each starting within
-- BACK_TO_BACK_GAP seconds of the previous one's end), no custom spell for REST_TIME seconds. Recasting the same spell
-- doesn't count, and doesn't break the row.
local MAX_BACK_TO_BACK = 2
local BACK_TO_BACK_GAP = 2
local REST_TIME = 5

-- Debug: how long ago the actor consumed something or started a consuming animation (Consuming Animated), for cast
-- failures
local function consumeInfo(state)
    local now = core.getSimulationTime()
    local parts = {}
    if state.consumedAt then parts[#parts + 1] = string.format("consumed %.1f s ago", now - state.consumedAt) end
    if state.consumeAnimStartedAt then
        parts[#parts + 1] = string.format("consuming animation %.1f s ago", now - state.consumeAnimStartedAt)
    end
    return #parts > 0 and ("(" .. table.concat(parts, ", ") .. ")") or ""
end

function CastSpell(config)
    local p = config.properties
    local TIMEOUT = 5
    local AIM_TOLERANCE = 0.08 -- radians

    local lastCastKey = nil
    local castReleased = false -- The spell left the caster's hands: a bolt is flying, a self spell is applied
    I.AnimationController.addTextKeyHandler("spellcast", function(groupname, key)
        lastCastKey = key
        if CAST_RELEASE_KEYS[key] then castReleased = true end
    end)

    config.start = function(task, state)
        task.customSpell = p.customSpell and p.customSpell()
        if task.customSpell == "" then task.customSpell = nil end
        if task.customSpell then
            task.spellId = state.customSpells[task.customSpell]
        else
            task.spellId = p.spell and p.spell()
        end
        task.aim = p.aim and p.aim()
        task.startedAt = core.getSimulationTime()
        task.phase = "prepare"
        task.lastEnemyPos = nil
        task.enemyVelocity = nil
        lastCastKey = nil
        if not task.spellId or task.spellId == "" or not state.enemyActor then
            magicUtil.log(config.name, "has no spell or enemy, not casting")
            return task:fail()
        end
        state.castingCustom = true
        state.magicBusy = true
        state.customSpellReservedUntil = nil
        types.Actor.setSelectedSpell(omwself, task.spellId)
        magicUtil.log(config.name, "casting", task.spellId, "aim:", task.aim)
    end

    config.run = function(task, state)
        local now = core.getSimulationTime()
        if now - task.startedAt > TIMEOUT or not state.enemyActor then
            magicUtil.log(config.name, "gave up in phase", task.phase, consumeInfo(state))
            return task:fail()
        end

        state.stance = types.Actor.STANCE.Spell

        local aimed = true
        if task.aim then
            -- Kept apart from lookDirection, which the Locomotion tree may set later in the frame
            local aimDir = spellAimDirection(task, state)
            state.aimDirection = util.vector3(aimDir.x, aimDir.y, 0)
            state.pitchTarget = -math.asin(util.clamp(aimDir.z / aimDir:length(), -1, 1))
            local forward = omwself.rotation:apply(util.vector3(0, 1, 0))
            local pitch = -math.asin(util.clamp(forward.z, -1, 1))
            local yawError = moveutils.lookRotation(omwself, omwself.position + state.aimDirection)
            aimed = math.abs(yawError) < AIM_TOLERANCE and math.abs(state.pitchTarget - pitch) < AIM_TOLERANCE
        end

        if task.phase == "prepare" then
            local selected = types.Actor.getSelectedSpell(omwself)
            local ready = types.Actor.getStance(omwself) == types.Actor.STANCE.Spell and selected ~= nil
                and string.lower(selected.id) == string.lower(task.spellId)
            if ready and aimed then
                task.phase = "press"
                task.pressedAt = now
                lastCastKey = nil
                castReleased = false
                task.reported = false
                magicUtil.log(config.name, "aimed and ready, pressing use. Distance:", state.range)
            end
        end

        if task.phase == "press" then
            if lastCastKey and CAST_START_KEYS[lastCastKey] then
                task.phase = "cast"
                magicUtil.log(config.name, "cast animation started:", lastCastKey)
            elseif now - task.pressedAt > 2 then
                magicUtil.log(config.name, "the cast didn't start after pressing use", consumeInfo(state))
                return task:fail()
            else
                state.attack = omwself.ATTACK_TYPE.Any
            end
        end

        -- Custom spells are reported as cast when released, so the main loop watches for a bolt landing from the moment
        -- it flies (the animation goes on for a while after that). At the end of the animation if no release was seen.
        local stopped = task.phase == "cast" and lastCastKey and CAST_STOP_KEYS[lastCastKey]
        if task.customSpell and not task.reported and (castReleased or stopped) and task.phase == "cast" then
            task.reported = true
            magicUtil.log(config.name, castReleased and "released" or "finished without a release key")
            state:onCustomSpellCast(task.customSpell, state.enemyActor)
        end
        if stopped then
            magicUtil.log(config.name, "cast finished")
            return task:success()
        end

        task:running()
    end

    config.finish = function(task, state)
        if task.customSpell and task.reported then
            local now = core.getSimulationTime()
            local lastEnd, lastKey = state.lastCustomCastEndAt, state.lastCustomCastKey
            local chain = state.customCastChain or 0
            if lastEnd and task.startedAt - lastEnd <= BACK_TO_BACK_GAP then
                if task.customSpell ~= lastKey then chain = chain + 1 end
            else
                chain = 1
            end
            if chain >= MAX_BACK_TO_BACK then
                state.customSpellRestUntil = now + REST_TIME
                magicUtil.log(config.name, chain, "custom spells back to back - resting for", REST_TIME, "s")
                chain = 0
            end
            state.customCastChain = chain
            state.lastCustomCastEndAt = now
            state.lastCustomCastKey = task.customSpell
        end
        state.castingCustom = false
        state.magicBusy = false
        state.pitchTarget = nil
        state.aimDirection = nil
    end

    return BT.Task:new(config)
end

BT.register("CastSpell", CastSpell)


local function pathLength(path, from)
    local length = 0
    local previous = from
    for i = 1, #path do
        length = length + (path[i] - previous):length()
        previous = path[i]
    end
    return length
end

local function distanceToSegment(point, a, b)
    local ab = b - a
    local lengthSquared = ab:dot(ab)
    if lengthSquared == 0 then return (point - a):length() end
    local t = util.clamp((point - a):dot(ab) / lengthSquared, 0, 1)
    return (point - (a + ab * t)):length()
end

local function pathDistanceTo(path, from, point)
    local closest = math.huge
    local previous = from
    for i = 1, #path do
        closest = math.min(closest, distanceToSegment(point, previous, path[i]))
        previous = path[i]
    end
    return closest
end

-- Picks a spot to move to and leaves it in state.repositionPoint. Samples random navmesh points around the enemy or the
-- actor ('around') within minDistance - maxDistance, and keeps the ones that pass: on the same floor, at least minAngle
-- degrees around the enemy from where the actor is (repositioning), further from the enemy than the actor
-- ('awayFromEnemy'), reachable with a path that doesn't pass within 'clearance' of the enemy, no longer than maxDetour
-- times the straight distance (0: any), through no door the actor can't open ('allowDoors' allows doors at all), and
-- with the enemy in sight from the spot or not ('enemyInSight').
-- Repositioning (enemyInSight) takes the passing spot furthest from the enemy. Hiding takes the best hiding spot: one
-- the enemy still can't see after stepping aside (probed from points around it), reached around corners rather than in
-- a straight line, and far from the enemy (see HIDE_WEIGHTS).
-- Spots on other floors are fine, up or down any stairs the path takes.
-- Sampling is spread over frames: up to 'attempts' samples, at most SAMPLE_BUDGET seconds of work per frame and at most
-- SEARCH_TIME_LIMIT seconds in total, so the actor never stands around searching for long. If no spot
-- passes, 'fallback' (default true) takes any reachable spot around the actor; otherwise the node fails, and with
-- 'failCombatState' the actor switches to that combat state.
-- Random spots only come from navmesh connected to the search center through the allowed areas (Detour searches
-- polygon links outwards from the center), so disconnected navmesh islands never come up.
function PickRepositionPoint(config)
    local p = config.properties
    local DOOR_NEAR_PATH = 100
    local SAMPLE_BUDGET = 0.002   -- Seconds of sampling work per frame
    local SEARCH_TIME_LIMIT = 0.5 -- Seconds (game time) the whole search may take
    local HIDE_PROBE_OFFSET = 200 -- Concealment probes: the enemy's eyes moved this far to its sides and towards the spot
    local HIDE_WEIGHTS = { concealment = 0.5, corners = 0.25, distance = 0.25 }

    -- A door on the path that the actor can't open (locked, no key). Load doors aren't on navmesh paths.
    local function pathHasBlockedDoor(path, from)
        for _, door in ipairs(nearby.doors) do
            if not types.Door.isTeleport(door) and not selfActor:canOpenDoor(door)
                and pathDistanceTo(path, from, door.position) < DOOR_NEAR_PATH then
                return true
            end
        end
        return false
    end

    -- Share (0 - 1) of lines of sight to the spot blocked from points around the enemy's eyes: a thin pillar blocks the
    -- exact line from the enemy but not the ones from a step aside, a wall or a corner blocks them all
    local function concealment(spot, halfHeight, enemy)
        local eye = gutils.getActorEyePos(enemy)
        local spotEye = spot + util.vector3(0, 0, halfHeight * 1.9)
        local toSpot = spotEye - eye
        local flat = util.vector3(toSpot.x, toSpot.y, 0):normalize()
        local side = util.vector3(-flat.y, flat.x, 0) * HIDE_PROBE_OFFSET
        local probes = { eye + side, eye - side, eye + flat * HIDE_PROBE_OFFSET }
        local blocked = 0
        for _, probe in ipairs(probes) do
            local result = nearby.castRay(probe, spotEye, {
                collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap + nearby.COLLISION_TYPE.Door
            })
            if result.hit then blocked = blocked + 1 end
        end
        return blocked / #probes
    end

    -- Sharpness of the turns along a path (0 - 1): a total turn of 180 degrees or more counts as 1
    local function cornerScore(path, from)
        local total = 0
        local previousDir = nil
        local previous = from
        for i = 1, #path do
            local segment = path[i] - previous
            local flat = util.vector2(segment.x, segment.y)
            if flat:length() > 1 then
                flat = flat:normalize()
                if previousDir then
                    total = total + math.acos(util.clamp(flat:dot(previousDir), -1, 1))
                end
                previousDir = flat
            end
            previous = path[i]
        end
        return math.min(1, total / math.pi)
    end

    config.start = function(task, state)
        local enemy = state.enemyActor
        if not enemy then return task:fail() end

        local bounds = types.Actor.getPathfindingAgentBounds(omwself)
        local allowDoors = p.allowDoors and p.allowDoors()
        local flags = nearby.NAVIGATOR_FLAGS.Walk
        if allowDoors then flags = flags + nearby.NAVIGATOR_FLAGS.OpenDoor end

        local selfPos = omwself.position
        local enemyPos = enemy.position
        local toSelf = selfPos - enemyPos
        local toSelfFlat = util.vector2(toSelf.x, toSelf.y)
        task.search = {
            enemy = enemy,
            bounds = bounds,
            allowDoors = allowDoors,
            navOptions = { agentBounds = bounds, includeFlags = flags },
            selfPos = selfPos,
            enemyPos = enemyPos,
            center = p.around() == "self" and selfPos or enemyPos,
            minDistance = p.minDistance(),
            maxDistance = p.maxDistance(),
            minAngle = p.minAngle and p.minAngle() or 0,
            maxDetour = p.maxDetour and p.maxDetour() or 0,
            awayFromEnemy = p.awayFromEnemy and p.awayFromEnemy(),
            wantSight = p.enemyInSight(),
            clearance = p.clearance(),
            attempts = p.attempts(),
            selfEnemyDistance = toSelfFlat:length(),
            toSelfFlat = toSelfFlat:normalize(),
            samples = 0,
            frames = 0,
            startedAt = core.getSimulationTime(),
            time = 0,
            best = nil,
            bestScore = -math.huge,
            rejected = {},
        }
        task.search.maxAngleCos = math.cos(math.rad(task.search.minAngle))
    end

    -- One sample; the passing spot and its score, or nil and the reason it was rejected
    local function sample(search)
        local point = nearby.findRandomPointAroundCircle(search.center, search.maxDistance, search.navOptions)
        if not point then return nil, "no navmesh point" end

        local fromCenter = point - search.center
        local distance = util.vector2(fromCenter.x, fromCenter.y):length()
        local toPoint = point - search.enemyPos
        local toPointFlat = util.vector2(toPoint.x, toPoint.y)
        local enemyDistance = toPointFlat:length()
        if distance < search.minDistance or distance > search.maxDistance then return nil, "distance" end
        if search.minAngle > 0 and toPointFlat:normalize():dot(search.toSelfFlat) > search.maxAngleCos then
            return nil, "not around the enemy"
        end
        if search.awayFromEnemy and enemyDistance <= search.selfEnemyDistance then return nil, "not away from the enemy" end
        -- Repositioning keeps the furthest spot, so a closer one can be skipped before the expensive checks
        if search.wantSight and enemyDistance <= search.bestScore then return nil, "closer than a spot already found" end

        local halfHeight = search.bounds.halfExtents.z
        if gutils.hasLineOfSightFromPoint(point, halfHeight, search.enemy) ~= search.wantSight then
            return nil, search.wantSight and "enemy not in sight" or "enemy in sight"
        end

        local hiddenness = 0
        if not search.wantSight then
            hiddenness = concealment(point, halfHeight, search.enemy)
            -- A spot can't beat the best one even with the sharpest corners on the way: skip the path search
            local upperBound = HIDE_WEIGHTS.concealment * hiddenness + HIDE_WEIGHTS.corners
                + HIDE_WEIGHTS.distance * math.min(1, enemyDistance / search.maxDistance)
            if upperBound <= search.bestScore then return nil, "worse hiding spot than one already found" end
        end

        local status, path = nearby.findPath(search.selfPos, point, search.navOptions)
        if status ~= nearby.FIND_PATH_STATUS.Success or #path == 0 or (path[#path] - point):length() > 50 then
            return nil, "unreachable"
        end
        if search.maxDetour > 0 and pathLength(path, search.selfPos) > search.maxDetour * (point - search.selfPos):length() + 100 then
            return nil, "long detour"
        end
        if pathDistanceTo(path, search.selfPos, search.enemyPos) < search.clearance then return nil, "path passes the enemy" end
        if search.allowDoors and pathHasBlockedDoor(path, search.selfPos) then return nil, "door it can't open" end

        if search.wantSight then return point, enemyDistance end
        local score = HIDE_WEIGHTS.concealment * hiddenness + HIDE_WEIGHTS.corners * cornerScore(path, search.selfPos)
            + HIDE_WEIGHTS.distance * math.min(1, enemyDistance / search.maxDistance)
        return point, score
    end

    local function finish(task, state)
        local search = task.search
        local reasons = {}
        for reason, count in pairs(search.rejected) do reasons[#reasons + 1] = reason .. " x" .. count end
        local rejections = #reasons > 0 and table.concat(reasons, ", ") or "none"
        local stats = string.format("%d samples in %d frames, %.2f ms (%.2f ms per sample)", search.samples, search.frames,
            search.time * 1000, search.samples > 0 and search.time * 1000 / search.samples or 0)

        if search.best then
            state.repositionPoint = search.best
            magicUtil.log(config.name, "picked a spot, score", string.format("%.2f", search.bestScore), "-", stats,
                "- rejected:", rejections)
            return task:success()
        end

        local fallbackAllowed = not p.fallback or p.fallback()
        local fallback = fallbackAllowed and nearby.findRandomPointAroundCircle(search.selfPos, search.maxDistance, search.navOptions)
        if fallback then
            state.repositionPoint = fallback
            magicUtil.log(config.name, "found no good spot (" .. rejections .. "), using a random one around self -", stats)
            return task:success()
        end

        local failState = p.failCombatState and p.failCombatState()
        if failState and failState ~= "" and enums.COMBAT_STATE[failState] then
            state.combatState = enums.COMBAT_STATE[failState]
        end
        magicUtil.log(config.name, "found no spot:", rejections, "-", stats, failState and ("- switching to " .. failState) or "")
        return task:fail()
    end

    config.run = function(task, state)
        local search = task.search
        if not search.enemy:isValid() then return task:fail() end
        search.frames = search.frames + 1
        local frameStart = core.getRealTime()
        repeat
            search.samples = search.samples + 1
            local point, scoreOrReason = sample(search)
            if point then
                if scoreOrReason > search.bestScore then search.best, search.bestScore = point, scoreOrReason end
            else
                search.rejected[scoreOrReason] = (search.rejected[scoreOrReason] or 0) + 1
            end
        until search.samples >= search.attempts or core.getRealTime() - frameStart >= SAMPLE_BUDGET
        search.time = search.time + (core.getRealTime() - frameStart)

        if search.samples >= search.attempts or core.getSimulationTime() - search.startedAt >= SEARCH_TIME_LIMIT then
            return finish(task, state)
        end
        task:running()
    end

    return BT.Task:new(config)
end

BT.register("PickRepositionPoint", PickRepositionPoint)
