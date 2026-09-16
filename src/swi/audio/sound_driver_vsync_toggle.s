@ SPDX-License-Identifier: LGPL-3.0-or-later
@ SoundDriverVSyncOff (SWI 0x28): stop the BIOS sound driver for one frame.
@
@ Entry:  none (SoundInfo from [SOUND_INFO_PTR])
@ Return: nothing defined; r0/r1/r3 handler scratch, r2 dispatcher-restored.
@
@ Checks the ident (SOUND_IDENT). On a good ident, lock it, stop FIFO DMA1/DMA2,
@ clear pcmDmaCounter (+0x04), zero the PCM mix buffer (+0x350, 0xc60 = 2 * 0x630 bytes),
@ then restore the ident word.
.thumb
swi_SoundDriverVSyncOff:
    ldr r1, =SOUND_INFO_PTR
    ldr r0, [r1]
    ldr r1, =SOUND_IDENT
    ldr r2, [r0]
    @ Timing note: shared fixed cost prologue pad
    movs r3, #3
.vsoff_pad1:
    subs r3, r3, #1
    bgt  .vsoff_pad1
    nop
    nop
    nop
    cmp  r2, r1
    bne  .vsoff_ret
    @ Timing note: fixed cost pad
    movs r3, #16
.vsoff_pad2:
    subs r3, r3, #1
    bgt  .vsoff_pad2
    nop
    nop
    movs r2, #0
    str  r2, [r0]
    ldr  r1, =REG_DMA1CNT_L
    str  r2, [r1]
    str  r2, [r1, #0x0c]
    strb r2, [r0, #0x04]
    movs r1, #0x35
    lsls r1, r1, #4
    adds r1, r1, r0
    movs r3, #0xc6
    lsls r3, r3, #4
.vsoff_clear:
    str  r2, [r1]
    adds r1, r1, #4
    subs r3, r3, #4
    bgt  .vsoff_clear
    ldr  r1, =SOUND_IDENT
    str  r1, [r0]
.vsoff_ret:
    bx lr

@ SoundDriverVSyncOn (SWI 0x29): re-enable the FIFO DMA channels using the SAD/DAD already
@ programmed by SoundDriverInit.
@
@ Entry:  none
@ Return: nothing defined; r0/r2 handler scratch.
@
@ The call is unconditional and does not read SoundInfo. It normally follows VSyncOff +
@ VBlankIntrWait, so the channels are already stopped. Writes 0xb6000000 (enable | FIFO start
@ timing | 32-bit | repeat) to DMA1CNT and DMA2CNT. SAD/DAD and the SoundInfo work area are
@ left untouched.
swi_SoundDriverVSyncOn:
    ldr  r0, =REG_DMA1CNT_L
    movs r2, #0xb6
    lsls r2, r2, #24
    @ Timing note: build the enable word by shift
    str r2, [r0]
    str r2, [r0, #0x0c]
    bx  lr
