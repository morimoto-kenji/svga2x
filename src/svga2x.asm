; SVGA2X - show a DOS/V (VGA 640x480 16-colour planar) screen at 2x on VMware SVGA II
;
; Copyright (c) 2026 Kenji Morimoto
; SPDX-License-Identifier: MIT
;
; Build:  nasm -f bin -o SVGA2X.COM svga2x.asm
;
; How it works
;   * The DOS/V display driver (JDISP.SYS etc.) keeps drawing into the normal VGA planes at A000h.
;   * VMware SVGA II can show its own linear framebuffer (FB, e.g. E8000000h) instead of the VGA
;     screen, while VGA memory and VGA registers keep working underneath.
;   * Every timer tick (INT 08h) the resident part reads the 4 VGA planes, converts each line to
;     32-bit pixels, doubles it horizontally and vertically (nearest neighbour), and writes it to
;     the FB.  Only lines whose contents changed are written (per-line hash).
;   * FB writes: real mode -> "unreal mode" (ES with a 4 GB limit);
;                V86 mode (EMM386, JEMMEX, ...) -> INT 15h AH=87h block move.
;   * INT 10h is hooked so that BIOS mode sets / VBE modes make SVGA2X step aside.
;   * The VGA latches, sequencer map mask and graphics-controller state are saved/restored around
;     every plane read, so foreground drawing is not disturbed.

        cpu     386
        bits    16
        org     100h

CH_LINES  equ   8                       ; lines read from VGA per chunk
CHUNKSZ   equ   CH_LINES*80             ; bytes per plane per chunk
MAXLINES  equ   480                     ; also the max number of hash entries (lines or text rows)
MAXSCALE  equ   3

; VMware SVGA II registers (index/value port pair at BAR0)
SVGA_REG_ID             equ 0
SVGA_REG_ENABLE         equ 1
SVGA_REG_WIDTH          equ 2
SVGA_REG_HEIGHT         equ 3
SVGA_REG_MAX_WIDTH      equ 4
SVGA_REG_MAX_HEIGHT     equ 5
SVGA_REG_BITS_PER_PIXEL equ 7
SVGA_REG_BYTES_PER_LINE equ 12
SVGA_REG_FB_START       equ 13
SVGA_REG_FB_OFFSET      equ 14
SVGA_REG_VRAM_SIZE      equ 15
SVGA_ID_2               equ 90000002h

MUX_FUNC  equ   0E700h                  ; INT 2Fh install check: AX=E700h -> AL=FFh, BX='2X', ES=seg
MUX_SIG   equ   5832h                   ; '2X'

%macro SVGA_OUT 2                       ; SVGA_OUT reg, value
        mov     ax, %1
        mov     ebx, %2
        call    svga_out
%endmacro
%macro SVGA_IN 1                        ; EAX = SVGA register
        mov     ax, %1
        call    svga_in
%endmacro
%macro PRINT 1
        mov     dx, %1
        mov     ah, 09h
        int     21h
%endmacro
%macro LINADDR 1                        ; EAX = CS*16 + %1
        xor     eax, eax
        mov     ax, cs
        shl     eax, 4
        add     eax, strict dword %1
%endmacro
%macro RDREG 2                          ; DX = index port; read register %1 into byte [%2]
        mov     al, %1
        out     dx, al
        inc     dx
        in      al, dx
        mov     [%2], al
        dec     dx
%endmacro

;==================================================================================================
; Resident part
;==================================================================================================
entry:  jmp     near init
signature db    'SVGA2X31'

;--------------------------------------------------------------------------------------------------
; INT 08h: chain first (EOI is sent by the BIOS), then do the work with interrupts enabled.
;--------------------------------------------------------------------------------------------------
int08:  pushf
        call    far [cs:old08]
        cmp     byte [cs:busy], 0
        jne     near .ret
        dec     byte [cs:cnt]
        jne     near .ret
        push    ax
        mov     al, [cs:rate]
        mov     [cs:cnt], al
        pop     ax
        cmp     byte [cs:in10], 0       ; never touch the hardware while INT 10h is running.  Leave
        je      short .run              ; the pass to the end of that INT 10h instead: text output
        mov     byte [cs:pend], 1       ; that never stops (DIR in a loop) is inside INT 10h at
        jmp     near .ret               ; almost every tick, and the display would starve.
.run:   mov     byte [cs:pend], 0
        mov     byte [cs:busy], 1
        sti
        pushad
        push    ds
        push    es
        push    cs
        pop     ds
        push    cs
        pop     es
        cld
        call    work
        pop     es
        pop     ds
        popad
        mov     byte [cs:busy], 0
.ret:   iret

;--------------------------------------------------------------------------------------------------
; INT 10h: turn SVGA off before a mode set, re-read the palette / track VBE modes afterwards.
;--------------------------------------------------------------------------------------------------
int10:  inc     byte [cs:in10]
%ifdef TRACE
        cmp     ah, 02h                 ; debug: log AX/BX of INT 10h calls (except text output)
        je      .notr
        cmp     ah, 03h
        je      .notr
        cmp     ah, 09h
        je      .notr
        cmp     ah, 0Eh
        je      .notr
        cmp     ah, 08h
        je      .notr
        push    si
        mov     si, [cs:trpos]
        mov     [cs:trbuf + si], ax
        mov     [cs:trbuf + si + 2], bx
        add     si, 4
        and     si, 1023
        mov     [cs:trpos], si
        pop     si
.notr:
%endif
        ; The caller's AX/BX are kept on the stack, not in variables: INT 10h is re-entered (e.g.
        ; DOS/V's JDISP calls INT 10h itself while handling a mode set), and a single variable
        ; would be overwritten by the nested call.
        push    bx
        push    ax
        cmp     ax, 4F02h               ; VBE set mode: let the VBE BIOS take the SVGA over as it is.
        jne     near .go                ; (Writing ENABLE=0 first made VMware's VBE BIOS fail: black
        mov     byte [cs:enabled], 0    ; screen.)  Just forget that we own it.
