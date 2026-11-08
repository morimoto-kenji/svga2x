; SVGA2X - show a DOS/V (VGA 640x480 16-colour planar) screen at 2x on VMware SVGA II
;
; Copyright (c) 2026 Kenji Morimoto <github@morimoto.ne.jp>
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
SVGA_PALETTE_BASE       equ 1024

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
        dec     byte [cs:cnt]           ; every RATE ticks, or at the next tick after any INT 10h call
        je      short .due              ; (screen output, cursor moves): with /R2 the cursor and
        cmp     byte [cs:act], 0        ; typing follow at 18.2 Hz, while an idle screen is only
        je      near .ret               ; redrawn every RATE ticks.
.due:   mov     byte [cs:act], 0
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
        mov     byte [cs:act], 1
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
        cmp     al, 07h                 ; read-only subfunctions (read palette register / overscan /
        je      near .done              ; all registers, read DAC register / block, read color
        cmp     al, 08h                 ; page state) cannot change the palette.  DOSSHELL calls
        je      near .done              ; them dozens of times while starting.
        cmp     al, 09h
        je      near .done
        cmp     al, 15h
        je      near .done
        cmp     al, 17h
        je      near .done
        cmp     al, 1Ah
        je      near .done
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
.done:  ; At most once per tick, on the way out of the outermost INT 10h called with interrupts
        ; enabled (a program, not an interrupt handler that may have interrupted one in the middle
        ; of an attribute controller sequence), re-read the attribute controller while SVGA is on:
        ; programs that change it (palette registers, blink bit) through the ports are followed
        ; as soon as they call INT 10h again (e.g. to move the cursor).
        cmp     byte [in10], 1
        jne     short .nochk
        cmp     byte [enabled], 0
        je      short .nochk
        test    byte [bp + 47], 02h     ; caller IF
        jz      short .nochk
        xor     ax, ax
        mov     es, ax
        mov     ax, [es:46Ch]
        cmp     ax, [atick]
        je      short .nochk
        mov     [atick], ax
        push    cs
        pop     es
        call    rdattr
        call    chkpal
.nochk: pop     es
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
        jne     short .win
        mov     al, 0FFh
        mov     bx, MUX_SIG
        push    cs
        pop     es
        iret
        ; Windows 3.x (INT 2Fh AX=1605h, enhanced/standard mode starting): SVGA2X steps aside for
        ; good.  Under MS EMM386, INT 15h AH=87h moves into the framebuffer above its first 4 MB
        ; triple-faulted the VM after Windows had been started and exited (not always the first
        ; time), whether or not SVGA2X had been active while Windows ran.  The normal VGA picture
        ; is shown from then on; run SVGA2X /U and SVGA2X again to get 2x back (at your own risk).
.win:   cmp     ax, 1605h
        jne     short .chain
        mov     byte [cs:winpause], 1
.chain: jmp     far [cs:old2f]

;--------------------------------------------------------------------------------------------------
; work: one update pass.  DS=ES=CS, IF=1.
;--------------------------------------------------------------------------------------------------
work:   cmp     byte [winpause], 0      ; Windows is starting or exiting
        jne     near .ret
        smsw    ax
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
.en:    cmp     byte [mirror], 0        ; DAC changed through the ports (e.g. a fade)?
        je      short .nomir
        call    chkpal
.nomir: cmp     byte [paldirty], 0
        je      near .np
        mov     byte [force], 1
        mov     byte [paldirty], 0
.np:    cmp     byte [v86], 0
        jne     near .nour
        call    unreal
.nour:  cmp     byte [curmode], 2
        je      near textpass
        xor     bp, bp                  ; BP = line

.line:  test    bp, CH_LINES-1
        jne     near .noread
        ; ---- VGA addresses of the next CH_LINES lines: start + y * stride, and from the line
        ;      after the line compare on, (y - LC - 1) * stride (DOS/V hardware scroll) ----
        xor     si, si
.la:    mov     ax, bp
        add     ax, si
        cmp     ax, [lcmp]
        jbe     short .la1
        sub     ax, [lcmp]
        dec     ax
        mul     word [gstride]
        jmp     short .la2
.la1:   mul     word [gstride]
        add     ax, [crtstart]
