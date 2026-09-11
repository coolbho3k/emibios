@ SPDX-License-Identifier: GPL-3.0-or-later
@ Executed at end of BIOS. Both are tail-called from boot_screen_show.
@   boot_final_burn      - re-anchors to the PPU grid then burns until handoff.
@   handoff_latch_prime  - the very last BIOS code. Pins CPU bus latches.
.arm
.align 2
boot_final_burn:
    @ Re-anchor to the PPU grid before the burn.
    mov r12, #MMIO_BASE
    add r1, r12, #0x200
    @ VCount IRQ exits this spin, FINAL_BURN_PAD/FINAL_FINE then place the handoff dot.
    adr  r0, .vc_irqh
    ldr  r2, =USER_IRQ_VECTOR
    str  r0, [r2] @ user IRQ handler ptr (mirror of 0x03fffffc)
    ldrh r0, [r12, #4]
    bic  r0, r0, #0xff00
    orr  r0, r0, #(HANDOFF_SCANLINE << 8)
    orr  r0, r0, #0x0020
    strh r0, [r12, #4]
    mov  r0, #4
    strh r0, [r1]
    strh r0, [r1, #2]
    mov  r0, #1
    strh r0, [r1, #8]
    mrs  r0, cpsr
    bic  r0, r0, #0x80
    msr  cpsr_c, r0
.vc_wait:
    ldrh r0, [r1, #8] @ poll IME. .vc_irqh clears it when the VCount IRQ is taken
    cmp  r0, #0
    bne  .vc_wait
    mrs  r0, cpsr
    orr  r0, r0, #0x80
    msr  cpsr_c, r0
    mov  r0, #0
    strh r0, [r1]
    str  r0, [r2]
    ldrh r0, [r12, #4]
    bic  r0, r0, #0xff00
    bic  r0, r0, #0x0020
    strh r0, [r12, #4]
    mov  r0, #4
    strh r0, [r1, #2]
    @ Clear the VCount IRQ frame at [0x03007f88,0x03007fa0)
    mov r0, #0
    sub r2, r2, #0x74 @ r2 = 0x03007f88 (frame base)
    str r0, [r2]
    str r0, [r2, #4]
    str r0, [r2, #8]
    str r0, [r2, #12]
    str r0, [r2, #16]
    str r0, [r2, #20]
    @ Do not force blank here. bs_cleanup blanks later, outside the VCount anchor.
    ldr r2, =FINAL_BURN_PAD
.boot_final_burn_loop:
    subs r2, r2, #1
    bne  .boot_final_burn_loop
    .rept FINAL_FINE
    nop
    .endr
    bx lr

.vc_irqh:                                     @ IRQ mode. Handler (0x128) saved r0-r3,r12,lr. r1=REG_IE preserved
    mov  r3, #4
    strh r3, [r1, #2]
    mov  r3, #0
    strh r3, [r1, #8] @ IME = 0. Stops re-fire and signals .vc_wait to exit
    bx   lr

@ Very last BIOS code. Replays a fixed ARM tail and final data load before cart handoff.
@ Uses r2 (handoff re-zeros r0-r3), preserves lr.
.align 2
handoff_latch_prime:
    ldr  r2, =PRIME_LATCH_WORD @ fixes the last data bus word sampled at the handoff
    movs r2, #BOOT_PRIME_ITERS @ short count
.handoff_latch_prime_loop:
    subs r2, r2, #1
    bne  .handoff_latch_prime_loop
    bx   lr

.ltorg
