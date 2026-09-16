@ SPDX-License-Identifier: GPL-3.0-or-later
@ GetBiosChecksum (SWI 0x0d): returns the same checksum as the retail BIOS, and takes the same
@ number of cycles to execute (41042).
@
@ Entry:  none
@ Return: r0 = 0xbaae187f (same as retail checksum), r1 = 1, r3 = 0x4000 (end of BIOS)
@ r2 and r4-r11 preserved.
.arm
swi_GetBiosChecksum:
    # Disable IRQ and FIQ
    mrs r1, cpsr
    orr r3, r1, #(IRQ_DISABLE | FIQ_DISABLE)
    msr cpsr_c, r3
    ldr r0, =0xbaae187f
    .set GBC_COUNT, 10237
    ldr r3, =GBC_COUNT
.gbc_loop:
    subs r3, r3, #1
    bne  .gbc_loop
    mov  r3, r3, lsl r3
    mov  r3, #0x4000
    # Re-enable IRQ and FIQ
    msr cpsr_c, r1
    mov r1, #1
    bx  lr
    .ltorg
