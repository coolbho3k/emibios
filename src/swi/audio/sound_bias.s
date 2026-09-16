@ SPDX-License-Identifier: LGPL-3.0-or-later
@ SoundBias (SWI 0x19): ramps the SOUNDBIAS bias field toward a target level at one unit per step.
@
@ Entry:  r0 = target select (0 picks bias 0x000, nonzero picks 0x200)
@         r1 = delay count, ignored on GBA
@ Return: r1 = the final SOUNDBIAS value. r0/r3 handler scratch, r2 dispatcher restored.
@
@ SOUNDBIAS is at REG_SOUNDBIAS, bias field in bits 0-9. This reads the current value, keeps the
@ upper bits, builds the target full value, then walks the low field one unit per step,
@ storing each intermediate value. The ramp direction is computed from cur vs target, so it
@ always terminates. Real SOUNDBIAS values are even and one of 0x000/0x200/0x4200, so the
@ one unit ramp lands exactly on target. An odd start, or a start above 0x200, is outside the
@ supported input range. Everything fits in r0-r3, so there is no stack frame.
@
@ Timing note: each step has a fixed cost. The up ramp runs at 31 cycles per step. The down
@ ramp cannot match the hardware bias write phase exactly, so its step cost runs a touch
@ short.
.thumb
.set SB_DELAY, 6
swi_SoundBias:
    ldr  r2, =REG_SOUNDBIAS
    ldrh r1, [r2]
    adds r3, r1, #0
    lsrs r3, r3, #10
    lsls r3, r3, #10
    cmp  r0, #0
    beq  .sb_have
    movs r0, #0x80
    lsls r0, r0, #2
    orrs r3, r0
.sb_have:
    adds r2, r2, #0 @ Timing note: setup cycle pad
    adds r2, r2, #0
    cmp  r1, r3
    beq  .sb_done
    bhi  .sb_dn
.sb_up:
    adds r1, #1
    strh r1, [r2]
    adds r2, r2, #0 @ Timing note: up ramp cycle pad
    movs r0, #SB_DELAY
.sb_udl:
    subs r0, #1
    bne  .sb_udl
    cmp  r1, r3
    bne  .sb_up
    b    .sb_done
.sb_dn:
    subs r1, #1
    strh r1, [r2]
    adds r2, r2, #0 @ Timing note: down ramp cycle pad
    movs r0, #SB_DELAY
.sb_ddl:
    subs r0, #1
    bne  .sb_ddl
    cmp  r1, r3
    bne  .sb_dn
.sb_done:
    bx lr
