# Isotope 0.14.5.4

## Faster big battles

- After every action the game no longer goes through the whole army to find the few soldiers who changed. It now keeps a running list of units that moved, died, switched sides or got in or out of a vehicle, and only looks at those.
- Each side's fog of war updates in about half the time (0.9 → 0.5 ms per action on the largest bench battle).
- The check for whether a sleeping civilian has spotted a soldier now only looks again at civilians whose row, column or diagonal changed (on most actions 3–4 civilians instead of about 30), and costs about a quarter of what it did (0.7 → 0.2 ms per action).
- Finding who a soldier can shoot at, or capture, now runs in the built-in C++ acceleration.
- The AI keeps its list of enemies between moves instead of rebuilding it every time.
- A 1,200-move AI battle on the largest map now takes about 3.1 seconds of computer time instead of 5.9 (9.0 seconds without the acceleration).

## Compatibility

- Soldiers, civilians and the AI make exactly the same moves as before; only the time changed.
- Network protocol **33** and replay schema **3** are unchanged: 0.14.5 through 0.14.5.4 play together, and saves and replays carry over.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.14.5.3...v0.14.5.4
