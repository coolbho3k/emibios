@ SPDX-License-Identifier: GPL-3.0-or-later
@ Halt (SWI 0x02): writes HALTCNT = 0 to halt the CPU until an enabled interrupt fires.
@
@ Entry:  none
@ Return: r0-r3 untouched
.arm
swi_Halt:
    mov  r11, #0
    mov  r12, #MMIO_BASE
    strb r11, [r12, #(REG_HALTCNT - MMIO_BASE)]
    bx   lr
