@ SPDX-License-Identifier: LGPL-3.0-or-later
@ LZ77 decompression: LZ77UnCompWrite8bit (0x11), LZ77UnCompWrite16bit (0x12).
@
@ Common interface:
@   r0  Source: 32-bit aligned header (bits 8-31 = decompressed size, bits 4-7 = type 1),
@       then the stream
@   r1  Destination (0x11: byte writes. 0x12: halfword buffered writes)
@
@ Stream format: a flag byte, then up to 8 blocks, MSB first. Flag bit 0 = literal (copy 1
@ byte src->dst). Flag bit 1 = back-ref of 2 bytes b0,b1: len = (b0>>4)+3,
@ disp = ((b0&0xf)<<8)|b1, copy len bytes from (dst-disp-1) one byte at a time, so disp=0
@ repeats the last byte (RLE). A valid stream produces exactly `size` bytes.
.arm

@ LZ77UnCompReadNormalWrite8bit (SWI 0x11): byte writes.
@
@ Return: r0 = src+consumed, r1 = dst+size, r3 = 0 if any back-ref ran (the copy counter
@ ends 0) else r3 is preserved. r2/r12 are dispatcher scratch. Size 0 reads only the header.
@
@ The pads cost the same in every memory region. The remaining count is decremented once per
@ back-ref, not per copied byte. The back-ref reads its header byte b0 twice so the number of
@ source reads stays fixed over the run.
    .set LZ_PRE,    0
    .set LZ_ONCE,   0
    .set LZ_FLAG_L, 2
    .set LZ_FLAG_B, 2
    .set LZ_LIT,    2
    .set LZ_BR,     0
    .set LZ_BRL,    0
    .set LZ_COPY,   0
    .set LZ_DONE,   6
    .set LZ_BAD,    10
@ No-guard entry for BIOS resident blobs (source below 0x4000, which the guard rejects). Same body
@ as the SWI: replicate the pre-guard prologue, then branch past the guard to the shared post-guard
@ label. r0 = src, r1 = dst. ARM (callable via bx from Thumb).
swi_LZ77UnCompWrite8bit_nv:
    push {r4-r6, lr}
    ldr  r5, [r0], #4
    movs r2, r5, lsr #8
    beq  .lz8_done
    mov  r12, #0
    b    .lz8_afterguard
swi_LZ77UnCompWrite8bit:
    @ IRQ-visible: a handler that spills the interrupted r4-r11 sees r4 = remaining>>3
    @ (group counter), r5 = current byte, r6 = disp. Pointers and working state are banked:
    @ r0 stream, r1 dst, r2 remaining, r3 length, r12 flag word, lr back-ref src. Frame is
    @ {r4-r6, lr} (4 words, r7 untouched).
    @ Around the literal/dispatch slots, some IRQ boundary phases still differ from retail.
    push             {r4-r6, lr}
    ldr              r5, [r0], #4
    movs             r2, r5, lsr #8
    beq              .lz8_done
    mov              r12, #0
    decomp_guard_arm r0, .lz8_badsrc, r2 @ dual source region guard (src and src+size, src end temp in lr)
.lz8_afterguard:
    .rept LZ_ONCE
    nop
    .endr
@ Per-path dispatch and reload copies: the literal loop carries an extra slot between the movs
@ and the bne, the back-ref loop does not. Each path's reload is inlined, so the reload costs
@ the same regardless of which path reached it, and can be tuned on its own.
.lz8_block:
    movs r12, r12, lsl #1
    nop
    bne  .lz8_gotbit
    ldrb r12, [r0], #1
    mov  r12, r12, lsl #24
    orr  r12, r12, #0x00800000 @ guard bit (falls out after 8 real bits)
    movs r12, r12, lsl #1
    mov  r4, r2, lsr #3
    .rept LZ_FLAG_L
    nop
    .endr
    b .lz8_gotbit
.lz8_gotbit:
    mov r4, r2, lsr #3
    nop
    nop
    bcs .lz8_backref
    @ literal: the group counter and pads are shared before the bcs so the no-reload dispatch
    @ keeps its branch spacing. The byte consume stays tight.
    ldrb r6, [r0], #1
    strb r6, [r1], #1
    subs r2, r2, #1
    bgt  .lz8_block
    nop
    b    .lz8_done
