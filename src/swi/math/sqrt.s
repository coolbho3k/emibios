@ SPDX-License-Identifier: LGPL-3.0-or-later
@ Sqrt (SWI 0x08): integer square root by Newton iteration.
@
@ Entry:  r0 = n
@ Return: r0 = isqrt(n); r1 = last candidate (x + n/x) >> 1 and r3 = last quotient n/x as
@ residues. r4-r11 preserved.
@
@   H    = floor(bitlen(n) / 2)
@   base = 1 << H
@   seed = base, or 2*base when (n >> H) > base
@   x    = (x + n/x) >> 1   until the next candidate stops shrinking
@
@ The divide n/x is a bit-by-bit long division. When x > n/2 the quotient is 0 or 1, taken by
@ the lighter .sqrt_q01 path.
@
@ Timing note: the no-ops on the divide path, the q01 path, and the back edges hold each
@ iteration at a fixed cost. The q01 step is one cycle lighter. The n==0 path pads with
@ .sqrt_zpad.
.arm
swi_Sqrt:
    cmp r0, #0
    beq .sqrt_zero
    mov r2, r0
    mov r1, #0
    mov r12, r2
    cmp r12, #1
    bls .sqrt_seed
.sqrt_h:
    mov r12, r12, lsr #2
    add r1, r1, #1
    cmp r12, #1
    bhi .sqrt_h
.sqrt_seed:
    mov r0, #1
    mov r0, r0, lsl r1
    mov r12, r2, lsr r1
    cmp r12, r0
    bhi .sqrt_bumped
.sqrt_loop:
    cmp r0, r2, lsr #1
    bhi .sqrt_q01
    nop
    nop
    nop
    nop
    mov r3, #BIT31
.sqrt_dnorm:
    movls r0, r0, lsl #1
    movls r3, r3, lsr #1
    cmp   r0, r2, lsr #1
    bls   .sqrt_dnorm
    subs  r12, r2, r0
    adc   r3, r3, r3
    cmp   r12, #2
    bhs   .sqrt_dslow
.sqrt_dloop:
    mov   r0, r0, lsr #1
    cmp   r12, r0
    subcs r12, r12, r0
    adcs  r3, r3, r3
    bcc   .sqrt_dloop
.sqrt_after:
    add   r1, r0, r3
    mov   r1, r1, lsr #1
    cmp   r1, r0
    movlt r0, r1
    blt   .sqrt_loop
    bx    lr
.sqrt_dslow:
    b .sqrt_dloop @ +5 cyc: taken bhs + this branch (div.s clones the loop instead)
.sqrt_q01:
    cmp   r2, r0
    movcs r3, #1
    movcc r3, #0
    add   r1, r0, r3
    mov   r1, r1, lsr #1
    nop
    cmp   r1, r0
    movlt r0, r1
    blt   .sqrt_q01cont
    bx    lr
.sqrt_q01cont:
    nop
    b .sqrt_loop
.sqrt_bumped:
    mov r0, r0, lsl #1
    b   .sqrt_loop
.sqrt_zero:
    @ n==0: result 0, residues r1=0 and r3=1.
    mov r0, #0
    mov r1, #0
    mov r3, #1
    mov r12, #10
.sqrt_zpad:
    subs r12, r12, #1
    bne  .sqrt_zpad
    mov  r12, r12
    mov  r12, r12
    bx   lr