.go:    ; Call the BIOS with the caller's flags (IF/TF cleared, as INT does), not with whatever our own
        ; CMPs left: a BIOS function that returns with IRET and does not touch CF hands those flags
        ; back, and QBASIC's PALETTE (no arguments) failed with "Illegal function call" when it got
        ; CF=1 from the compare above.
        push    bp
        mov     bp, sp                  ; [bp+2] AX, [bp+4] BX, [bp+6] IP, [bp+8] CS, [bp+10] flags
        push    ax
        mov     ax, [bp + 10]
        and     ax, 0FCFFh
        mov     [cs:callfl], ax
        pop     ax
        pop     bp
        push    word [cs:callfl]
        popf
        push    word [cs:callfl]
        call    far [cs:old10]
        pushf                           ; keep the flags returned by the BIOS
        pushad
        push    ds
        push    es
        push    cs
        pop     ds
        push    cs
        pop     es
        cld
        mov     bp, sp                  ; [bp+38] caller AX, [bp+40] caller BX
        mov     ax, [bp + 38]
        cmp     ah, 0
        je      near .mode
        cmp     ax, 4F02h
        je      near .vbe
        cmp     ah, 11h                 ; character generator functions: re-read the font
        jne     short .nf
        mov     byte [fontdirty], 1
        jmp     near .done
.nf:    cmp     ah, 10h                 ; palette functions
        jne     near .done
        call    getpal
        jmp     near .done
.mode:  cmp     byte [enabled], 0        ; BIOS set mode: SVGA off *after* the mode set.  Turning it
        je      near .mode2              ; off before made VMware show double-scan modes (640x200,
        call    disable                  ; QBASIC SCREEN 8) as garbage.
.mode2: mov     byte [susp], 0
        mov     byte [force], 1
        mov     byte [fontdirty], 1
        call    getpal
        jmp     near .done
.vbe:   mov     byte [force], 1
        mov     byte [susp], 0
        mov     bx, [bp + 40]
        and     bx, 1FFh
        cmp     bx, 100h                ; VESA mode -> leave the hardware alone
        jb      near .done
        mov     byte [susp], 1
.done:  pop     es
        pop     ds
        popad
        ; A tick was skipped while INT 10h was running: do that pass now, on the way out of the
        ; outermost INT 10h (the BIOS / DOS/V driver has finished with the hardware), but only if
        ; the caller had interrupts enabled.
        cmp     byte [cs:pend], 0
        je      short .nopend
        cmp     byte [cs:in10], 1
        jne     short .nopend
        cmp     byte [cs:busy], 0
        jne     short .nopend
        push    bp
        mov     bp, sp                  ; [bp+8] IP, [bp+10] CS, [bp+12] caller flags
        test    byte [bp + 13], 02h     ; caller IF
        pop     bp
        jz      short .nopend
        mov     byte [cs:pend], 0
        mov     byte [cs:busy], 1
        mov     byte [cs:in10], 0
        sti
        pushad
        push    ds
        push    es
        push    cs
        pop     ds
        push    cs
        pop     es
        cld
        call    work
        pop     es
        pop     ds
        popad
        cli
        mov     byte [cs:busy], 0
        jmp     short .flags
.nopend:
        dec     byte [cs:in10]
.flags:
        ; Return the BIOS result flags (CF, ZF, ...) but the caller's IF/TF: the BIOS was called
        ; with IF=0 (we are inside an INT), so passing its flags straight back would leave the
        ; caller running with interrupts disabled.
        push    bp
        mov     bp, sp                  ; [bp+2] BIOS flags, [bp+4] AX, [bp+6] BX,
        push    ax                      ; [bp+8] IP, [bp+10] CS, [bp+12] caller flags
        mov     ax, [bp + 2]
        and     ax, 0FCFFh              ; drop TF, IF
        and     word [bp + 12], 0300h   ; keep caller TF, IF
        or      [bp + 12], ax
        pop     ax
        pop     bp
        add     sp, 6                   ; discard BIOS flags, caller AX/BX copies
        iret
;--------------------------------------------------------------------------------------------------
; INT 2Fh: install check
;--------------------------------------------------------------------------------------------------
int2f:  cmp     ax, MUX_FUNC
        jne     short .chain
        mov     al, 0FFh
        mov     bx, MUX_SIG
        push    cs
        pop     es
        iret
.chain: jmp     far [cs:old2f]

;--------------------------------------------------------------------------------------------------
; work: one update pass.  DS=ES=CS, IF=1.
;--------------------------------------------------------------------------------------------------
work:   smsw    ax
        test    al, 1
        jz      short .rm               ; protected/V86 mode now:
        cmp     byte [v86], 0           ;   OK only if we were installed under a V86 monitor
        je      near .ret
.rm:    call    hwchk                   ; AL = 0 (other mode), 1 (640x480 planar), 2 (80-col text)
        test    al, al
        jne     near .ok
        cmp     byte [enabled], 0       ; unsupported mode: show plain VGA
        je      near .ret
        call    disable
        jmp     near .ret
.ok:    cmp     byte [susp], 0
        jne     near .ret
        mov     [newmode], al
        mov     word [modew], 640       ; source width: 640 (graphics) or 80 * 8/9 (text)
        cmp     al, 1
        je      short .w
        movzx   ax, byte [tcw]
        imul    ax, ax, 80
        mov     [modew], ax
.w:     cmp     byte [enabled], 0
        je      near .doen
        mov     al, [newmode]
        cmp     al, [curmode]
        jne     near .doen
        mov     ax, [vlines]
        cmp     ax, [curv]
        jne     near .doen
        mov     ax, [modew]
        cmp     ax, [curw]
        je      near .en
.doen:  call    enable                  ; (re)program the SVGA; CF = VM cannot show this size
        jc      near .ret
