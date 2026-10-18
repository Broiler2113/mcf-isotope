# Isotope 0.12.9

This is a **source-only release**. Download **Source code (zip)** or **Source code (tar.gz)** below, import `project.godot` in Godot 4.7, and run with the GL Compatibility renderer.

## Shields, blasts and captives
- A drone or blast that lands right on a soldier always kills it, even with a friendly Shield Bearer standing next to it.
- Shield Bearers still shelter the soldiers beside them from the rest of a blast.
- A frag grenade asks a Shield Bearer for two 2+ rolls (both must hold), even on a direct hit.
- A Shield Bearer can only be shot from a neighboring cell. Snipers, Marksmen, Anti-Tank soldiers and tank cannons can still fire from range.
- Grabbed soldiers can now be killed by blasts, fire, gas, bullets, vehicles and collapses.
- A captive held in the line of fire takes the bullets meant for its captor.

## Holdout
- Holdout can be played alone: remove the second slot in the lobby and face the waves by yourself.
- Every wave is its own entry in the turn order ("Wave I", "Wave II"…), placed at a random spot like a raider army.
- The active wave gets the green arrow in the Initiative window, and the sidebar names it on its turn.
- Only the wave whose turn it is acts, and each wave shows its own alive/dead count.
- Holdout fighters no longer stand next to fire or burn their own flamers and Shield Bearers.

## Bodies
- Bodies never land on a cell with a unit or under a hovering drone, whether dropped, dragged or thrown by a broken corpse wall.
- In the map editor the body brush skips unit cells, and placing a unit on a body removes the body.
- Soldiers can no longer deploy or land on a body cell and vanish from the board.

## Fixes
- LDF walls no longer pick up colored department lines from nearby walls.
- Fire that burns a mounted drone station frees its shuttle seat.
- A guest's controls no longer freeze when the host turns down one of its moves.
- No dice are rolled for a random event when no event can happen.

**Compatibility:** network protocol 20; all players must use the same release.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.12.8...v0.12.9
