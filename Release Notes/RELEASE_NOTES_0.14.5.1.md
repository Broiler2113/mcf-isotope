# Isotope 0.14.5.1

## Faster AI turns

- The AI works out its plan for each turn much faster: on the biggest maps the thinking before an AI turn's first move dropped from about 0.4 seconds to about 0.15 seconds.
- The heavy parts of that plan now run in the game's built-in C++ acceleration (Windows, Intel Mac and Apple Silicon): rating every cell each soldier could move to, mapping where enemy fire can reach, and tracing marksman beams.
- The AI plays exactly the same moves as before; only the time it takes changed. Without the acceleration (other systems, or when switched off) the game uses the original code, also unchanged.
- **Settings → Interface → Performance** now lists six accelerated systems.

## Compatibility

- Network protocol **33** and replay schema **3** are unchanged from 0.14.5: 0.14.5 and 0.14.5.1 play together, and saves and replays carry over.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.14.5...v0.14.5.1