.en:    cmp     byte [paldirty], 0
        je      near .np
        mov     byte [force], 1
        mov     byte [paldirty], 0
.np:    cmp     byte [v86], 0
        jne     near .nour
        call    unreal
.nour:  cmp     byte [curmode], 2
        je      near textpass
        mov     ax, [crtstart]
        mov     [srcoff], ax
        xor     bp, bp                  ; BP = line

.line:  test    bp, CH_LINES-1
        jne     near .noread
        ; ---- read CH_LINES lines of all 4 planes into chunk[] ----
        cli
        mov     dx, 3C4h                ; sequencer: save index and map mask, enable all planes
        in      al, dx
        mov     [s_si], al
        mov     al, 2
        out     dx, al
        inc     dx
        in      al, dx
        mov     [s_mm], al
        mov     al, 0Fh
        out     dx, al
        mov     dx, 3CEh                ; graphics controller: save index, mode, read map
        in      al, dx
        mov     [s_gi], al
        mov     al, 5
        out     dx, al
        inc     dx
        in      al, dx
        mov     [s_g5], al
        and     al, 0F4h                ; read mode 0, write mode 1
        or      al, 1
        out     dx, al
        dec     dx
        mov     al, 4
        out     dx, al
        inc     dx
        in      al, dx
        mov     [s_g4], al              ; DX = 3CFh, index 4 (read map select)
        push    ds
        mov     ax, 0A000h
        mov     ds, ax
        mov     byte [0FFFFh], 0        ; write mode 1: park the foreground's latches off-screen
%assign p 0
%rep 4
        mov     al, p
        out     dx, al
        mov     si, [cs:srcoff]
        mov     di, chunk + p*CHUNKSZ
        mov     cx, CHUNKSZ/4
        rep     movsd
%assign p p+1
%endrep
        mov     al, [0FFFFh]            ; reload the foreground's latches
        pop     ds
        mov     al, [s_g4]
        out     dx, al
        dec     dx
        mov     al, 5
        out     dx, al
        inc     dx
        mov     al, [s_g5]
        out     dx, al
        dec     dx
        mov     al, [s_gi]
        out     dx, al
        mov     dx, 3C4h
        mov     al, 2
        out     dx, al
        inc     dx
        mov     al, [s_mm]
        out     dx, al
        dec     dx
        mov     al, [s_si]
        out     dx, al
        sti

.noread:
        mov     bx, bp                  ; BX = offset of this line inside the chunk
        and     bx, CH_LINES-1
        imul    bx, bx, 80
        xor     edx, edx                ; hash the 4 plane rows of this line
%assign p 0
%rep 4
        lea     si, [bx + chunk + p*CHUNKSZ]
        mov     cx, 20
.h%[p]:    lodsd
        rol     edx, 5
        add     edx, eax
        loop    .h%[p]
%assign p p+1
%endrep
        mov     di, bp
        shl     di, 2
        cmp     edx, [di + hashes]
        jne     near .chg
        cmp     byte [force], 0
        je      near .next
.chg:   mov     [di + hashes], edx
        ; ---- convert 640 planar pixels to 640*scale 32-bit pixels ----
        lea     si, [bx + chunk]
        mov     di, linebuf
        mov     cx, 80
.col:   mov     bl, [si]                ; plane 0..3
        mov     bh, [si + CHUNKSZ]
        mov     dl, [si + 2*CHUNKSZ]
        mov     dh, [si + 3*CHUNKSZ]
        inc     si
        push    cx
        mov     cx, 8
.bit:   xor     al, al
        shl     dh, 1
        rcl     al, 1
        shl     dl, 1
        rcl     al, 1
        shl     bh, 1
        rcl     al, 1
        shl     bl, 1
        rcl     al, 1
        and     eax, 0Fh
        mov     eax, [eax*4 + pal32]
        push    cx
        movzx   cx, byte [scale]
        rep     stosd
        pop     cx
        loop    .bit
        pop     cx
        loop    .col
        movzx   eax, bp                 ; FB address of line scale*y
        movzx   ecx, byte [scale]
        mul     ecx
        mul     dword [pitch]
        add     eax, [fbbase]
        movzx   cx, byte [scale]        ; write the line scale times
.rep:   push    cx
        call    mvline
        pop     cx
        add     eax, [pitch]
        loop    .rep
.next:  add     word [srcoff], 80
        inc     bp
        cmp     bp, [vlines]
        jb      near .line
        mov     byte [force], 0
.ret:   ret

;--------------------------------------------------------------------------------------------------
; textpass: render an 80-column text screen.  Rows whose characters/attributes (and cursor) did
; not change since the last pass are skipped.
;--------------------------------------------------------------------------------------------------
textpass:
        cmp     byte [fontdirty], 0
        je      short .fok
        call    readfont
        mov     byte [fontdirty], 0
        mov     byte [force], 1
.fok:   push    ds                      ; BIOS data: tick count (cursor blink), mode-select shadow
        xor     ax, ax
        mov     ds, ax
        mov     al, [46Ch]
        mov     ah, [465h]
        pop     ds
        mov     byte [bgmask], 0Fh      ; 3x8 mode-select bit 5 = blink enabled -> 8 background colours
        test    ah, 20h
        jz      short .nobl
        mov     byte [bgmask], 07h
.nobl:  mov     word [currow], 0FFFFh   ; cursor position (row/col on screen), or none
        test    byte [c0a], 20h         ; cursor disabled
        jne     short .nocur
        test    al, 08h                 ; blink: visible half of the time
        jz      short .nocur
        mov     ah, [c0e]
        mov     al, [c0f]
        sub     ax, [crtstart]
        jb      short .nocur
        mov     bx, [tstride]
        shr     bx, 1                   ; characters per row in memory
        xor     dx, dx
        div     bx
        cmp     dx, 80
        jae     short .nocur
        cmp     al, [trows]
        jae     short .nocur
        mov     [currow], ax
        mov     [curcol], dx
