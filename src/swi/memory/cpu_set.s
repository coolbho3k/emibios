@ SPDX-License-Identifier: LGPL-3.0-or-later
@ CpuSet (SWI 0x0b) and CpuFastSet (SWI 0x0c)
@
@ Block copy and fill. CpuSet moves 16- or 32-bit units. CpuFastSet moves 32-bit units in
@ eight-word blocks. r2 is the mode word: low 21 bits are the count, bit 24 selects fill, bit 26
@ (CpuSet only) selects 32-bit.
@
@ Source-region guard: a source with no bit set in 0x0e000000 is in the BIOS region, so the
@ transfer is skipped and the destination left untouched. Each routine places the guard
@ differently.
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
    guard_pad_thumb 28 @ skip path cycle pad -> 116, matches the retail BIOS
    movs            r3, #0x17
    lsls            r3, r3, #4
    bx              lr
.cs_valid:
    push {r4, r5, lr}
    lsls r4, r2, #11
    lsrs r4, r4, #11
    beq  .cs_count0
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
    .set PRE16C, 13
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
    .set BUD16C, 13
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
    .set PRE16F, 9
    .rept PRE16F
    nop
    .endr
.cs_fill16_loop:
    adds r5, #2
    cmp  r5, lr
    strh r3, [r1, r5]
    nop
    bne  .cs_fill16_loop
    .set BUD16F, 9
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
    .set PRE32C, 10
    .rept PRE32C
    nop
    .endr
.cs_copy32_loop:
    nop
    cmp   r1, r12
    ldmia r0!, {r3}
    stmia r1!, {r3}
    bne   .cs_copy32_loop
    .set BUD32C, 10
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
    .set PRE32F, 6
    .rept PRE32F
    nop
    .endr
.cs_fill32_loop:
    @ Timing note: the store sits immediately before the branch, fixing the IRQ order.
    nop
    cmp   r1, r12
    stmia r1!, {r3}
    bne   .cs_fill32_loop
    .set BUD32F, 9
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
@ IRQ-visible: an IRQ can land during the count extraction. The BIOS IRQ stub banks only
@ r0-r3/r12/lr, so a handler that spills the interrupted r4-r11 sees the live r10 = r2<<11 (the
@ count before the final shift), r11 = 0x1f, and r12 = 0x20. Push first so the count completes a
@ couple of cycles before that window, then set those registers to read correctly at it. The
@ source region guard is deferred past the push, since the copy/fill it gates runs well after the
@ window. The pushed {r4-r11} frame must hold 0x170 in the r11 slot: some callers under-read that
@ slot after a CpuFastSet. r10 is restored to the caller's value by the ldmfd.
swi_CpuFastSet:
    mov   r11, #0x170
    stmfd sp!, {r4 - r11}
    mov   r10, r2, lsl #11
    mov   r12, #0x20
    mov   r11, #0x1f
    tst   r0, #SRC_REGION_MASK
    beq   .cfs_badsrc_framed
    .set CFS_PUBPAD, 1
    .rept CFS_PUBPAD
    nop
    .endr
    lsrs r10, r10, #11
    beq  .cpufastset_end0
    b    .cfs_body
swi_CpuFastSet_nv:
    @ No-guard entry for RegisterRamReset's boot-phase fills. Still interruptible, so it keeps the
    @ same live r10/r11 window and the same instruction order (count after the no-ops).
    mov   r11, #0x170
    stmfd sp!, {r4 - r11}
    mov   r10, #0x4000
    mov   r11, #0x1f
    nop
    nop
    nop
    mov   r10, r2, lsl #11
    lsrs  r10, r10, #11
    beq   .cpufastset_end0
.cfs_body:
    tst r2, #(1 << 24)
    bne .cpufastset_fill
    .set LEFC, 7
    .rept LEFC
    nop
    .endr
.cpufastset_copy:
    ldmia r0!, {r2, r3, r4, r5, r6, r7, r8, r9}
    stmia r1!, {r2, r3, r4, r5, r6, r7, r8, r9}
    subs  r10, r10, #8
    bgt   .cpufastset_copy
    .rept (8 - LEFC)
    nop
    .endr
    b .cpufastset_restore
.cpufastset_fill:
    ldr r2, [r0]
    mov r3, r2
    mov r4, r2
    mov r5, r2
    mov r6, r2
    mov r7, r2
    mov r8, r2
    mov r9, r2
    .set LEFF, 3
    .rept LEFF
    nop
    .endr
.cpufastset_fill_loop:
    stmia r1!, {r2, r3, r4, r5, r6, r7, r8, r9}
    subs  r10, r10, #8
    bgt   .cpufastset_fill_loop
    .rept (9 - LEFF)
    nop
    .endr
.cpufastset_restore:
    nop
    ldmfd sp!, {r4 - r11}
    bx    lr
.cpufastset_end0:
    @ count 0: pad to a fixed cost. The register-specified shift is two cycles, result discarded.
    mov   r12, r12, lsl r12
    nop
    nop
    ldmfd sp!, {r4 - r11}
    bx    lr
.cfs_badsrc_framed:
    guard_pad 8 @ skip path cycle pad -> 118, matches the retail BIOS
    ldmfd     sp!, {r4 - r11}
    mov       r3, #0x170
    bx        lr
