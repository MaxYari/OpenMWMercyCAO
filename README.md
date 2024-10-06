# Mercy: Combat AI Overhaul

A significant overhaul of in-combat NPC behavior for OpenMW. Using a custom Lua behavior trees library, with new voice lines and animations. Overhauls melee NPCs, partially affects ranged and spellcasters.

![Demo 1](/imgs/demo1.gif)
![Demo 2](/imgs/demo2.gif)
![Demo 3](/imgs/demo3.gif)

## How to install

- Download this repository as an archive and install using Mod Organizer 2. Or manually place the contents of this repository into your ".../Morrowind/Data Files" folder.
- Ensure that `MercyCAO Compatibility Patches.omwscripts` is at the very bottom of your Content Files list in the OpenMW launcher (you can drag it to reorder).
- Enable the mod's .omwscript file in the "Content Files" tab of the OpenMW launcher.

Have fun!

## Credit

ElevenLabs-generated voice lines by [vonwolfe](https://next.nexusmods.com/profile/vonwolfe).

## Mod compatibility

Not compatible with most mods directly affecting NPC behavior in combat, unless a compatibility patch is provided by a mod author or here.

Compatibility patches included here provide a compatibility layer for the following mods:

[Take Cover](https://www.nexusmods.com/morrowind/mods/54976) by [mym](https://next.nexusmods.com/profile/mym)

Note that compatibility patches are written using the Mercy: CAO extension interface (read below).

## Adding Mercy compatibility to your mod

Mercy provides an interface through which you can disable mercy for a specific actor as well as read/set some Mercy-specific AI information.


### Simple interface - overriding Mercy

A simple enable/disable switch is available. Want to take control of the actor and get Mercy: CAO out of the way? Use that! Don't forget to re-enable Mercy on the when you are done.

```Lua
local interfaces = require('openmw.interfaces')

local function onUpdate(dt)
   if interfaces.MercyCAO then
      if i_want_to_control_the_actor_now then
         interfaces.MercyCAO.enabled = false
      else 
         interfaces.MercyCAO.enabled = true
      end
   end
end

return {
    engineHandlers = {
        onUpdate = onUpdate,
    }
}
```

Note that some potentially usefull inforamtion is available on the interfaces.MercyCAO.state object. It can be useful if you want to integrate your mod a little bit better with Mercy. For example you might want to override NPC only when they are in an active combat state and not fleeing or standing ground/warning player not to come close, in that case - you migh check interfaces.MercyCAO.state.combatState == "FIGHT". Other useful properties of the state object are listed below under the Advanced interface section.

### Advanced interface - extending Mercy: CAO

Mercy provides an interface for extensions. The extension interface is primarily meant to be used for development of additional small behaviours that will be intertwined with the rest of the Mercy logic. For example - you might develop a sidestep/dodge mod and you'd like NPCs to also use it from time to time. Using this extension interface you can inject your dodge logic as a task that NPC will do alongside other Mercy tasks (strafing, circling, attacking e.t.c) 
First of all, the Mercy script should be in a load order _before_ your extension. 
Secondly, you should inject the extension (`interfaces.MercyCAO.addExtension(...)`) before the first onUpdate call, otherwise, Mercy will finish its initialization without acknowledging your extension. 
It's not possible to inject the extension in the middle of Mercy's runtime.

Extensions are done using `interfaces.MercyCAO.addExtension(treeName, combatState, stance, extensionObject)`.
Mercy AI is globally split into two different behavior trees (`treeName` argument. And actually, it's three trees, but let's ignore the third one - it's an auxiliary and doesn't have any extension points):
- `Locomotion` - A tree responsible for character movement through space - strafing, chasing, moving around, etc.
- `Combat` - Responsible for attacking - checking range, making quick or long swings, series of attacks, etc.
These trees run in parallel.

Furthermore, all of the behaviors/branches within those trees are grouped within four principal combat AI states (`combatState` argument):
- `STAND_GROUND` - Although technically in a combat state (Combat AI package, in fact Mercy works _only_ when the combat package is active) - the actor is hesitant to engage, will not rush towards the enemy, will slowly move around a bit, play a warning voice line. If too much time passes in this state (while the enemy is in line of sight) or an enemy gets too close - the combat state will switch to `FIGHT`
- `FIGHT` - Main engagement mode. The actor will run, strafe, chase, fall back, attack, etc. If the actor's health gets too low - it _might_ switch to `RETREAT` or `MERCY` state.
- `RETREAT` - Checks if there are other actors nearby potentially aggressive towards the actor's enemy - if so - retreats towards them and waits there. Similarly to `STAND_GROUND` - if the enemy gets too close - reengages `FIGHT`
- `MERCY` - The actor asks for mercy, lays down their weapons/items, and gets pacified. If the actor is attacked too much during this process - will reengage `FIGHT`

Lastly, behaviors within each `combatState` are separated by the current character stance, which can be:
- `Melee` - Character is currently holding a melee weapon
- `Marksman` - Character is holding a marksman weapon
- `Spell` - Character is in a spellcasting stance
- `Any` - Character is in any stance

`extensionObject` is a Lua table that implements your behavior, it's structured in a very similar way to behavior nodes used internally by Mercy. This table is supposed to implement a set of methods that will be called by the behavior tree when the execution flow reaches that part of the tree.

Interface use example:
```Lua
local interfaces = require('openmw.interfaces')

interfaces.MercyCAO.addExtension("Locomotion", "STAND_GROUND", "Melee", {
   name = "My custom extension",
   start = function(task, state)
      print("My custom extension started")
   end,
   run = function(task, state)
      print("My custom extension running!")
      -- From within this function you should report one of the following statuses:
      task:success() -- Ends this task (extension) with a success state. The execution will continue through the rest of MercyCAO behaviours.
      -- task:fail() -- Same as success, in extensions fail and result in the same outcome, yet it's still a good idea to report an appropriate status.
      -- task:running() -- Report this to signify that your task is still running. run method will start again next frame.
   end,
   finish = function(task, state)
      print("My custom extension is done!")
   end
})
```

`state` argument is a shared behavior tree's state object (sometimes called a "blackboard" in other behavior tree libraries/implementations), it's a table of properties and functions to which all of the Mercy: CAO behavior trees have direct access.
It is also available outside the task function via `interfaces.MercyCAO.state`.

There are a number of properties you can set on a state object to affect the actor, main ones are:

```Lua
-- Values below are default values. These properties are reset to their defaults EVERY FRAME before the tree runs, so if you want to keep .movement at a specific value - you need to set it every frame, i.e every run() of your extension!
state.stance = types.Actor.STANCE.Weapon
state.run = true
state.jump = false
state.attack = 0 -- directly maps to self.controls.use
state.movement = 0
state.sideMovement = 0
state.lookDirection = nil -- a global vector from actor toward its look target, actor will be interpolate-rotated towards that, otherwise it will look at its enemyActor
state.vanillaBehavior = false -- a global switch, while this is true - npc AI is controlled by the OpenMW engine and not by Mercy
-- Value below will NOT be reset every frame - you can change it to force Mercy trees to switch into a different combat state
-- See possible states in scripts/enums.lua
state.combatState = "STAND_GROUND",
-- Below is a current combat package target, you shouldn't change this - but it's useful to know who this actor is fighting against
state.enemyActor
-- current character stance, read-only, same as stance argument mentioned before
state.detStance 
-- current frame's delta time
state.dt

```

Note: currently spellcaster's `FIGHT` behaviors are forced to be handled by the vanilla AI. If you want to implement such a behavior (which should include picking spells, switching between them, casting them, etc.) - disable the vanilla behavior for spellcasters flag:

```Lua
interfaces.MercyCAO.setSpellCastersAreVanilla(false)
```

Without any additional changes this will mean that a spellcaster with a melee weapon in its hands will be stuck in Mercy melee behaviour, so again, set this to false this only if you are ready to implement the spell and stance switch logic!

If your extension was successfully attached - you should see a [MercyCAO][...] Found an extension your_extension ... message printed in the console (f10 Lua console or a game process console, not in-game tilde console).

If you are familiar with the concept of behavior trees here's a visual aid explaining where those extension nodes are injected (image is old, stances are not reflected):

![alt text](/imgs/extension.png)

If you want to read about behavior trees - see my haphazard writeup and some links (and images!) in [this repository](https://github.com/MaxYari/behaviourtreelua2e).

### Advanced interface - Adding additional voicelines

In its current state only some of the race/gender combinations have new AI-generated voicelines (see `scripts/custom_voice_records.lua` for a list of all implemented races/genders). At the moment of writing the work on adding new voiceline have been stopped. If you desire to add the missing voicelines you can do so using the `MercyCAO.interfaces.addVoiceRecords(records)` where records is an object of the same format as a records object found in `scripts/custom_voice_records.lua`. `records` object you provide will be merged with the existing `records` object.

Example:

```Lua
local interfaces = require('openmw.interfaces')

interfaces.MercyCAO.addVoiceRecords(StandGround = {
      {
         race = "imperial",
         gender = "female",
         infos = {
            {
               text = "",
               sound = "path_to_file_1.mp3"
            },
            {
               text = "",
               sound = "path_to_file_2.mp3"
            },
            {
               text = "",
               sound = "path_to_file_3.mp3"
            }
         }
      },)
```

Whenever Mercy will trigger this voiceline - one of the provided files will be randomly selected and played.


## MWSE compatibility

This is an OpenMW Lua mod, it's not compatible with MWSE. It's probably possible to port it since most of the mod is pure Lua, but I'm not familiar with MWSE and am not planning to change that. If you'd like to port it - feel free to do so. If possible please keep this mod as a dependency.

## Appreciation

My thanks go to the OpenMW Discord community for massively helping me overcome a multitude of Lua hurdles, testing, and providing feedback.

## Generative AI use disclaimer 

As mentioned before - Eleven Labs was used to generate new voice lines. ChatGPT was used as a coding and writing assistant.


