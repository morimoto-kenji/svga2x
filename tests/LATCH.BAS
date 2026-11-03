' Deterministic heavy drawing (read-modify-write, PAINT, XOR PUT) to test latch safety
SCREEN 12
RANDOMIZE 12345
DIM spr%(2000)
CIRCLE (20, 20), 18, 14: PAINT (20, 20), 4, 14
GET (0, 0)-(40, 40), spr%
FOR n = 1 TO 4000
  x = INT(RND * 600): y = INT(RND * 440): c = INT(RND * 16)
  SELECT CASE n MOD 5
  CASE 0: LINE (x, y)-(x + INT(RND * 40), y + INT(RND * 40)), c, BF
  CASE 1: CIRCLE (x + 20, y + 20), INT(RND * 20) + 1, c
  CASE 2: PSET (x, y), c: PSET (x + 1, y), c XOR 15
  CASE 3: PUT (x, y), spr%, XOR
  CASE 4: LINE (x, y)-(INT(RND * 640), INT(RND * 480)), c
  END SELECT
NEXT
LOCATE 30, 1: PRINT "DONE";
SLEEP
SCREEN 0
WIDTH 80
SYSTEM
