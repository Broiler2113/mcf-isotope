class_name ManualText
extends RefCounted

## Текст «Manual» (0.12, решение владельца: справочник, открываемый в любой момент, а не
## обучение в первом бою). Числа берутся из констант правил - поменяется правило, поменяется
## и справочник. Разметка - BBCode для RichTextLabel; [h] - подзаголовок раздела.

## Разделы по порядку: [заголовок, текст]. Карточки бойцов строит окно само (UNIT_BLURBS).
static func sections() -> Array:
	return [
		["Getting Started", """[h]The match[/h]
A match has two phases. In [b]deployment[/b] each side buys an army with its points and places it in its own zone. Then the [b]battle[/b] begins.

[h]Turns and rounds[/h]
Sides act in an [b]initiative order[/b] rolled once per match; every new round keeps the same order. On your turn you may activate [b]any of your units, in any order[/b], until you press [b]End Turn[/b]. A side with no units left is skipped.

[h]Action points[/h]
Most units have [b]%d AP[/b] per round (the Commander has 3). Moving, shooting, grabbing, using an item, digging and building each cost 1 AP. The Marksman's laser costs 2. AP refill when a new round begins.

[h]Undo[/h]
Moves and other actions that rolled no dice can be undone ([b]%s[/b]). Anything that rolled dice is final.

[h]Winning[/h]
Depends on the game mode - see [b]Game Modes[/b]. By default the last team with soldiers standing wins.""" % [MCF.AP_PER_ACTIVATION, Keybinds.label("game_undo")]],

		["Movement", """[h]Speed[/h]
A unit's [b]speed[/b] is how many movement points one Move gives. Movement you don't use stays available, so one AP of movement can be spent in several short hops.

[h]Costs[/h]
Every step - straight or diagonal - costs [b]1[/b]. Climbing onto cover costs more: [b]%d[/b] for 0.5 m, [b]%d[/b] for 1 m, [b]%d[/b] for 1.5 m. Walls, tall dirt piles, drone stations, vehicles, other soldiers and [b]corpses[/b] block the way.

[h]Hedgehogs[/h]
Nobody can stand on an anti-tank hedgehog, but infantry can jump over it in a straight line for [b]%d[/b].

[h]Hazards on the way[/h]
Stepping on a mine stops you on it and sets it off. Walking into fire kills anyone who is not fireproof. Carrying a prisoner or dragging an object costs [b]%d[/b] movement.""" % [MCF.CLIMB_COST[0.5], MCF.CLIMB_COST[1.0], MCF.CLIMB_COST[1.5],
				MCF.HEDGEHOG_JUMP_COST, MCF.CAPTURE_CARRY_PENALTY]],

		["Shooting", """[h]Firing lines[/h]
Shots travel only along the [b]8 straight lines[/b] from the shooter: its row, its column and the two perfect diagonals. A target one cell off those lines cannot be shot at all until someone moves.

[h]Hitting[/h]
A weapon's range is split into six bands. The farther the target, the higher the d6 roll you need - from [b]1+[/b] up close to [b]6[/b] at the edge of range. Beyond range the shot is impossible.

[h]Killing[/h]
Every hit is then [b]parried[/b]: the target rolls its armor number (4+, 3+, 2+…) and survives on a success. Some weapons make the parry harder - the Sniper and Shield Bearer by 2, the Miner by 1.

[h]Rate of fire[/h]
Rate of fire is how many dice one Shoot action rolls. A burst can be split between targets for the same AP.

[h]Friendly fire[/h]
A bullet hits the [b]first soldier on the line[/b], friend or foe. Keep your own men out of each other's firing lines.

[h]Modifiers[/h]
• [b]Smoke and gas block[/b] sight and aimed fire.
• Sniper: an automatic hit up to %d cells with no fortification in between.
• In vacuum a shot knocks the shooter back %d cell and the target %d (not the anti-tank).""" % [MCF.SNIPER_AUTOHIT_RANGE,
				MCF.ZEROG_SHOOTER_KNOCKBACK, MCF.ZEROG_TARGET_KNOCKBACK]],

		["Lasers", """[h]Potential[/h]
The Marksman's laser costs 2 AP and starts with 10 potential. It automatically hits along one of the eight straight firing lines. It pierces objects and soldiers while it has enough potential to pay for each obstacle.

[h]Costs[/h]
Wooden walls and glass cost 0; every second glass pane restores 1 potential. Low cover, airlocks, hedgehogs, drone stations and DPMGs cost 1. Ordinary walls and sandbag walls cost 2, corpse walls cost 3, and LDF costs 4. A soldier costs 2, or 3 when carrying a corpse shield. Vehicles and pillboxes use 10 potential per point of durability.

[h]Stopping the beam[/h]
Armored walls and the map boundary stop the beam. A vehicle also stops the beam, even if destroyed. A Shield Bearer absorbs the beam and stops it completely. Trenches shelter their occupants unless the shooter shares their straight trench line. The aiming preview shows each cost and where the beam stops."""],

		["Cover & Trenches", """[h]How cover works[/h]
Cover counts only on [b]the cell right next to the target, on the side facing the shooter[/b]. Within 2 cells there is no cover at all. A 1 m obstacle in that cell adds [b]+%d[/b] to the roll needed. Cover makes a soldier harder to hit, never harder to kill.

[h]Corpses[/h]
A corpse lying on the ground hides nobody. Five corpses on one cell become a [b]corpse wall[/b] - a full wall. A soldier can carry corpses as a shield: [b]+1 to its parry[/b] for each.

[h]Trenches[/h]
A soldier in a trench [b]cannot be shot from more than 1 cell away[/b]. An enemy standing at the lip can fire down into it. The Marksman's beam passes over trenches unless the Marksman stands in the same straight run of trench.

[h]Tanks[/h]
A living tank blocks the [b]enemy's[/b] sight; its own side sees straight through it.""" % [MCF.COVER_MOD[1.0]]],

		["Fog of War", """[h]Off[/h]
Everything is visible.

[h]Standard[/h]
You see enemies only where your team has a line of sight. The terrain is known, but the marks of battle - corpses, blood, casings, rubble - appear only after one of your soldiers has seen them.

[h]Realistic[/h]
You know only what your team sees now and what it has seen before.

[h]Sight[/h]
Sight runs in straight rays. Walls, closed airlocks, smoke and gas block it; glass does not. The whole team shares what any member sees. A drone hovering over a wall is blind.""" ],

		["Grab, Carry & Corpses", """[h]Grab[/h]
Grab an adjacent soldier for 1 AP. An enemy resists with an opposed d6 (ties are re-rolled); an ally comes freely. A soldier can be grabbed only once per round.

[h]Carry[/h]
While carrying, the captor moves %d less. Moving the captive to another adjacent cell is free.

[h]Break free[/h]
A prisoner breaks free on a [b]4+[/b] for 1 AP. Killing the captor frees the prisoner.

[h]Corpses[/h]
Bodies block movement. Pick them up as shields, drop them for free, stack %d on one cell to build a corpse wall. A blast scatters a corpse wall.""" % [MCF.CAPTURE_CARRY_PENALTY, MCF.CORPSE_WALL_COUNT]],

		["Fortifications", """[h]Building[/h]
The [b]Engineer[/b] builds sandbags (1 m cover), hedgehogs (stop vehicles, can be jumped), pillboxes, and once per match a [b]LDF wall[/b] of six connected tiles in any shape that never burns. Engineers also weld airlocks and repair vehicles.

[h]Digging[/h]
Any soldier can dig a trench; the Engineer digs twice as fast. The dug earth piles up next to the trench as low cover.

[h]Demolition[/h]
The [b]Miner[/b] and the Engineer tear down fortifications for 1 AP each.

[h]Dragging[/h]
Sandbags, hedgehogs, dirt piles, heavy furniture and corpses can be dragged. Sandbags dragged onto sandbags become a sandbag wall.

[h]Airlocks and guns[/h]
An airlock opens while a living soldier stands next to it. A stationary machine gun (DPMG) is fired from an adjacent cell: range %d, %d shots.""" % [MCF.DPMG_RANGE, MCF.DPMG_RATE_OF_FIRE]],

		["Fire", """[h]Spreading[/h]
Fire spreads at the start of the turn of the side that lit it. Each burning cell tries its 4 straight neighbors: grass, wooden floors and wooden walls catch on a [b]3+[/b], other floors on a [b]4+[/b]. Fire from a random event spreads once at the end of every round.

[h]Deadly[/h]
A soldier on a cell that catches fire dies, and walking into fire kills. [b]Shield Bearers and Flamethrowers are fireproof.[/b]

[h]Breaches[/h]
Fire eats walls, glass and airlocks on its cells, opening the way through.

[h]Putting it out[/h]
Fire never goes out on its own. The extinguisher grenade douses an area; building or digging over a burning cell smothers it. Nothing burns in vacuum, and LDF walls and pillboxes never burn.""" ],

		["Grenades & Items", """Items are used up when used, hit or miss.

[h]Frag grenade[/h] - Machinegunner
Thrown up to %d cells along a straight line. On a miss it falls short and still explodes. The X-shaped blast always kills in its center; everyone else in it must pass two parry rolls, each 1 harder than usual. A Shield Bearer anywhere in it, center included, blocks it like two bullets: two rolls at 2+.

[h]Smoke grenade[/h] - Heavy Infantry
Thrown like a frag. A 3×3 cloud stays until the end of the next round, blocks sight and aimed fire, and harms no one. Use it to cross open ground or to blind a machine gun.

[h]Fire extinguisher grenade[/h] - Flamethrower
Puts out fire in its area.

[h]Drone station[/h] - Drone Operator
Placing the station launches a drone straight away. A station can also occupy a shuttle seat; an operator in an adjacent seat can fly its drone.

[h]LDF - Engineer[/h]
Large Deployable Fortification. A single-use fortification: place six connected tiles in any shape, starting next to the engineer. Costs 1 AP. LDF walls do not burn.""" % [MCF.GRENADE_RANGE]],

		["Mines", """[h]Laying[/h]
The [b]Minesweeper[/b] lays up to %d anti-personnel mines in one action, or anti-vehicle mines that only vehicles set off.

[h]Danger[/h]
Any soldier who steps on an anti-personnel mine sets it off - [b]your own side included[/b]. Your side always knows where its own mines are.

[h]Clearing[/h]
[b]Sweep[/b] reveals enemy mines within %d cells in sight for one turn. [b]Disarm[/b] removes an adjacent mine. Fire sets anti-personnel mines off, and blasts destroy them.

[h]Old minefields[/h]
A random event can scatter forgotten anti-personnel and anti-vehicle mines on any map. Nobody is told where they are, and each one goes off only some of the time - a safe step today is no promise for the next.""" % [MCF.MINES_PER_ACTION, MCF.MINE_REVEAL_RADIUS]],

		["Drones", """[h]Launching[/h]
The [b]Drone Operator[/b] places a drone station, which launches a drone at once. The operator must stand next to the station to fly it.

[h]Flying[/h]
A drone flies up to %d per action but never farther than %d cells from its station. It can perch on a wall (and is blind there) but cannot cross it.

[h]Detonating[/h]
A drone blows itself up over a 3×3 area, killing everyone in it and leveling walls it sits on. It parries hits on a 5+.""" % [MCF.DRONE_FLIGHT_RANGE, MCF.DRONE_LEASH]],

		["Vehicles", """[h]Crew[/h]
A vehicle acts with the AP of its living crew. Soldiers can board enemy vehicles: whoever holds the majority of the crew owns it.

[h]Tank[/h]
3×3, three crew. Its main gun reaches %d cells and fires up to twice a round. The armor is modular - tower, both tracks and gun can each be knocked out, but only destroying the [b]hull[/b] ends the tank. A tank blocks enemy sight.

[h]Shuttle[/h]
A fast 2×2 transport with four seats. A Drone Operator can put a drone station on a seat and operate its drone from an adjacent seat.

[h]Borg[/h]
A one-man walker: the operator stays on the field inside it. An Engineer inside spends 1 AP on three constructions of the same type (walls, glass, airlocks, sandbags or hedgehogs), one pillbox, or nine trench digs. Unused construction credits expire at the end of the turn.

[h]Fighting vehicles[/h]
An anti-tank charge damages a vehicle only with a [b]direct hit[/b]. Anti-vehicle mines tear at the hull. Engineers repair damaged parts.""" % [MCF.CANNON_RANGE]],

		["Civilians", """Neutral civilians start passive. Once fighting breaks out, or one of them sees a soldier, they wake up, hunt the nearest soldier and shoot - they are hostile to everyone. A civilian [b]bought[/b] with deployment points fights for the side that bought it.""" ],

		["Random Events", _events_text()],

		["Game Modes", """[h]Annihilation[/h]
The last team with soldiers standing wins.

[h]Capture & Hold[/h]
Zones (1, 3 or 5) are placed fairly between the deployment zones and shown to everyone; a cramped map may get fewer, since every zone must be equally far for both sides. The host can instead [b]draw the zones[/b] in the lobby (up to 5). At the end of every round each zone belongs to the team with [b]more soldiers in it[/b] (a tie scores nothing); every zone held scores [b]1 point[/b]. First to the target (12 by default) wins. Wiping out the enemy still wins outright. The map shows who held each zone at the last round end.

[h]Holdout[/h]
All players defend together against [b]waves[/b] led by an AI or the trained model. A wave lands every %d rounds - [b]or right after the previous wave is wiped out[/b] - and each is bigger than the last. Its landing edge is announced a round ahead. Hold 5, 10 or 15 waves to win; in Endless you play for how long you last.""" % [MatchMode.WAVE_EVERY]],

		["AI Personalities", """Every AI plays at full strength and values its soldiers' lives - it uses cover, avoids open fire and does not throw units away. They differ in [b]manner[/b]:

[h]Tactician[/h]
%s

[h]Aggressor[/h]
%s

[h]Fortifier[/h]
%s

[h]Learned[/h]
The trained model (RLM). Falls back to a Tactician when no model is running.""" % [AIPersonality.BLURBS[0], AIPersonality.BLURBS[1], AIPersonality.BLURBS[2]]],
	]