.lz8_backref:
    @ Two ALU instructions separate each stream load, keeping IRQ timing steady across VBlank
    @ during a back-ref. The subs flags survive until the ble.
    ldrb r5, [r0]
    mov  r3, r5, lsr #4
    add  r3, r3, #3
    ldrb r5, [r0], #1
    and  r5, r5, #0xf
    subs r2, r2, r3
    ldrb r6, [r0], #1
    orr  r6, r6, r5, lsl #8
    sub  lr, r1, r6
    sub  lr, lr, #1
    ble  .lz8_brlast
    .rept LZ_BR
    nop
    .endr
.lz8_copy:
    ldrb r5, [lr], #1
    strb r5, [r1], #1
    .rept LZ_COPY
    nop
    .endr
    subs r3, r3, #1
    bne  .lz8_copy
    @ copy loop falls through into the dispatch that reloads the flag word and picks
    @ the next back-ref or literal.
.lz8_block_br:
    movs r12, r12, lsl #1
    bne  .lz8_gotbit
    ldrb r12, [r0], #1
    mov  r12, r12, lsl #24
    orr  r12, r12, #0x00800000
    movs r12, r12, lsl #1
    mov  r4, r2, lsr #3
    .rept LZ_FLAG_B
    nop
    .endr
    b .lz8_gotbit
.lz8_brlast:
    .rept LZ_BRL
    nop
    .endr
.lz8_copy2:
    ldrb r5, [lr], #1
    strb r5, [r1], #1
    .rept LZ_COPY
    nop
    .endr
    subs r3, r3, #1
    bne  .lz8_copy2
    @ The final back-ref path has one fewer epilogue pad to repay the shared pre-bcs dispatch
    @ slot without changing literal-ending streams.
    guard_pad (LZ_DONE - 1)
    pop       {r4-r6, lr}
    bx        lr
.lz8_done:
    guard_pad LZ_DONE
    pop       {r4-r6, lr}
    bx        lr
.lz8_badsrc:
    guard_pad LZ_BAD
    pop       {r4-r6, lr}
    bx        lr

@ LZ77UnCompReadNormalWrite16bit (SWI 0x12): same LZ77 stream as 0x11, written in halfwords.
@ Decompression is byte-granular but the destination only takes 16-bit writes, so the low byte
@ of each pair is buffered and the completed pair is stored on the odd position.
@
@ Bug-for-bug: each back-ref source byte is read straight from the destination (dst[cur-disp-1]).
@ Because the pending low byte is only buffered (not yet written), a disp=0 RLE back-ref reads the
@ stale/cleared destination. An "all 0xAB" run decompresses to AB,00,00,00,... not all-AB. This is
@ reproduced exactly, not fixed.
@
@ Return: r1 = dst + 2*floor(size/2).
@
@ The pads cost the same in every memory region. The back-ref reads its header byte b0 twice so
@ the number of source reads stays fixed over the run. The back-ref exits like the literal path.
    .set LZH_FLAG, 7
    .set LZH_LIT,  3
    .set LZH_BR,   3
    .set LZH_CPA,  5
    .set LZH_CPF,  1
    .set LZH_CPG,  1
    .set LZH_DONE, 0
swi_LZ77UnCompWrite16bit:
    @ IRQ-visible: an IRQ mid SWI exposes r4-r11 to the game's handler (the stub banks
    @ only r0-r3/r12/lr), so the register allocation is the contract: r4 = disp+1, r5 = copy
    @ remaining, r6 = raw flag byte, r7 = flag-bit counter (7..0, MSB first), r9 = byte temp,
    @ r8 = halfword buffer, r10 = output bytes remaining. Pointers and scratch live in banked regs:
    @ r0 = stream, r1 = dst halfword ptr, r2 = back-ref src byte ptr, r3 = merge shift (0 even /
    @ 8 odd, the eors toggle provides the parity flags), r12 = flag bit mask, lr = scratch.
    @ Timing note: the copy loop has a fixed two-byte period, so a mid copy IRQ lands at a
    @ known point.
    @ Frame image: {r4-r7, s8, s9, s10, lr} where s8-s10 hold the caller's r8-r10 during the call
    @ and are zeroed before return (the post-image is three zero locals).
    stmfd            sp!, {r4-r10, lr}
    sub              sp, sp, #12
    ldr              r12, [r0], #4
    movs             r10, r12, lsr #8
    mov              r8, #0
    beq              .lzh_done_pad0
    mov              r3, #8
    decomp_guard_arm r0, .lzh_badsrc, r10 @ dual source region guard (5 cyc), cost and phase
                                  @ neutral. r7=7 is set by .lzh_reload0. src end temp lives in
                                  @ lr (IRQ-invisible).
    b .lzh_reload0
