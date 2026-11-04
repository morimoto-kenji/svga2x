# Changelog

## 0.4.1 (2026-11-04)

- With `/Rn` (n > 1), the screen is redrawn at the next timer tick after any INT 10h call (text
  output, cursor moves), so the cursor no longer jumps in file managers such as FD; only an
  unchanging screen is redrawn every n ticks. Idle CPU use is unchanged (KTBBS waiting screen with
  `/R2`: about 6 %).

## 0.4.0 (2026-11-04)

- Changed: `SVGA2X` without options now shows the status (resident or not, scale, update rate,
  and whether the screen is shown at 2x/3x, in the normal display, or dormant after Windows).
  Installing needs `/S2` or `/S3`; `/Rn` is accepted only together with one of them.
- Messages say "resident" instead of "installed"; the install message is just "Now resident.";
  every run shows the author and contact address.
- Author and contact address in the source, LICENSE and README.

## 0.3.1 (not released separately; included in 0.4.0)

- Fix: during endless text output (e.g. `DIR` in a batch loop) the 2x picture froze for tens of
  seconds, because almost every timer tick arrived while INT 10h was running and the pass was
  skipped. A skipped pass is now done at the end of the INT 10h call.
- Fix: INT 10h calls returned CF=1 (and other flags) left over from SVGA2X's own compare instead of
  the caller's flags, whenever the BIOS function returns with IRET. QBASIC `PALETTE` without
  arguments failed with "Illegal function call". The BIOS is now called with the caller's flags.
- Fix: the resident part kept the standard handles open, so each `SVGA2X > NUL` used up one
  DOS file table entry for good; after enough installs, redirection and pipes failed ("Cannot
  execute FIND.EXE"). The handles are now closed before going resident.
- DOS/V with JDISP.SYS hardware scrolling (the default without `/HS=OFF`) is now doubled: VGA
  graphics with a line stride other than 80 bytes (CRTC 13h, here 128) and the CRTC line compare
  wrap are followed. Before, such a screen was treated as unsupported and left at 1x.
- Windows 3.x: SVGA2X steps aside for good when Windows starts (INT 2Fh 1605h). With MS EMM386,
  framebuffer copies above the first 4 MB after Windows had run triple-faulted the VM.
- INT 15h AH=87h: the descriptor table is rebuilt for every call (the BIOS / memory manager
  writes into it).
- The install message points to `/?` instead of listing only `/R`; messages fit in 80 columns.
- README: VMware applies `svga.maxWidth` / `svga.maxHeight` only with `svga.autodetect = "FALSE"`.

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