static func _events_text() -> String:
	var out := "Random events are switched on in the lobby. A due round announces an event at its start; most land at the end of that round, so everyone gets one turn to react. Announced zones stay visible under fog.\n"
	for pair in RandomEvents.REGISTRY:
		out += "\n[h]%s[/h]\n%s\n" % [pair[1], RandomEvents.NOTES.get(pair[0], "")]
	return out

## Карточки бойцов: роль и умение - то, чего не видно из цифр.
const UNIT_BLURBS := {
	"sniper": "Long rifle. Automatic hit up to %d cells when no fortification is in the way, and imposes a -2 defense penalty." % MCF.SNIPER_AUTOHIT_RANGE,
	"marksman": "Laser: 10 potential. Firing costs 2 AP.",
	"anti_tank": "Rocket that kills everyone in a 3×3 blast. On a miss it falls short and still explodes. Damages vehicles with a direct hit.",
	"flamethrower": "Six-cell flame jet that sets the ground alight and splashes around walls. Fireproof. Carries an extinguisher grenade.",
	"engineer": "Builds sandbags, hedgehogs, pillboxes and an LDF (Large Deployable Fortification): six connected tiles in any shape. Welds airlocks, repairs vehicles and digs twice as fast.",
	"miner": "Melee fighter (−1 to the parry) who tears down fortifications in one action.",
	"sapper": "Lays up to five mines in one action, anti-vehicle mines too, sweeps for and disarms enemy mines.",
	"shield_bearer": "Slow melee fighter. Only adjacent soldiers can fire at it; Snipers, Marksmen, Anti-Tank soldiers and tank cannons can also fire from range. Its shield stops lasers. Blocks a frag grenade, even a direct hit, on two 2+ rolls. Survives other blasts outside their center and shelters the soldiers next to it, but a direct hit kills it. Fireproof.",
	"drone_operator": "Places a drone station that launches an exploding drone. Must stay next to the station to fly it.",
}