.lzh_done_pad0:
    nop
    b .lzh_done
.lzh_block:
    subs r7, r7, #1
    bmi  .lzh_reload0i
    b    .lzh_have
.lzh_reload_tail:
    nop
    mov  r7, #7
    ldrb r6, [r0], #1
    mov  r12, r6, lsl #24
.lzh_have:
    movs r12, r12, lsl #1
    bcs  .lzh_backref
.lzh_lit_entry:
    eors   r3, r3, #8
    moveq  r8, #0
    ldrb   r9, [r0], #1
    orr    r8, r8, r9, lsl r3
    nop
    nop
    strhne r8, [r1], #2
    subs   r10, r10, #1
    bgt    .lzh_block
    nop
    nop
    nop
    b      .lzh_done
.lzh_reload0i:
    nop
.lzh_reload0:
    nop
    b .lzh_reload_tail
.lzh_backref:
    @ the 3 stream loads spread with 2 ALU each (P,P,L,A,A,L,A,A,L,A,A) like the 8-bit path,
    @ so a mid back-ref IRQ lands at the retail acceptance phase.
    nop
    nop
.lzh_backref_s:
    ldrb r9, [r0]
    mov  r5, r9, lsr #4
    add  r5, r5, #3
    ldrb r9, [r0], #1
    and  lr, r9, #0xf
    sub  r10, r10, r5
    ldrb r4, [r0], #1
    add  r4, r4, lr, lsl #8
    add  r4, r4, #1
    @ src byte ptr: cursor = r1 + 1 - (r3>>3)  (r3=0: low byte pending -> cursor = r1+1)
    sub r2, r1, r4
    sub r2, r2, r3, lsr #3
    .rept LZH_BR - 2
    nop
    .endr
    nop
.lzh_copy:
    nop
    eors  r3, r3, #8
    moveq r8, #0
    .rept LZH_CPA - 3
    nop
    .endr
    ldrb r9, [r2, #1]! @ source byte from dst (a pending byte reads stale, the bug above)
    .rept LZH_CPF
    nop
    .endr
    orr  r8, r8, r9, lsl r3
    strh r9, [sp]
    mov  lr, lr, lsl lr
    .rept LZH_CPG
    nop
    .endr
    strhne r8, [r1], #2
    subs   r5, r5, #1
    nop
    bne    .lzh_copy
    cmp    r10, #0
    ble    .lzh_done_ble
    b      .lzh_block_br
                                  @ (its literal-side branch pays the pads back, so br->lit is unshifted)
.lzh_done_ble:
.lzh_done:
    .rept LZH_DONE
    nop
    .endr
    mov   r12, #0
    mov   r2, #0
    stmia sp!, {r2, r10, r12}
    @ zeros to the locals below the frame, then restore and return
    ldmia sp!, {r4-r10, lr}
    bx    lr

@ protected/low source: return without touching dst. Restore the
@ pushed frame without the zero locals epilogue (the return is
@ reached before it). r0 = src+4, r1 = dst unchanged.
.lzh_badsrc:
    guard_pad 8 @ skip path cycle pad -> 123, matches the retail BIOS
    @ leave r3 = 0 here, overriding the `mov r3,#8` parity seed set
    @ before the guard. r3 is dispatcher-scratch, so this is end state
    @ only.
    mov   r3, #0
    add   sp, sp, #12
    ldmia sp!, {r4-r10, lr}
    bx    lr
.lzh_block_br:
                                  @ LZH_BR needs -3 on both exits, so the literal side is a full
                                  @ in-line clone, 3 tighter than the padded dispatch route (a
                                  @ branch cannot reach it in -3).
    subs   r7, r7, #1
    bmi    .lzh_reload_tail
    movs   r12, r12, lsl #1
    bcs    .lzh_backref_s
    eors   r3, r3, #8
    moveq  r8, #0
    ldrb   r9, [r0], #1
    orr    r8, r8, r9, lsl r3
    strhne r8, [r1], #2
    subs   r10, r10, #1
    bgt    .lzh_block
    nop
    nop
    nop
    b      .lzh_done
