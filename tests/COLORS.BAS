' 16-colour bars in SCREEN 12, then palette change via PALETTE
SCREEN 12
FOR i = 0 TO 15
  LINE (i * 40, 0)-(i * 40 + 39, 239), i, BF
NEXT
LOCATE 20, 1: PRINT "COLORS: press a key"
SLEEP
PALETTE 1, 63 * 65536
PALETTE 2, 63 * 256 + 63
LOCATE 21, 1: PRINT "PALETTE 1=red 2=yellow: press a key"
SLEEP
SCREEN 0
WIDTH 80
SYSTEM