.nocur: mov     al, [c0a]
        and     al, 1Fh
        mov     [cstart], al
        mov     al, [c0b]
        and     al, 1Fh
        mov     [cend], al
        mov     word [trow], 0
.row:   mov     ax, [trow]              ; copy this row (char, attr) x 80 from B800h
        mul     word [tstride]
        mov     si, [crtstart]
        shl     si, 1
        add     si, ax
        mov     di, rowbuf
        mov     cx, 80
        push    ds
        mov     ax, 0B800h
        mov     ds, ax
        rep     movsw
        pop     ds
        mov     si, rowbuf              ; hash it, plus cursor and blink state
        mov     cx, 40
        xor     edx, edx
.h:     lodsd
        rol     edx, 5
        add     edx, eax
        loop    .h
        movzx   eax, byte [bgmask]
        xor     edx, eax
        mov     ax, [trow]
        cmp     ax, [currow]
        jne     short .hc
        mov     ax, [curcol]
        shl     eax, 16
        mov     ah, [cstart]
        mov     al, [cend]
        add     eax, 5A5A0001h
        xor     edx, eax
.hc:    mov     di, [trow]
        shl     di, 2
        cmp     edx, [di + hashes]
        jne     short .chg
        cmp     byte [force], 0
        je      near .nextrow
.chg:   mov     [di + hashes], edx
        mov     word [tline], 0
.line:  mov     si, rowbuf
        mov     di, linebuf
        xor     bp, bp                  ; BP = column
.col:   mov     al, [si]                ; character
        mov     [tchar], al
        movzx   ebx, byte [si + 1]      ; attribute
        add     si, 2
        mov     ecx, ebx
        and     ebx, 0Fh
        mov     edx, [ebx*4 + pal32]    ; EDX = foreground
        shr     ecx, 4
        and     cl, [bgmask]
        mov     eax, [ecx*4 + pal32]
        mov     [tbg], eax              ; background
        movzx   bx, byte [tchar]        ; font row
        shl     bx, 4
        add     bx, [tline]
        mov     bl, [bx + fontc]
        mov     byte [tcur], 0
        cmp     bp, [curcol]            ; cursor cell and scan line?
        jne     short .nc
        mov     ax, [trow]
        cmp     ax, [currow]
        jne     short .nc
        mov     al, [tline]
        cmp     al, [cstart]
        jb      short .nc
        cmp     al, [cend]
        ja      short .nc
        mov     bl, 0FFh
        mov     byte [tcur], 1
.nc:    mov     [tbits], bl
        mov     bh, 8
.px:    mov     eax, [tbg]
        shl     bl, 1
        jnc     short .bg
        mov     eax, edx
.bg:    movzx   cx, byte [scale]
        rep     stosd
        dec     bh
        jnz     short .px
        cmp     byte [tcw], 9           ; 9th column: background, or column 8 repeated for
        jne     short .n9               ; line-drawing characters C0h..DFh (and the cursor)
        mov     eax, [tbg]
        cmp     byte [tcur], 0
        jne     short .fg9
        cmp     byte [tchar], 0C0h
        jb      short .s9
        cmp     byte [tchar], 0DFh
        ja      short .s9
        test    byte [tbits], 1
        jz      short .s9
.fg9:   mov     eax, edx
.s9:    movzx   cx, byte [scale]
        rep     stosd
.n9:    inc     bp
        cmp     bp, 80
        jb      near .col
        movzx   eax, word [trow]        ; FB address of output line ((row*tch)+line)*scale
        movzx   ecx, byte [tch]
        mul     ecx
        add     ax, [tline]
        movzx   ecx, byte [scale]
        mul     ecx
        mul     dword [pitch]
        add     eax, [fbbase]
        movzx   cx, byte [scale]
.rep:   push    cx
        call    mvline
        pop     cx
        add     eax, [pitch]
        loop    .rep
        inc     word [tline]
        movzx   ax, byte [tch]
        cmp     [tline], ax
        jb      near .line
.nextrow:
        inc     word [trow]
        movzx   ax, byte [trows]
        cmp     [trow], ax
        jb      near .row
        mov     byte [force], 0
        ret

;--------------------------------------------------------------------------------------------------
; readfont: copy the character generator (font map A, 256 x 16 lines) from VGA plane 2 into
;           fontc[], the same way the BIOS accesses it.  All registers are saved and restored and
;           interrupts are off, so the foreground never sees the changed state.
;--------------------------------------------------------------------------------------------------
readfont:
        cli
        mov     dx, 3C4h
        in      al, dx
        mov     [t_si], al
        RDREG   2, f_s2
        RDREG   3, f_s3
        RDREG   4, f_s4
        mov     ax, 0402h               ; map mask = plane 2
        out     dx, ax
        mov     ax, 0704h               ; sequential addressing, extended memory
        out     dx, ax
        mov     dx, 3CEh
        in      al, dx
        mov     [t_gi], al
        RDREG   4, f_g4
        RDREG   5, f_g5
        RDREG   6, f_g6
        mov     ax, 0204h               ; read map = plane 2
        out     dx, ax
        mov     ax, 0005h               ; read mode 0, no odd/even
        out     dx, ax
        mov     ax, 0406h               ; memory map A000h/64K, no chain
        out     dx, ax
        mov     al, [f_s3]              ; font map A = bits 5,3,2 of character map select
        mov     bl, al
        shr     bl, 3
        and     bl, 4
        shr     al, 2
        and     al, 3
        or      bl, al
        xor     bh, bh
        shl     bx, 1
        mov     bx, [bx + fontblk]
        push    ds
        push    es
        push    cs
        pop     es
        mov     ax, 0A000h
        mov     ds, ax
        mov     di, fontc
        mov     cx, 256
