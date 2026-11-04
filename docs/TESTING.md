# Test record

Environment: VMware Workstation 26.0.1 (virtual hardware 19), MS-DOS 6.2/V (Japanese), JDISP.SYS
`/HS=OFF`, POWER.EXE. Three CONFIG.SYS variants: HIMEM only (real mode), MS EMM386 4.95, JemmEx
5.86 (`I=TEST SPLIT NOINVLPG`).

Screens were captured through VMware's VNC server and checked by a script: every 2x2 block of the
output must be uniform, and for the latch test the 2x output, sampled at (2x, 2y), must be
identical to a 1x capture taken without SVGA2X.

QBASIC programs are in [`tests/`](../tests). QBASIC refuses to run in DOS/V Japanese mode, so they
are run after `CHEV US`.

| # | Test | Real mode | EMM386 | JemmEx |
|---|---|---|---|---|
| 1 | Ctrl+Alt+Del while installed and active: BIOS/boot menu shown normally | OK | OK | OK |
| 2 | `LATCH.BAS` (4000 random read-modify-write draws, PAINT, XOR PUT) while SVGA2X runs: VGA contents identical to a run without SVGA2X (307,200 pixels) | OK | OK | OK |
| 3 | `COLORS.BAS`: 16 standard colours exact; `PALETTE` changes followed | OK | OK | OK |
| 4 | `MODES.BAS`: SCREEN 9 → 1280x700, SCREEN 8 (640x200 double scan) and SCREEN 13 → left alone, SCREEN 12 → 1280x960, back to text | OK | OK | OK |
| 4b | `S8B.BAS`: SCREEN 12 → SCREEN 8 shows correctly | OK | – | – |
| 5 | MJL 1.08 (VESA 1024x768x8 image viewer), twice in a row: VESA picture shown, 2x restored after exit | OK | OK | OK |
| 6 | DSP4A `/LG0 /E` (DOS/V 80x30, 480 lines) → 1280x960 | OK | – | OK |
| 7 | `CHEV US` / `CHEV JP` (text mode ↔ DOS/V) | OK | OK | OK |
| 8 | `/U` (memory freed, plain VGA back); refused if a later TSR hooked the same vectors | OK | OK | OK |
| 9 | `/?`, second install refused | OK | – | OK |
| 10 | `/S3` (1920x1425): `LATCH.BAS` identical, every 3x3 block uniform; MJL and return to 3x | OK | – | OK |
| 11 | `/S1`, `/S4` rejected; 2x regression (`LATCH.BAS`, `COLORS.BAS`) after the `/S` change | OK | – | OK |
| 12 | Host display: full screen on a 1920x1080 host shows the 1280x950 image 1:1 and centred (all 1,216,000 pixels identical to the guest framebuffer); window without stretch: pure colours, bottom cut off (~930 lines available); window with "Stretch guest": fits, but ~3 % of the pixels are interpolated greys | OK | – | – |
| 12b | Host display, text mode: full screen on a 1920x1080 host shows the 1440x800 text picture 1:1 and centred at (240,140) (all 1,152,000 pixels identical to the guest framebuffer) | – | – | OK |
| 13 | Text mode 80x25 (QBASIC IDE: colours, line drawing, 9th column, scroll bars) at 2x: identical to the 720x400 picture without SVGA2X except the blinking cursor (which alternates 0 / 18 differing pixels as it blinks) | OK | – | OK |
| 14 | `MODE CON LINES=50` (8x8 font), `LINES=43` (350 lines, 8-dot cells), `MODE CO80` after it (350-line 80x25), `LINES=25`: identical except the cursor; `MODE CO40` left alone | OK | – | – |
| 15 | Text at 3x (2160x1200) identical except the cursor; `CHEV JP`/`CHEV US` switching between DOS/V 3x and text 3x | OK | – | – |
| 16 | Regression after adding text mode: LATCH, COLORS, MODES, S8B, MJL | OK | – | OK (LATCH) |
| 17 | Long run, 60 min: `SCROLL.BAT` (endless `DIR` in DOS/V) with a capture every 30 s (118 captures): every 2x2 block uniform, picture keeps changing, DOS clock within 1 s of the host, no memory loss | – | – | OK (0.3.1) |
| 18 | Long run, 60 min: `STRESS.BAS` (SCREEN 12 drawing, `PALETTE` changes and reset, coloured text output, SCREEN 9, 80x50 text, in a loop; 116 captures): every block uniform, no errors, clock within 1 s | – | – | OK (0.3.1) |
| 19 | Speed of endless output: 30 × `DIR C:\DOS /W` takes 20.8 s with SVGA2X (about 17.4 s without), and the 2x picture is updated throughout | – | – | OK (0.3.1) |
| 20 | 20 rounds of `/U`, `CHEV US`, install, `/U`, `/S3`, `CHEV JP`, `/U`, install (output redirected to NUL): ends in DOS/V 2x, resident size and total free memory unchanged, pipes still work | – | – | OK (0.3.1) |
| 21 | `.vmx` with `svga.maxWidth = "640"`, `svga.maxHeight = "480"`: without `svga.autodetect = "FALSE"` VMware ignores them (log: max 2360x1773) and SVGA2X works; with it, `SVGA2X` and `SVGA2X /S3` refuse with the message and stay out of memory | – | – | OK (0.3.1) |
| 22 | Win3.1 VM (MS-DOS 6.2/V + Windows 3.1J, MS EMM386, JDISP.SYS **with** hardware scroll: CRTC 13h = 40h, line compare 453): 2x after the stride / line-compare support; 2x capture vs 1x capture after `/U` (shifted by the two rows printed in between): 0 differing pixels of 255,360 | – | OK | – |
| 23 | Windows 3.1 enhanced mode started and exited 3 times with SVGA2X resident: no crash, Windows at its normal 640x480, DOS at 1x afterwards, `/U` still works | – | OK | – |
| 24 | MS-DOS Shell (DOSSHELL from the MS-DOS 6.2 Supplemental Disk): text mode → 1440x800, graphics mode (30 lines, 640x480) → 1280x960, also under DOS/V Japanese mode; back to the prompt normally | – | – | OK |
| 25 | Options of 0.4.0: no options → status ("Not resident." / "Display:  1280x950 (VGA graphics)." / "Display:  1440x800 (text).", with "Resident: 2x, update every 2 ticks."); `/R2` alone refused; `/S2 /R2` and `/S2` install; `/S3` while resident refused; `/S4` refused; `/?`; `/U` removes a 0.3.1 copy | – | OK (0.4.0) | – |
| 26 | 0.4.1 with `/S2 /R2`: idle CPU at the DOS prompt 7.1–7.3 % (0.4.0: 6.3–7.2 %); KTBBS waiting screen 5.9–6.3 % (0.4.0: 5.0–6.4 %), line response unchanged; cursor in FD follows smoothly (checked by the user) | – | OK (0.4.1) | – |

