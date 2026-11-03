# SVGA2X

**Crisp 2x / 3x display for DOS (DOS/V) screens in VMware — a tiny TSR, no host tools needed.**

[日本語版 README](README.ja.md)

VMware shows a DOS guest's 640x480 screen as a small window, and its "stretch" option makes it
blurry. SVGA2X runs *inside* the DOS guest: it mirrors the VGA 640x480 16-colour screen to the
VMware SVGA II framebuffer at exactly 2x or 3x (each pixel becomes a 2x2 or 3x3 block), so the
window is two or three times the size and pixel-sharp. Because it lives in the guest, the VM behaves the same on any host.

It was written for Japanese DOS/V (whose text console is drawn in VGA graphics mode by
`JDISP.SYS`), but it works with anything that uses a 640-pixel-wide 16-colour planar VGA mode
(mode 12h and variants with 350–480 lines), and also with ordinary 80-column VGA **text modes**
(80x25 = 720x400 becomes 1440x800 or 2160x1200; 80x43, 80x50 etc. work too).

## Features

- Exact nearest-neighbour 2x (1280x960) or 3x (1920x1440) scaling, 32-bit colour (palette read
  from the VGA DAC)
- Follows the number of visible lines (e.g. DOS/V's 475 lines → 1280x950, 480 lines → 1280x960)
- 80-column text modes are re-drawn with the font currently loaded in the VGA (8- or 9-dot cells,
  line-drawing characters, blinking cursor, colours), so English DOS and text-mode programs are
  doubled as well
- Steps aside automatically for other modes (40-column text, 320x200, 640x200, 256 colours) and
  VESA (VBE) modes, and comes back when a supported mode returns
- Only changed lines are redrawn
- Works in real mode (HIMEM only) **and** under V86 memory managers (MS EMM386, JemmEx)
- About 20 KB resident; can be removed with `/U`

## Requirements

- VMware Workstation / Player (virtual SVGA II adapter, PCI 15AD:0405)
- 386 or later (always true in VMware), DOS 3.3+
- For V86 mode: the memory manager must allow `INT 15h AH=87h` copies to the framebuffer
  (MS EMM386 and JemmEx do by default; JemmEx with `NOCHECK` does not)

## Usage

```
SVGA2X          install (resident), 2x
SVGA2X /S3      install, 3x (1920x1440; needs a host screen of that size)
SVGA2X /U       remove
SVGA2X /Rn      update every n timer ticks (n = 1..9, default 1 = 18.2 times/s)
SVGA2X /?       help
```

Put it in `AUTOEXEC.BAT` after the display driver (e.g. after DOS/V's `CHEV JP`/`JDISP.SYS` are
active). Leave VMware's "Stretch guest" off; the window will become 1280x950/960. If the window is
larger than the guest screen, VMware centres it.

### Fitting the screen on the host

The output is only pixel-sharp when VMware shows it 1:1:

- **Full screen** (Ctrl+Alt+Enter) is the best choice when the host screen is large enough
  (2x on a 1920x1080 monitor: the 1280x950 image is shown 1:1 and centred).
- In a **window** on a 1080p monitor the menu, toolbar, tabs and status bar leave only about
  930 lines, so the bottom of a 950/960-line image is cut off. Hide the toolbar/tabs/status bar
  (View > Customize) to make room.
- **"Stretch guest" on** makes everything fit, but VMware then scales the image (e.g. to about
  97.5 % in a 1080p window) with interpolation, so edges get slightly soft (measured: about 3 % of
  the pixels in intermediate greys instead of 3 pure colours). Fine if you prefer seeing the whole
  screen, but not pixel-sharp.
- 3x (1920x1440) needs a 2560x1440 or larger host screen.

Before installing, SVGA2X checks that the VM allows the resolution (`SVGA_REG_MAX_WIDTH/HEIGHT`
and VRAM size). If a `.vmx` limits the display, e.g. `svga.maxWidth = "640"`, SVGA2X refuses with
a message; remove or raise `svga.maxWidth`, `svga.maxHeight` (and `svga.vramSize` if set).

## Building

[NASM](https://www.nasm.us/) 2.x or 3.x:

```
nasm -f bin -o SVGA2X.COM src/svga2x.asm
```

or run `build.bat` (Windows) / `make`.

## Tested with

| Environment | Result |
|---|---|
| VMware Workstation 26.0.1, MS-DOS 6.2/V (Japanese), HIMEM only | OK |
| same, MS EMM386 4.95 | OK (via INT 15h AH=87h) |
| same, JemmEx 5.86 (`I=TEST SPLIT NOINVLPG`) | OK (via INT 15h AH=87h) |

Host CPU use of the idle VM (one core = 100 %): 3.4 % without SVGA2X, about 8–11 % with it (5–6 % with `/R2`), about the same at 3x.
See [docs/TESTING.md](docs/TESTING.md) for the full test record and [docs/TECHNICAL.md](docs/TECHNICAL.md) for how it works.

## Limitations / known issues

- VMware only (uses the SVGA II register interface directly). VirtualBox's VMSVGA adapter
  and QEMU's `-vga vmware` emulate the same device but have not been tested.
- Full-screen scrolling under a V86 memory manager is CPU-heavy (one `INT 15h` call per output
  line). A JemmEx JLM back-end is a possible future improvement.
- Programs that program the DAC directly through ports (not via INT 10h) may show wrong colours
  until the next mode set.
- Text modes: blinking characters are shown without blinking; 512-character fonts use font map A
  only; a font loaded directly through the VGA ports (not via INT 10h AH=11h) is picked up at the
  next mode set; 40-column modes are not doubled.
- Windows 3.x enhanced mode / DOS boxes: SVGA2X pauses itself when the CPU is in protected mode
  and it was installed in real mode.

## License

MIT — see [LICENSE](LICENSE).