.ch:    mov     si, bx
        movsd                           ; 16 lines of this character
        movsd
        movsd
        movsd
        add     bx, 32
        loop    .ch
        pop     es
        pop     ds
        mov     dx, 3CEh                ; restore
        mov     ah, [f_g6]
        mov     al, 6
        out     dx, ax
        mov     ah, [f_g5]
        mov     al, 5
        out     dx, ax
        mov     ah, [f_g4]
        mov     al, 4
        out     dx, ax
        mov     al, [t_gi]
        out     dx, al
        mov     dx, 3C4h
        mov     ah, [f_s4]
        mov     al, 4
        out     dx, ax
        mov     ah, [f_s2]
        mov     al, 2
        out     dx, ax
        mov     al, [t_si]
        out     dx, al
        sti
        ret
fontblk dw      0000h, 4000h, 8000h, 0C000h, 2000h, 6000h, 0A000h, 0E000h

;--------------------------------------------------------------------------------------------------
; hwchk: classify the current VGA mode (colour adapters only)
;   AL=1  16-colour planar graphics, 640 wide, 350..480 lines (sets vlines, crtstart)
;   AL=2  text mode, 80 columns, 8/9-dot cells up to 16 lines high, 200..480 lines
;         (sets vlines, crtstart, tcw, tch, trows, tstride, cursor registers)
;   AL=0  anything else
;--------------------------------------------------------------------------------------------------
hwchk:  mov     dx, 3CCh                ; misc output: colour (3Dx) addressing?
        in      al, dx
        test    al, 1
        je      near .bad
        cli
        mov     dx, 3C4h
        in      al, dx
        mov     [t_si], al
        RDREG   1, t_s1                 ; clocking mode: bit0 = 8-dot cells, bit3 = half dot clock
        mov     al, [t_si]
        out     dx, al
        mov     dx, 3CEh
        in      al, dx
        mov     [t_gi], al
        RDREG   6, t_g6
        RDREG   5, t_g5
        mov     al, [t_gi]
        out     dx, al
        mov     dx, 3D4h
        in      al, dx
        mov     [t_ci], al
        RDREG   01h, c01
        RDREG   12h, c12
        RDREG   07h, c07
        RDREG   13h, c13
        RDREG   0Ch, c0c
        RDREG   0Dh, c0d
        RDREG   09h, c09
        RDREG   0Ah, c0a
        RDREG   0Bh, c0b
        RDREG   0Eh, c0e
        RDREG   0Fh, c0f
        mov     al, [t_ci]
        out     dx, al
        sti
        cmp     byte [c01], 4Fh         ; 80 character clocks
        jne     near .bad
        xor     bx, bx                  ; visible lines = vertical display end + 1
        mov     bl, [c12]
        test    byte [c07], 02h
        jz      short .v8
        or      bh, 1
.v8:    test    byte [c07], 40h
        jz      short .v9
        or      bh, 2
.v9:    inc     bx
        mov     [vlines], bx
        cmp     bx, MAXLINES
        ja      near .bad
        mov     ah, [c0c]
        mov     al, [c0d]
        mov     [crtstart], ax
        mov     al, [t_g6]
        and     al, 0Dh
        cmp     al, 05h                 ; graphics, memory map A000h/64K
        je      short .gfx
        cmp     al, 0Ch                 ; text, memory map B800h/32K
        jne     near .bad
        ; ---- text mode ----
        test    byte [t_s1], 08h        ; 40-column modes (half dot clock): not handled
        jne     near .bad
        test    byte [c09], 80h         ; double scan: not handled
        jne     near .bad
        cmp     bx, 200
        jb      near .bad
        mov     al, [c09]
        and     al, 1Fh
        inc     al
        cmp     al, 16
        ja      near .bad
        cmp     al, 8                   ; (also keeps the row division below 256)
        jb      near .bad
        mov     [tch], al
        mov     ax, bx                  ; rows = lines / cell height
        div     byte [tch]
        mov     [trows], al
        mov     byte [tcw], 9
        test    byte [t_s1], 01h
        jz      short .c9
        mov     byte [tcw], 8
.c9:    movzx   ax, byte [c13]          ; bytes per row = offset register * 4 (word mode)
        shl     ax, 2
        cmp     ax, 160
        jb      near .bad
        mov     [tstride], ax
        mov     al, 2
        ret
.gfx:   test    byte [t_g5], 40h        ; not 256-colour shift mode
        jne     near .bad
        cmp     bx, 350
        jb      near .bad
        cmp     byte [c13], 28h         ; 80 bytes per line
        jne     near .bad
        test    byte [c09], 9Fh         ; no double scan, 1 scan line per row (rejects 640x200 modes)
        jne     near .bad
        mov     al, 1
        ret
.bad:   xor     al, al
        ret

;--------------------------------------------------------------------------------------------------
; enable: (modew*scale) x (vlines*scale) x 32bpp for [newmode].
;         CF=1 (and SVGA off) if the VM's limits do not allow that size.
;--------------------------------------------------------------------------------------------------
enable: movzx   ebx, word [modew]
        movzx   ecx, byte [scale]
        imul    ebx, ecx                ; EBX = width
        cmp     ebx, [maxw]
        ja      near .no
        movzx   eax, word [vlines]
        imul    eax, ecx                ; EAX = height
        cmp     eax, [maxh]
        ja      near .no
        push    eax
        imul    eax, ebx
        shl     eax, 2
        cmp     eax, [vram]
        pop     eax
        ja      near .no
        mov     [lbdw], ebx
        mov     dx, bx
        shl     dx, 1
        mov     [lbwords], dx
        push    eax
        mov     ax, SVGA_REG_WIDTH
        call    svga_out
        pop     ebx
        mov     ax, SVGA_REG_HEIGHT
        call    svga_out
        SVGA_OUT SVGA_REG_BITS_PER_PIXEL, 32
        SVGA_OUT SVGA_REG_ENABLE, 1
        SVGA_IN SVGA_REG_BYTES_PER_LINE
        mov     [pitch], eax
        SVGA_IN SVGA_REG_FB_OFFSET
        add     eax, [fbstart]
        mov     [fbbase], eax
        mov     al, [newmode]
        mov     [curmode], al
        mov     ax, [vlines]
        mov     [curv], ax
        mov     ax, [modew]
        mov     [curw], ax
        mov     byte [enabled], 1
        mov     byte [force], 1
        mov     byte [paldirty], 0
        mov     byte [fontdirty], 1
        clc
        ret