Bugs found and fixed by these tests:

- INT 10h callers were left with interrupts disabled (QBASIC `PALETTE` hung the machine).
- SCREEN 8 garbage after leaving a 2x mode (SVGA was turned off before the BIOS mode set).
- VESA programs got a black screen (SVGA was turned off before the VBE mode set).
- 2x not restored after a VESA program under DOS/V (non-re-entrant INT 10h hook).
- (test 17) Endless text output froze the 2x picture for tens of seconds under JemmEx: almost every
  timer tick arrived while INT 10h was running, and the pass was skipped. Fixed in 0.3.1 (the pass
  is done at the end of that INT 10h).
- (test 18) QBASIC `PALETTE` without arguments failed with "Illegal function call": the INT 10h hook
  called the BIOS with its own flags, so callers got CF=1 back. Fixed in 0.3.1.
- (test 20) After repeated `SVGA2X > NUL`, pipes failed ("Cannot execute FIND.EXE"): the resident
  part kept its standard handles open, leaking one DOS file table entry per install. Fixed in
  0.3.1 (handles closed before going resident).
- (test 22) DOS/V with hardware scrolling (JDISP.SYS without `/HS=OFF`) was never doubled: only a
  line stride of 80 bytes was accepted. Fixed in 0.3.1.
- (test 23) With MS EMM386, after Windows 3.1 had been started and exited, the next INT 15h AH=87h
  copy above the first 4 MB of the framebuffer triple-faulted the VM (found with read-only and
  step-by-step diagnostics: the setup, a one-line copy at line 0 or 818 and reads were fine, a
  copy at line 820 crashed). Doubling Windows' own screen worked, and pausing during Windows was
  not enough (the second start/exit still crashed). SVGA2X now steps aside for good when Windows
  starts.

## Host CPU (VM process, one core = 100 %, DOS prompt idle)

| | no SVGA2X | default (18.2 Hz) | `/R2` |
|---|---|---|---|
| Real mode | 3.4 % | 8.9 % | – |
| MS EMM386 | – | 10.6 % | 6.2 % |
| JemmEx | – | 8.1 % | 4.7 % |
| Real mode, `/S3` | – | 8.3 % | – |
| JemmEx, `/S3` | – | 7.5 % | – |
| JemmEx, text mode (80x25) | – | 2.3 % | – |

Full-screen scrolling (`dir`) under V86 managers: 54 % (EMM386) / 71 % (JemmEx) at 2x, 61 % (JemmEx) at 3x.

## Not tested yet

- Runs longer than one hour; serial communication programs running at the same time
- DOS extenders (DOS/4GW, DJGPP); Windows 3.1 with JemmEx; the 4 MB crash with JemmEx
- VirtualBox VMSVGA, QEMU `-vga vmware`, other VMware versions
