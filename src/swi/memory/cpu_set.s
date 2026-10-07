@ SPDX-License-Identifier: LGPL-3.0-or-later
@ CpuSet (SWI 0x0b) and CpuFastSet (SWI 0x0c)
@
@ Block copy and fill. CpuSet moves 16- or 32-bit units. CpuFastSet moves 32-bit units in
@ eight-word blocks. r2 is the mode word: low 21 bits are the count, bit 24 selects fill, bit 26
@ (CpuSet only) selects 32-bit.
@
@ Source-region guard: a source with no bit set in 0x0e000000 is in the BIOS region, so the
@ transfer is skipped and the destination left untouched. Each routine places the guard
@ differently. CpuSet also skips when src + count * 4 has none of those bits set.
@
@ Timing note: each path splits its nonloop pad into a PRE pad before the first store and a POST
@ pad after the last, held so PRE + POST is constant. The in-loop pads set the per element period.
@ Do not retune those for store phase.

@ CpuSet (SWI 0x0b), Thumb (entered through the +1 in the SWI table, returns with bx to the ARM
@ dispatcher).
@
@ Entry:  r0 = src, r1 = dst, r2 = mode word (decode above)
@ Return: 16-bit transfers leave r0/r1 unchanged, 32-bit transfers advance them; r3 = 0x170 on
@ every path. r4-r11 preserved, r2/r12 dispatcher-restored.
@
@ The 32-bit path uses single-register LDMIA/STMIA so an unaligned pointer reads and writes the
@ aligned word while the pointer itself advances unaligned.
.thumb
swi_CpuSet:
    movs            r3, #0x70
    lsls            r3, r3, #21
    tst             r0, r3
    bne             .cs_valid
    ldr             r3, [sp] @ skip path cycle pad -> 116, matches the retail BIOS
    ldr             r3, [sp]
    ldr             r3, [sp]
    guard_pad_thumb 10
    ldr             r3, [sp]
    ldr             r3, [sp]
    ldr             r3, [sp]
    movs            r3, #0x17
    lsls            r3, r3, #4
    bx              lr
.cs_valid:
    push {r4, r5, lr}
    lsls r4, r2, #11
    lsrs r4, r4, #11
    beq  .cs_count0
    lsls r5, r4, #2
    adds r5, r0, r5
    lsls r5, r5, #4
    lsrs r5, r5, #29
    beq  .cs_end_skip
    lsls r5, r2, #5
    bmi  .cs_32
    @ ---- 16-bit (r0/r1 unchanged) ----
    lsls r5, r2, #7
    bmi  .cs_fill16
.cs_copy16:
    lsls r4, r4, #1
    subs r3, r4, #2
    mov  lr, r3
    movs r5, #0
    subs r5, #2
    .set PRE16C, 8
    .rept PRE16C
    nop
    .endr
.cs_copy16_loop:
    adds r5, #2
    cmp  r5, lr
    ldrh r3, [r0, r5]
    strh r3, [r1, r5]
    nop
    bne  .cs_copy16_loop
    .set BUD16C, 8
    .rept (BUD16C - PRE16C)
    nop
    .endr
    b .cs_end
.cs_fill16:
    lsls r4, r4, #1
    subs r3, r4, #2
    mov  lr, r3
    movs r5, #0
    subs r5, #2
    ldrh r3, [r0]
    .set PRE16F, 4
    .rept PRE16F
    nop
    .endr
.cs_fill16_loop:
    adds r5, #2
    cmp  r5, lr
    strh r3, [r1, r5]
    nop
    bne  .cs_fill16_loop
    .set BUD16F, 4
    .rept (BUD16F - PRE16F)
    nop
    .endr
    b .cs_end
.cs_32:
    lsls r5, r2, #7
    bmi  .cs_fill32
.cs_copy32:
    lsls r4, r4, #2
    adds r5, r1, r4
    subs r3, r5, #4
    mov  r12, r3
    .set PRE32C, 5
    .rept PRE32C
    nop
    .endr
.cs_copy32_loop:
    nop
    cmp   r1, r12
    ldmia r0!, {r3}
    stmia r1!, {r3}
    bne   .cs_copy32_loop
    .set BUD32C, 5
    .rept (BUD32C - PRE32C)
    nop
    .endr
    b .cs_end
