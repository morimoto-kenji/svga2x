; SVGA2X - show a DOS/V (VGA 640x480 16-colour planar) screen at 2x on VMware SVGA II
;
; Copyright (c) 2026 SVGA2X contributors
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
MAXLINES  equ   480

; VMware SVGA II registers (index/value port pair at BAR0)
SVGA_REG_ID             equ 0
SVGA_REG_ENABLE         equ 1
SVGA_REG_WIDTH          equ 2
SVGA_REG_HEIGHT         equ 3
SVGA_REG_BITS_PER_PIXEL equ 7
SVGA_REG_BYTES_PER_LINE equ 12
SVGA_REG_FB_START       equ 13
SVGA_REG_FB_OFFSET      equ 14
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
signature db    'SVGA2X01'

;--------------------------------------------------------------------------------------------------
; INT 08h: chain first (EOI is sent by the BIOS), then do the work with interrupts enabled.
;--------------------------------------------------------------------------------------------------
int08:  pushf
        call    far [cs:old08]
        cmp     byte [cs:busy], 0
        jne     near .ret
        cmp     byte [cs:in10], 0       ; never touch the hardware while INT 10h is running
        jne     near .ret
        dec     byte [cs:cnt]
        jne     near .ret
        push    ax
        mov     al, [cs:rate]
        mov     [cs:cnt], al
        pop     ax
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
        mov     [cs:lastax], ax
        mov     [cs:lastbx], bx
        cmp     ah, 0
        je      near .pre
        cmp     ax, 4F02h
        jne     near .go
.pre:   cmp     byte [cs:busy], 0
        jne     near .go
        cmp     byte [cs:enabled], 0
        je      near .go
        call    disable
.go:    pushf
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
        mov     ax, [lastax]
        cmp     ah, 0
        je      near .mode
        cmp     ax, 4F02h
        je      near .vbe
        cmp     ah, 10h                 ; palette functions
        jne     near .done
        call    getpal
        jmp     near .done
.mode:  mov     byte [susp], 0
        mov     byte [force], 1
        call    getpal
        jmp     near .done
.vbe:   mov     byte [force], 1
        mov     byte [susp], 0
        mov     bx, [lastbx]
        and     bx, 1FFh
        cmp     bx, 100h                ; VESA mode -> leave the hardware alone
        jb      near .done
        mov     byte [susp], 1
.done:  pop     es
        pop     ds
        popad
        dec     byte [cs:in10]
        popf
        retf    2

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
.rm:    call    hwchk
        test    al, al
        jne     near .ok
        cmp     byte [enabled], 0       ; not a 640-wide planar mode: show plain VGA
        je      near .ret
        call    disable
        jmp     near .ret
.ok:    cmp     byte [susp], 0
        jne     near .ret
        cmp     byte [enabled], 0
        je      near .doen
        mov     ax, [vlines]
        cmp     ax, [curv]              ; number of lines changed -> set the mode again
        je      near .en
.doen:  call    enable
.en:    cmp     byte [paldirty], 0
        je      near .np
        mov     byte [force], 1
        mov     byte [paldirty], 0
.np:    cmp     byte [v86], 0
        jne     near .nour
        call    unreal
.nour:  mov     ax, [crtstart]
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
        ; ---- convert 640 planar pixels to 1280 32-bit pixels ----
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
        stosd
        stosd
        loop    .bit
        pop     cx
        loop    .col
        movzx   eax, bp                 ; FB address of line 2*y
        shl     eax, 1
        mul     dword [pitch]
        add     eax, [fbbase]
        call    mvline
        add     eax, [pitch]
        call    mvline
.next:  add     word [srcoff], 80
        inc     bp
        cmp     bp, [vlines]
        jb      near .line
        mov     byte [force], 0
.ret:   ret

;--------------------------------------------------------------------------------------------------
; hwchk: AL=1 if the VGA is in a colour, 640-wide, 16-colour planar graphics mode with 350..480
;        visible lines.  Sets [vlines] and [crtstart] (CRTC start address).
;--------------------------------------------------------------------------------------------------
hwchk:  mov     dx, 3CCh                ; misc output: colour (3Dx) addressing?
        in      al, dx
        test    al, 1
        je      near .bad
        cli
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
        mov     al, [t_ci]
        out     dx, al
        sti
        mov     al, [t_g6]              ; graphics mode, memory map A000h/64K
        and     al, 0Dh
        cmp     al, 05h
        jne     near .bad
        test    byte [t_g5], 40h        ; not 256-colour shift mode
        jne     near .bad
        cmp     byte [c01], 4Fh         ; 80 character clocks = 640 pixels
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
        cmp     bx, 350
        jb      near .bad
        cmp     bx, MAXLINES
        ja      near .bad
        cmp     byte [c13], 28h         ; 80 bytes per line
        jne     near .bad
        mov     ah, [c0c]
        mov     al, [c0d]
        mov     [crtstart], ax
        mov     al, 1
        ret
.bad:   xor     al, al
        ret

;--------------------------------------------------------------------------------------------------
; enable: 1280 x (2*vlines) x 32bpp
;--------------------------------------------------------------------------------------------------
enable: SVGA_OUT SVGA_REG_WIDTH, 1280
        mov     ax, [vlines]
        mov     [curv], ax
        movzx   ebx, ax
        shl     ebx, 1
        mov     ax, SVGA_REG_HEIGHT
        call    svga_out
        SVGA_OUT SVGA_REG_BITS_PER_PIXEL, 32
        SVGA_OUT SVGA_REG_ENABLE, 1
        SVGA_IN SVGA_REG_BYTES_PER_LINE
        mov     [pitch], eax
        SVGA_IN SVGA_REG_FB_OFFSET
        add     eax, [fbstart]
        mov     [fbbase], eax
        mov     byte [enabled], 1
        mov     byte [force], 1
        mov     byte [paldirty], 0
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
; mvline: copy linebuf (5120 bytes) to physical address EAX.  Preserves EAX.
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
        mov     cx, 2560
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
        mov     ecx, 1280
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
vlines  dw      0
curv    dw      0
iobase  dw      0
lastax  dw      0
lastbx  dw      0
crtstart dw     0
srcoff  dw      0
busy    db      0
in10    db      0
cnt     db      0
rate    db      0
enabled db      0
susp    db      0
force   db      0
paldirty db     0
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
        align   4, db 0
pal32   times 16 dd 0
hashes  times MAXLINES dd 0
chunk   times 4*CHUNKSZ db 0
linebuf times 1280*4 db 0
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
        ; ---- command line: /U, /Rn ----
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
.notu:  cmp     al, 'R'
        jne     short .pa
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
        ; 2) write a pattern at FB+15 MB (off-screen) and read it back
        LINADDR tbP
        mov     ebx, eax
        mov     edx, [fbstart]
        add     edx, 0F00000h
        mov     cx, 16
        call    t87
        jb      near e_87
        mov     ebx, [fbstart]
        add     ebx, 0F00000h
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
        PRINT   m_inst
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

m_title   db 'SVGA2X 0.1.0 - VGA 640x480 16-colour screen at 2x on VMware SVGA II', 13, 10, '$'
m_inst    db 'Installed.  SVGA2X /U = remove, /Rn = update every n ticks (1-9)', 13, 10, '$'
m_help    db 'Usage: SVGA2X [/U] [/Rn]', 13, 10
          db '  (none)  install resident', 13, 10
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
