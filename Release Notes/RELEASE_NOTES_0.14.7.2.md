# Isotope 0.14.7.2

## Online multiplayer

- Fixed: friends were dropped from online games right after joining or right after the match started. Large messages, like a long match being continued from a save, were too big for the lobby server, and it closed the whole game. Everything sent online is now compressed, about 15 times smaller.
- If the connection to the lobby server is lost, the battle now says so in the log, and an AI takes over the armies of the players who are gone instead of waiting for them forever.
- Online games need everyone on 0.14.7.2.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.14.7.1...v0.14.7.2
