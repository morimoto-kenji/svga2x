# SVGA2X technical notes

## Idea

The VMware SVGA II device has two independent display paths:

- the legacy VGA (memory at A0000h, VGA registers), and
- its own linear framebuffer (FB, BAR1, e.g. `E8000000h`), enabled with `SVGA_REG_ENABLE`.

When SVGA mode is enabled, the *displayed* image comes from the FB, but VGA memory and VGA
registers keep working. A DOS/V display driver therefore continues to draw into the VGA planes
without noticing anything. SVGA2X periodically converts those planes into the FB at 2x.

This was verified empirically on VMware Workstation 26.0.1 (virtual hardware 19).

## Mode setting

```
SVGA_REG_ID       <- 0x90000002 (SVGA_ID_2), read back to confirm
SVGA_REG_WIDTH    <- 640 * scale          (scale = 2 or 3, /S option)
SVGA_REG_HEIGHT   <- scale * visible lines
SVGA_REG_BPP      <- 32
SVGA_REG_ENABLE   <- 1
pitch  = SVGA_REG_BYTES_PER_LINE
base   = SVGA_REG_FB_START + SVGA_REG_FB_OFFSET
```

`SVGA_REG_ENABLE <- 0` returns to the VGA display unchanged. No FIFO / update commands are used;
VMware picks up FB writes by itself in this legacy mode.

### Why 32 bpp and not 8 bpp

With 8 bpp the palette registers (index 1024+) can be written, but the displayed colours were
replaced by the raw 6-bit VGA DAC values shortly afterwards (e.g. `2A2A2A` instead of `AAAAAA`).
Writes to the VGA DAC seem to be mirrored into the SVGA palette. 32 bpp avoids the palette
completely; SVGA2X converts colour indices itself (attribute palette → DAC → 8-bit RGB).

## Detecting the VGA mode

Every pass reads (with interrupts disabled, indices saved/restored):

| Register | Condition |
|---|---|
| Misc output (3CCh) bit 0 | colour addressing (3Dx) |
| GC 6 | graphics mode, memory map A000h/64K |
| GC 5 bit 6 | not 256-colour shift mode |
| CRTC 01h | 4Fh (640 pixels) |
| CRTC 12h + overflow (07h bits 1,6) | visible lines 350..480 |
| CRTC 13h | 28h (80 bytes per line) |
| CRTC 09h & 9Fh | 0 (no double scan, one scan line per row) |
| CRTC 0Ch/0Dh | start address (added to the source offset) |

If the check fails, SVGA is disabled so the normal VGA picture (text mode etc.) is shown.

## Text modes

80-column colour text modes (GC 6 = alphanumeric at B800h, CRTC 01h = 4Fh, no half dot clock,
no double scan, cells 8..16 lines high) are re-drawn by SVGA2X itself:

- Characters/attributes are read from B800h (start address CRTC 0Ch/0Dh, row stride = CRTC 13h * 4).
- The font is copied from VGA plane 2 into a 4 KB cache (256 characters x 16 lines), using the same
  register setup as the BIOS (sequencer 2/4, GC 4/5/6), with interrupts off and every register
  restored.  Font map A is taken from sequencer register 3.  The cache is refreshed on entering a
  text mode and after INT 10h AH=00h / AH=11h.
- Cell width 8 or 9 (sequencer 1 bit 0).  In 9-dot mode the 9th column repeats column 8 for
  C0h..DFh (line-drawing characters), otherwise it is background (VGA line graphics enabled, the
  BIOS default).
- Background uses 8 colours when blinking is enabled (BIOS mode-select shadow 40:65h bit 5).
  Blinking characters are drawn without blinking.
- Cursor: CRTC 0Ah/0Bh (shape, bit 5 = off) and 0Eh/0Fh (position), blinking with bit 3 of the
  BIOS tick counter.
- Change detection is per text row (hash of the 160 bytes plus cursor state).

## Reading VGA memory safely from an interrupt

The resident part interrupts arbitrary foreground code, possibly in the middle of a VGA drawing
sequence. Around each read it:

1. saves the sequencer index and map mask, the GC index, GC 4 (read map) and GC 5 (mode);
2. sets map mask = 0Fh, GC 5 = read mode 0 / write mode 1, and writes one byte to `A000:FFFF`
   — in write mode 1 this stores the **foreground's latches** off-screen;
3. reads the planes (GC 4 = 0..3);
4. reads `A000:FFFF` to reload the foreground's latches;
5. restores all registers.

