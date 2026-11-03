# SVGA2X

**Crisp 2x display for DOS (DOS/V) screens in VMware — a tiny TSR, no host tools needed.**

[日本語版 README](README.ja.md)

VMware shows a DOS guest's 640x480 screen as a small window, and its "stretch" option makes it
blurry. SVGA2X runs *inside* the DOS guest: it mirrors the VGA 640x480 16-colour screen to the
VMware SVGA II framebuffer at exactly 2x (each pixel becomes a 2x2 block), so the window is twice
the size and pixel-sharp. Because it lives in the guest, the VM behaves the same on any host.

It was written for Japanese DOS/V (whose text console is drawn in VGA graphics mode by
`JDISP.SYS`), but it works with anything that uses a 640-pixel-wide 16-colour planar VGA mode
(mode 12h and variants with 350–480 lines).

## Features

- Exact nearest-neighbour 2x scaling, 32-bit colour (palette read from the VGA DAC)
- Follows the number of visible lines (e.g. DOS/V's 475 lines → 1280x950, 480 lines → 1280x960)
- Steps aside automatically for text modes, other graphics modes and VESA (VBE) modes, and comes
  back when the 640-wide planar mode returns
- Only changed lines are redrawn
- Works in real mode (HIMEM only) **and** under V86 memory managers (MS EMM386, JemmEx)
- About 11 KB resident; can be removed with `/U`

## Requirements

- VMware Workstation / Player (virtual SVGA II adapter, PCI 15AD:0405)
- 386 or later (always true in VMware), DOS 3.3+
- For V86 mode: the memory manager must allow `INT 15h AH=87h` copies to the framebuffer
  (MS EMM386 and JemmEx do by default; JemmEx with `NOCHECK` does not)

## Usage

```
SVGA2X          install (resident)
SVGA2X /U       remove
SVGA2X /Rn      update every n timer ticks (n = 1..9, default 1 = 18.2 times/s)
SVGA2X /?       help
```

Put it in `AUTOEXEC.BAT` after the display driver (e.g. after DOS/V's `CHEV JP`/`JDISP.SYS` are
active). Leave VMware's "Stretch guest" off; the window will become 1280x950/960. If the window is
larger than the guest screen, VMware centres it.

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

Host CPU use of the idle VM (one core = 100 %): 3.4 % without SVGA2X, about 8–11 % with it.
See [docs/TECHNICAL.md](docs/TECHNICAL.md) for details and measurements.

## Limitations / known issues

- VMware only (uses the SVGA II register interface directly). VirtualBox's VMSVGA adapter
  and QEMU's `-vga vmware` emulate the same device but have not been tested.
- Full-screen scrolling under a V86 memory manager is CPU-heavy (one `INT 15h` call per output
  line). A JemmEx JLM back-end is a possible future improvement.
- Programs that program the DAC directly through ports (not via INT 10h) may show wrong colours
  until the next mode set.
- Windows 3.x enhanced mode / DOS boxes: SVGA2X pauses itself when the CPU is in protected mode
  and it was installed in real mode.

## License

MIT — see [LICENSE](LICENSE).
