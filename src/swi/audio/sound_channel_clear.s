@ SPDX-License-Identifier: LGPL-3.0-or-later
@ SoundChannelClear (SWI 0x1e): stops all 12 DirectSound channels for the active SoundInfo.
@
@ Entry:  none (SoundInfo from [SOUND_INFO_PTR])
@ Return: r3 preserved on every path; r0/r1 handler scratch, r2 dispatcher-restored.
@
@ If the ident word is not SOUND_IDENT, return without touching anything.
@
@ Writes 0 to the status byte (offset 0) of all 12 channel structs at SoundInfo+0x50,
@ stride 0x40. Count is a fixed 12, independent of maxChans.
.thumb
swi_SoundChannelClear:
    ldr  r0, =SOUND_INFO_PTR
    ldr  r0, [r0]
    movs r2, #4 @ Timing note: prologue pad
.scc_pad0:
    subs r2, r2, #1
    bgt  .scc_pad0
    ldr  r1, =SOUND_IDENT
    ldr  r2, [r0]
    cmp  r2, r1
    bne  .scc_ret
    movs r2, #13
.scc_pad1:
    subs r2, r2, #1
    bgt  .scc_pad1
    movs r1, #0
    adds r0, #0x50
    movs r2, #12
.scc_loop:
    strb r1, [r0]
    adds r0, #0x40
    subs r2, r2, #1
    bgt  .scc_loop
.scc_ret:
    bx lr
    .ltorg
