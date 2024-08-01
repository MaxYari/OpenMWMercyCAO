<img width="385" alt="image" src="https://github.com/MaxYari/OpenMWExperimentalMods/assets/12214398/ffc47f1e-c09c-4aae-9f52-a322c07f3e00">
<img width="385" alt="image" src="https://github.com/MaxYari/OpenMWExperimentalMods/assets/12214398/d3296b67-aea1-47d8-a75c-475fb761156d">

# Mercy: Combat AI Overhaul

A significant overhaul of in-combat NPC behavior for OpenMW. Using custom lua behavior trees library, with new voice lines and animations. Melee NPCs are fully affected. Ranged and spellcasters affected only partially.

## How to install

- Download this repository as an archive and install using Mod Organizer 2. Or manually place the contents of this repository into your ".../Morrowind/Data Files" folder. 
- Enable the mod's .omwscript file in "Content Files" tab of the OpenMW launcher.

Have fun!

## Credit

ElevenLabs-generated voice lines by [vonwolfe](https://next.nexusmods.com/profile/vonwolfe).

#### Extending Mercy: CAO

Mercy provides an interface for extensions. Using this interface its possible to develop new NPC behaviors compatible with Mercy or compatibility patches for other mods.
First of all Mercy script should be in a load order _before_ your extension. Secondly you should use the extension interface before the first onUpdate call, otherwise Mercy will finish its initialisation without acknowledging your extension. It's not possible to extend Mercy in a middle of it's runtime.

Extensions are done using `interfaces.MercyCAO.addExtension(treeName, combatState, stance, extensionObject)`.
Mercy AI is globally split to 2 different behaviour trees (`treeName` argument. And actually its 3 trees, but let's ignore the 3rd one - it's an auxiliary and doesn't have any extension points):
- `Locomotion` - A tree responsible for character movement through space - strafing, chasing, moving around e.t.c
- `Combat` - responsible for attacking - checking range, making quick or long swings, series of attacks e.t.c
Those trees run in parallel.

Furtermore all of the behaviours/branches within those trees are grouped within 4 principal combat AI states (`combatState` argument):
- `STAND_GROUND` - Although technically in a combat state (Combat ai package, in fact Mercy works _only_ when combat package is active) - actor is hesitant to engage, will not rush towards the enemy, will slowly move around a bit, play a warning voice line. If too much time will pass in this state (while enemy is in line of sight) or an enemy will get too close - combat stat will switch to `FIGHT`
- `FIGHT` - Main engagement mode. Actor will run, strafe, chase, fallback, attack e.t.c. If actor's health gets too low - it _might_ switch to `RETREAT` or `MERCY` state.
- `RETREAT` - Checks if there are other actors nearby potentially aggressive towards actors enemy - if so - retreats towards them and waits there. Similarly to `STAND_GROUND` - if enemy gets too close - reingages `FIGHT`
- `MERCY` - Actor asks for mercy, lays down their weapons/items and gets pacified. If Actor is attacked too much during this process - will reingage `FIGHT`

Lastly, behaviours within each `combatState` are separated by the current character stance, which can be:
- `Melee` - Character is currently holding a melee weapon
- `Marksman` - Character is holding marksman weapon
- `Spell` - Character is in a spellcasting stance
- `Any` - Character is in any stance

`extensionObject` is a lua table that implements your behaviour, it's structured in a very similar way to behaviour nodes used internally by Mercy. This table supposed to implement a set of methods that will be called by the behaviour tree when the execution flow reached that part of the tree.



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
      -- task:success() -- Ends this task (extension) with a success state. This will continue execution through the rest of MercyCAO behaviours in this part of the tree.
      task:fail() -- End with a failure state. This will prevent the rest of behaviors in this part of the tree from running.
      -- task:running() -- Return this to signify that your task is still running. run function will start again next frame.
   end,
   finish = function(task, state)
      print("My custom extension is done!")
    end
})
```

`state` argument is a shared behaviour tree's state object (sometimes called a "blackboard" in other behaviour tree libraries/implementations), its a table of properties and functions to which all of the Mercy: CAO behaviour trees have direct access.

There are number of properties you can set on a state object to affect the actor, main ones are:

```Lua
-- Velues below are default values. These properties are reset to their defaults EVERY FRAME before the tree runs, so if you want to keep .movement at a specific value - you need to set it every frame, i.e every run() of your extension!
state.stance = types.Actor.STANCE.Weapon
state.run = true
state.jump = false
state.attack = 0 -- directly maps to self.controls.use
state.movement = 0
state.sideMovement = 0
state.lookDirection = nil -- a global vector from actor toward its look target, actor will be interpolate-rotated towards that, otherwise it will look at its enemyActor
state.vanillaBehavior = false -- a global switch, while this is true - npc AI is controlled by the OpenMW engine and not by Mercy
-- Value below will NOT be reset every frame - you can change it to force Mercy trees to switch into a different combat state
state.combatState = "STAND_GROUND",
-- Below is a current combat package target, you shouldn't change this - but it's useful to know who this actor is fighting against
state.enemyActor
-- current character stance, read-only, same as stance argument mentioned before
state.detStance 
-- current frame's delta time
state.dt

```

If your extension was successfully attached - you should see a `[MercyCAO][...] Found an extension your_extension ...` message printed in the console (f10 lua console or a game process console, not in-game tilda console).

If you are familiar with the concept of behaviour trees here's a visual aid explaining where those extension nodes are injected (stances are not reflected in the image since it's not yet updated):
![alt text](/imgs/extension.png)

If you want to read about behaviour trees - see my haphazard writeup and some links (and images!) in [this repository](https://github.com/MaxYari/behaviourtreelua2e).

## MWSE compatibility

This is an OpenMW Lua mod, it's not compatible with MWSE. It's is probably possible to port it since most of the mod is pure Lua, but I'm not familiar with MWSE and am not planning to change that. If you'd like to prot it - feel free to do so. If possible please keep this mod as a dependency.

## Appreciation

My thanks go to OpenMW discord community for massively helping me overcome a multitude of Lua hurdles, testing and providing feedback.