.no:    cmp     byte [enabled], 0
        je      short .no2
        call    disable
.no2:   stc
        ret

disable:                                ; callable with any DS
        SVGA_OUT SVGA_REG_ENABLE, 0
        mov     byte [cs:enabled], 0
        ret

;--------------------------------------------------------------------------------------------------
; getpal: build pal32[16] (B,G,R,0) from attribute palette -> DAC.  DS=ES=CS; calls the BIOS
;         directly (not through our own INT 10h hook).
;--------------------------------------------------------------------------------------------------
getpal: xor     si, si
        mov     di, pal32
.lp:    mov     ax, 1007h               ; read attribute palette register BL -> BH
        mov     bx, si
        pushf
        call    far [cs:old10]
        mov     bl, bh
        xor     bh, bh
        mov     ax, 1015h               ; read DAC register BX -> DH=R CH=G CL=B (6 bit)
        pushf
        call    far [cs:old10]
        mov     al, cl
        call    sc6
        stosb
        mov     al, ch
        call    sc6
        stosb
        mov     al, dh
        call    sc6
        stosb
        xor     al, al
        stosb
        inc     si
        cmp     si, 16
        jb      short .lp
        mov     byte [paldirty], 1
        ret

sc6:    mov     ah, al                  ; 6-bit -> 8-bit
        shl     al, 2
        shr     ah, 4
        or      al, ah
        ret

;--------------------------------------------------------------------------------------------------
; unreal: give ES a 4 GB limit (real mode only)
;--------------------------------------------------------------------------------------------------
unreal: cli
        o32 sgdt [savgdt]
        o32 lgdt [gdtr]
        mov     eax, cr0
        or      al, 1
        mov     cr0, eax
        jmp     short $+2
        mov     bx, 8
        mov     es, bx
        and     al, 0FEh
        mov     cr0, eax
        jmp     short $+2
        o32 lgdt [savgdt]
        push    cs
        pop     es
        sti
        ret

;--------------------------------------------------------------------------------------------------
; mvline: copy linebuf (640*scale dwords) to physical address EAX.  Preserves EAX.
;--------------------------------------------------------------------------------------------------
mv87:   mov     [g87 + 1Ah], ax         ; V86: INT 15h AH=87h, destination descriptor base
        push    eax
        shr     eax, 16
        mov     [g87 + 1Ch], al
        mov     [g87 + 1Fh], ah
        pop     eax
        push    eax
        push    si
        push    cx
        mov     si, g87
        mov     cx, [lbwords]
        mov     ah, 87h
        int     15h
        pop     cx
        pop     si
        pop     eax
        ret

mvline: cmp     byte [v86], 0
        jne     near mv87
        push    es
        push    byte 0
        pop     es                      ; ES base 0, limit 4 GB (unreal)
        mov     edi, eax
        mov     esi, linebuf
        mov     ecx, [lbdw]
        a32 rep movsd
        pop     es
        ret

svga_out:                               ; AX = register, EBX = value
        push    dx
        push    eax
        mov     dx, [cs:iobase]
        movzx   eax, ax
        out     dx, eax
        inc     dx
        mov     eax, ebx
        out     dx, eax
        pop     eax
        pop     dx
        ret

svga_in:                                ; AX = register -> EAX
        push    dx
        mov     dx, [cs:iobase]
        movzx   eax, ax
        out     dx, eax
        inc     dx
        in      eax, dx
        pop     dx
        ret

;--------------------------------------------------------------------------------------------------
; Resident data
;--------------------------------------------------------------------------------------------------
        align   8, db 0
gdt:    dq      0
        db      0FFh, 0FFh, 0, 0, 0, 92h, 8Fh, 0       ; flat 4 GB data
%macro GDT87 0                          ; INT 15h AH=87h descriptor table
        times 16 db 0
        db      0FFh, 0FFh, 0, 0, 0, 93h, 0, 0         ; source
        db      0FFh, 0FFh, 0, 0, 0, 93h, 0, 0         ; destination
        times 16 db 0
%endmacro
g87:    GDT87
v86     db      0
gdtr    dw      15
        dd      0
savgdt  dw      0
        dd      0
old08   dd      0
old10   dd      0
old2f   dd      0
fbstart dd      0
pitch   dd      0
fbbase  dd      0
lbdw    dd      0                       ; line length in dwords (640*scale)
lbwords dw      0                       ; line length in words (for INT 15h/87h)
vlines  dw      0
curv    dw      0
iobase  dw      0
crtstart dw     0
srcoff  dw      0
busy    db      0
pend    db      0                       ; a pass was skipped because INT 10h was running
callfl  dw      0                       ; caller's flags for the BIOS call (INT 10h hook)
in10    db      0
cnt     db      0
rate    db      0
enabled db      0
susp    db      0
force   db      0
paldirty db     0
scale   db      2
fontdirty db    1
newmode db      0
curmode db      0
tcw     db      0                       ; text: cell width (8/9), height, rows
tch     db      0
trows   db      0
bgmask  db      0
tcur    db      0
tchar   db      0
tbits   db      0
cstart  db      0
cend    db      0
t_si    db      0
t_s1    db      0
f_s2    db      0
f_s3    db      0
f_s4    db      0
f_g4    db      0
f_g5    db      0
f_g6    db      0
c0a     db      0
c0b     db      0
c0e     db      0
c0f     db      0
        align   2, db 0