Reads are done in chunks of 8 lines to reduce the number of port accesses (port I/O is what
dominates the cost under VMware: per-line register handling cost 19.4 % host CPU at idle,
8-line chunks 8.9 %).

## Writing the framebuffer

- **Real mode**: "unreal mode" — enter protected mode briefly, load ES with a 4 GB data
  descriptor, return to real mode. ES keeps the 4 GB limit; `a32 rep movsd` copies each line.
  Re-established every pass (some programs reset segment limits).
- **V86 mode** (EMM386, JemmEx, ...): `INT 15h AH=87h` (block move), one call per output line
  (5120 bytes). Before installing, SVGA2X checks that this really reaches the FB:
  1. read 32 bytes from `FB` and from `FB & 00FFFFFFh` — if they are identical, the memory manager
     ignores the high address byte, and a write would hit low memory (`E8000000h & 00FFFFFFh = 0`
     = the interrupt vector table!) → refuse;
  2. write a pattern to `FB + 15 MB` (off-screen), read it back, compare.

## Interrupt hooks

- **INT 08h**: chains to the old handler first (so the EOI is sent), then works with interrupts
  enabled. Skipped while a pass is still active. If INT 10h is running when a pass is due, the pass
  is left to the end of that INT 10h instead: the INT 10h hook runs it on the way out of the
  outermost call (when the caller had interrupts enabled). Without this, endless text output such
  as `DIR` in a loop is inside INT 10h at almost every tick and the 2x picture froze for tens of
  seconds at a time (found by the long-running test, fixed in 0.3.1). A pass is due every `/Rn`
  ticks, or at the next tick after any INT 10h call (0.4.1): with `/R2` a moving cursor was only
  caught 9 times a second and seemed to jump, while an unchanging screen does not need more.
- **INT 10h**: after AH=00h (set mode) SVGA is disabled (doing it *before* the BIOS mode set made
  VMware show 640x200 double-scan modes as garbage). For AX=4F02h (VBE set mode) SVGA2X only
  forgets that it owns the SVGA and lets the VBE BIOS take it over (writing ENABLE=0 first made the
  VBE BIOS fail). After a VBE mode >= 100h SVGA2X stays suspended until the next set-mode. After
  AH=00h and after the AH=10h subfunctions that can change it the palette is re-read; the read-only
  ones (AL = 07h, 08h, 09h, 15h, 17h, 1Ah) are skipped. Since 0.4.2 the palette is read through the
  ports (attribute controller 3C0h/3C1h, DAC 3C7h/3C9h) instead of INT 10h AX=1007h/1015h: VMware's
  VGA BIOS takes about one frame (16 ms) per call, so one re-read (32 calls) took half a second,
  and DOSSHELL, which calls AH=10h about 30 times while starting, needed 16 s instead of 3. The
  palette registers can only be read with PAS (bit 5 of the attribute index) = 0, which blanks the
  VGA output; all 16 are read in one go with interrupts off and PAS is set again at once (with
  PAS = 1 all 16 read back as the same value and the 2x picture was blank). The old handler is called
  with the caller's flags (IF/TF cleared): most BIOS functions return with IRET, so the flags the
  caller gets back are the ones pushed for the call. (0.3.0 and earlier pushed the flags left by
  its own CMP, so callers got CF=1 back and QBASIC's `PALETTE` without arguments failed.)
  The caller's AX/BX are kept on the stack because INT 10h is re-entered (DOS/V's JDISP calls
  INT 10h while handling a mode set), and the BIOS result flags are returned with the caller's
  IF/TF (the BIOS is called with IF=0).
- **INT 2Fh** AX=E700h: install check (AL=FFh, BX='2X', ES=resident segment).

## Measurements (VMware Workstation 26.0.1, host CPU of the VM process, one core = 100 %)

| Configuration | idle | `dir` scrolling |
|---|---|---|
| no SVGA2X | 3.4 % | – |
| real mode, per-line reads | 19.4 % | – |
| real mode, 8-line chunks | 8.9 % | – |
| MS EMM386 4.95 (INT 15h/87h) | 10.6 % | 54 % |
| JemmEx 5.86 (INT 15h/87h) | 8.1 % | 71 % |
| MS EMM386 4.95, `/R2` | 6.2 % | – |
| JemmEx 5.86, `/R2` | 4.7 % | – |

## Ideas for the future

- JemmEx JLM back-end: map the FB into Jemm's linear address space (`_PageReserve`,
  `_PageCommitPhys`) and copy from ring 0 — removes the per-line INT 15h cost.
- VCPI back-end for other memory managers.
