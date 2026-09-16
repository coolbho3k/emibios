@ SPDX-License-Identifier: LGPL-3.0-or-later
@ SoundDriverInit (SWI 0x1a): set up the BIOS sound driver in a caller-provided work area.
@
@ Entry:  r0 = SoundInfo work area (prior content ignored)
@ Return: r0 = the ident word ('Smsh'), r1 = 0x9f, r3 = 0x170 as residues.
@
@ Zero the whole 0xfb0-byte struct, write the default header (ident, maxChans 8,
@ mainVolume 15, freq index 4, and the freq-index-4 PCM constants), install six
@ "do nothing" callback/jump pointers at +0x28..+0x3c (+0x24 stays zero), publish the
@ work pointer at SOUND_INFO_PTR, set SOUNDCNT_H = 0x210e / SOUNDCNT_X = 0x80 /
@ SOUNDBIAS = 0x4200, program and arm the FIFO DMA (DMA1/DMA2 SAD = mix-buffer
@ halves at +0x350/+0x980, DAD = FIFO A/B, control 0xb6000000), and start Timer0.
@
@ The routine then busy waits to a fixed PPU scanline before returning.
.thumb
.set INIT_WORK_PAD, 6
swi_SoundDriverInit:
    adds r1, r0, #0
    movs r2, #0
    movs r3, #0xfb
    lsls r3, r3, #4
.init_zero:
    str  r2, [r1]
    adds r1, r1, #4
    subs r3, r3, #4
    bgt  .init_zero
    ldr  r1, =SOUND_IDENT
    str  r1, [r0, #0x00]
    movs r1, #8
    strb r1, [r0, #0x06]
    movs r1, #15
    strb r1, [r0, #0x07]
    movs r1, #4
    strb r1, [r0, #0x08]
    movs r1, #7
    strb r1, [r0, #0x0b]
    movs r1, #0xe0
    str  r1, [r0, #0x10]
    ldr  r1, =0x3443
    str  r1, [r0, #0x14]
    ldr  r1, =0x273
    str  r1, [r0, #0x18]
    ldr  r1, =swi_DoNothing + 1
    str  r1, [r0, #0x28]
    str  r1, [r0, #0x2c]
    str  r1, [r0, #0x30]
    str  r1, [r0, #0x34]
    str  r1, [r0, #0x38]
    str  r1, [r0, #0x3c]
    ldr  r1, =SOUND_INFO_PTR
    str  r0, [r1]
    ldr  r1, =REG_SOUNDCNT_L
    ldr  r2, =0x210e
    strh r2, [r1, #0x02]
    movs r2, #0x80
    strh r2, [r1, #0x04]
    ldr  r2, =0x4200
    strh r2, [r1, #0x08]
    ldr  r1, =REG_DMA1SAD
    movs r2, #0x35
    lsls r2, r2, #4
    adds r2, r2, r0
    str  r2, [r1, #0x00]
    ldr  r2, =REG_FIFO_A
    str  r2, [r1, #0x04]
    movs r2, #0x98
    lsls r2, r2, #4
    adds r2, r2, r0
    str  r2, [r1, #0x0c]
    ldr  r2, =REG_FIFO_B
    str  r2, [r1, #0x10]
    movs r2, #0xb6
    lsls r2, r2, #24
    str  r2, [r1, #0x08]
    str  r2, [r1, #0x14]
    ldr  r1, =0x0080fb1a
    ldr  r2, =REG_TM0CNT_L
    str  r1, [r2]
    @ Sound setup VBlank sync
    ldr r1, =REG_VCOUNT
    @ Target is VCount==159, the last visible scanline just before VBlank at 160.
.init_vwait:
    ldrb r2, [r1]
    cmp  r2, #159
    @ level poll: proceed the moment VCount==159
    bne  .init_vwait
    movs r3, #INIT_WORK_PAD @ Timing note: post poll settle
.init_wp:
    subs r3, r3, #1
    bgt  .init_wp
    @ Return residue: callers read these back after the Init wrapper. r0 = ident,
    @ r1 = 0x9f, r3 = 0x170.
    ldr  r0, =SOUND_IDENT
    movs r1, #0x9f
    ldr  r3, =0x170
    bx   lr
    .ltorg
