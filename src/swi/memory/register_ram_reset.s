@ SPDX-License-Identifier: LGPL-3.0-or-later
@ RegisterRamReset (SWI 0x01), Thumb: clears RAM regions and resets IO ports by flag.
@
@ Entry:  r0 = ResetFlags: bit0 EWRAM, bit1 IWRAM, bit2 Palette, bit3 VRAM, bit4 OAM, bit5 SIO,
@         bit6 Sound, bit7 other IO
@ Return: no result registers (r0 ends as handler scratch); r1-r7 saved/restored, r2/r11/r12
@ dispatcher-restored.
@
@ Clears run in this order: other IO, sound, SIO, EWRAM, Palette, VRAM, OAM, then IWRAM
@ last. IWRAM must be last because it holds the live BIOS stack, and its clear stops at
@ 0x7e00 so the top 0x200 bytes (BIOS stack reserve) survive.
@
@ DISPCNT is forced blank at entry, re-blanked after the other-IO clear zeroes it, and blanked
@ again unconditionally at the end, so the display stays blank across the whole SWI. The blank
@ freezes the renderer on the caller's own pre-reset frame.
@
@ Stack bytes below the caller's SP are undefined scratch and are not part of the contract.
@
@ Timing note: each region is padded to a fixed per region cost, set by the TR_* constants. In the
@ other-IO region the IRQ and affine writes happen before the DMA/timer clear, so a running Timer0
@ freezes its counter at the disable write near the end of that region.
@
@ TPAD loop,nops expands to `movs r3,#loop` then `bl t_pad4` (~4 cyc/iter) plus `nops` filler movs.
.equ TR_ALWAYS_L,    15
.equ TR_ALWAYS_N,    0
.equ TR_OTHER_MID_L, 40
.equ TR_OTHER_MID_N, 0
.equ TR_OTHER_L,     1
.equ TR_OTHER_N,     3
.equ TR_SND_L,       14
.equ TR_SND_N,       2
.equ TR_SIO_L,       5
.equ TR_SIO_N,       2
.equ TR_EWRAM_L,     0
.equ TR_EWRAM_N,     1
.equ TR_PAL_L,       0
.equ TR_PAL_N,       1
.equ TR_VRAM_L,      0
.equ TR_VRAM_N,      1
.equ TR_OAM_L,       0
.equ TR_OAM_N,       1
.equ TR_IWRAM_L,     0
.equ TR_IWRAM_N,     1

.macro TPAD loop, nops
.if \loop > 0
    movs r3, #\loop
    bl   t_pad4
.endif
.rept \nops
    nop
.endr
.endm

