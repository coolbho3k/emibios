@ SPDX-License-Identifier: LGPL-3.0-or-later
@ Run-length decompression: RLUnCompWrite8bit (0x14), RLUnCompWrite16bit (0x15).
@ Both handlers run all-Thumb, dispatched straight into Thumb (swi_table[0x14]/[0x15] = handler + 1).
@ The continuous 1-word/2-instr Thumb fetch reproduces the per byte cycle costs.
@
@ Common interface:
@   r0  Source: 32-bit header (bits 8-31 = decompressed size in bytes), then a stream of
@       {flag byte, data} runs (bit7 of the flag = compressed run)
@   r1  Destination (0x14: byte writes. 0x15: halfword buffered writes)
@ Return (both): pop callee-saved then bx (ARMv4T pop{pc} won't interwork back to the ARM dispatcher).
@
@ The cycle costs are the same in every memory region: the store cost (the only region varying
@ part) cancels, so one set of pads covers EWRAM/IWRAM/VRAM. RL never writes Palette, so there is no
@ PPU/DMA store phase to match. The NOP pads below are per call/block/byte, each adjusting one term
@ of the cost. Block counts settle against `remaining` at each block boundary, and valid streams sum
@ to `size`.

@ cycle pads that cost the same in every region
@ Each pad is one per (call / block / byte), adjusting one term of the cost. The store cost
@ (the only region dependent part) is untouched, so one set of pads holds across all regions.
    .set RL8_FIRST,   4
    .set RL8_LITBLK,  0
    .set RL8_RUNBLK,  0
    .set RL8_LITBYTE, 0
    .set RL8_RUNBYTE, 0
    .set RL8_EXIT,    0

.thumb

@ RLUnCompReadNormalWrite8bit (SWI 0x14): run-length, byte writes.
@
@ Return: r0 = src+4 + bytes consumed from the stream, r1 = dst + bytes written, r3 = 0x170,
@ r2 preserved (dispatch-restored).
@
@ header>>8 = decompressed size in bytes, then flag bytes:
@   bit7=1 -> run of (flag&0x7f)+3 copies of the next data byte
@   bit7=0 -> literal block of (flag&0x7f)+1 copied bytes
@ Blocks always run in full: an exact stream writes `size` bytes. A final block
@ more than the remainder overshoots past `size` (same as Write16bit below).
swi_RLUnCompReadNormalWrite8bit:
    push            {r4, r5, r6, r7, lr}
    ldmia           r0!, {r2}
    nop
    lsrs            r2, r2, #8
    beq             .rl8_size0
    guard_pad_thumb 3
    adds            r7, r2, #0
    @ Dual source region guard (src+4 and src+4+size). r0 = src+4, r2 = size.
    @ r3 = mask scratch (clobbered to 0x170 anyway), r6 = src end temp (pushed but otherwise unused).
    lsls            r3, r0, #4
    guard_pad_thumb 3
    lsrs            r3, r3, #29
    beq             .rl8_badsrc
    adds            r6, r0, r2
    lsls            r6, r6, #4
    lsrs            r6, r6, #29
    beq             .rl8_badsrc
    guard_pad_thumb RL8_FIRST
@ Overrun tolerant: a stream's final block may declare more bytes than remain. The block still
@ runs in full and leaves r7 (bytes remaining) negative. The signed block check exits.
.rl8_block:
    cmp  r7, #0
    ble  .rl8_done
    ldrb r4, [r0]
    adds r0, #1
    lsls r3, r4, #25
    lsrs r3, r3, #25
    cmp  r3, r4
    bne  .rl8_run
    adds r3, #1
    subs r7, r3
    .rept RL8_LITBLK
    nop
    .endr
.rl8_lit:
    ldrb r2, [r0]
    strb r2, [r1]
    adds r0, #1
    adds r1, #1
    .rept RL8_LITBYTE
    nop
    .endr
    subs r3, #1
    bne  .rl8_lit
    b    .rl8_block
.rl8_run:
    adds r3, #3
    subs r7, r3
    ldrb r5, [r0]
    adds r0, #1
    .rept RL8_RUNBLK
    nop
    .endr
.rl8_runl:
    strb r5, [r1]
    adds r1, #1
    .rept RL8_RUNBYTE
    nop
    .endr
    subs r3, #1
    bne  .rl8_runl
    b    .rl8_block
.rl8_size0:
    guard_pad_thumb 13
    b               .rl8_done
.rl8_badsrc:                @ guard only: source in BIOS region. Pad then fall into the shared return.
    guard_pad_thumb 8 @ skip path cycle pad -> 123, matches the retail BIOS
.rl8_done:
    .rept RL8_EXIT
    nop
    .endr
    pop {r4, r5, r6, r7}
    pop {r3} @ the return address (0x170), left in r3 as the residue
    bx  r3

@ 16-bit pads
    .set RL16_FIRST,      18
    .set RL16_EXIT,       9
    .set RL16_RUNHDR_PAD, 1

@ RLUnCompReadNormalWrite16bit (SWI 0x15): run-length, halfword buffered writes.
@
@ Return: r0 = src+4+consumed, r1 = dst+2*floor(size/2), r3 = 0x170, r2 preserved. The final
@ block may overshoot the declared size: it runs in full and the exit is remaining<=0.
@
@ IRQ-visible: a handler that spills the interrupted r4-r11 sees r4 = pair phase as the shift
@ amount (0 = low half next, 8 = high), r5 = remaining output bytes, r6 = byte staging
@ (then byte<<phase), r7 = halfword pair accumulator (cleared after each store). r2 = flag
@ scratch and r3 = block count are dispatcher-restored, invisible.
@ r0 trails one byte behind the stream: flag = [r0,#1], literal data = [r0,#1] with a post-use
@ add, run data = [r0,#2] reread twice per output byte (fixed source-read count), r0 frozen until
@ the block ends. Pair assembly is branch free: lsl r6,r4 places the byte, the low half toggles
@ r4=8 (movs: Z=0 N=0, C kept), the high half subs r4,#8 (Z=1) and flushes [strh, add r1,#2,
@ mov r7,#0]. Odd-length blocks exit mid pair and the phase carries across blocks (an odd parity
@ entry re-enters at the high half via the header dispatch).
swi_RLUnCompReadNormalWrite16bit:
    push  {r4, r5, r6, r7, lr}
    sub   sp, #12 @ the run-byte stash slot (below the caller SP: undefined scratch)
    movs  r4, #0
    ldmia r0!, {r2}
    lsrs  r2, r2, #8
    movs  r7, #0
    adds  r5, r2, #0
    beq   .rl16_done0s
    @ Dual source region guard (src+4 and src+4+size). r0 = src+4, r2 = size (pre pool reload).
    @ r3/r6 are scratch until decoder setup. The prologue timing budget includes the 7-cycle guard.
    decomp_guard_thumb r0, r3, .rl16_badsrc, r2, r6
.rl16_afterguard:
    @ block-1 entry: late r4 init, one ldrh (flag|data, src+4 always even), word stash, early r0
    @ consume, stash reread. The lsr#8 extracts the data and puts flag bit7 in C = the selector.
    ldr  r2, .rl16_pool0
    ldr  r2, .rl16_pool0
    movs r4, #0
    cmp  r5, #0
    ldrh r2, [r0]
    mov  r12, r2
    nop
    adds r2, #1
    mov  r2, r12
    lsls r3, r2, #25
    lsrs r3, r3, #25
    mov  r6, r12
    lsrs r2, r6, #8
    bcs  .rl16_runB1
    adds r3, #1
    subs r5, r3
    nop
    ldr  r2, [sp]
    str  r2, [sp]
    b    .rl16_litlE
.rl16_runB1:
    adds r3, #3
    subs r5, r3
    ldr  r2, [sp]
    nop
    nop
    str  r2, [sp]
    str  r2, [sp]
    ldrb r6, [r0, #1]
    str  r6, [sp]
    adds r0, #1
    b    .rl16_runpE_have
.rl16_done0s:
    nop
.rl16_badsrc:
    nop
    guard_pad_thumb 4
    guard_pad_thumb 9 @ skip path cycle pad -> 126, matches the retail BIOS
    add             sp, #12
    pop             {r4, r5, r6, r7}
    pop             {r3}
    bx              r3
.align 2
.rl16_pool0: .word 0xc0dec0de

@ The block machinery exists in two parity copies (even = low half next, odd = high half next).
@ Every block-end branch targets the copy matching the resulting parity, so odd parity block
@ boundaries cost the same as even ones (the odd-entry overhead is zero).
.rl16_blockE:
    nop
    adds r3, #1
    ldr  r2, [sp]
    ldrb r6, [r0, #1]
    lsrs r2, r6, #7
    bne  .rl16_runE
    adds r3, r6, #1
    subs r5, r3
    adds r0, #1
    ldr  r2, [sp]
    str  r2, [sp]
.rl16_litlE:
    ldrb r6, [r0, #1]
    lsls r6, r4
    orrs r7, r6
    adds r0, #1
    nop
    movs r4, #8
    ldr  r2, .rl16_pool
    subs r3, #1
    bne  .rl16_litlE_hi
    cmp  r5, #0
    ble  .rl16_exit
    nop
    nop
    b    .rl16_blockO
.rl16_litlE_hi:
    ldrb r6, [r0, #1]
    lsls r6, r4
    orrs r7, r6
    adds r0, #1
    nop
    subs r4, #8
    nop
    strh r7, [r1]
    adds r1, #2
    movs r7, #0
    subs r3, #1
    bne  .rl16_litlE
@ literal-block end, even parity (fall through only)
    cmp r5, #0
    ble .rl16_exit
    b   .rl16_blockE
.rl16_runE:
    lsls r3, r6, #25
    lsrs r3, r3, #25
    adds r3, #3
    subs r5, r3
    str  r2, [sp]
    str  r2, [sp]
    ldrb r6, [r0, #2]
    str  r6, [sp]
    adds r0, #2
.rl16_runpE:
    ldr r6, [sp]
.rl16_runpE_have:
    lsls r6, r4
    orrs r7, r6
    nop
    movs r4, #8
    ldr  r2, .rl16_pool
    subs r3, #1
    bne  .rl16_runpE_hi
    cmp  r5, #0
    ble  .rl16_exit
    nop
    nop
    b    .rl16_blockO
.rl16_runpE_hi:
    ldr  r6, [sp]
    lsls r6, r4
    orrs r7, r6
    nop
    subs r4, #8
    nop
    strh r7, [r1]
    adds r1, #2
    movs r7, #0
    subs r3, #1
    bne  .rl16_runpE
.rl16_runendE:
    cmp r5, #0
    ble .rl16_exit
    b   .rl16_blockE
.align 2
.rl16_pool: .word 0xc0dec0de      @ pc-rel scratch target, same cost in every region
.rl16_blockO:
    nop
    adds r3, #1
    ldr  r2, [sp]
    ldrb r6, [r0, #1]
    lsrs r2, r6, #7
    bne  .rl16_runO
    adds r3, r6, #1
    subs r5, r3
    adds r0, #1
    ldr  r2, [sp]
    str  r2, [sp]
.rl16_litlO:
    ldrb r6, [r0, #1]
    lsls r6, r4
    orrs r7, r6
    adds r0, #1
    subs r4, #8
    strh r7, [r1]
    adds r1, #2
    movs r7, #0
    subs r3, #1
    bne  .rl16_litlE
    cmp  r5, #0
    ble  .rl16_exit
    b    .rl16_blockE
.rl16_runO:
    lsls r3, r6, #25
    lsrs r3, r3, #25
    adds r3, #3
    subs r5, r3
    str  r2, [sp]
    str  r2, [sp]
    ldrb r6, [r0, #2]
    str  r6, [sp]
    adds r0, #2
.rl16_runpO:
    ldr  r2, [sp]
    lsls r6, r4
    orrs r7, r6
    subs r4, #8
    strh r7, [r1]
    adds r1, #2
    movs r7, #0
    subs r3, #1
    bne  .rl16_runpE
    b    .rl16_runendE
.rl16_exit:
    adds r0, #1
    nop
.rl16_done:
    add sp, #8
    pop {r2, r4, r5, r6, r7}
    pop {r3} @ r3 = saved lr = the 0x170 dispatcher return, left as the
    bx  r3   @ documented residue
