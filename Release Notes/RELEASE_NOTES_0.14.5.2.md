# Isotope 0.14.5.2

## Faster AI turns

- Each AI move is decided about twice as fast on big maps (about 4 ms → 2 ms per move on the largest bench battle).
- A soldier with a smoke grenade no longer makes the AI hesitate: weighing where to throw it dropped from about 24 ms to about 6 ms.
- Sappers, shooters and soldiers next to bodies stopped re-checking the whole army or the whole map before each choice.
- The check for whether a sleeping civilian has spotted a soldier now runs in the built-in C++ acceleration.
- A 1,200-move AI battle on the largest map now takes 7.6 seconds of computer time instead of 9.5 (11.4 instead of 12.6 without the acceleration).
- The AI and the civilians make exactly the same choices as before; only the time changed.

## Compatibility

- Network protocol **33** and replay schema **3** are unchanged: 0.14.5, 0.14.5.1 and 0.14.5.2 play together, and saves and replays carry over.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.14.5.1...v0.14.5.2
