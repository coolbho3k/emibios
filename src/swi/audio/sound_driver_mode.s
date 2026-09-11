@ SPDX-License-Identifier: GPL-3.0-or-later
@ SoundDriverMode (SWI 0x1b): apply a packed mode word to the active SoundInfo.
@
@ Entry:  r0 = packed mode word
@ Return: nothing defined; r4/r5 saved/restored, r0-r3 handler scratch
@
@ Validate the ident (SOUND_IDENT). Invalid = no-op. Fields are applied only if
@ their bits are nonzero. A zero field leaves the prior value.
@   bits 0-7   reverb        -> SoundInfo+0x05 = r0 & 0x7f   (bit7 = apply, not stored)
@   bits 8-11  maxChans      -> SoundInfo+0x06
@   bits 12-15 mainVolume  -> SoundInfo+0x07
@   bits 20-23 DA resolution -> SOUNDBIAS bits 14-15 = (DA-8)<<14 (bias level kept)
@   bits 16-19 freq index 1..12 -> SoundInfo+0x08, plus the per-index table values
@        pcmDmaPeriod(+0x0b) pcmSamplesPerVBlank(+0x10) pcmFreq(+0x14) divFreq(+0x18),
@        and Timer0 (TM0CNT = reload | enable, reload = 0x10000 - round(2^24/pcmFreq)).
@ SOUNDCNT_L/H/X and the FIFO DMA registers are not touched.
.thumb
.set MODE_PAD_PRE,  2
.set MODE_PAD_A,    31
.set MODE_PAD_RAMP, 4546
.set MODE_WORK_PAD, 139
swi_SoundDriverMode:
    push {r4, r5}
    adds r4, r0, #0
    ldr  r0, =SOUND_INFO_PTR
    ldr  r0, [r0]
    ldr  r1, =SOUND_IDENT
    ldr  r2, [r0]
    movs r3, #MODE_PAD_PRE @ Timing note: shared prologue pad
.mode_pad_pre:
    subs r3, r3, #1
    bgt  .mode_pad_pre
    cmp  r2, r1
    bne  .mode_inv
    @ Re-entrancy lock: bump the ident to valid+1 (0x68736d54) for the duration of Mode.
    @ A VSync or Main IRQ landing mid-Mode then reads the bad ident and skips, so it cannot
    @ process an extra sound tick against half updated fields. r0 = SI here.
    adds r2, r1, #1
    str  r2, [r0]
    movs r3, #MODE_PAD_A @ Timing note: valid path field pad
.mode_pad_a:
    subs r3, r3, #1
    bgt  .mode_pad_a
    adds r1, r4, #0
    lsls r2, r1, #24
    beq  .mode_maxch
    movs r2, #0x7f
    ands r1, r2
    strb r1, [r0, #5]
.mode_maxch:
    lsrs r1, r4, #8
    movs r2, #0xf
    ands r1, r2
    beq  .mode_vol
    strb r1, [r0, #6]
.mode_vol:
    lsrs r1, r4, #12
    movs r2, #0xf
    ands r1, r2
    beq  .mode_da
    strb r1, [r0, #7]
.mode_da:
    @ Branchless and constant-time.
    lsrs r1, r4, #20
    movs r2, #0xf
    ands r1, r2
    negs r3, r1
    asrs r3, r3, #31 @ r3 = P = (DA!=0) ? 0xffffffff : 0   (predicate mask)
    subs r1, #8
    lsls r1, r1, #14
    ands r1, r3
    movs r2, #0x3
    lsls r2, r2, #14
    ands r2, r3
    ldr  r5, =REG_SOUNDBIAS
    ldrh r3, [r5]
    bics r3, r2
    orrs r3, r1
    strh r3, [r5]
.mode_freq:
    lsrs r1, r4, #16
    movs r2, #0xf
    ands r1, r2
    beq  .mode_unlock
    cmp  r1, #12
    bls  .mode_freq_ok
    movs r1, #12
.mode_freq_ok:
    strb r1, [r0, #8]
    subs r1, #1
    lsls r2, r1, #3
    lsls r1, r1, #1
    adds r1, r2
    ldr  r2, =mode_freqtable
    adds r2, r1
    ldrh r1, [r2]
    strb r1, [r0, #0x0b]
    ldrh r1, [r2, #2]
    str  r1, [r0, #0x10]
    ldrh r1, [r2, #4]
    str  r1, [r0, #0x14]
    ldrh r1, [r2, #6]
    str  r1, [r0, #0x18]
    ldrh r1, [r2, #8]
    movs r3, #0x80
    lsls r3, r3, #16
    orrs r1, r3
    ldr  r2, =REG_TM0CNT_L
    str  r1, [r2]
    ldr  r2, =REG_VCOUNT
    @ Target is VCount==159, the last visible scanline just before VBlank at 160.
.mode_vwait:
    ldrb r3, [r2]
    cmp  r3, #159
    @ level poll: proceed the moment VCount==159
    bne  .mode_vwait
    movs r3, #MODE_WORK_PAD @ Timing note: post poll settle
.mode_workpad:
    subs r3, r3, #1
    bgt  .mode_workpad
.mode_unlock:
    ldr r0, =SOUND_INFO_PTR
    ldr r0, [r0]
    ldr r1, =SOUND_IDENT
    str r1, [r0]
.mode_ret:
    pop {r4, r5}
    bx  lr
.mode_inv:                     @ invalid-ident exit: no lock was taken, so leave the ident alone
    pop {r4, r5}
    bx  lr
    .ltorg
.align 1
mode_freqtable: @ per freq index 1..12: pcmDmaPeriod, psv, pcmFreq, divFreq, reload
    .hword 16, 0x060, 0x1666, 0x5b7, 0xf492
    .hword 12, 0x084, 0x1ecc, 0x428, 0xf7b0
    .hword 9, 0x0b0, 0x2910, 0x31e, 0xf9c4
    .hword 7, 0x0e0, 0x3443, 0x273, 0xfb1a
    .hword 6, 0x108, 0x3d98, 0x214, 0xfbd8
    .hword 5, 0x130, 0x46ed, 0x1ce, 0xfc64
    .hword 4, 0x160, 0x5220, 0x18f, 0xfce2
    .hword 3, 0x1c0, 0x6886, 0x139, 0xfd8d
    .hword 3, 0x210, 0x7b30, 0x10a, 0xfdec
    .hword 2, 0x260, 0x8dda, 0x0e7, 0xfe32
    .hword 2, 0x2a0, 0x9cc9, 0x0d1, 0xfe5e
    .hword 2, 0x2c0, 0xa440, 0x0c8, 0xfe71

    .ltorg