.la2:   mov     di, si
        shl     di, 1
        mov     [laddr + di], ax
        inc     si
        cmp     si, CH_LINES
        jb      short .la
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
        mov     di, chunk + p*CHUNKSZ
        xor     bx, bx
.r%[p]:  mov     si, [cs:laddr + bx]
        cmp     si, 10000h - 80         ; line runs past the end of the 64K plane: byte copy
        ja      short .w%[p]          ; (SI wraps to 0 like the VGA address counter)
        mov     cx, 20
        rep     movsd
        jmp     short .n%[p]
.w%[p]:  mov     cx, 80
        rep     movsb
.n%[p]:  add     bx, 2
        cmp     bx, CH_LINES*2
        jb      short .r%[p]
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
.next:  inc     bp
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
.fok:   push    ds                      ; BIOS data: tick count (cursor blink)
        xor     ax, ax
        mov     ds, ax
        mov     al, [46Ch]
        pop     ds
        mov     byte [bgmask], 0Fh      ; attribute mode control bit 3 = blink -> 8 background colours
        test    byte [a10], 08h         ; (not the BIOS shadow at 0:465h, which programs that set
        jz      short .nobl             ; the register through the ports do not update)
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
        RDREG   14h, c14
        RDREG   17h, c17
        RDREG   18h, c18
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
        cmp     byte [c13], 28h         ; 80..256 bytes per line (DOS/V with hardware scroll: 128)
        jb      near .bad
        cmp     byte [c13], 80h
        ja      near .bad
        test    byte [c14], 40h         ; byte addressing only (no doubleword mode)
        jne     near .bad
        test    byte [c17], 40h         ; (no word mode)
        je      near .bad
        movzx   ax, byte [c13]
        shl     ax, 1
        mov     [gstride], ax
        xor     ax, ax                  ; line compare: bits 0-7 in 18h, bit 8 in 07h.4, bit 9 in 09h.6
        mov     al, [c18]
        test    byte [c07], 10h
        jz      short .lc8
        or      ah, 1
.lc8:   test    byte [c09], 40h
        jz      short .lc9
        or      ah, 2
.lc9:   mov     [lcmp], ax
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
; getpal: re-read the attribute controller and build pal32[16] (B,G,R,0) from it and the DAC.
;         Called only after the BIOS has returned from INT 10h (and at install), so no BIOS or
;         driver code is in the middle of an attribute controller / DAC sequence.  DS=ES=CS.
;         (Before 0.4.2 it used INT 10h AX=1007h/1015h; VMware's VGA BIOS takes about one frame
;         (16 ms) per call, so the 32 calls took half a second, and DOSSHELL, which calls AH=10h
;         dozens of times, needed 16 s to start instead of 3.)
;--------------------------------------------------------------------------------------------------
getpal: call    rdattr
        mov     di, pal32
        call    mkpal
        mov     byte [paldirty], 1
        ret

;--------------------------------------------------------------------------------------------------
; rdattr: read attribute palette registers 0..0Fh, mode control (10h), colour plane enable (12h)
;         and colour select (14h) into attrp/a10/a12/a14.  Only at a point where nobody is in the
;         middle of an attribute controller sequence (its index/data flip-flop cannot be read
;         back on VMware: CRTC 24h/26h are not implemented).  The palette registers can only be
;         read with PAS (bit 5 of the index) = 0, which blanks the VGA output for a moment
;         (invisible while the SVGA shows our picture); with PAS = 1 every register read back as
;         the same value.  The attribute index is restored and the flip-flop left at index.
;--------------------------------------------------------------------------------------------------
rdattr: pushf
        mov     dx, 3CCh                ; misc output: bit 0 = colour (3DAh) / mono (3BAh) ports
        in      al, dx
        mov     bx, 3BAh
        test    al, 1
        jz      short .mono
        mov     bx, 3DAh
.mono:  cli
        mov     dx, 3C0h                ; current index (with PAS), to restore it at the end
        in      al, dx
        mov     [aidx], al
        mov     di, attrp
        xor     cx, cx
.lp:    mov     al, cl                  ; index, PAS = 0
        call    .rd
        and     al, 3Fh
        stosb
        inc     cx
        cmp     cx, 16
        jb      short .lp
        mov     al, 30h
        call    .rd
        mov     [a10], al
        mov     al, 32h
        call    .rd
        and     al, 0Fh
        mov     [a12], al
        mov     al, 34h
        call    .rd
        mov     [a14], al
        mov     dx, bx                  ; restore the index (and PAS)
        in      al, dx
        mov     dx, 3C0h
        mov     al, [aidx]
        out     dx, al
        mov     dx, bx                  ; leave the flip-flop at index
        in      al, dx
        popf
        ret
