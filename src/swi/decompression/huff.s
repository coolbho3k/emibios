@ SPDX-License-Identifier: GPL-3.0-or-later
@ HuffUnCompReadNormal (SWI 0x13): decompresses Huffman streams with 4-bit or 8-bit symbols.
@
@ Entry:  r0 = source: 32-bit header (bits 0-3 = symbol bit-width 4/8, bits 8-31 = size in
@              bytes), then a u8 tree size, the tree, then the bitstream (32-bit words,
@              MSB = first bit)
@         r1 = destination (32-bit aligned)
@ Return: r0 = bitstream ptr after the last word read, r1 = dst + round_up(size,4), r3 = last
@ word written; size 0 writes nothing and leaves r0 = src, r3 = the header word. r4-r11
@ saved/restored.
@
@ The tree root is at src+5. From a node at address A with offset field o:
@   child0 = (A & ~1) + o*2 + 2
@   child1 = child0 + 1
@ Bit 7 of the node marks child0 as a data node, bit 6 marks child1 as a data node.
@
@ Output is written in whole 32-bit words. The size rounds up to a word and decoding keeps
@ consuming the (zero) padding bits to fill the last word.
@
@ IRQ-visible (SPSR mid-call = ARM, T=0): a handler that spills the interrupted
@ r4-r11 sees r4 = width, r5 = bit word, r6 = node byte (then masked offset), r7 = node address,
@ r8 = bits left, r9 = 0 (the zero shift-reg that makes `mov rX,rX,lsl r9` a 2 cycle pad),
@ r10 = decoded symbol (persistent), r11 = 32-width. Root/child-addr temps live in r12/lr
@ (dispatcher-restored, IRQ-invisible).
@
@ Timing note: the per symbol walk has a fixed instruction schedule, so a mid symbol IRQ lands
@ at a known point with those registers live.
@
@ Region parity: each tree node byte and the tree size byte are read twice (once per field).
@ The walk loop is duplicated per width. Only the word boundary mask (3 for 8-bit, 7 for 4-bit)
@ differs.
.arm
    .set HUFF_LOAD8, 8
    .set HUFF_LOAD4, 5
    .set HUFF_DONE,  10
    .set HUFF_DONE8, 13
    .set HUFF_DONE4, 13
