# Isotope 0.9.7

## Gameplay and presentation

- Field and town maps now use grass art for every outer ground cell, including when flammable terrain is disabled. The ground beyond the board also stays grass, without dirt or gray patches. Nonflammable terrain keeps its existing fire rules.
- Demolish Fortification now works on wooden, standard, armored, brick, stucco, cinderblock, soil, glass, armored glass, airlock, and station walls. The world boundary remains protected.
- Gas clouds have pixel-art texture and block sight through affected cells. Cloud outlines and timers remain readable.
- The main menu no longer shows the small “MCF Isotope” window header or “Turn-based tactics” subtitle.
- Leaving a match or replay while an AI or animation timer is pending no longer asks a detached scene node for its tree.

## RLM training and play

- Fixed large-board policy serving and large-army premature passes. Giant-map training now includes 120–200 soldiers per side, tanks, positioning signals, and responses to visible vehicle drive lanes.
- Added occasional artillery and gas events to training, with public hazard observations and rewards for escaping danger zones.
- Added round-based learning credit, broader scenario coverage, historical opponents, paired checkpoint evaluation, and optional human replay import for imitation learning.
- Added automatic RLM memory-cache cleanup and checkpointed restart under resource pressure, plus bounded trimming of RLM diagnostic logs.
- The dashboard now reports completed training wins, losses, and draws, and partial evaluation results as games finish.

Training changes take effect for a local trainer when that trainer is updated or resumed using the documented deployment helper. This release does not itself restart a running training process or establish human-level playing strength.

The small deterministic AI battle signature was refreshed for the expanded demolition choices. Medium and large battle signatures remain unchanged.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.9.6...v0.9.7
