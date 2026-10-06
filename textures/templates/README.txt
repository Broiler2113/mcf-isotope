MCF TACTICS -- TEXTURE TEMPLATES

One file per object: <name>_atlas.png, 128 x 160 pixels (tile side 32).

  rows 0..3  the 16 autotile tiles. Index = N*1 + E*2 + S*4 + W*8,
             column = index % 4, row = index / 4:
               row 0:  0 alone    1 N        2 E        3 N+E
               row 1:  4 S        5 N+S      6 E+S      7 N+E+S
               row 2:  8 W        9 N+W     10 E+W     11 N+E+W
               row 3: 12 S+W     13 N+S+W   14 E+S+W   15 all four
  row 4      the four facings of the single sprite: up, right, down, left.
             Furniture is drawn with its back UP; the game turns it to the wall,
             but a facing drawn here is used as it is, without rotating.

Repaint the cells you care about, keep the size, and drop the file into
user://textures with the SAME name. An atlas replaces both <name>.png and
<name>_autotile.png for that object; empty cells in it stay empty.

These files are source material, not game data: the game never reads this folder.