@ No-guard entry for a BIOS resident blob (source below 0x4000, which the guard rejects).
@ Sets up the decoder and enters the shared body. No fixed cycle target. r0 = src, r1 = dst. ARM.
swi_HuffUnCompReadNormal_nv:
    push {r4-r11, lr}
    mov  r9, #0
    ldrb r4, [r0]
    and  r4, r4, #0xf
    rsb  r11, r4, #12
    ldr  r2, [r0]
    mov  r2, r2, lsr #8
    ldrb r10, [r0, #4]!
    add  r10, r10, #1
    add  r7, r0, #1
    mov  r12, r7
    b    .huff_afterguard
swi_HuffUnCompReadNormal:
    push {r4-r11, lr}
    @ Read the size and tree-size byte before the source guard. Rejected sources skip decoder setup.
    ldr  r10, [r0]
    movs r2, r10, lsr #8
    ldrb r10, [r0, #4]!
    beq  .huff_done0 @ size 0 (Z from the movs, the ldrb left it intact)
    @ Dual source region guard (src+4 and src+4+size). r0 = src+4, r2 = size.
    @ lr = source end temp (IRQ-invisible, the stub overwrites lr). Reloaded to #1 below.
    decomp_guard_arm r0, .huff_badsrc, r2
    @ r0 = src+4: the tree root is at +1 and header byte0 at -4. r10 holds the tree size byte.
    mov  r9, #0
    add  r10, r10, #1
    add  r7, r0, #1
    ldrb r4, [r0, #-4]
    mov  r12, r7
    and  r4, r4, #0xf
    nop @ prologue timing pad
    rsb  r11, r4, #12
    mov  r6, r6, lsl r9
    nop
    b    .hp1
.hp1:
    nop
    b .hp2
.hp2:
    nop
    nop
.huff_afterguard:
    mov   lr, #1
    add   r2, r2, #3
    add   r0, r0, r10, lsl #1
    bic   r2, r2, #3
    mov   r8, #32
    ldr   r5, [r0], #4
    subs  r8, r8, #1
    cmp   r4, #4
    moveq r2, r2, lsl #1 @ 4-bit: 2 symbols per byte
    bne   .h8_first

@ First 4-bit symbol: load the root node before shifting the bitstream. Further tree steps
@ use .h4_walk; a leaf is packed here.
.h4_first:
    ldrb  r6, [r7]
    mov   r6, r6, lsl r9
    movs  r5, r5, lsl #1
    add   r10, r7, #1 @ root is src+5 (odd): (r7&~1)+2 == r7+1
    ldrb  r6, [r7]
    and   r11, r6, #0x3f
    adc   r11, r11, r11
    tstcc r6, #0x80
    tstcs r6, #0x40
    addeq r12, r10, r11
    beq   .h4_fstub
    mov   r6, r6, lsl r9
    ldrb  r10, [r10, r11]
    rsb   r11, r4, #32
    mov   r10, r10, lsl r11
    orr   r3, r10, r3, lsr #4
    subs  r2, r2, #1
    bne   .h4_loop
    b     .huff_last4
.h4_fstub:
    mov r3, r3, lsr #4
    nop
    b   .h4_walk

@ 8-bit symbol loop
.h8_loop:
    @ symbol layout mirrors .h4_loop (8-bit masks/shifts).
    movs r12, r2, lsl #30
.h8_top:
    streq r3, [r1], #4
    rsb   r11, r4, #12
.h8_entry:
    mov r12, r7
    mov r3, r3, lsr #8
    nop
    b   .h8_walk
.h8_walk:
    subs r8, r8, #1
    bmi  .h8_reload
.h8_have8:
    mov   r10, #1
    movs  r5, r5, lsl #1
    ldrb  r6, [r12]
    mov   r6, r6, lsl r9
    mov   r10, r12, lsr #1
    mov   r10, r10, lsl #1
    ldrb  r11, [r12]
    and   r11, r11, #0x3f
    adc   r11, r11, r11
    add   r10, r10, #2
    tstcc r6, #0x80
    tstcs r6, #0x40
    beq   .h8_desc
    mov   r6, r6, lsl r9
    ldrb  r10, [r10, r11]
    rsb   r11, r4, #32
    orr   r3, r3, r10, lsl r11
    subs  r2, r2, #1
    nop
    bne   .h8_loop
    b     .huff_last8
.h8_desc:
    add r12, r10, r11
    nop
    b   .h8_walk
.h8_reload:
    ldr  r5, [r0], #4
    mov  r8, #32
    subs r8, r8, #1
    b    .h8_have8
.huff_last8:
    str       r3, [r1], #4
    guard_pad HUFF_DONE8
    pop       {r4-r11, lr}
    bx        lr

@ symbol-1 block, 8-bit: same shape as .h4_first (8-bit pack).
.h8_first:
    ldrb r6, [r7]
    @ (no 2-cyc pad here: this reclaims the dispatch bne-taken +2. The symbol-1 path is a
    @  per-width split that pays 3 cyc where a shared path would pay 1)
    movs  r5, r5, lsl #1
    add   r10, r7, #1
    ldrb  r6, [r7]
    and   r11, r6, #0x3f
    adc   r11, r11, r11
    tstcc r6, #0x80
    tstcs r6, #0x40
    addeq r12, r10, r11
    beq   .h8_fstub
    mov   r6, r6, lsl r9
    ldrb  r10, [r10, r11]
    rsb   r11, r4, #32
    mov   r10, r10, lsl r11
    orr   r3, r10, r3, lsr #8
    subs  r2, r2, #1
    bne   .h8_loop
    b     .huff_last8
.h8_fstub:
    mov r3, r3, lsr #8
    nop
    b   .h8_walk

@ 4-bit symbol loop (identical but for the boundary mask)
.h4_loop:
    @ Per-symbol layout: common boundary block, then the walk step (leaf, or internal via the
    @ two branch descend stub), then the leaf tail. The node walks in r12 (r7 stays root, IRQ-
    @ visible). r11 cycles 12-width -> node byte -> fold -> 32-width per symbol. r10 = seed 1 ->
    @ base fold -> base+2 -> symbol.
    movs r12, r2, lsl #29
.h4_top:
    streq r3, [r1], #4
    rsb   r11, r4, #12
.h4_entry:
    mov r12, r7
    mov r3, r3, lsr #4
    nop
    b   .h4_walk
.h4_walk:
    subs r8, r8, #1
    bmi  .h4_reload
.h4_have4:
    mov   r10, #1
    movs  r5, r5, lsl #1
    ldrb  r6, [r12]
    mov   r6, r6, lsl r9
    mov   r10, r12, lsr #1
    mov   r10, r10, lsl #1
    ldrb  r11, [r12]
    and   r11, r11, #0x3f
    adc   r11, r11, r11 @ r11 = offset*2 + bit
    add   r10, r10, #2
    tstcc r6, #0x80
    tstcs r6, #0x40
    beq   .h4_desc
    mov   r6, r6, lsl r9
    ldrb  r10, [r10, r11]
    rsb   r11, r4, #32
    orr   r3, r3, r10, lsl r11
    subs  r2, r2, #1
    nop
    bne   .h4_loop
    b     .huff_last4
.h4_desc:
    add r12, r10, r11
    nop
    b   .h4_walk
.h4_reload:
    ldr  r5, [r0], #4
    mov  r8, #32
    subs r8, r8, #1
    b    .h4_have4
.huff_last4:
    str       r3, [r1], #4
    guard_pad HUFF_DONE4
    pop       {r4-r11, lr}
    bx        lr
.huff_badsrc:                    @ source in BIOS/low region: return, dst untouched.
    guard_pad 5 @ skip path cycle pad -> 121, matches the retail BIOS
    @ leave r0 = original src, not src+4 (the guard runs after the
    @ tree size read `ldrb r10,[r0,#4]!` advanced r0). r1/r2/r3 pass
    @ through unchanged.
    sub r0, r0, #4
    pop {r4-r11, lr}
    bx  lr
.huff_done0:                     @ size 0: end state r0 = src, r3 = header
    sub r0, r0, #4
    ldr r3, [r0]
.huff_done:
    guard_pad HUFF_DONE
    pop       {r4-r11, lr}
    bx        lr
