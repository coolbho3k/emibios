@ SPDX-License-Identifier: GPL-3.0-or-later
@ ArcTan (SWI 0x09): arc tangent of a signed Q1.14 ratio.
@
@ Entry:  r0 = ratio
@ Return: r0 = signed angle; r1 = a = -((x*x) asr 14) and r3 = the final Horner
@ accumulator b as residues. r2 preserved.
@
@ Degree-7 polynomial in a = -x*x, evaluated in Horner form, then multiplied by x (degree 15 in x):
@   a = -(((x*x) low32) asr 14)
@   b = Horner(a, 0xa9, 0x390, 0x91c, 0xfb6, 0x16aa, 0x2081, 0x3651, 0xa2f9)
@   r0 = ((b*x) low32) asr 16
@ Each step is b = ((a*b) asr 14) + c. The split adds below are just the ARM
@ immediate encodings for the larger coefficients.
@
@ Past |x| > 0x4000 (|tan| > 1) the polynomial leaves its designed domain.
@ At |x| >= 0xb505 (sqrt(2^31)) the 32-bit x*x additionally overflows signed and
@ the arithmetic shift flips a's sign.
@
@ Timing note: the multiply order defines each Horner step. ARM7TDMI multiply cost also depends
@ on the operand value.
.arm
swi_ArcTan:
    mul r1, r0, r0
    mov r1, r1, asr #14
    rsb r1, r1, #0      @ r1 residue: a
    mov r3, #0xa9
    mul r3, r1, r3
    mov r3, r3, asr #14
    add r3, r3, #0x390
    mul r3, r1, r3
    mov r3, r3, asr #14
    add r3, r3, #0x900
    add r3, r3, #0x01c
    mul r3, r1, r3
    mov r3, r3, asr #14
    add r3, r3, #0xf00
    add r3, r3, #0x0b6
    mul r3, r1, r3
    mov r3, r3, asr #14
    add r3, r3, #0x1600
    add r3, r3, #0x00aa
    mul r3, r1, r3
    mov r3, r3, asr #14
    add r3, r3, #0x2000
    add r3, r3, #0x0081
    mul r3, r1, r3
    mov r3, r3, asr #14
    add r3, r3, #0x3600
    add r3, r3, #0x0051
    mul r3, r1, r3
    mov r3, r3, asr #14
    add r3, r3, #0xa200
    add r3, r3, #0x00f9 @ r3 residue: final b
    mul r0, r3, r0
    mov r0, r0, asr #16
    bx  lr
