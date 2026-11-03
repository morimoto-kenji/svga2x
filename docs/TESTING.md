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

Bugs found and fixed by these tests:

- INT 10h callers were left with interrupts disabled (QBASIC `PALETTE` hung the machine).
- SCREEN 8 garbage after leaving a 2x mode (SVGA was turned off before the BIOS mode set).
- VESA programs got a black screen (SVGA was turned off before the VBE mode set).
- 2x not restored after a VESA program under DOS/V (non-re-entrant INT 10h hook).

## Host CPU (VM process, one core = 100 %, DOS prompt idle)

| | no SVGA2X | default (18.2 Hz) | `/R2` |
|---|---|---|---|
| Real mode | 3.4 % | 8.9 % | – |
| MS EMM386 | – | 10.6 % | 6.2 % |
| JemmEx | – | 8.1 % | 4.7 % |
| Real mode, `/S3` | – | 8.3 % | – |
| JemmEx, `/S3` | – | 7.5 % | – |

Full-screen scrolling (`dir`) under V86 managers: 54 % (EMM386) / 71 % (JemmEx) at 2x, 61 % (JemmEx) at 3x.

## Not tested yet

- The refusal message when the `.vmx` limits the resolution (`svga.maxWidth` etc.)
- Long-running stability (hours), serial communication programs running at the same time
- DOS extenders (DOS/4GW, DJGPP), Windows 3.1 enhanced mode
- VirtualBox VMSVGA, QEMU `-vga vmware`, other VMware versions
