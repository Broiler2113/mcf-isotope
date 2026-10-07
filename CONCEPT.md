# MCF Isotope — The Game

A turn-based tactical skirmish for one to eight sides, played on a top-down grid.
Two squads of a dozen soldiers, a derelict space station or a bombed-out town, and
a few rounds to decide who is still standing. It is a digital adaptation of the
tabletop wargame *Mind Control Factor*, and it keeps the thing that makes that game
work: **every shot is two dice rolls you watch happen, and almost every death was
avoidable a move earlier.**

This document describes the game — what it is, how a battle goes, and the rules that
matter at the table. It is not a technical specification; for the implementation, its
constants and its contracts, see `GAME_SPEC.md`.

---

## 1. The pitch

You command a squad, not an army. Twelve soldiers, each one bought with points, each
one able to act twice a turn, each one killable by a single unlucky roll. There is no
hit-point bar, no healing, no reinforcements. A soldier is alive or a body on the
floor, and the body stays where it fell — in the doorway, blocking the only route, or
in your arms as a shield.

The battlefield is as much a combatant as the soldiers. Walls block sight and
bullets; airlocks slide open as you approach and shut behind you; a trench makes a
man untouchable from across the room and helpless to the soldier who walks up to its
lip. Engineers build, miners demolish, fire spreads, and vacuum is one broken window
away.

The whole game is readable at a glance: a grid, labelled tiles, coloured sides, and
dice that roll on screen where both players can see them.

---

## 2. How a battle goes

```
Main menu → set up the match → deploy your force → battle → match over
```

**Set up.** Pick a map (generated, authored, or built in the editor), a size, the
number of sides, fog of war on or off, civilians, random events, and who plays each
side — a human at this machine, the AI, or a peer over the network.

**Deploy.** Every side spends points on soldiers and vehicles and places them in its
deployment zone, on the real map, with the real walls in view. There is no point cap
by default; the counter is there for an agreed budget. On symmetric maps the first
side's formation is mirrored into every other zone, so nobody wins the deployment.

**Battle.** Initiative is rolled once for the whole match and never again: it is an
order of *sides*, not of units. On your turn you activate any of your units, in any
order, as many as you like, and pass when you are done. When the order wraps around,
a new round begins and everyone's action points come back.

**Match over.** The moment only one team still has a living soldier, the board
freezes and names the winner. Nothing is accepted after that — but the match is still
there to look at, save, or scroll back through.

---

## 3. The board

The map is a grid of square cells. Each cell has a floor (deck plate, soil, grass,
flammable boards, or none at all — open space), a height, and at most one object:
a wall, a window, sandbags, a trench, a piece of furniture, a mine, a door.

**Height is the whole terrain system.** Two metres or more is a wall: it cannot be
entered, and it blocks sight and fire. Below that, height is cover you can climb
over, at a movement cost that rises with the obstacle. A half-metre crate slows you;
a metre of sandbags slows you more and makes you harder to shoot.

**Distance is Chebyshev** — a diagonal step is one step, so ranges are squares, not
circles. Movement is a budget of points spent per step, not a fixed number of tiles,
and the leftovers stay available: a soldier who moves three cells of his nine can
stop, look, and keep walking on the same action.

**Space is a floor like any other, except there is no floor.** On station and
asteroid maps the map ends in vacuum, and vacuum is crossable: soldiers can go
outside through an airlock, walk the hull walkways between the solar panels, and come
back in somewhere else. A window broken into the void is a shortcut and a death trap
at once.

---

## 4. The turn

Each soldier gets **2 action points** per activation (the commander gets 3). Every
basic action costs one: move, shoot, grab, use an item, build, dig, break something,
board a vehicle. A few cost the full activation — a marksman's laser, for instance.

Within your turn, order does not matter. You can move one soldier, shoot with a
second, move the first again if he kept movement in hand, then pass. Nothing is
committed until it is resolved, and a mistake can be taken back: undo walks the turn
backwards one action at a time.

At the end of a turn, in this order: the next side comes up, the civilians take their
activations, fire creeps one cell, and vehicles refill their crews' action points.

---

## 5. Shooting

This is the heart of the game, and it is deliberately restrictive.

**The firing line.** A target can only be shot if it stands on one of the eight rays
out of the shooter: same row, same column, or an exact 45° diagonal. One step off the
diagonal and it cannot be shot at all — not at a penalty, not at long odds, at all.
Positioning is therefore not about getting close, it is about getting *in line*, and
stepping out of line is a real defence. Grenades and tank shells, which are aimed at
a cell rather than a man, use their own axis rules instead.

**Two rolls, in this order.**

1. **The hit roll.** The weapon's range is divided into six bands; each band out
   costs a pip. Point blank hits on a 1, the far edge of the range needs a 6, and
   beyond it the shot is refused outright rather than rolled.
2. **The defence roll.** The target rolls against its own armour, modified by what
   the shooter brings to bear. Only a failed defence kills.

Nothing is revealed early: the death is shown after the defence die lands. Where a
human is defending, that player rolls the die by hand.