.rd:    push    ax                      ; AL = index -> AL = register
        mov     dx, bx                  ; input status 1: reset the flip-flop to index
        in      al, dx
        pop     ax
        mov     dx, 3C0h
        out     dx, al
        inc     dx                      ; 3C1h: read
        in      al, dx
        ret

;--------------------------------------------------------------------------------------------------
; mkpal: build 16 colours (B,G,R,0) at ES:DI from attrp/a10/a12/a14 and the DAC.  Pixel value i
;        -> palette register (i AND colour plane enable) -> DAC index (colour select bits 7-6,
;        and bits 5-4 too when mode control bit 7 is set).  The DAC is read from the VMware SVGA
;        palette registers, which mirror it (checked at install), when possible: that does not
;        disturb a DAC read/write sequence the foreground may be in the middle of, so it is safe
;        in the timer interrupt.  Otherwise through the VGA ports (INT 10h context only).
;--------------------------------------------------------------------------------------------------
mkpal:  xor     si, si
.lp:    mov     bx, si
        and     bl, [a12]
        mov     bl, [attrp + bx]
        mov     al, [a14]
        mov     ah, al
        and     ah, 0Ch
        shl     ah, 4                   ; colour select bits 3-2 -> DAC index bits 7-6
        test    byte [a10], 80h
        jz      short .n54
        and     bl, 0Fh                 ; P5,P4 from colour select bits 1-0
        and     al, 03h
        shl     al, 4
        or      bl, al
        jmp     short .ix
.n54:   and     bl, 3Fh
.ix:    or      bl, ah                  ; BL = DAC index
        cmp     byte [mirror], 0
        je      short .vga
        movzx   bx, bl
        imul    bx, bx, 3
        add     bx, SVGA_PALETTE_BASE
        mov     ax, bx
        call    svga_in
        mov     cl, al                  ; R
        lea     ax, [bx + 1]
        call    svga_in
        mov     ch, al                  ; G
        lea     ax, [bx + 2]
        call    svga_in                 ; AL = B
        jmp     short .st
.vga:   pushf
        cli
        mov     dx, 3C7h                ; DAC read index
        mov     al, bl
        out     dx, al
        mov     dx, 3C9h                ; R, G, B (6 bit)
        in      al, dx
        mov     cl, al
        in      al, dx
        mov     ch, al
        in      al, dx
        popf
.st:    and     al, 3Fh
        call    sc6                     ; B
        stosb
        mov     al, ch                  ; G
        and     al, 3Fh
        call    sc6
        stosb
        mov     al, cl                  ; R
        and     al, 3Fh
        call    sc6
        stosb
        xor     al, al
        stosb
        inc     si
        cmp     si, 16
        jb      near .lp
        ret

;--------------------------------------------------------------------------------------------------
; chkpal: rebuild the colours; if they differ from pal32, take them and redraw everything.
;         DS=ES=CS, DF=0.
;--------------------------------------------------------------------------------------------------
chkpal: mov     di, paltmp
        call    mkpal
        mov     si, paltmp
        mov     di, pal32
        mov     cx, 16
        repe    cmpsd
        je      short .same
        mov     si, paltmp
        mov     di, pal32
        mov     cx, 16
        rep     movsd
        mov     byte [force], 1