.align 2
.thumb
@ swi_table adds the Thumb bit explicitly to this plain label's BIOS-relative offset.
swi_RegisterRamReset:
    @ r12 holds the return address (the dispatcher clobbers r12 after us).
    mov  r12, lr
    push {r1-r7}
    adds r4, r0, #0
    movs r0, #0
    push {r0}
    mov  r0, sp                 @ r0 = &zero: fixed valid source for the CpuFastSet fills
    ldr  r5, =swi_CpuFastSet_nv @ cached CpuFastSet_nv entry (preserves r4-r11, so r5 survives the t_cfs calls)
    movs r1, #4
    lsls r1, r1, #24
    movs r2, #0x80
    strh r2, [r1, #0]           @ DISPCNT = 0x80: forced blank for the whole SWI
    @ ---- other IO (bit 7, tested via N) ----
    lsls r3, r4, #24
    bpl  .t_no_other
    movs r1, #4
    lsls r1, r1, #24
    ldr  r2, =0x01000018
    bl   t_cfs
    subs r1, #0x60
    movs r2, #0x80
    strh r2, [r1, #0]
    TPAD TR_OTHER_MID_L, TR_OTHER_MID_N
    ldr  r1, =REG_IE
    movs r2, #0
    str  r2, [r1, #0]    @ IE/IF = 0
    str  r2, [r1, #4]    @ WAITCNT = 0: back to slow ROM waits (game-visible fetch timing)
    str  r2, [r1, #8]    @ IME = 0
    movs r1, #4
    lsls r1, r1, #24
    movs r2, #0x80
    lsls r2, r2, #1
    strh r2, [r1, #0x20] @ BG2PA/PD, BG3PA/PD = 0x100 (identity scale)
    strh r2, [r1, #0x26]
    strh r2, [r1, #0x30]
    strh r2, [r1, #0x36]
    @ POSTFLG/HALTCNT are left alone. Writing HALTCNT here would halt the CPU.
    adds r1, #0xb0
    ldr  r2, =0x01000018
    bl   t_cfs @ clear DMA/timer block 0xb0..0x10f (Timer0 disable lands here)
    TPAD TR_OTHER_L, TR_OTHER_N
.t_no_other:
    @ ---- sound (bit 6) ----
    lsls r3, r4, #25
    bpl  .t_no_snd
    ldr  r1, =0x04000060
    ldr  r2, =0x01000008
    bl   t_cfs
    subs r1, #0x20       @ base 0x04000060 (all offsets below fit a Thumb strh imm)
    movs r2, #0
    strh r2, [r1, #0x20] @ SOUNDCNT_L/_H/_X = 0
    strh r2, [r1, #0x22]
    strh r2, [r1, #0x24]
    movs r3, #0x80
    strh r3, [r1, #0x24] @ then SOUNDCNT_X = 0x80: sound enable on, so Wave RAM below is writable
    @ Zero Wave RAM 0x90-0x9f in both banks. The writable bank is the one not selected in SOUND3CNT_L.
    strh r2, [r1, #0x10]
    strh r2, [r1, #0x30]
    strh r2, [r1, #0x32]
    strh r2, [r1, #0x34]
    strh r2, [r1, #0x36]
    strh r2, [r1, #0x38]
    strh r2, [r1, #0x3a]
    strh r2, [r1, #0x3c]
    strh r2, [r1, #0x3e]
    movs r3, #0x40
    strh r3, [r1, #0x10]
    strh r2, [r1, #0x30]
    strh r2, [r1, #0x32]
    strh r2, [r1, #0x34]
    strh r2, [r1, #0x36]
    strh r2, [r1, #0x38]
    strh r2, [r1, #0x3a]
    strh r2, [r1, #0x3c]
    strh r2, [r1, #0x3e]
    ldrh r3, [r1, #0x28] @ SOUNDBIAS: clear the amplitude-cycle bits, keep the level
    movs r6, #0xfc
    lsls r6, r6, #8
    bics r3, r6
    strh r3, [r1, #0x28]
    movs r3, #0x70
    strh r3, [r1, #0x10] @ SOUND3CNT_L = 0x70
    movs r2, #0
    strh r2, [r1, #0x24] @ SOUNDCNT_X sound enable back off
    TPAD TR_SND_L, TR_SND_N
.t_no_snd:
    @ ---- SIO (bit 5) ----
    lsls r3, r4, #26
    bpl  .t_no_sio
    ldr  r1, =REG_SIO_BASE
    ldr  r2, =0x01000020
    bl   t_cfs
    ldr  r1, =0x04000110
    movs r2, #0x80
    lsls r2, r2, #8
    strh r2, [r1, #0x24] @ RCNT = 0x8000 (general-purpose mode)
    movs r2, #7
    strh r2, [r1, #0x30] @ JOYCNT: ack the three write-1-to-clear flags
    TPAD TR_SIO_L, TR_SIO_N
.t_no_sio:
    @ ---- EWRAM (bit 0) ----
    lsls r3, r4, #31
    bpl  .t_no_ewram
    movs r1, #2
    lsls r1, r1, #24
    ldr  r2, =0x0100ffff @ fill 0xffff words (CpuFastSet rounds the count up to a multiple of 8)
    bl   t_cfs
    TPAD TR_EWRAM_L, TR_EWRAM_N
.t_no_ewram:
    @ ---- Palette (bit 2) ----
    lsls r3, r4, #29
    bpl  .t_no_pal
    movs r1, #5
    lsls r1, r1, #24
    ldr  r2, =0x01000100
    bl   t_cfs
    TPAD TR_PAL_L, TR_PAL_N
.t_no_pal:
    @ ---- VRAM (bit 3) ----
    lsls r3, r4, #28
    bpl  .t_no_vram
    movs r1, #6
    lsls r1, r1, #24
    ldr  r2, =0x01006000
    bl   t_cfs
    TPAD TR_VRAM_L, TR_VRAM_N
.t_no_vram:
    @ ---- OAM (bit 4) ----
    lsls r3, r4, #27
    bpl  .t_no_oam
    movs r1, #7
    lsls r1, r1, #24
    ldr  r2, =0x01000100
    bl   t_cfs
    TPAD TR_OAM_L, TR_OAM_N
.t_no_oam:
    @ ---- IWRAM (bit 1, last. Never clears 0x7e00-0x7fff) ----
    lsls r3, r4, #30
    bpl  .t_no_iwram
    movs r1, #3
    lsls r1, r1, #24
    ldr  r2, =0x01001f80
    bl   t_cfs
    TPAD TR_IWRAM_L, TR_IWRAM_N
.t_no_iwram:
    movs r1, #4
    lsls r1, r1, #24
    movs r2, #0x80
    strh r2, [r1] @ DISPCNT = 0x80 once more (unconditional)
    TPAD TR_ALWAYS_L, TR_ALWAYS_N
    add  sp, #4
    pop  {r1-r7}
    bx   r12
t_cfs:            @ Thumb->ARM tail-call into CpuFastSet through r5. Its bx lr returns
    bx   r5       @ to the bl site (lr carries the Thumb bit)
t_pad4:
.t_pad4_loop:
    subs r3, #1
    bne  .t_pad4_loop
    bx   lr
    .ltorg

@ The boot path runs this same handler via `swi #0x010000` (see entrypoint.s) instead of a second
@ RAM-clear copy. The SWI forces blank at entry rather than at the end, which changes the clear's
@ PPU-contention trajectory, so the cart-handoff cycle is re-pinned by the recal burn (calibration.s).
