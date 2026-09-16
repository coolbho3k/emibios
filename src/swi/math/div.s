@ SPDX-License-Identifier: LGPL-3.0-or-later
@ Div (SWI 0x06) and DivArm (SWI 0x07): signed integer divide.
.arm
.p2align 2

@ DivArm (SWI 0x07): Div with the operands exchanged (r0 = Divisor, r1 = Number).
@ Swaps them and falls through to Div.
swi_DivArm:
    mov r3, r1
    mov r1, r0
    mov r0, r3

@ Div (SWI 0x06)
@
@ Entry:  r0 = Number, r1 = Divisor
@ Return: r0 = Number / Divisor, r1 = remainder, r3 = abs(quotient). The remainder
@ takes the sign of Number. r2 is scratch.
@
@ One uniform shift divide. A sentinel bit 0x80000000 is seeded into the quotient
@ register and slid down during normalize and doubles as the loop terminator. Each
@ step does adcs r3,r3,r3, and when the sentinel leaves bit 31, the carry stops the
@ loop. That removes the need to keep the original divisor for an end test, so both
@ operand signs stay live (r12 = sign(Number) mask, r1 = signed Divisor).
@
@ Divide by zero freezes: |Number| <= 1 returns cleanly,
@ |Number| >= 2 hangs (.div_freeze). This matches the retail BIOS behavior.
@
@ Timing note: cost depends on operand magnitude.
swi_Div:
    mov   r12, r0, asr #32
    movs  r2, r1
    rsbmi r2, r2, #0
    beq   .div_by_zero
    eor   r0, r0, r12
    sub   r0, r0, r12
    cmp   r2, r0, lsr #1
    bhi   .div_q01
    mov   r3, #BIT31
.div_shift:
    movls r2, r2, lsl #1
    movls r3, r3, lsr #1
    cmp   r2, r0, lsr #1
    bls   .div_shift
    subs  r0, r0, r2
    adc   r3, r3, r3
    cmp   r0, #2
    bhs   .div_slow
.div_loop:
    mov   r2, r2, lsr #1
    cmp   r0, r2
    subcs r0, r0, r2
    adcs  r3, r3, r3
    bcc   .div_loop
.div_apply:
    eor  r2, r12, r1, asr #32
    eors r1, r0, r12, asr #32
    adc  r1, r1, #0
    eors r0, r3, r2, asr #32 @ r3 residue: abs(quotient)
    adc  r0, r0, #0
    bx   lr
.div_slow:
    @ Timing note: the +5-cycle slow path.
    nop
    nop
    nop
.div_loop2:
    mov   r2, r2, lsr #1
    cmp   r0, r2
    subcs r0, r0, r2
    adcs  r3, r3, r3
    bcc   .div_loop2
    eor   r2, r12, r1, asr #32
    eors  r1, r0, r12, asr #32
    adc   r1, r1, #0
    eors  r0, r3, r2, asr #32
    adc   r0, r0, #0
    bx    lr
.div_by_zero:
    eor r0, r0, r12
    sub r0, r0, r12
    cmp r0, #2
    bhs .div_freeze
.div_q01:
    subs  r0, r0, r2
    addcc r0, r0, r2
    mov   r3, #0
    adc   r3, r3, #0
    eor   r2, r12, r1, asr #32
    eors  r1, r0, r12, asr #32
    adc   r1, r1, #0
    eors  r0, r3, r2, asr #32
    adc   r0, r0, #0
    bx    lr
.div_freeze:
    b .div_freeze
