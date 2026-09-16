@ SPDX-License-Identifier: LGPL-3.0-or-later
.arm
exception_irq:
    stmfd sp!, {r0-r3, r12, lr}
    mov   r0, #MMIO_BASE
    add   lr, pc, #0    @ lr = 0x138 (the ldmfd below), the user handler's return address
    ldr   pc, [r0, #-4] @ jump to the user vector at [0x03fffffc], the IWRAM mirror of 0x03007ffc
    ldmfd sp!, {r0-r3, r12, lr}
    subs  pc, lr, #4    @ back to the interrupted instruction, CPSR restored from SPSR_irq
