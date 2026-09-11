@ SPDX-License-Identifier: GPL-3.0-or-later
@ ObjAffineSet (SWI 0x0f) and BGAffineSet (SWI 0x0e)
@
@ Build affine matrices from scale and angle. Both share a 256-entry sine LUT in
@ 2.14 fixed point (1.0 = 0x4000), indexed by the high byte of the u16 angle
@ (theta>>8, low byte ignored). cos(i) = sin(i+64), with the LUT index masked
@ to 256 entries.
@
@ Affine params (8.8 outputs) are (scale_8.8 * trig_2.14) >> 14 with an arithmetic
@ shift (floor toward -inf):
@   Pa = (sx*cos)>>14   Pb = -((sx*sin)>>14)   Pc = (sy*sin)>>14   Pd = (sy*cos)>>14
@ Pb negates after the shift.
@
@ Timing note: the pads hold both loops at a fixed per iteration cost. BGAffineSet's store order
@ (startx, starty, then Pa-Pd) is observable on the bus.
.arm

@ ObjAffineSet (SWI 0x0f)
@
@ Entry:  r0 = source -> ObjAffineSource { s16 sx, s16 sy, u16 theta, u16 pad } (8 bytes)
@         r1 = dest   -> Pa, then Pb,Pc,Pd at +offset, +2*offset, +3*offset (s16 each)
@         r2 = number of calculations
@         r3 = offset in bytes between the four params (2 = continuous, 8 = OAM-interleaved)
@ Return: r0 = source + 8*count, r1 = dest + 4*offset*count; r3 untouched. r4-r8
@ saved/restored, r2/r12 dispatcher-restored.
swi_ObjAffineSet:
    cmp   r2, #0
    beq   .obj_count0
    stmfd sp!, {r4-r8}
    adr   r8, sine_lut @ keep unconditional
    nop
.obj_loop:
    @ Bus note: field read order is theta, then sx, sy.
    ldrh  r12, [r0, #4]
    mov   r12, r12, lsr #8
    add   r6, r8, r12, lsl #1
    ldrsh r7, [r6]
    ldrsh r4, [r0]
    ldrsh r5, [r0, #2]
    add   r12, r12, #64
    and   r12, r12, #0xff
    add   r6, r8, r12, lsl #1
    ldrsh r6, [r6]
    mov   r8,  #0      @ zero for Pb's negate below
    mul   r12, r6, r4
    mov   r12, r12, asr #14
    strh  r12, [r1], r3
    mul   r12, r7, r4
    sub   r12, r8, r12, asr #14
    strh  r12, [r1], r3
    nop
    mul   r12, r7, r5
    mov   r12, r12, asr #14
    strh  r12, [r1], r3
    mul   r12, r6, r5
    mov   r12, r12, asr #14
    strh  r12, [r1], r3
    add   r0, r0, #8
    adr   r8, sine_lut @ keep unconditional
    subs  r2, r2, #1
    bne   .obj_loop
    ldmfd sp!, {r4-r8}
    bx    lr
.obj_count0:
    mov r12, #3
.obj_c0pad:
    subs r12, r12, #1
    bne  .obj_c0pad
    bx   lr

@ BGAffineSet (SWI 0x0e)
@
@ Entry:  r0 = source -> BgAffineSource (20 bytes):
@           s32 cx, s32 cy, s16 dispx, s16 dispy, s16 sx, s16 sy, u16 theta, u16 pad
@         r1 = dest -> BgAffineDest (16 bytes): s16 Pa, Pb, Pc, Pd, s32 startx, s32 starty
@         r2 = number of calculations
@ Return: r0/r1 past the last source/dest; r3 = last Pa as residue. r4-r11
@ saved/restored, r2/r12 dispatcher-restored.
@
@ Pa..Pd match ObjAffineSet. The start is the center minus the matrix applied to
@ the display center, s32 wrapping (not clamp):
@   startx = cx - (Pa*dispx + Pb*dispy)      starty = cy - (Pc*dispx + Pd*dispy)
swi_BGAffineSet:
    cmp   r2, #0
    beq   .bg_count0
    stmfd sp!, {r4-r11, lr}
    adr   r9, sine_lut @ keep unconditional
    nop
.bg_loop:
    @ Bus note: field read order is theta, then sx, sy.
    ldrh  r6, [r0, #16]
    mov   r6, r6, lsr #8
    add   r12, r9, r6, lsl #1
    ldrsh r8, [r12]
    ldrsh r4, [r0, #12]
    ldrsh r5, [r0, #14]
    add   r7, r6, #64
    and   r7, r7, #0xff
    add   r12, r9, r7, lsl #1
    ldrsh r7, [r12] @ cancels the LDM +1 so the startx store stays on time
    mul   r12, r7, r4
    mov   r10, r12, asr #14
    mul   r12, r8, r4
    mov   r12, r12, asr #14
    rsb   r11, r12, #0
    mul   r12, r8, r5
    mov   r4,  r12, asr #14
    mul   r12, r7, r5
    mov   r5,  r12, asr #14
    ldmia r0, {r3, r6, r8}
    mov   r7, r8, asr #16
    mov   r8, r8, lsl #16
    mov   r8, r8, asr #16
    mul   r12, r10, r8
    sub   r3,  r3, r12
    mul   r12, r11, r7
    sub   r3,  r3, r12
    str   r3,  [r1, #8]
    mul   r12, r4, r8
    sub   r6,  r6, r12
    mul   r12, r5, r7
    sub   r6,  r6, r12
    str   r6,  [r1, #12]
    mov   r12, r12
    strh  r10, [r1]
    strh  r11, [r1, #2]
    strh  r4,  [r1, #4]
    strh  r5,  [r1, #6]
    mov   r3,  r10  @ r3 residue: Pa
    mov   r12, r12
    mov   r12, r12
    mov   r12, r12
    add   r0, r0, #20
    add   r1, r1, #16
    subs  r2, r2, #1
    bne   .bg_loop
    ldmfd sp!, {r4-r11, lr}
    bx    lr
.bg_count0:
    mov r12, #5
.bg_c0pad:
    subs r12, r12, #1
    bne  .bg_c0pad
    bx   lr

@ sine_lut.s is generated at build time by tools/gen/sine_lut.zig.
#include "sine_lut.s"
