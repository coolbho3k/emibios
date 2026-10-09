@ SPDX-License-Identifier: LGPL-3.0-or-later
@ SoftReset (SWI 0x00) and the shared reset_modes setup.
@
@ Entry:  none (reads the return mode flag byte at 0x03007ffa)
@ Return: never. Enters ROM (flag 0x00) or RAM (any other value) in System mode with
@ r0-r12 = 0, SVC/IRQ/SYS stacks and SPSRs reset, and the top 0x200 bytes of IWRAM cleared.
@
@ Included from entrypoint.s with the boot/reset group, not with the other SWI handlers. Placement
@ is free: exception_reset starts at 0x68 (reset vector = 0xea000018) via .org 0x68 in
@ boot/hard_reset.s, and these are reached only by exception_reset's relative bl reset_modes and by
@ pointer (swi_table[0]). swi_SoftReset falls through to reset_modes.
.arm
swi_SoftReset:
    @ return mode flag byte at 0x03007ffa (= 0x04000000 - 6 via IWRAM mirroring)
    mov  r0, #MMIO_BASE
    ldrb r2, [r0, #-6]
    @ The flag selects the entrypoint by whole-byte != 0, not by bit0.
    @ 0x02 and 0x80 both return to RAM, only 0x00 returns to ROM.
    cmp       r2, #0
    moveq     lr, #ROM_ENTRYPOINT
    movne     lr, #RAM_ENTRYPOINT
    guard_pad 10
reset_modes:
    mov r0, #MODE_SVC
    msr cpsr_cf, r0
    ldr sp, =SVC_STACK
    mov lr, #0
    msr spsr_cf, lr
    mov r0, #MODE_IRQ
    msr cpsr_c, r0
    ldr sp, =IRQ_STACK
    mov lr, #0
    msr spsr_cf, lr
    mov r0, #MODE_SYS
    msr cpsr_cf, r0
    ldr sp, =SYS_STACK
    @ Clear the 0x200 byte protected region at 0x03007e00..0x03008000 and zero r0-r12 from it.
    mov r0, #IWRAM_START
    add r0, r0, #0x8000 @ r0 = 0x03008000 (end of IWRAM)
    ldr r1, =-0x200
    mov r2, #0
    .soft_reset_RAM_clear:
        str  r2, [r0, r1]
        adds r1, #4
        bne  .soft_reset_RAM_clear
    sub      r0, r0, #0x200
    ldmia    r0, { r0-r12 }
    bx       lr
@ Start+Select at boot. The multiboot path runs with IRQs live but never calls reset_modes, so set
@ the IRQ mode stack here.
hard_reset_multiboot:
    mov r0, #MODE_IRQ
    msr cpsr_c, r0
    ldr sp, =IRQ_STACK
    mov r0, #MODE_SYS
    msr cpsr_c, r0
    ldr r0, =multiboot_receiver_detect + 1
    bx  r0 @ Thumb transport detector
.ltorg