.same:  ret

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
mv87:   ; V86: INT 15h AH=87h.  The descriptor table is rebuilt for every call: the BIOS / memory
        ; manager fills in the GDT, CS and SS entries, and values left there by Windows 3.x (which
        ; serves INT 15h AH=87h while it runs) made the next call after Windows had exited
        ; triple-fault the VM.  ES = CS.
        push    di
        push    cx
        push    eax
        mov     di, g87
        xor     eax, eax
        mov     cx, 12
        rep     stosd
        mov     word [g87 + 10h], 0FFFFh        ; source: limit, base = linebuf, data r/w
        mov     word [g87 + 18h], 0FFFFh        ; destination: limit, base = EAX, data r/w
        mov     byte [g87 + 15h], 93h
        mov     byte [g87 + 1Dh], 93h
        mov     eax, [srclin]
        mov     [g87 + 12h], ax
        shr     eax, 16
        mov     [g87 + 14h], al
        mov     [g87 + 17h], ah
        pop     eax
        pop     cx
        pop     di
        mov     [g87 + 1Ah], ax
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
srclin  dd      0                       ; linear address of linebuf (INT 15h/87h source)
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
gstride dw      80                      ; graphics: bytes per line in VGA memory
lcmp    dw      3FFh                    ; graphics: CRTC line compare
laddr   times CH_LINES dw 0
busy    db      0
winpause db     0                       ; set while Windows switches modes (INT 2Fh 1605h..1608h, 1609h..1606h)
act     db      0                       ; INT 10h was called since the last pass
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
c14     db      0
c17     db      0
c18     db      0
c0c     db      0
c0d     db      0
c09     db      0
        align   4, db 0
pal32   times 16 dd 0
paltmp  times 16 dd 0
attrp   times 16 db 0                   ; attribute palette registers 0..0Fh
a10     db      0Ch                     ; attribute mode control (bit 3: blink, bit 7: P5/P4 select)
a12     db      0Fh                     ; colour plane enable
a14     db      0                       ; colour select
aidx    db      0
mirror  db      0                       ; the SVGA palette registers mirror the VGA DAC
        align   2, db 0
atick   dw      0                       ; tick of the last attribute re-read at the end of INT 10h
        align   4, db 0
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
        ; ---- command line: /U, /Sn, /Rn (none: show the status) ----
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
        mov     byte [f_s], 1
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
        mov     byte [f_r], 1
        jmp     short .pa
.paend: cmp     byte [f_r], 0           ; /Rn only together with /S2 or /S3
        je      short .rok
        cmp     byte [f_s], 0
        je      near e_rneed
.rok:
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
        cmp     byte [f_s], 0
        je      near status
        PRINT   m_already
        jmp     near exit1
.notinst:
        cmp     byte [f_s], 0
        jne     near .doinst
        PRINT   m_notinst
        cmp     byte [f_u], 0
        jne     near exit1
        PRINT   m_hint
        mov     ax, 4C00h
        int     21h

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
        call    mirchk
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
        mov     [srclin], eax
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

;--------------------------------------------------------------------------------------------------
; Status of the resident copy (segment in [rseg])
;--------------------------------------------------------------------------------------------------
status: mov     es, [rseg]
        PRINT   m_st1                   ; "Resident: "
        movzx   ax, byte [es:scale]
        call    pdec
        PRINT   m_st2                   ; "x, update every "
        movzx   ax, byte [es:rate]
        call    pdec
        mov     dx, m_st3               ; " tick." / " ticks."
        cmp     byte [es:rate], 1
        je      short .t1
        mov     dx, m_st3s
.t1:    mov     ah, 9
        int     21h
        cmp     byte [es:winpause], 0
        je      short .nw
        PRINT   m_stwin
        jmp     short .done
.nw:    cmp     byte [es:enabled], 0
        jne     short .en
        PRINT   m_stoff
        jmp     short .done
.en:    PRINT   m_ston                  ; "Display:  "
        movzx   cx, byte [es:scale]
        mov     ax, [es:curw]
        mul     cx
        call    pdec
        mov     dl, 'x'
        mov     ah, 2
        int     21h
        movzx   cx, byte [es:scale]
        mov     ax, [es:curv]
        mul     cx
        call    pdec
        mov     dx, m_stgr
        cmp     byte [es:curmode], 1
        je      short .p
        mov     dx, m_sttx
.p:     mov     ah, 9
        int     21h
.done:  mov     ax, 4C00h
        int     21h

; pdec: print AX in decimal
pdec:   xor     cx, cx
        mov     bx, 10
.d:     xor     dx, dx
        div     bx
        push    dx
        inc     cx
        test    ax, ax
        jnz     short .d
.o:     pop     dx
        add     dl, '0'
        mov     ah, 2
        int     21h
        loop    .o
        ret

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
e_rneed: PRINT  m_rneed
        jmp     near exit1
e_scale: PRINT  m_scale
        jmp     near exit1
e_size: PRINT   m_size
        jmp     near exit1

