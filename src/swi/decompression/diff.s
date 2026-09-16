@ SPDX-License-Identifier: LGPL-3.0-or-later
@ Diff unfilters: Diff8bitWrite8bit (0x16), Diff8bitWrite16bit (0x17), Diff16bit (0x18).
@
@ Each undoes a prefix-difference filter. The destination starts from prev = 0 and each
@ output element is prev + this element's diff, wrapping (not clamp).
@
@ Common interface:
@   r0  Source: 32-bit header (bits 8-31 = data size in bytes), then the diff stream
@   r1  Destination

@ Diff8bitUnfilterWrite8bit (SWI 0x16): byte diffs, byte writes, all-Thumb. Dispatched straight into Thumb
@ (swi_table[0x16] = handler + 1) for a continuous half rate Thumb fetch.
@
@   out[i] = (out[i-1] + diff[i]) & 0xff,  prev = 0
@
@ Return: r0 = src+4+size, r1 = dst+size, r3 = 0x170. r4 saved/restored, r2/r12 are dispatch
@ scratch.
@
@ strb writes the low byte, so the 32-bit running sum needs no per step mask. The header is
@ one ldmia, the first instruction (r0 -> src+4). The loop count (size) follows.
@
@ Source validity: if (src & 0x0e000000) == 0 (a BIOS/low region source) the header is read but
@ nothing is written (r0 = src+4, r1 unchanged, r3 = 0x170). A Thumb ALU clobbers carry, so the
@ check is a mask test on r0 (= src+4, same top byte as src when in range), not a deferred carry
@ branch.
@
@ Timing note: the store schedule has a nonuniform first gap, so the loop peels store 0 and runs
@ do while for the rest. Size 0/1 take the .small path.
@
@ Timing note: a Palette RAM access during active display stalls when it lands 0 mod 4, so
@ D8_S0WR splits store 0's read from its write and D8_HDR seeds the stall at the header phase.
@ No real input hits Palette RAM in active display.
    @ The handler stays all-Thumb (an ARM veneer would overshoot the prologue cycle budget), so
    @ the source region check is inlined in Thumb with pads that reproduce the prologue timing.
    @ Only a mid SWI T-bit read can see the state choice.
    .set D8_HDR,      3
    .set D8_PRE,      1
    .set D8_ENTRY,    3
    .set D8_S0WR,     3
    .set D8_PAD,      1
    .set D8_FIRSTGAP, 0
    .set D8_TEXIT,    3
    .set D8_DONE,     0
    .set D8_ONE,      2
    .set D8_ONEPRE,   3
    .set D8_SKIP,     9
.thumb
swi_Diff8bitUnfilterWrite8bit:
    push            {r4, lr}
    guard_pad_thumb D8_HDR
    ldmia           r0!, {r2}
    movs            r3, #0
    lsrs            r2, r2, #8
    @ Source-region check via the shared shift macro: (src+4 & 0x0e000000)==0 -> skip. Single check,
    @ cost held at 4 cyc (3 + the nop below): the dual form's +3 would shift the store band, which
    @ has no neutral prologue pad here. r4 = scratch (saved).
    decomp_guard_thumb r0, r4, .d8w8_skip
.d8w8_afterguard:
    nop
    .rept D8_PRE
    nop
    .endr
    cmp             r2, #1
    bls             .d8w8_small
    guard_pad_thumb D8_ENTRY
    @ store 0 (peeled): read D8_S0WR early vs its write. first read gap +3, write on its cycle
    ldrb            r4, [r0]
    adds            r0, #1
    adds            r3, r3, r4
    guard_pad_thumb D8_S0WR
    .rept D8_PAD
    nop
    .endr
    strb r3, [r1]
    adds r1, #1
    subs r2, #1
    .rept D8_FIRSTGAP
    nop
    .endr
.d8w8_loop:
    ldrb r4, [r0]
    adds r0, #1
    adds r3, r3, r4
    .rept D8_PAD
    nop
    .endr
    strb r3, [r1]
    adds r1, #1
    subs r2, #1
    bne  .d8w8_loop
    .rept D8_TEXIT
    nop
    .endr
