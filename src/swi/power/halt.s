@ SPDX-License-Identifier: LGPL-3.0-or-later
@ Halt (SWI 0x02): writes HALTCNT = 0 to halt the CPU until an enabled interrupt fires.
@
@ Entry:  none
@ Return: r0-r3 untouched
.arm
swi_Halt:
    mov r2, #0
    mov r12, #MMIO_BASE
    @ Timing note: 3 cycles before the halt write set which IRQs still wake it.
    nop
    nop
    nop
    strb r2, [r12, #(REG_HALTCNT - MMIO_BASE)]
    bx   lr