**Modifiers you can see.** A metre of cover between the target and the shooter is −2
to hit. Fire between them makes aiming worse. A body carried as a shield adds a pip
to the defence. Snipers and shield bearers strip pips off the target's defence. Every
modifier is listed on the dice prompt, so the number you need is never a mystery.

**Rate of fire** is the number of hit dice in one shooting action, and a burst can
switch targets between bullets without spending another point. Every ordered bullet
is rolled, even if the first one kills.

**Trenches** are the counter to all of it: a man in a trench cannot be shot at range
at all. Walk up to the edge and you can fire down into it — unless you are firing a
flat laser beam, which passes over his head from anywhere but another trench.

---

## 6. The soldiers

| Soldier | Range | Shots | Armour | Speed | Signature |
|---|---:|---:|:---:|---:|---|
| Light infantry | 12 | 2 | 4+ | 9 | The baseline, and the legs of the squad |
| Heavy infantry | 12 | 3 | 3+ | 6 | Slower, tougher, more lead |
| Assault | 3 | 8 | 4+ | 9 | Shotgun chain — devastating in a corridor, useless across a hall |
| Machinegunner | 6 | 4 | 3+ | 6 | Suppressing volume, carries a frag grenade |
| Sniper | 30 | 1 | 4+ | 6 | Auto-hits inside 12, strips two pips of defence |
| Marksman | ∞ | 1 | 4+ | 4 | Piercing laser with unlimited range — it goes through people |
| Anti-tank | 18 | 1 | 4+ | 6 | A 3×3 blast that kills outright and flattens terrain |
| Flamethrower | 6 | 1 | 3+ | 6 | Sets the room on fire; carries the extinguisher |
| Commander | 12 | 4 | 2+ | 6 | Three action points, hard to kill, worth hunting |
| Engineer | 12 | 1 | 4+ | 6 | Builds, digs six trenches an action, raises one wall per match |
| Miner | 1 | 1 | 4+ | 6 | Demolishes anything in one action |
| Drone operator | 12 | 1 | 4+ | 6 | Deploys the station that launches drones |
| Shield bearer | 1 | 1 | 2+ | 4 | Blocks and shoves; nearly unkillable from the front |
| Civilian | 12 | 1 | 5+ | 9 | Cheap, fragile, and in everybody's way |

A drone is not bought: it is launched from a station, flies far, sees for the side
that owns it, and ends by detonating.

**Factions** are a matter of appearance and flavour; the rules are the same for
everyone. The faction decides the colour, the portrait, and the art a side's soldiers
are drawn with.

---

## 7. Bodies

Corpses are objects, and they matter.

A body lies where the soldier fell and **blocks the cell** like a living man — in a
doorway, it holds the doors open and nobody can close them. A body can be picked up
and carried as a shield, one pip of defence per body, at the cost of your hands. It
can be dragged, stacked, and five bodies on one cell become a **corpse wall**, two
metres of cover that anybody can shoot over but nobody can walk through.

Prisoners work the same way. A soldier can grab an adjacent enemy and hold them; the
captive cannot act until he breaks free on his own turn, and carrying him slows the
captor to a walk.

---

## 8. Building the battlefield

Engineers and miners rewrite the map while the battle is on.

| Thing | Built by | Effect |
|---|---|---|
| Sandbags | Engineer, 1 action | A metre of cover; can be dragged along |
| Hedgehog | Engineer, 2 actions | Cannot be crossed on foot — jumped over, never stood on |
| Trench | Anyone digs; engineer digs six at once | Immunity to fire from range |
| Wall / window / airlock | Engineer, 1 action | Seals or opens a route |
| Deployable wall | Engineer, once per match | Six connected sections of black monolith; fireproof, and it smothers fire |
| Pillbox | Engineer, 2 actions | Concrete box that soaks two heavy hits; the embrasure version lets soldiers fire out |
| Machine gun post | Engineer, 1 action | Fired by whoever stands next to it: range 12, eight shots |
| Mines | Sapper | Hidden until stepped on; a sweeper reveals them for his own side |
| Drone station | Drone operator | Launches drones; deploying it launches the first |

Miners and engineers also **demolish**: one action, and a wall, a window, an airlock,
a pillbox or a corpse wall is simply gone. The AI does this to clear its own path.

**Airlocks** open for anyone alive standing within one cell and close behind them. An
engineer can weld one shut for good, which is how a corridor gets sealed.

---

## 9. Fire, gas and vacuum

**Fire** spreads orthogonally, one cell per round, at the start of the turn of the
side that started it. It burns flammable floors and wooden walls, kills what stands
in it, and makes shooting through it harder. A flamethrower starts it on purpose; a
blast starts it by accident. The extinguisher grenade and the engineer's deployable
wall put it out.

**Gas** arrives as a random event, settles over a block of the map for a few rounds,
and makes everyone inside roll each round to hold their breath. Vehicle crews are
sealed in and safe.

**Vacuum** is not poison — it is the absence of the floor. A depressurised
compartment, a hull breach, the open space outside the station: soldiers can cross
all of it, and sometimes must.

