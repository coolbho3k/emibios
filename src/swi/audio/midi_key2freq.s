@ SPDX-License-Identifier: GPL-3.0-or-later
@ MidiKey2Freq (SWI 0x1f): convert a MIDI key plus fine adjustment to a SoundChannel frequency.
@
@ Entry:  r0 = WaveData*, r1 = MIDI key, r2 = fine adjust (256ths of a semitone)
@ Return: r0 = frequency; r4-r7 saved/restored, r1/r3 handler scratch.
@
@ Keys above 178 clamp to (key = 178, fine = 255). The equal tempered ratio table
@ is mk_freqtable[n] = round(2^(n/12) * 2^30) for n = 0..12.
@
@   octave   = key / 12         (computed as (key * 5462) >> 16)
@   semitone = key % 12
@   m0, m1   = table[semitone], table[semitone+1], each prescaled by octave at
@              reduced precision:  octave <= 13 -> value >> (13 - octave)
@                                  octave 14    -> value << 1
@   mult     = m0 + (((m1 - m0) * fine) >> 8)        (linear interp)
@   result   = high word of (WaveData->freq * mult)
.set MK_BASE_PAD,  0
.set MK_IN_PAD,    8
.set MK_NF_PAD,    5
.set MK_WIDE_PAD,  0
.set MK_TAIL_PAD,  27
.set MK_LEFT_PAD,  4
.set MK_CLAMP_PAD, 4
.align 2
.arm
swi_MidiKey2Freq:
    stmdb sp!, {r4, r5, r6, r7}
    ldr   r3, [r0, #4]
    cmp   r1, #178
    movhi r1, #178
    movhi r2, #255
    mulhi r6, r0, r1
    mulhi r6, r0, r1
    ldr   r4, =5462
    mul   r4, r1, r4
    mov   r4, r4, lsr #16
    add   r5, r4, r4, lsl #1
    sub   r5, r1, r5, lsl #2
    adr   r6, mk_freqtable
    add   r6, r6, r5, lsl #2
    ldmia r6, {r0, r1}
    cmp   r4, #13
    bhi   .mk_left
    rsb   r7, r4, #13
    mov   r0, r0, lsr r7
    mov   r1, r1, lsr r7
    b     .mk_interp
.mk_left:
    guard_pad MK_LEFT_PAD
    mov       r0, r0, lsl #1
    mov       r1, r1, lsl #1
.mk_interp:
    guard_pad MK_BASE_PAD
    cmp       r2, #0
    beq       .mk_nofine
    sub       r1, r1, r0
    cmp       r4, #11
    bhs       .mk_wide
    mul       r1, r1, r2
    guard_pad MK_IN_PAD
    add       r1, r0, r1, lsr #8
.mk_mul64:
    umull r2, r0, r3, r1
    mov   r2, #(MK_TAIL_PAD + 1) / 4
7802:
    subs r2, r2, #1
    bgt  7802b
    .rept (MK_TAIL_PAD + 1) % 4
    nop
    .endr
    ldmia sp!, {r4, r5, r6, r7}
    bx    lr
.mk_nofine:
    mov       r1, r0
    guard_pad MK_NF_PAD
    b         .mk_mul64
.mk_wide:
    umull     r6, r7, r1, r2
    mov       r1, r6, lsr #8
    orr       r1, r1, r7, lsl #24
    add       r1, r1, r0
    guard_pad MK_WIDE_PAD
    b         .mk_mul64
    .ltorg

.align 2
mk_freqtable:
    .word 1073741824, 1137589835, 1205234447, 1276901417
    .word 1352829926, 1433273380, 1518500250, 1608794973
    .word 1704458901, 1805811301, 1913190429, 2026954652
    .word 2147483648
