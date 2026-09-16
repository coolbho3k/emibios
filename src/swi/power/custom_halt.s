@ SPDX-License-Identifier: LGPL-3.0-or-later
@ CustomHalt (SWI 0x27): writes the caller's r2 to HALTCNT.
@
@ Entry:  r2 = HALTCNT value (bit 7 set = stop, clear = halt)
@ Return: r0-r3 untouched
.arm
swi_CustomHalt:
    mov  r12, #MMIO_BASE
    strb r2, [r12, #0x301]
    bx   lr
