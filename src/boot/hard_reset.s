@ SPDX-License-Identifier: LGPL-3.0-or-later
@ exception_reset has to be at 0x68. SoundDriverVSync can read the actual value of BIOS[0] before
@ sound init. A few games have been observed to fold this value into their state, so b exception_reset
@ must always branch to 0x68.
.arm
@ SWI 0x26 always reboots. Its first instructions sit below 0x68 because the reset vector at 0x68
@ checks POSTFLG before falling through to them.
swi_HardReset:
    @ Block pending game IRQs before switching to SYS mode.
    @ RegisterRamReset clears IE/IME later, but SWI 0x26 can enter here with a pending
    @ source and a stale game IRQ vector still installed.
    mov  r0, #MMIO_BASE
    strb r0, [r0, #(REG_IME - MMIO_BASE)] @ IME = 0 before SYS mode unmasks CPU IRQs
    add  r1, r0, #(REG_IE - MMIO_BASE)
    strh r0, [r1]                         @ IE = 0 before pending IRQ can re-latch
    msr  cpsr_cf, #MODE_SYS
    @ Start+Select at boot takes the multiboot download path instead of booting the cart.
    mov  r0, #MMIO_BASE
    add  r0, r0, #(REG_KEYINPUT - MMIO_BASE)
    ldrh r1, [r0]
    and  r1, r1, #(KEY_START | KEY_SELECT)
    b    .hard_reset_keys
@ Pad to retail's cost, then sp = 0x03007ff0 in the current mode, set N and return to lr-4.
@ sp is the only register free for the pad loop.
.debug_tail:
    mov sp, #8
.debug_burn:
    subs sp, sp, #1
    bne  .debug_burn
    ldr  sp, .debug_sp
    msr  cpsr_f, #0x80000000
    subs pc, lr, #4
.debug_sp:
    .word 0x03007ff0
.org 0x68, 0
exception_reset:
    @ After boot (POSTFLG = 1) a jump to 0 does not reboot. GBATEK says it goes to the debug
    @ vector. On retail this masks IRQ/FIQ in the current mode, leaves r12 = cpsr | 0xc0 and
    @ returns to the instruction that jumped. Calling a null pointer crashes.
    mov  r12, #MMIO_BASE
    ldrb r12, [r12, #(REG_POSTFLG - MMIO_BASE)]
    cmp  r12, #1
    bne  swi_HardReset
    mrs  r12, cpsr
    orr  r12, r12, #(IRQ_DISABLE | FIQ_DISABLE)
    nop @ IRQ mask lands at retail's cycle
    msr  cpsr_fc, r12
    b    .debug_tail
.hard_reset_keys:
    cmp r1, #0 @ both pressed reads 0
    @ The multiboot path  runs with IRQs live but never calls reset_modes, so set the
    @ IRQ mode stack here.
    msreq cpsr_c, #MODE_IRQ
    ldreq sp, =IRQ_STACK
    msreq cpsr_c, #MODE_SYS
    ldreq r0, =multiboot_receiver_detect + 1
    bxeq  r0 @ Thumb transport detector
    bl    reset_modes
    mov   r0, #0xff
    @ RegisterRamReset(0xff). Forces blank at entry, which changes clear timing.
    swi #0x010000
    mov r0, #0xff
    swi #0x010000                  @ second clear. Boot clears twice.
    bl  reset_modes
    mov r0, #MMIO_BASE
    ldr r1, =.hard_reset_IO_values @ table lives outside the cart handoff prefetch area
    mov r4, #8
    .hard_reset_IO_setup:
        ldrh r2, [r1], #2
        ldrh r3, [r1], #2
        strh r3, [r0, r2]
        subs r4, r4, #1
        bne  .hard_reset_IO_setup
    strh     r0, [r0, #(REG_DISPSTAT - MMIO_BASE)]
    strh     r0, [r0, #(REG_BG0CNT - MMIO_BASE)]
    strh     r0, [r0, #(REG_WINOUT - MMIO_BASE)]
    add      r1, r0, #(REG_IME - MMIO_BASE)
    strh     r0, [r1]
    @ POSTFLG = 1: byte store, so it hits only POSTFLG (0x04000300) and not the adjacent HALTCNT
    @ (0x04000301). Games read it to tell a cold boot from a warm reset.
    mov  r1, #1
    strb r1, [r0, #(REG_POSTFLG - MMIO_BASE)]
    @ Boot screen: draw logo + credits, hold, clean up. Handoff stays at the same PPU phase
    @ at cycle 76001675. It re-anchors to the PPU grid and recal burns the delta.
    bl boot_screen_entry
    @ Cart handoff: zeroed visible registers, then enter the cart at 0x08000000.
    msr cpsr_cf, #MODE_SYS
    mov r0, #0
    mov r1, #0
    mov r2, #0
    mov r3, #0
    mov r12, #0
    mov lr, #ROM_ENTRYPOINT
    bx  lr
    @ Bus note: these words are never executed. Games that read the BIOS area after boot should
    @ always see the last prefetched instruction until BIOS code runs again. The correct value we
    @ observe is 0xe129f000 (msr cpsr_fc, r0).
    .word 0xe129f000
    .word 0xe129f000
