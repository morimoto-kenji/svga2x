# Changelog

## 0.3.1 (unreleased)

- Fix: during endless text output (e.g. `DIR` in a batch loop) the 2x picture froze for tens of
  seconds, because almost every timer tick arrived while INT 10h was running and the pass was
  skipped. A skipped pass is now done at the end of the INT 10h call.
- Fix: INT 10h calls returned CF=1 (and other flags) left over from SVGA2X's own compare instead of
  the caller's flags, whenever the BIOS function returns with IRET. QBASIC `PALETTE` without
  arguments failed with "Illegal function call". The BIOS is now called with the caller's flags.
- Fix: the resident part kept the standard handles open, so each `SVGA2X > NUL` used up one
  DOS file table entry for good; after enough installs, redirection and pipes failed ("Cannot
  execute FIND.EXE"). The handles are now closed before going resident.
- The install message points to `/?` instead of listing only `/R`.

## 0.3.0 (unreleased)

- 80-column VGA text modes are doubled/tripled too (80x25 → 1440x800 / 2160x1200, 80x43, 80x50,
  350-line 80x25): re-drawn from the text buffer with the font read from VGA plane 2, 8/9-dot cells,
  line-drawing characters, blinking cursor, blink/intensity attribute.
- The font is re-read after INT 10h AH=00h / AH=11h.  Resident part about 20 KB.

## 0.2.0 (unreleased)

- `/S2` (default) and `/S3` scale factor; 3x = 1920x1440 (1920x1425 for DOS/V's 475 lines).
- Check the VM's maximum resolution and VRAM size before installing, with a hint about
  `svga.maxWidth` / `svga.maxHeight` / `svga.vramSize`.
- V86 write test now uses the last page of VRAM (works with VMs that have less than 16 MB).
- Fixes: INT 10h callers left with interrupts disabled; 640x200 double-scan modes shown as garbage
  after a 2x mode; VESA programs got a black screen; 2x not restored after a VESA program under
  DOS/V (non-re-entrant INT 10h hook). Modes with CRTC double scan are no longer accepted.

## 0.1.0 (unreleased)

- First version: 2x mirror of VGA 640x(350..480)x16 planar modes to VMware SVGA II at 32 bpp.
- Real mode (unreal mode) and V86 mode (INT 15h AH=87h, verified before installing).
- INT 10h tracking of mode sets, VBE modes and palette changes; `/U` uninstall, `/Rn` update rate.
