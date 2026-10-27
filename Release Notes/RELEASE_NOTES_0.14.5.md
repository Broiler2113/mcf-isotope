# Isotope 0.14.5

## Civilians

- A civilian who sees another civilian wake up wakes up too, and so do the civilians who see that one. Everyone woken this way joins the same group, so one wake-up still takes one place in the initiative order.
- Fixed: sleeping civilians standing on the map's main diagonal no longer wake up whenever a tank has crew aboard.

## Smoother battles

- No more freeze at the first smoke of a fogless battle, or when a spectator switches to a new side: the board the new viewer remembers is prepared ahead of time, and the terrain is no longer repainted from scratch.
- On big maps the AI no longer freezes the screen for a third of a second at the start of each of its turns: it works its plan out over a few frames, and plays exactly the same moves.
- The worst stutter in a big AI battle dropped from about 0.36 seconds to 0.05 seconds.
- Soldiers are drawn on their own layer and redrawn only when something about them changes: panning, zooming and hovering over a big battle costs a fraction of what it did.
- Fog of war, doors and airlocks, and civilian wake-up checks only look again at the soldiers who moved, so actions in big battles resolve about a quarter faster.

## Compatibility

- Network protocol **33**: 0.14.5 cannot join games hosted on 0.14.4.x, and the other way around.
- Replay schema **3** is unchanged. Replays recorded before 0.14.5 still open, but civilians in them now follow the new wake-up rule, so a replay with civilians may play out differently from the original match.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.14.4.2...v0.14.5
