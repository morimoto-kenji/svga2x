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
SVGA_REG_WIDTH    <- 1280
SVGA_REG_HEIGHT   <- 2 * visible lines
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
| CRTC 0Ch/0Dh | start address (added to the source offset) |

If the check fails, SVGA is disabled so the normal VGA picture (text mode etc.) is shown.

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
  enabled. Skipped while INT 10h is running or a pass is still active.
- **INT 10h**: before AH=00h (set mode) or AX=4F02h (VBE set mode), SVGA is disabled. After a
  VBE mode >= 100h SVGA2X stays suspended until the next set-mode. After AH=00h / AH=10h the
  palette is re-read (via the old INT 10h vector).
- **INT 2Fh** AX=E700h: install check (AL=FFh, BX='2X', ES=resident segment).

## Measurements (VMware Workstation 26.0.1, host CPU of the VM process, one core = 100 %)

| Configuration | idle | `dir` scrolling |
|---|---|---|
| no SVGA2X | 3.4 % | – |
| real mode, per-line reads | 19.4 % | – |
| real mode, 8-line chunks | 8.9 % | – |
| MS EMM386 4.95 (INT 15h/87h) | 10.6 % | 54 % |
| JemmEx 5.86 (INT 15h/87h) | 8.1 % | 71 % |

## Ideas for the future

- JemmEx JLM back-end: map the FB into Jemm's linear address space (`_PageReserve`,
  `_PageCommitPhys`) and copy from ring 0 — removes the per-line INT 15h cost.
- Integer factors other than 2 (e.g. 3x for 4K hosts).
- Text mode support (render the 720x400 text screen with the VGA font).
- VCPI back-end for other memory managers.
