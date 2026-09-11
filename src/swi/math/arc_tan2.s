@ SPDX-License-Identifier: GPL-3.0-or-later
@ ArcTan2 (SWI 0x0a): full circle angle of a vector, octant decomposed atan2. Built
@ on swi_ArcTan (0x09).
@
@ Entry:  r0 = X, r1 = Y (full s32)
@ Return: r0 = angle 0..0xffff (octant 8 returns exactly 0x10000, not masked)
@ r1 = ArcTan's intermediate for the reduced ratio (or Y on the X==0 axis) and
@ r3 = 0x170 as residues (rewritten at .at2_axpad after the bl to ArcTan clobbers
@ it). r2 preserved.
@
@ The sign is bit 31 (Y=0x8000 counts as +32768). |.| is the overflow-abs, so
@ |INT_MIN| = 0x80000000.
@   Y==0 : r0 = X<0 ? 0x8000 : 0,        r1 = 0   (+X / -X axis)
@   X==0 : r0 = Y<0 ? 0xc000 : 0x4000,   r1 = Y   (+Y / -Y axis)
@   |X|>|Y| (shallow): t = (Y<<14)/X,  r0 = ArcTan(t) + {X<0:0x8000, X>0&Y<0:0x10000}
@   else    (steep)  : t = (X<<14)/Y,  r0 = (Y<0?0xc000:0x4000) - ArcTan(t)
@ The |X| vs |Y| compare is signed, so |INT_MIN| reads as the least value. t is a
@ signed divide truncated toward zero, and r0 is not masked. The exact |X|==|Y|
@ diagonal goes shallow except when both are negative (then steep).
@
@ Timing note: the ratio uses the same normalized shift divide as Div. A NOP sled at
@ .at2_axpad burns r12 cycles. r6 carries the octant base plus the division sub path
@ tag. r10 carries the |X|==|Y| tie break correction (0 off diagonal), folded into
@ r12 at .at2_done. The frameless axis paths and the main path share one 12 deep sled.
.arm
swi_ArcTan2:
    cmp   r1, #0
    bne   .at2_xtest
    cmp   r0, #0
    mov   r0, #0
    movmi r0, #0x8000
    mov   r1, #0 @ r1 residue: 0
    mov   r12, #7
    addmi r12, r12, #3
    b     .at2_axpad
.at2_xtest:
    cmp   r0, #0
    bne   .at2_main
    cmp   r1, #0
    mov   r0, #0x4000
    movmi r0, #0xc000 @ r1 residue: stays = Y
    mov   r12, #9
    addmi r12, r12, #2
    b     .at2_axpad
.at2_main:
    stmfd sp!, {r4-r8, r10, lr}
    mov   r10, #0
    mov   r4, r0
    mov   r5, r1
    eor   r6, r4, r4, asr #31
    sub   r6, r6, r4, asr #31
    eor   r7, r5, r5, asr #31
    sub   r7, r7, r5, asr #31
    cmp   r6, r7
    bgt   .at2_shallow
    blt   .at2_steep
    ands  r10, r4, r5
    bmi   .at2_steep_diag
    mvn   r10, #1
.at2_shallow:
    mov r0, r5, lsl #14
    mov r1, r4
    bl  at2_sdiv
    bl  swi_ArcTan
    cmp r4, #0 @ sets the final cpsr
    bmi .at2_sh_xneg
    cmp r5, #0
    blt .at2_sh_oct8
    add r6, r6, #0
    b   .at2_done
.at2_sh_oct8:
    add r0, r0, #0x10000
    add r6, r6, #0
    b   .at2_done
.at2_sh_xneg:
    add r0, r0, #0x8000
    add r6, r6, #0
    add r6, r6, r5, lsr #31
    add r6, r6, r5, lsr #31
    b   .at2_done
.at2_steep_diag:
    mvn r10, #2
.at2_steep:
    mov   r0, r4, lsl #14
    mov   r1, r5
    bl    at2_sdiv
    bl    swi_ArcTan
    mov   r8, #0x4000
    cmp   r5, #0 @ sets the final cpsr
    movmi r8, #0xc000
    rsb   r0, r0, r8
    mov   r7, r4, lsr #31
    addmi r6, r6, #5
    submi r6, r6, r7, lsl #2
    addpl r6, r6, #0
    addpl r6, r6, r7, lsl #1
.at2_done:
    add   r12, r6, r10
    ldmfd sp!, {r4-r8, r10, lr}
.at2_axpad:
    @ Computed jump burns r12 cycles. Depth 12 covers the largest pad (r12 <= 11).
    @ r3 residue: 0x170.
    mov r3, #0x170
    rsb r12, r12, #11
    add pc, pc, r12, lsl #2
    .rept 12
    nop
    .endr
    bx lr

@ Signed divide, truncated toward zero: r0 = r0 / r1 (r1 != 0). Same normalized
@ shift divide as Div, mapped onto r7 (shifted divisor) and r8 (quotient/sentinel).
@ Clobbers r0, r1, r7, r8, r12. Returns r6 = division sub path tag for the timing sled.
at2_sdiv:
    mov   r6, #3
    mov   r12, r0, asr #31
    movs  r7, r1
    rsbmi r7, r7, #0
    eor   r0, r0, r12
    sub   r0, r0, r12
    cmp   r7, r0, lsr #1
    bhi   .at2_div_q01
    mov   r8, #BIT31
.at2_div_shift:
    movls r7, r7, lsl #1
    movls r8, r8, lsr #1
    cmp   r7, r0, lsr #1
    bls   .at2_div_shift
    subs  r0, r0, r7
    adc   r8, r8, r8
    cmp   r0, #2
    bhs   .at2_div_slow
.at2_div_loop:
    mov   r7, r7, lsr #1
    cmp   r0, r7
    subcs r0, r0, r7
    adcs  r8, r8, r8 @ sentinel exits bit 31 -> carry stops the loop
    bcc   .at2_div_loop
.at2_div_apply:
    eor r7, r12, r1, asr #31
    eor r0, r8, r7
    sub r0, r0, r7
    bx  lr
.at2_div_slow:
    mov r6, #2
    b   .at2_div_loop
.at2_div_q01:
    subs r0, r0, r7
    mov  r8, #0
    adc  r8, r8, #0
    @ Sign apply inlined (no branch to .at2_div_apply). Drops one taken branch (3 cyc),
    @ so this path's tag is 3. That keeps the sled pad 3+r10 >= 0 on the |X|==|Y|
    @ diagonal (r10 = -2 or -3) so the computed jump cannot underflow. Off the diagonal,
    @ the -3 cancels the +3 tag.
    mov r6, #3
    eor r7, r12, r1, asr #31
    eor r0, r8, r7
    sub r0, r0, r7
    bx  lr
