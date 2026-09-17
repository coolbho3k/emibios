@ SPDX-License-Identifier: LGPL-3.0-or-later
@ exception_reset has to be at 0x68. SoundDriverVSync can read the actual value of BIOS[0] before
@ sound init. A few games have been observed to fold this value into their state, so b exception_reset
@ must always branch to 0x68.
.arm
.org 0x68, 0
exception_reset:
swi_HardReset:
    @ Block pending game IRQs before switching to SYS mode.
    @ RegisterRamReset clears IE/IME later, but SWI 0x26 can enter here with a pending
    @ source and a stale game IRQ vector still installed.
    mov  r0, #MMIO_BASE
    strb r0, [r0, #(REG_IME - MMIO_BASE)] @ IME = 0 before SYS mode unmasks CPU IRQs
    add  r1, r0, #(REG_IE - MMIO_BASE)
    strh r0, [r1]                         @ IE = 0 before pending IRQ can re-latch
    msr  cpsr_cf, #MODE_SYS
    bl   reset_modes
    mov  r0, #0xff
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
    @ Leave TM0CNT_L at 0. Matching the boot-sound stopped value (0xff8a) would
    @ briefly enable Timer0, and that perturbs games that never read it.
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
