@ SPDX-License-Identifier: LGPL-3.0-or-later
@ SoundBias (SWI 0x19): ramps the SOUNDBIAS bias field toward a target level at two units per step.
@
@ Entry:  r0 = target select (0 picks bias 0x000, nonzero picks 0x200)
@         r1 = delay count, ignored on GBA
@ Return: r1 = the final SOUNDBIAS value. r0/r3 handler scratch, r2 dispatcher restored.
@
@ SOUNDBIAS is at REG_SOUNDBIAS, bias field in bits 1-9 (bit 0 unused). This reads the current
@ value, clears bit 0, keeps the upper bits and walks the field two units per step, storing each
@ intermediate value. Target 0x200 only ramps up: a start at or above it is left alone. Target
@ 0x000 ramps down from any start. Everything fits in r0-r3, so there is no stack frame.
@
@ Timing note: an up step costs 62 cycles and a down step 61. Already at target costs the same
@ as the loop exit, so every path is a fixed cost plus a per step cost.
.thumb
.set SB_DELAY, 13
swi_SoundBias:
    ldr  r2, =REG_SOUNDBIAS
    ldrh r1, [r2]
    lsrs r1, r1, #1
    lsls r1, r1, #1
    lsrs r3, r1, #10
    lsls r3, r3, #10
    cmp  r0, #0
    beq  .sb_down
    movs r0, #0x80
    lsls r0, r0, #2
    orrs r3, r0
    nop @ Timing note: up setup pad
.sb_up:
    cmp  r1, r3
    bhs  .sb_done
    adds r1, #2
    nop @ Timing note: up store phase pad
    nop
    nop
    strh r1, [r2]
    movs r0, #SB_DELAY
.sb_udl:
    subs r0, #1
    bne  .sb_udl
    b    .sb_up
.sb_down:
    nop @ Timing note: down setup pad
    nop
    nop
    nop
.sb_dn:
    cmp  r1, r3
    bls  .sb_done
    subs r1, #2
    strh r1, [r2]
    movs r0, #SB_DELAY
.sb_ddl:
    subs r0, #1
    bne  .sb_ddl
    nop @ Timing note: down step pad
    nop
    b    .sb_dn
.sb_done:
    bx lr