; t87: EBX = source physical address, EDX = destination physical address, CX = words; CF on error
; mirchk: do the VMware SVGA palette registers mirror the VGA DAC?  DAC entry 255 (not used by
;         the 16-colour and text modes) is changed through the ports, compared with the SVGA
;         register, and restored.  Sets [mirror].
mirchk: cli
        mov     dx, 3C7h
        mov     al, 0FFh
        out     dx, al
        mov     dx, 3C9h
        mov     di, dsav
        mov     cx, 3
.m1:    in      al, dx
        and     al, 3Fh
        stosb
        loop    .m1
        mov     bl, 3Fh                 ; write the complement of each component
        call    .put
        call    .cmp
        mov     [mirror], al
        xor     bl, bl                  ; restore
        call    .put
        call    .cmp
        and     [mirror], al
        sti
        ret
.put:   mov     dx, 3C8h
        mov     al, 0FFh
        out     dx, al
        inc     dx
        mov     si, dsav
        mov     cx, 3
.p1:    lodsb
        xor     al, bl
        out     dx, al
        loop    .p1
        ret
.cmp:   mov     si, dsav                ; AL = 1 if SVGA regs = dsav XOR BL
        mov     di, SVGA_PALETTE_BASE + 255*3
        mov     cx, 3
.c1:    mov     ax, di
        call    svga_in
        and     al, 3Fh
        mov     ah, [si]
        xor     ah, bl
        cmp     al, ah
        jne     short .c0
        inc     si
        inc     di
        loop    .c1
        mov     al, 1
        ret
.c0:    xor     al, al
        ret
dsav    db      0, 0, 0

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
f_s     db      0
f_r     db      0

m_title   db 'SVGA2X 0.4.2 - VGA graphics and 80-column text at 2x/3x on VMware SVGA II', 13, 10
          db '(c) 2026 Kenji Morimoto <github@morimoto.ne.jp>', 13, 10, '$'
m_inst    db 'Now resident.', 13, 10, '$'
m_help    db 'Usage: SVGA2X [/S2 | /S3 [/Rn] | /U]', 13, 10
          db '  (none)  show the status', 13, 10
          db '  /S2     stay resident, 2x (1280x960)', 13, 10
          db '  /S3     stay resident, 3x (1920x1440)', 13, 10
          db '  /Rn     (with /S2 or /S3) update every n ticks, n = 1..9 (default 1 = 18.2/s)', 13, 10
          db '  /U      remove from memory', 13, 10
          db 'Works in real mode (HIMEM only) and under EMM386 / JEMMEX (V86 mode).', 13, 10, '$'
m_already db 'Already resident.', 13, 10, '$'
m_notinst db 'Not resident.', 13, 10, '$'
m_hint    db 'To make it resident: SVGA2X /S2 (2x) or /S3 (3x).  Help: SVGA2X /?', 13, 10, '$'
m_st1     db 'Resident: $'
m_st2     db 'x, update every $'
m_st3     db ' tick.', 13, 10, '$'
m_st3s    db ' ticks.', 13, 10, '$'
m_ston    db 'Display:  $'
m_stgr    db ' (VGA graphics).', 13, 10, '$'
m_sttx    db ' (text).', 13, 10, '$'
m_stoff   db 'Display:  normal (this screen mode is not supported).', 13, 10, '$'
m_stwin   db 'Display:  normal (dormant since Windows started; /U, then /S2 or /S3 resumes).', 13, 10, '$'
m_rneed   db 'Error: /R needs /S2 or /S3.', 13, 10, '$'
m_removed db 'Removed from memory.', 13, 10, '$'
m_cant    db 'Cannot remove: vectors hooked by another program.', 13, 10, '$'
m_v86ok   db 'V86 mode: framebuffer access via INT 15h AH=87h verified.', 13, 10, '$'
m_87      db 'Error: INT 15h AH=87h cannot reach the framebuffer (V86 mode).', 13, 10, '$'
m_nodev   db 'Error: VMware SVGA II not found.', 13, 10, '$'
m_id      db 'Error: unexpected SVGA ID or framebuffer address.', 13, 10, '$'
m_scale   db 'Error: /S must be 2 or 3.', 13, 10, '$'
m_size    db 'Error: the VM does not allow this resolution (maximum size or VRAM too small).', 13, 10
          db '       Check svga.autodetect, svga.maxWidth/Height, svga.vramSize in the .vmx.', 13, 10, '$'
