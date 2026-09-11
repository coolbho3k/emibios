@ SPDX-License-Identifier: GPL-3.0-or-later
@ IntrWait (SWI 0x04) and VBlankIntrWait (SWI 0x05)
.arm

@ VBlankIntrWait (SWI 0x05): IntrWait(r0 = 1, r1 = 1), discarding any stale VBlank flag and
@ waiting for a fresh one. Falls through.
swi_VBlankIntrWait:
    mov r0, #1
    mov r1, #1

@ IntrWait (SWI 0x04): wait for one of the interrupt flags in r1 to appear in the BIOS
@ interrupt flags word at 0x03fffff8.
@
@ Entry:  r0 = check/discard select, r1 = flags to wait for
@ Return: r0 = matched (acknowledged) flags, r1 unchanged, r3 = 0
@
@   r0 = 0 : return immediately if a waited flag is already set, otherwise halt and wait.
@   r0 != 0: acknowledge the currently-set matched flags first, then halt and wait for a new one.
@
@ The flags word is polled into r2. At the halt r2 is 0 (no flag yet), which is the value a VBlank
@ IRQ interrupts and a game can read off the IRQ stack. r4 holds the constant 1 used for the
@ IME = 1 write and is the only register saved here. r2 and r12 are dispatcher-restored.
swi_IntrWait:
    stmfd sp!, {r4, lr}
    mov   r12, #MMIO_BASE
    mov   r4, #1
    cmp   r0, #0
    bne   .intr_wait_ack
    mov   r3, #0
    nop
    nop
    b     .intr_wait_check0
.intr_wait_ack:
    mov  r3, #0
    strb r3, [r12, #(REG_IME - MMIO_BASE)]
    ldrh r2, [r12, #-8]
    ands r0, r1, r2 @ r0 = matched flags. ands sets Z so an interrupted CPSR shows it
    bic  r2, r2, r0
    strh r2, [r12, #-8]
    strb r4, [r12, #(REG_IME - MMIO_BASE)]
.intr_wait_halt:
    nop @ Timing note: 1 cyc acceptance slot between IME = 1 and the halt
    strb r3, [r12, #(REG_HALTCNT - MMIO_BASE)]
    @ Timing note: post wake window. The taken branch holds the halt on a prefetch refill, not
    @ an ALU op. Do not replace with nop padding.
    b .intr_wait_check
.intr_wait_check:
    strb   r3, [r12, #(REG_IME - MMIO_BASE)]
    ldrh   r2, [r12, #-8]
    ands   r0, r1, r2
    bicne  r2, r2, r0
    strhne r2, [r12, #-8]
    strb   r4, [r12, #(REG_IME - MMIO_BASE)]
    beq    .intr_wait_halt
    @ Timing note: pad the matched exit to the fixed return cost. The Timer prescaler phase
    @ sampled at return must stay stable.
    nop
    nop
    nop
    nop
    ldmfd sp!, {r4, lr}
    bx    lr

@ r0 = 0 first check: return immediately if a waited flag is already set. Same body as the wait
@ loop, but the matched exit is lighter because this path never paid the post wake branch.
.intr_wait_check0:
    strb   r3, [r12, #(REG_IME - MMIO_BASE)]
    ldrh   r2, [r12, #-8]
    ands   r0, r1, r2
    bicne  r2, r2, r0
    strhne r2, [r12, #-8]
    strb   r4, [r12, #(REG_IME - MMIO_BASE)]
    beq    .intr_wait_halt
    nop
    nop
    nop
    ldmfd  sp!, {r4, lr}
    bx     lr
