# Isotope 0.11

## Online multiplayer

- Play over the internet: the Multiplayer page now has a **Lobbies** list of open games in place of LAN games. Pick a game and join it, entering a password if the host set one.
- **Host Online** puts your lobby on the list. The listing shows the map, the players and whether the battle has started.
- Hosts can turn **Allow spectators** off.
- Direct IP connection is still there for LAN and VPN games, and the lobby server address can be changed on the Multiplayer page.
- Fixed guests' tank, shuttle and borg orders being ignored by the host.

## Lighting

- Reworked dynamic lighting: smoother light, softer shadows, warm orange lamps, and no more black spots or diagonal stains.
- Light passes over furniture and low cover; only walls, closed doors and other structures stop it. Walls next to a light are lit, and a lamp's own tile glows.
- Lighting is much faster: its cost now depends on the screen, not on the number of lamps.
- Added a **Darkness** slider in **Options → Display**.
- Generated maps light every room, space wall lamps out, and put beacons at airlocks. Houses in towns and fields get their own lamps instead of streetlights.
- Consoles, vending machines, TVs and specimen fridges now glow.
- Wall lamps now hang on one side of their wall and light only that side. Light no longer leaks through walls into the area behind them, and lit walls are lit evenly across the whole tile.
- A wall can carry a separate lamp on each side. A lamp can only be shot from its own side; an explosion that hits the wall still destroys every lamp on it.
- Generated stations no longer put lamps on the hull's outside, while asteroid surfaces stay lit. Wall lamps never face into another wall.

## Combat

- You can select and order other soldiers while one of yours is still walking.
- Rolls that need 7+ are automatic failures and no longer ask you to roll.
- **Enter** rolls the dice (rebindable in Settings).
- After a partial burst the **Shoot** button stays, and the rest of the magazine can go at any other target within the same action.
- Anti-tank aiming shows the roll needed on every target cell, and shells, flames and marksman shots no longer show a "Glass N+" label.
- Random events now land at the end of the round, so every player gets a turn to react.
- With fog of war off, gas hides only the units standing inside it.
- Fixed the AI losing track of the whole map whenever there was gas anywhere on the board.
- Before/After shows units exactly as they look in battle.

## Map editor

- Right-click a lamp to change its colour or remove it; on a Mac touchpad use a two-finger click, or Ctrl+click. The lamp's glass changes colour with its light.
- **R** picks which side of the wall a lamp goes on. Every wall lamp shows a coloured bar and arrow on its side, and the brush previews where the next one will hang.
- Editor lighting has its own **Lighting** button and the **Shift+L** shortcut.
- Variants (furniture colours, door textures, wall accents) open in a small popup next to the palette button.
- The built-in rooms (Small room, Large room, Corridor, House, Pillbox, Sandbag nest, Trench line, Hedgehog row) are now ordinary presets that can be edited, renamed or deleted. Any preset can now be renamed.

## Saves and sharing

- Saves, replays, editor maps and presets are plain files in the **Isotope Data** folder next to the game. Copy a file in and it appears in its list, with no import step. **Open Folder** buttons are in the menu and the editor.
- A saved game loaded in the lobby shows a preview of its battlefield and armies.

## Textures

- All furniture and lamps are redrawn in a realistic style. Pianos, wardrobes, desks, bunk beds, dumpsters, generators and fuel tanks are each drawn as one picture across their tiles.

## Interface

- Removed the "Space" option from random maps; vacuum now follows the map type.
- Removed several hint texts (multiplayer, saves, deployment zones, UI scale). Loading a save now just says "Loaded *save name*".
- The main menu now displays version **0.11**.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.10...v0.11
