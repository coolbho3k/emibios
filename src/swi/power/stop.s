@ SPDX-License-Identifier: GPL-3.0-or-later
@ Stop (SWI 0x03): writes HALTCNT = 0x80 to enter low-power stop. The CPU and clocks stay
@ halted until a keypad, serial, or cartridge interrupt wakes it.
@
@ Entry:  none
@ Return: r0-r3 untouched
.arm
swi_Stop:
    mov  r11, #0x80
    mov  r12, #MMIO_BASE
    strb r11, [r12, #(REG_HALTCNT - MMIO_BASE)]
    bx   lr