modew   dw      0
curw    dw      0
tstride dw      0
trow    dw      0
tline   dw      0
currow  dw      0
curcol  dw      0
        align   4, db 0
tbg     dd      0
maxw    dd      0
maxh    dd      0
vram    dd      0
s_si    db      0
s_mm    db      0
s_gi    db      0
s_g5    db      0
s_g4    db      0
t_gi    db      0
t_g6    db      0
t_g5    db      0
t_ci    db      0
c01     db      0
c12     db      0
c07     db      0
c13     db      0
c0c     db      0
c0d     db      0
c09     db      0
        align   4, db 0
pal32   times 16 dd 0
hashes  times MAXLINES dd 0
chunk   times 4*CHUNKSZ db 0
linebuf times 720*MAXSCALE*4 db 0
rowbuf  times 160 db 0
fontc   times 256*16 db 0
%ifdef TRACE
trpos   dw      0
trbuf   times 1024 db 0
%endif
resend:

;==================================================================================================
; Transient part (discarded after going resident)
;==================================================================================================
init:   cld
        PRINT   m_title
        smsw    ax
        test    al, 1
        jz      short .rm
        mov     byte [v86], 1
.rm:
        ; ---- command line: /U, /Rn, /Sn ----
        mov     byte [rate], 1
        mov     si, 81h
.pa:    lodsb
        cmp     al, 0Dh
        je      near .paend
        cmp     al, '/'
        jne     short .pa
        lodsb
        cmp     al, 0Dh
        je      near .paend
        and     al, 0DFh
        cmp     al, '?' & 0DFh
        je      near help
        cmp     al, 'U'
        jne     short .notu
        mov     byte [f_u], 1
        jmp     short .pa
.notu:  cmp     al, 'S'
        jne     short .nots
        lodsb
        sub     al, '0'
        cmp     al, 2
        jb      near e_scale
        cmp     al, MAXSCALE
        ja      near e_scale
        mov     [scale], al
        jmp     short .pa
.nots:  cmp     al, 'R'
        jne     near .pa
        lodsb
        sub     al, '0'
        cmp     al, 1
        jb      short .pa
        cmp     al, 9
        ja      short .pa
        mov     [rate], al
        jmp     short .pa
.paend:
        ; ---- already installed? ----
        mov     ax, MUX_FUNC
        int     2Fh
        cmp     al, 0FFh
        jne     near .notinst
        cmp     bx, MUX_SIG
        jne     near .notinst
        mov     ax, es
        mov     [rseg], ax
        push    cs
        pop     es
        cmp     byte [f_u], 0
        jne     near uninst
        PRINT   m_already
        jmp     near exit1
.notinst:
        cmp     byte [f_u], 0
        je      near .doinst
        PRINT   m_notinst
        jmp     near exit1

.doinst:
        ; ---- find VMware SVGA II (PCI 15AD:0405) ----
        mov     ax, 0B102h
        mov     cx, 0405h
        mov     dx, 15ADh
        xor     si, si
        int     1Ah
        jb      near e_nodev
        test    ah, ah
        jne     near e_nodev
        mov     ax, 0B10Ah              ; BAR0 = I/O base
        mov     di, 10h
        int     1Ah
        and     cl, 0FCh
        mov     [iobase], cx
        SVGA_OUT SVGA_REG_ID, SVGA_ID_2
        SVGA_IN SVGA_REG_ID
        cmp     eax, SVGA_ID_2
        jne     near e_id
        SVGA_IN SVGA_REG_FB_START
        cmp     eax, 100000h
        jb      near e_id
        mov     [fbstart], eax
        ; ---- line length, and does the VM allow (640*scale) x (480*scale) x 32bpp? ----
        movzx   eax, byte [scale]
        imul    eax, eax, 640
        mov     [lbdw], eax
        shl     ax, 1
        mov     [lbwords], ax
        SVGA_IN SVGA_REG_MAX_WIDTH
        mov     [maxw], eax
        cmp     eax, [lbdw]
        jb      near e_size
        movzx   ebx, byte [scale]
        imul    ebx, ebx, MAXLINES
        SVGA_IN SVGA_REG_MAX_HEIGHT
        mov     [maxh], eax
        cmp     eax, ebx
        jb      near e_size
        imul    ebx, [lbdw]             ; bytes needed = width*4 * height
        shl     ebx, 2
        SVGA_IN SVGA_REG_VRAM_SIZE
        mov     [vram], eax
        cmp     eax, ebx
        jb      near e_size
        LINADDR linebuf                 ; INT 15h/87h source descriptor = linebuf
        mov     [g87 + 12h], ax
        shr     eax, 16
        mov     [g87 + 14h], al
        cmp     byte [v86], 0
        je      near .chkdone
        push    cs
        pop     es
        ; ---- V86: make sure INT 15h AH=87h really reaches the FB ----
        ; 1) reading FB and FB&00FFFFFFh must give different data (else the high byte is dropped,
        ;    and a write would land in low memory)
        mov     ebx, [fbstart]
        LINADDR tbA
        mov     edx, eax
        mov     cx, 16
        call    t87
        jb      near e_87
        mov     ebx, [fbstart]
        and     ebx, 00FFFFFFh
        LINADDR tbB
        mov     edx, eax
        mov     cx, 16
        call    t87
        jb      near e_87
        mov     si, tbA
        mov     di, tbB
        mov     cx, 32
        repe    cmpsb
        je      near e_87
        ; 2) write a pattern into the last page of VRAM (off-screen) and read it back
        LINADDR tbP
        mov     ebx, eax
        mov     edx, [fbstart]
        add     edx, [vram]
        sub     edx, 1000h
        mov     cx, 16
        call    t87
        jb      near e_87
        mov     ebx, [fbstart]
        add     ebx, [vram]
        sub     ebx, 1000h
        LINADDR tbA
        mov     edx, eax
        mov     cx, 16
        call    t87
        jb      near e_87
        mov     si, tbA
        mov     di, tbP
        mov     cx, 32
        repe    cmpsb
        jne     near e_87
        PRINT   m_v86ok
