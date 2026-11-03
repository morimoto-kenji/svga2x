' Endless stress loop for long-running tests: graphics drawing, text output, palette changes and
' mode switches.  Press any key to stop (checked between phases).
RANDOMIZE TIMER
cycle& = 0
DO
  cycle& = cycle& + 1
  ' --- SCREEN 12: random drawing for 20 s ---
  SCREEN 12
  t! = TIMER
  DO WHILE TIMER - t! < 20 AND TIMER >= t!
    x = INT(RND * 600): y = INT(RND * 440): c = INT(RND * 16)
    LINE (x, y)-(x + INT(RND * 40), y + INT(RND * 40)), c, BF
    CIRCLE (INT(RND * 640), INT(RND * 480)), INT(RND * 60) + 1, INT(RND * 16)
  LOOP
  LOCATE 1, 1: PRINT "cycle"; cycle&
  ' --- palette changes ---
  FOR i = 1 TO 15: PALETTE i, INT(RND * 64) + INT(RND * 64) * 256 + INT(RND * 64) * 65536: NEXT
  t! = TIMER: DO WHILE TIMER - t! < 3 AND TIMER >= t!: LOOP
  PALETTE
  IF INKEY$ <> "" THEN EXIT DO
  ' --- text mode: scrolling coloured output for 20 s ---
  SCREEN 0: WIDTH 80, 25
  t! = TIMER
  DO WHILE TIMER - t! < 20 AND TIMER >= t!
    COLOR INT(RND * 16), INT(RND * 8)
    PRINT "cycle"; cycle&; STRING$(INT(RND * 60), CHR$(176 + INT(RND * 48)))
  LOOP
  COLOR 7, 0
  IF INKEY$ <> "" THEN EXIT DO
  ' --- SCREEN 9 and 80x50 text briefly ---
  SCREEN 9: CIRCLE (320, 175), 150, 14
  t! = TIMER: DO WHILE TIMER - t! < 5 AND TIMER >= t!: LOOP
  SCREEN 0: WIDTH 80, 50
  FOR i = 1 TO 200: PRINT i; "80x50 text"; : NEXT
  t! = TIMER: DO WHILE TIMER - t! < 5 AND TIMER >= t!: LOOP
  WIDTH 80, 25
  IF INKEY$ <> "" THEN EXIT DO
LOOP
SCREEN 0: WIDTH 80, 25: COLOR 7, 0: CLS
PRINT "STRESS stopped after"; cycle&; "cycles"
SYSTEM
