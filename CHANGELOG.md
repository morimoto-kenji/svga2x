# Changelog

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
