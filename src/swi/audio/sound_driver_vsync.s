@ SPDX-License-Identifier: GPL-3.0-or-later
@ SoundDriverVSync (SWI 0x1d): called once per VBlank. Counts down the PCM DMA, and restarts
@ the FIFOs when it expires.
@
@ Entry:  none (SoundInfo from [SOUND_INFO_PTR])
@ Return: r3 = the ident word read, as residue. r1 preserved when ident mismatch.
@
@ If the ident word is not SOUND_IDENT, return without touching anything.
@
@ Valid path: decrement pcmDmaCounter (+0x04). While the signed result stays > 0, store it
@ and return. When it reaches <= 0, reload it from pcmDmaPeriod (+0x0b) and restart the FIFO
@ DMA.
.thumb
swi_SoundDriverVSync:
    ldr  r0, =SOUND_INFO_PTR
    ldr  r0, [r0]
    ldr  r3, [r0] @ r3 = ident word, left as a residue
    ldr  r2, =SOUND_IDENT
    cmp  r3, r2
    bne  .vsync_ret
    ldrb r1, [r0, #0x04]
    subs r1, r1, #1
    strb r1, [r0, #0x04]
    bgt  .vsync_ret
    ldrb r1, [r0, #0x0b]
    strb r1, [r0, #0x04]
    ldr  r1, =REG_DMA1CNT_L
    movs r2, #0
    str  r2, [r1]
    @ Both FIFOs need the edge so the DMA reloads SAD to the buffer base
    @ on restart. Without it, the left FIFO keeps its drifted SAD and
    @ plays garbage.
    str r2, [r1, #0x0c]
    ldr r2, =0xb6000000
    str r2, [r1]
    str r2, [r1, #0x0c]
    nop @ Timing note: pad the reload+restart path
    nop
.vsync_ret:
    bx lr
