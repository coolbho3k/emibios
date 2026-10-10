// SPDX-License-Identifier: MIT
//! Timer0 leftover and Halt IRQ return address.
//! Records at 0x02000100: TM0CNT_L at entry, the lr the BIOS IRQ handler stacked, the Timer0 low byte
//! read in the user handler, then 0xA5. The TM0CNT word at ROM 0xC4 is patched by the test.
export const _gba_header linksection(".gbaheader") = @import("header.zig").gbaHeader("HALTTIME", "HLTM");

comptime {
    asm (
        \\.section .text.romstart,"ax",%progbits
        \\.arm
        \\.global romMain
        \\romMain:
        \\    b     1f
        \\.Ltm0_cfg:
        \\    .word 0x00c0ffdd
        \\1:
        \\    mov   r3, #0x04000000
        \\    add   r2, r3, #0x100
        \\    ldrh  r0, [r2]
        \\    mov   r1, #0x02000000
        \\    add   r1, r1, #0x100
        \\    str   r0, [r1]
        \\    mov   r0, #0
        \\    str   r0, [r3, #0x80]
        \\    str   r0, [r3, #0x84]
        \\    str   r0, [r3, #0x200]
        \\    str   r0, [r3, #0x208]
        \\    adr   r4, .Lirq
        \\    ldr   r0, =0x03007ffc
        \\    str   r4, [r0]
        \\    mov   r0, #8
        \\    str   r0, [r3, #0x200]
        \\    mov   r0, #1
        \\    str   r0, [r3, #0x208]
        \\    ldr   r0, =0x4014
        \\    str   r0, [r3, #0x204]
        \\    add   r3, r3, #0x100
        \\    adr   r4, .Ltm0_cfg
        \\    adr   r0, .Lrun + 1
        \\    bx    r0
        \\.Lirq:
        \\    mov   r0, #0
        \\    mov   r3, #0x04000000
        \\    str   r0, [r3, #0x208]
        \\    add   r3, r3, #0x100
        \\    ldr   r8, [r3]
        \\    and   r8, r8, #0xff
        \\    str   r0, [r3]
        \\    mov   r6, lr
        \\    ldmfd sp!, {r0-r3, r12, lr}
        \\    mov   r5, lr
        \\    stmfd sp!, {r0-r3, r12, lr}
        \\    mov   lr, r6
        \\    mov   r3, #0x04000000
        \\    add   r3, r3, #0x100
        \\    mov   pc, lr
        \\.ltorg
        \\.thumb
        \\.Lrun:
        \\    ldr   r0, [r4]
        \\    str   r0, [r3]
        \\    swi   2
        \\    str   r5, [r1, #4]
        \\    mov   r0, r8
        \\    str   r0, [r1, #8]
        \\    movs  r0, #0xa5
        \\    str   r0, [r1, #12]
        \\2:  b     2b
        \\.arm
    );
}