.cs_fill32:
    @ Mid-fill an IRQ that spills the interrupted r4-r11 sees r4 = byte length, r5 = dst end,
    @ r6-r11 = caller's, and flags N=1,C=0. The bound lives in r12 so r5 stays the full end.
    lsls  r4, r4, #2
    adds  r5, r1, r4
    subs  r3, r5, #4
    mov   r12, r3
    ldmia r0!, {r3}
    .set PRE32F, 1
    .rept PRE32F
    nop
    .endr
.cs_fill32_loop:
    @ Timing note: the store sits immediately before the branch, fixing the IRQ order.
    nop
    cmp   r1, r12
    stmia r1!, {r3}
    bne   .cs_fill32_loop
    .set BUD32F, 4
    .rept (BUD32F - PRE32F)
    nop
    .endr
.cs_end:
    pop  {r4, r5}
    pop  {r3}
    mov  r12, r3
    movs r3, #0x17
    lsls r3, r3, #4 @ r3 = 0x170 residue
    bx   r12
.cs_end_skip:
    nop
    b .cs_end
.cs_count0:
    .set CS0, 4
    .rept CS0
    nop
    .endr
    b .cs_end
    .ltorg
.arm
.align 2

@ CpuFastSet (SWI 0x0c), ARM.
@
@ Entry:  r0 = src, r1 = dst, r2 = mode word (decode above; the count rounds up to 8-word blocks)
@ Return: copy advances r0/r1 past the last block, fill advances r1 only; r3 = 0x170 on the guard
@ skip, the 3rd word of the last block after a copy (the fill value after a fill), the caller's r3
@ untouched on count 0. r4-r11 preserved, r2/r12 dispatcher-restored.
@
@ The pushed lr slot holds 0x170, which some callers read after a CpuFastSet. Exits pop it into
@ r11 and return through lr, since RegisterRamReset's IWRAM fill overwrites the frame.
swi_CpuFastSet:
    stmfd sp!, {r4 - r10, lr}
    mov   r10, r2, lsl #11
    mov   r12, r10, lsr #11
    b     .+4
    cmp   r12, #0
    beq   .cfs_count0
    nop
    nop
    tst   r0, #SRC_REGION_MASK
    beq   .cfs_badsrc_framed
    b     .+4
    nop
    add   r10, r1, r12, lsl #2
.cfs_body:
    tst r2, r2, lsr #25 @ C = fill bit
    bcc .cpufastset_copy
    ldr r2, [r0]
    mov r3, r2
    mov r4, r2
    mov r5, r2
    mov r6, r2
    mov r7, r2
    mov r8, r2
    mov r9, r2
.cpufastset_fill_loop:
    cmp   r1, r10
    stmcc r1!, {r2, r3, r4, r5, r6, r7, r8, r9}
    bcc   .cpufastset_fill_loop
    b     .cpufastset_restore
.cpufastset_copy:
    cmp   r1, r10
    ldmcc r0!, {r2, r3, r4, r5, r6, r7, r8, r9}
    stmcc r1!, {r2, r3, r4, r5, r6, r7, r8, r9}
    bcc   .cpufastset_copy
.cpufastset_restore:
    ldmfd sp!, {r4 - r11}
    bx    lr
swi_CpuFastSet_nv:
    @ No-guard entry for RegisterRamReset's boot-phase fills. r12 holds the caller's return address.
    mov   r11, #0x170
    stmfd sp!, {r4 - r11}
    mov   r10, #0x4000
    mov   r11, #0x1f
    nop
    nop
    nop
    mov   r10, r2, lsl #11
    movs  r10, r10, lsr #11
    beq   .cpufastset_end0
    add   r10, r1, r10, lsl #2
    b     .cfs_body
.cfs_count0:
    mov r12, r12, lsl r12
.cpufastset_end0:
    @ count 0: pad to a fixed cost. The register-specified shift is two cycles, result discarded.
    mov   r12, r12, lsl r12
    nop
    nop
    ldmfd sp!, {r4 - r11}
    bx    lr
.cfs_badsrc_framed:
    guard_pad 3 @ skip path cycle pad -> 118, matches the retail BIOS
    ldmfd     sp!, {r4 - r11}
    mov       r3, #0x170
    bx        lr