.d8w8_done:
    .rept D8_DONE
    nop
    .endr
    movs r3, #0x17
    lsls r3, r3, #4 @ r3 = 0x170 residue
    pop  {r4}
    pop  {r2}
    bx   r2         @ interwork return to the ARM dispatcher (ARMv4T: pop{pc} won't switch)
.d8w8_small:
    subs r2, #1 @ size 0 -> -1 (C clear). size 1 -> 0
    bcc  .d8w8_done
    ldrb r4, [r0]
    adds r0, #1
    adds r3, r3, r4
    .rept D8_ONEPRE
    nop
    .endr
    strb r3, [r1]
    adds r1, #1
    .rept D8_ONE
    nop
    .endr
    @ inline epilogue (no branch to .d8w8_done): the dropped 3 cycle branch balances D8_ONEPRE=3
    .rept D8_DONE
    nop
    .endr
    movs r3, #0x17
    lsls r3, r3, #4
    pop  {r4}
    pop  {r2}
    bx   r2
.d8w8_skip:                       @ out-of-range src: header already read (r0 = src+4), r1 unchanged, r3=0x170
    guard_pad_thumb D8_SKIP
    guard_pad_thumb 1 @ skip path cycle pad +1 -> 116, matches the retail BIOS
    movs            r3, #0x17
    lsls            r3, r3, #4
    pop             {r4}
    pop             {r2}
    bx              r2
.arm
.p2align 2

@ Diff8bitUnfilterWrite16bit (SWI 0x17): byte diffs, halfword writes.
@
@ Return: r0 = src+4+size, r1 = dst + 2*floor(size/2), r3 = 0x170 residue (the handler does not
@ use r3). Dispatcher restores r2/r11/r12 -> scratch.
@
@ Same 8-bit running sum as 0x16, but output is written as halfwords (pairs of consecutive
@ output bytes via strh). floor(size/2) halfwords are written. An odd trailing byte is still
@ read (prev advances) but not written.
@
@ The pads cost the same in every memory region. size 0 takes a lighter branch path, even
@ sizes add a per pair loop pad, and an odd tail byte adds its own pad.
    .set D8W16_FIX,  9
    .set D8W16_S0,   14
    .set D8W16_LOOP, 21
    @ Timing note: part of the per pair pad sits before the strh, delaying each store without
    @ changing the per pair total.
    .set D8W16_PRE,  16
    .set D8W16_TAIL, 15
    .set D8W16_SKIP, 19
swi_Diff8bitUnfilterWrite16bit:
    ldmia r0!, {r2}
    lsr   r2, r2, #8
    @ Dual source region guard (src+4 and src+4+size) via the shared macro. r12 = source end temp
    @ (lr is the live return). D8W16_FIX accounts for the guard's two extra cycles.
    decomp_guard_arm r0, .d8w16_skip, r2, r12
.d8w16_afterguard:
    mov       r12, #0
    guard_pad D8W16_FIX
    cmp       r2, #0
    bne       .d8w16_loop
    guard_pad D8W16_S0
    b         .d8w16_done
.d8w16_loop:
    cmp  r2, #2
    blt  .d8w16_tail
    ldrb r11, [r0], #1
    add  r12, r12, r11
    and  r3, r12, #0xff
    ldrb r11, [r0], #1
    add  r12, r12, r11
    orr  r3, r3, r12, lsl #8
    .rept D8W16_PRE
    nop
    .endr
    strh r3, [r1], #2
    .rept (D8W16_LOOP - D8W16_PRE)
    nop
    .endr
    sub r2, r2, #2
    b   .d8w16_loop
.d8w16_tail:
    cmp       r2, #0
    beq       .d8w16_done
    ldrb      r11, [r0], #1
    add       r12, r12, r11
    guard_pad D8W16_TAIL
.d8w16_done:
    mov r3, #0x170 @ SWI-dispatch residue
    bx  lr
.d8w16_skip:
    guard_pad D8W16_SKIP
    guard_pad 13 @ skip path cycle pad +13 -> 123, matches the retail BIOS
    mov       r3, #0x170
    bx        lr

@ Diff16bitUnfilter (SWI 0x18): 16-bit diffs, halfword writes.
@   out[i] = (out[i-1] + diff_hw[i]) & 0xffff,  prev = 0
@ Return: r0 = src+4 + 2*nhw, r1 = dst + 2*nhw, r2 preserved. r3 ends = the last diff halfword
@ the loop read for nhw>=2. For nhw<=1 the loop never runs and r3 = 0xba4 (this SWI's dispatch
@ residue).
@
@ nhw = (size+1)>>1 halfwords (rounds up, so an odd size reads and writes one byte past). strh
@ writes prev & 0xffff, so the 32-bit accumulator in r12 needs no per step mask. Dispatcher
@ restores r2/r12.
@
@ The pads cost the same in every memory region. The nhw>=1 first-halfword path and the
@ nhw>=2 loop each add their own pad, then +3 cyc per halfword in the loop.
    @ Timing note: DONE cycles move from the prologue to the epilogue, shifting every strh
    @ earlier without changing the total.
    .set D16_DONE,  9
    .set D16_BASE,  (16 - D16_DONE)
    .set D16_FIRST, 6
    .set D16_ENTRY, 2
    .set D16_LOOP,  3
    .set D16_SKIP,  24
swi_Diff16bitUnfilter:
    ldmia r0!, {r2}
    mov   r3, #0xb00 @ 0xba4 residue (skip + nhw<=1 paths leave it in r3)
    orr   r3, r3, #0xa4
    lsr   r2, r2, #8
    @ Dual source region guard (src+4 and src+4+size) via the shared macro. r12 = source end temp
    @ (lr is the live return, r3 = 0xba4 for the skip path). D16_BASE accounts for the guard's
    @ two extra cycles.
    decomp_guard_arm r0, .d16_skip, r2, r12
.d16_afterguard:
    add  r2, r2, #1
    movs r2, r2, lsr #1 @ r2 = nhw = (size+1)>>1. Z set iff size == 0
    .rept D16_BASE
    nop
    .endr
    beq .d16_done
    .rept D16_FIRST
    nop
    .endr
    ldrh r12, [r0], #2
    strh r12, [r1], #2
    subs r2, r2, #1
    beq  .d16_done_nhw1 @ nhw==1: r3 still 0xba4 (separate -2 exit balances D16_FIRST+2)
    .rept D16_ENTRY
    nop
    .endr
.d16_loop:
    ldrh r3, [r0], #2
    add  r12, r12, r3
    strh r12, [r1], #2
    .rept D16_LOOP
    nop
    .endr
    subs r2, r2, #1
    bne  .d16_loop
.d16_done:
    .rept D16_DONE
    nop
    .endr
    bx lr
.d16_done_nhw1:                    @ nhw==1 exit: D16_DONE-2 balances the +2 first-store delay
    .rept (D16_DONE - 2)
    nop
    .endr
    bx lr
.d16_skip:
    guard_pad D16_SKIP
    bx        lr