.chkdone:
        xor     eax, eax                ; GDTR base for unreal mode
        mov     ax, cs
        shl     eax, 4
        add     eax, strict dword gdt
        mov     [gdtr + 2], eax
        mov     al, [rate]
        mov     [cnt], al
        ; ---- hook INT 08h, 10h, 2Fh ----
        mov     ax, 3508h
        int     21h
        mov     [old08], bx
        mov     [old08 + 2], es
        mov     ax, 3510h
        int     21h
        mov     [old10], bx
        mov     [old10 + 2], es
        mov     ax, 352Fh
        int     21h
        mov     [old2f], bx
        mov     [old2f + 2], es
        push    cs
        pop     es
        call    getpal
        cli
        mov     dx, int08
        mov     ax, 2508h
        int     21h
        mov     dx, int10
        mov     ax, 2510h
        int     21h
        mov     dx, int2f
        mov     ax, 252Fh
        int     21h
        sti
        mov     es, [2Ch]               ; free the environment
        mov     ah, 49h
        int     21h
        mov     word [2Ch], 0
        PRINT   m_inst
        ; Close the standard handles: a resident program keeps its open files, so "SVGA2X > NUL"
        ; would leave one system file table entry in use for good, and after enough installs
        ; redirection and pipes fail ("Cannot execute FIND.EXE").
        xor     bx, bx
.cl:    mov     ah, 3Eh
        int     21h
        inc     bx
        cmp     bx, 5
        jb      short .cl
        mov     dx, resend
        add     dx, 15
        shr     dx, 4
        mov     ax, 3100h
        int     21h

;--------------------------------------------------------------------------------------------------
; Uninstall (resident segment in [rseg])
;--------------------------------------------------------------------------------------------------
uninst:
%macro CHKVEC 2                         ; vector, handler
        mov     ax, 3500h | %1
        int     21h
        mov     ax, es
        cmp     ax, [rseg]
        jne     near e_cant
        cmp     bx, %2
        jne     near e_cant
%endmacro
        CHKVEC  08h, int08
        CHKVEC  10h, int10
        CHKVEC  2Fh, int2f
        mov     es, [rseg]
        mov     byte [es:busy], 1
        cli
%macro RESTVEC 2
        push    ds
        lds     dx, [es:%2]
        mov     ax, 2500h | %1
        int     21h
        pop     ds
%endmacro
        RESTVEC 08h, old08
        RESTVEC 10h, old10
        RESTVEC 2Fh, old2f
        sti
        mov     ax, [es:iobase]
        mov     [iobase], ax
        cmp     byte [es:enabled], 0
        je      short .noen
        SVGA_OUT SVGA_REG_ENABLE, 0
.noen:  mov     ah, 49h
        int     21h
        PRINT   m_removed
        mov     ax, 4C00h
        int     21h

help:   PRINT   m_help
        mov     ax, 4C00h
        int     21h
e_nodev:
        PRINT   m_nodev
        jmp     near exit1
e_id:   PRINT   m_id
        jmp     near exit1
e_cant: PRINT   m_cant
exit1:  mov     ax, 4C01h
        int     21h
e_87:   PRINT   m_87
        jmp     near exit1
e_scale: PRINT  m_scale
        jmp     near exit1
e_size: PRINT   m_size
        jmp     near exit1

; t87: EBX = source physical address, EDX = destination physical address, CX = words; CF on error
t87:    mov     [gt + 12h], bx
        push    ebx
        shr     ebx, 16
        mov     [gt + 14h], bl
        mov     [gt + 17h], bh
        pop     ebx
        mov     [gt + 1Ah], dx
        push    edx
        shr     edx, 16
        mov     [gt + 1Ch], dl
        mov     [gt + 1Fh], dh
        pop     edx
        mov     si, gt
        mov     ah, 87h
        int     15h
        ret

gt:     GDT87
tbA     times 32 db 0
tbB     times 32 db 0EEh
tbP     db      'SVGA2X INT15/87 write test 1234', 0
rseg    dw      0
f_u     db      0

m_title   db 'SVGA2X 0.3.1 - VGA 16-colour graphics and 80-column text at 2x/3x on VMware SVGA II', 13, 10, '$'
m_inst    db 'Installed.  SVGA2X /U = remove, /? = help', 13, 10, '$'
m_help    db 'Usage: SVGA2X [/Sn] [/Rn] | /U', 13, 10
          db '  (none)  install resident', 13, 10
          db '  /Sn     scale factor, n = 2 (default, 1280x960) or 3 (1920x1440)', 13, 10
          db '  /U      remove from memory', 13, 10
          db '  /Rn     update every n timer ticks, n = 1..9 (default 1 = 18.2 Hz)', 13, 10
          db 'Works in real mode (HIMEM only) and under EMM386 / JEMMEX (V86 mode).', 13, 10, '$'
m_already db 'Already installed.', 13, 10, '$'
m_notinst db 'Not installed.', 13, 10, '$'
m_removed db 'Removed.', 13, 10, '$'
m_cant    db 'Cannot remove: vectors hooked by another program.', 13, 10, '$'
m_v86ok   db 'V86 mode: framebuffer access via INT 15h AH=87h verified.', 13, 10, '$'
m_87      db 'Error: INT 15h AH=87h cannot reach the framebuffer (V86 mode).', 13, 10, '$'
m_nodev   db 'Error: VMware SVGA II not found.', 13, 10, '$'
m_id      db 'Error: unexpected SVGA ID or framebuffer address.', 13, 10, '$'
m_scale   db 'Error: /S must be 2 or 3.', 13, 10, '$'
m_size    db 'Error: the VM does not allow this resolution (max width/height or VRAM too small;', 13, 10
          db '       check svga.maxWidth, svga.maxHeight, svga.vramSize in the .vmx).', 13, 10, '$'
