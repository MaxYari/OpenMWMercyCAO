# Mercy: Combat AI Overhaul

A significant overhaul of in-combat NPC behavior for OpenMW. Using custom lua behavior trees library, with new voice lines and animations. Overhauls Melee NPCs, partially affects ranged and spellcasters. 

![Demo 1](/imgs/demo1.gif)
![Demo 2](/imgs/demo2.gif)
![Demo 3](/imgs/demo3.gif)

## How to install

- Download this repository as an archive and install using Mod Organizer 2. Or manually place the contents of this repository into your ".../Morrowind/Data Files" folder. 
- Ensure that `MercyCAO Compatibility Patches.omwscripts` is at the very bottom of your Content Files list in OpenMW launcher (you can drag it to reorder).
- Enable the mod's .omwscript file in "Content Files" tab of the OpenMW launcher.

Have fun!

## Credit

ElevenLabs-generated voice lines by [vonwolfe](https://next.nexusmods.com/profile/vonwolfe).

## Mod compatibility

Not compatibly with most mods directly affecting NPC behaviour in combat, unless a compatibility patch is provided by a mod author or here.

Compatibility patches included here provide a compatibility layer for following mods:

[Take Cover](https://www.nexusmods.com/morrowind/mods/54976) by [mym](https://next.nexusmods.com/profile/mym)

Note that compatibility patches are written using Mercy: CAO extension interface (read below).

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

Note: currently spellcaster's FIGHT behaviours are force to be handled by the vanilla AI. If you want to implement such a behaviour (which should include picking spells, switching between them, casting them etc) - disable the vanilla behaviour for spellcasters flag:

```Lua
interfaces.MercyCAO.setSpellCastersAreVanilla(false)
```

If your extension was successfully attached - you should see a `[MercyCAO][...] Found an extension your_extension ...` message printed in the console (f10 lua console or a game process console, not in-game tilda console).

If you are familiar with the concept of behaviour trees here's a visual aid explaining where those extension nodes are injected (stances are not reflected in the image since it's not yet updated):
![alt text](/imgs/extension.png)

If you want to read about behaviour trees - see my haphazard writeup and some links (and images!) in [this repository](https://github.com/MaxYari/behaviourtreelua2e).

## MWSE compatibility

This is an OpenMW Lua mod, it's not compatible with MWSE. It's is probably possible to port it since most of the mod is pure Lua, but I'm not familiar with MWSE and am not planning to change that. If you'd like to prot it - feel free to do so. If possible please keep this mod as a dependency.

## Appreciation

My thanks go to OpenMW discord community for massively helping me overcome a multitude of Lua hurdles, testing and providing feedback.


