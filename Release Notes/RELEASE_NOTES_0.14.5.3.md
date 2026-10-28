# Isotope 0.14.5.3

## Smoother big battles

- The battle screen spends about a third less time drawing each frame on the largest bench battle (5.2 → 3.3 ms), because soldiers whose look did not change are no longer re-checked.
- While soldiers walk, only the walkers are redrawn.
- The short freeze every 48 actions, when the replay saves a checkpoint, is about half as long (34 → 20 ms): the compression now runs in the background.
- Breaking a wall or digging in sight of a large army while smoke or gas hangs anywhere on the map no longer stalls the screen (up to 90 ms → about 25 ms).
- A 1,200-move AI battle on the largest map now takes about 5.5 seconds of computer time instead of 7.3.

## Hotseat and spectating

- Passing the turn in a hotseat game no longer stalls while the screen switches to the other player's memory of the map (about 60 ms → 3 ms on the largest bench battle).
- The same applies when a spectator switches to another side's view.

## Zooming and group orders

- Zooming in or out no longer freezes the screen for a fraction of a second when the ground tiles change sharpness (about 300 ms → under 20 ms per zoom step). The map editor and deployment screen get the same fix.
- Pressing Move with a big group selected no longer stalls while the preview is worked out.
- Giving the order is about five times quicker: 200 soldiers start walking after about 60 ms instead of 340 ms.

## Compatibility

- Soldiers, civilians and the AI make exactly the same moves as before; only the time changed.
- Network protocol **33** and replay schema **3** are unchanged: 0.14.5 through 0.14.5.3 play together, and saves and replays carry over.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.14.5.2...v0.14.5.3