---

## 10. Fog of war

With fog on, a side sees what its own soldiers and vehicles can see — and the whole
team shares one map. Sight is unlimited in range: what stops it is geometry. Walls,
closed airlocks, pillboxes and the hull of an **enemy** tank block the line; living
men, bodies, your own vehicles and windows do not.

An enemy you cannot see cannot be shot. A tank is therefore a mobile wall for the
other side and a window for yours, and a drone sent over a roof is a pair of eyes.

Fog can be turned off entirely, which turns the game into a pure positional duel.

---

## 11. Vehicles

| Vehicle | Size | Crew | Speed | What it is |
|---|:---:|:---:|---:|---|
| Tank | 3×3 | 3 | 16 | Four machines in one: hull, tower, tracks and gun are damaged separately |
| Shuttle | 2×2 | 4 seats | 30 | Open transport — the passengers sit in the hull cells, visible and shootable |
| Borg | 1×1 | 1 | 9 | A powered suit: the operator stays on the grid and plays as a soldier with better numbers |

A tank's gun has a range of 30, fires at most twice a round, hits or falls short, and
detonates either way. Its crew is off the board and takes hits when the hull does.
A tank runs men over, blocks the enemy's sight, and leaves a wreck wherever it dies —
and often explodes on the way out.

Vehicles can be **boarded by anyone**, including the enemy. Whoever holds the
majority of the living crew owns the machine; a contested vehicle does nothing at all.
A borg whose operator is dead can be taken over: the body is pushed out onto the
next cell.

---

## 12. Civilians and other neutrals

Civilians belong to no side and are hostile to none of them until something wakes
them. Asleep, they stand around their quarter. The first shot anywhere on the map
wakes them all, and from then on they move for themselves: they run from fire,
scatter from the shooting, and will pick up a weapon or a body if one is in reach.

They take their activations as their own slot in the initiative order, and the groups
that wake split off into slots of their own, so the turn order reads as a story of
which part of the map has woken up.

A civilian can also be *bought* as a cheap soldier. One you paid for is an ordinary
member of your squad, not a neutral.

**Independent armies** are something else: a random event lands a hostile force on a
map edge that fights everyone, including the civilians, and does not count towards
anybody's victory.

---

## 13. Random events

Switch them on and the map itself gets a turn. Events are announced one round before
they land, with the zone drawn on the board — so there is always exactly one round to
get out of the way, or to push somebody into it.

- **Artillery barrage** — a rectangle is shelled; about half the cells in it are
  destroyed outright, with whoever stood on them. It usually aims at the thickest
  concentration of soldiers on the map, whoever they belong to.
- **Gas cloud** — a block of the map fills with gas for a few rounds and chokes what
  stays inside it.
- **Independent army** — raiders land on a map edge and start walking inwards.

How often they fire and in what proportions is set per match.

---

## 14. Maps

**Generated.** The generator builds five kinds of map at six sizes, up to 250×250:

- **Station** — departments, corridors, service tunnels, airlocks and solar panels
  out on the hull, surrounded by vacuum.
- **Town** — districts of houses, shops, workshops and yards along streets.
- **Field** — open ground, ruins, huts, rocks and dug-in positions.
- **Bunker** — the station plan buried in rock, with no vacuum anywhere.
- **Asteroid** — a town-sized island in space, built of station plating.

Every map is framed by ten cells of plain ground, and the ground continues past the
edge of the board to the edge of the screen, so the battlefield reads as a place
rather than a cut-out rectangle. Maps can be mirrored for strict symmetry, seeded for
exact reproduction, and filled with furniture and civilians to taste.

**Authored.** The map editor works like a paint program: brushes, lines, rectangles,
fills, selection, copy and paste, stamps for ready-made rooms and bunkers, symmetry
modes that paint every mirrored copy at once, and the generator available as a
starting point. A preset decides which tileset the map is drawn with.

---

## 15. Ways to play

- **Hot seat** — several humans at one machine.
- **Against the AI** — in three strengths, on either side, or on both at once with
  the players watching.
- **Over a network** — a lobby for up to eight slots, teams, factions, colours and a
  chat, with the host setting up the match and everyone watching the same board.
- **Replays** — every local match records itself and plays back at your pace,
  with scrubbing and a speed control.
- **Saves** — a match can be saved mid-battle and resumed with the same roles.

The AI is honest about what it does: it plans a whole turn at a time, forms up,
takes cover, concentrates fire on what it can actually kill, demolishes obstacles in
its way, mans vehicles it finds, and avoids known minefields. It does not throw
grenades or pilot drones.

---

## 16. What the game is not

- There is no campaign, no persistence between battles, and no upgrades. A match is
  self-contained.
- There are no hit points for soldiers. A man is killed by a single failed defence
  roll, always.
- There is no hidden information beyond fog of war and mines: every number, every
  modifier and every die is on screen.
- Cover never makes a soldier harder to *kill*, only harder to *hit*. The tabletop
  does it differently; this is a deliberate departure.
