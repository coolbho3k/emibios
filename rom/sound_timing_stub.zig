// SPDX-License-Identifier: MIT
//! SoundDriverInit / SoundDriverMode timing probe for tests/audio/sound_timing_test.zig.
//! Runs from IWRAM. Timer1 (with Timer2 cascaded) is started by DMA0 at a VBlank or HBlank edge,
//! so every end time is measured from a fixed PPU position.
//! Results: EWRAM 0x02000100 = word count, then the words; 0x02000000 = 0x7e57c0de when done.
export const _gba_header linksection(".gbaheader") = @import("header.zig").gbaHeader("SNDTIME", "STIM");

extern const sndt_begin: u8;
extern const sndt_end: u8;

comptime {
    asm (
        \\.section .text.sndt, "ax", %progbits
        \\.arm
        \\.balign 4
        \\.global sndt_begin
        \\.global sndt_end
        \\@ r10 = IO, r11 = output cursor, r12 = IO + 0x100
        \\sndt_begin:
        \\    mov  r10, #0x04000000
        \\    ldr  r11, =0x02000104
        \\    add  r12, r10, #0x100
        \\    ldr  r0, =0x03007ff0
        \\    mov  r1, #0
        \\    str  r1, [r0]
        \\    @ A: Mode with no driver
        \\    bl   tstart
        \\    mov  r0, #0
        \\    swi  0x1b0000
        \\    bl   tstop
        \\    @ B: Init at seven VBlank phases
        \\    mov  r9, #0
        \\1:  mov  r6, #0
        \\    mov  r7, r9
        \\    bl   vbl_trial_init
        \\    add  r9, r9, #1
        \\    cmp  r9, #7
        \\    bne  1b
        \\    @ C: Init around the line 159 edge, HBlank 150 anchor
        \\    mov  r9, #0
        \\1:  ldr  r7, =3136
        \\    add  r7, r7, r9
        \\    bl   hbl_trial_init
        \\    add  r9, r9, #1
        \\    cmp  r9, #16
        \\    bne  1b
        \\    @ D: Mode costs without a rate change
        \\    mov  r1, #0
        \\    strh r1, [r12, #2]
        \\    adr  r8, d_vals
        \\1:  ldr  r7, [r8], #4
        \\    cmp  r7, #0xff000000
        \\    beq  2f
        \\    bl   tstart
        \\    mov  r0, r7
        \\    swi  0x1b0000
        \\    bl   tstop
        \\    b    1b
        \\2:
        \\    @ E: Mode rate changes at seven VBlank phases
        \\    adr  r8, e_vals
        \\1:  ldr  r6, [r8], #4
        \\    cmp  r6, #0
        \\    beq  2f
        \\    mov  r9, #0
        \\3:  mov  r7, r9
        \\    bl   vbl_trial_mode
        \\    add  r9, r9, #1
        \\    cmp  r9, #7
        \\    bne  3b
        \\    b    1b
        \\2:
        \\    @ F: Mode rate change around the line 159 edge, HBlank 152 anchor
        \\    adr  r8, f_vals
        \\1:  ldr  r6, [r8], #4
        \\    cmp  r6, #0
        \\    beq  2f
        \\    ldr  r7, [r8], #4
        \\    mov  r9, #0
        \\3:  add  r7, r7, #1
        \\    bl   hbl_trial_mode
        \\    add  r9, r9, #1
        \\    cmp  r9, #8
        \\    bne  3b
        \\    b    1b
        \\2:
        \\    @ G: state seen by an IRQ during the Init wait, then the maxChans channel clear
        \\    ldr  r0, =0x03007ffc
        \\    adr  r1, irq_handler
        \\    str  r1, [r0]
        \\    ldr  r1, =0x3220
        \\    strh r1, [r10, #4]
        \\    add  r0, r10, #0x200
        \\    mov  r1, #4
        \\    strh r1, [r0]
        \\    mov  r1, #1
        \\    str  r1, [r0, #8]
        \\    ldr  r0, =0x02000080
        \\    mvn  r1, #0
        \\    str  r1, [r0]
        \\    str  r1, [r0, #4]
        \\    bl   wait160
        \\    ldr  r1, =0x00800000
        \\    str  r1, [r12]
        \\    ldr  r0, =0x03002000
        \\    swi  0x1a0000
        \\    add  r0, r10, #0x200
        \\    mov  r1, #0
        \\    str  r1, [r0, #8]
        \\    ldr  r0, =0x02000080
        \\    ldr  r1, [r0]
        \\    str  r1, [r11], #4
        \\    ldr  r1, [r0, #4]
        \\    str  r1, [r11], #4
        \\    ldr  r0, =0x03002000
        \\    mov  r1, #0xff
        \\    mov  r2, #12
        \\    add  r3, r0, #0x50
        \\1:  strb r1, [r3], #0x40
        \\    subs r2, r2, #1
        \\    bne  1b
        \\    mov  r1, #0
        \\    strh r1, [r12, #2]
        \\    mov  r0, #0x800
        \\    swi  0x1b0000
        \\    ldr  r0, =0x03002050
        \\    mov  r1, #0
        \\    mov  r2, #12
        \\1:  ldrb r3, [r0], #0x40
        \\    orr  r1, r1, r3
        \\    subs r2, r2, #1
        \\    bne  1b
        \\    str  r1, [r11], #4
        \\    ldr  r0, =0x02000100
        \\    sub  r1, r11, r0
        \\    mov  r1, r1, lsr #2
        \\    sub  r1, r1, #1
        \\    str  r1, [r0]
        \\    ldr  r0, =0x02000000
        \\    ldr  r1, =0x7e57c0de
        \\    str  r1, [r0]
        \\9:  b    9b
        \\
        \\irq_handler:
        \\    ldr  r3, =0x02000080
        \\    ldr  r1, =0x03002000
        \\    ldr  r1, [r1]
        \\    str  r1, [r3]
        \\    add  r1, r0, #0x100
        \\    ldrh r1, [r1, #2]
        \\    str  r1, [r3, #4]
        \\    add  r1, r0, #0x200
        \\    mov  r2, #4
        \\    strh r2, [r1, #2]
        \\    mov  r2, #0
        \\    strh r2, [r0, #4]
        \\    bx   lr
        \\
        \\tstart:
        \\    mov  r1, #0
        \\    str  r1, [r12, #4]
        \\    ldr  r1, =0x00800000
        \\    str  r1, [r12, #4]
        \\    bx   lr
        \\tstop:
        \\    ldrh r1, [r12, #4]
        \\    str  r1, [r11], #4
        \\    mov  r1, #0
        \\    str  r1, [r12, #4]
        \\    bx   lr
        \\wait160:
        \\    ldrh r1, [r10, #6]
        \\    cmp  r1, #160
        \\    beq  wait160
        \\1:  ldrh r1, [r10, #6]
        \\    cmp  r1, #160
        \\    bne  1b
        \\    bx   lr
        \\
        \\@ arm TM1 (count) and TM2 (cascade) so DMA0 starts TM1 at the next event in r2 (DMA0CNT)
        \\arm_anchor:
        \\    ldr  r1, =0x00800000
        \\    str  r1, [r12, #4]
        \\    mov  r1, #0
        \\    str  r1, [r12, #4]
        \\    str  r1, [r12, #8]
        \\    ldr  r1, =0x00840000
        \\    str  r1, [r12, #8]
        \\    add  r0, r10, #0xb0
        \\    adr  r1, word80
        \\    str  r1, [r0]
        \\    ldr  r1, =0x04000104
        \\    str  r1, [r0, #4]
        \\    str  r2, [r0, #8]
        \\    bx   lr
        \\
        \\@ busy wait r7 cycles in 1 cycle steps (r7 >= 8)
        \\delay:
        \\    mov  r1, r7, lsr #2
        \\    sub  r1, r1, #1
        \\1:  subs r1, r1, #1
        \\    bne  1b
        \\    and  r0, r7, #3
        \\    rsb  r0, r0, #3
        \\    add  pc, pc, r0, lsl #2
        \\    nop
        \\    nop
        \\    nop
        \\    nop
        \\    nop
        \\    bx   lr
        \\
        \\@ r6 = mode value (0: Init), r7 = delay
        \\vbl_trial_init:
        \\vbl_trial_mode:
        \\    push {lr}
        \\    mov  r1, #0
        \\    strh r1, [r12, #2]
        \\1:  ldrh r1, [r10, #6]
        \\    cmp  r1, #100
        \\    bne  1b
        \\    ldr  r2, =0x94000001
        \\    bl   arm_anchor
        \\1:  ldrh r1, [r10, #6]
        \\    cmp  r1, #160
        \\    bne  1b
        \\    add  r7, r7, #8
        \\    bl   delay
        \\    ldrh r5, [r12, #4]
        \\    movs r0, r6
        \\    ldreq r0, =0x03001000
        \\    swieq 0x1a0000
        \\    swine 0x1b0000
        \\    bl   rec_end
        \\    pop  {lr}
        \\    bx   lr
        \\
        \\@ r6 = mode value (0: Init), r7 = delay, anchored at HBlank of line 150 (Init) or 152 (Mode)
        \\hbl_trial_init:
        \\hbl_trial_mode:
        \\    push {lr}
        \\    mov  r1, #0
        \\    strh r1, [r12, #2]
        \\    cmp  r6, #0
        \\    moveq r3, #150
        \\    movne r3, #152
        \\1:  ldrh r1, [r10, #6]
        \\    cmp  r1, r3
        \\    bne  1b
        \\    ldr  r2, =0xa4000001
        \\    bl   arm_anchor
        \\1:  ldrh r1, [r12, #4]
        \\    cmp  r1, #0
        \\    beq  1b
        \\    bl   delay
        \\    ldrh r5, [r12, #4]
        \\    movs r0, r6
        \\    ldreq r0, =0x03001000
        \\    swieq 0x1a0000
        \\    swine 0x1b0000
        \\    bl   rec_end
        \\    pop  {lr}
        \\    bx   lr
        \\
        \\@ record start (r5), end time since the anchor, and the Timer0 counter
        \\rec_end:
        \\    ldrh r1, [r12, #4]
        \\    ldrh r2, [r12, #8]
        \\    ldrh r3, [r12]
        \\    orr  r1, r1, r2, lsl #16
        \\    str  r5, [r11], #4
        \\    str  r1, [r11], #4
        \\    str  r3, [r11], #4
        \\    bx   lr
        \\
        \\word80: .word 0x00800000
        \\d_vals: .word 0, 0x80, 0x100, 0x1000, 0x800000, 0x900100, 0xff000000
        \\e_vals: .word 0x10000, 0x40000, 0x90000, 0xc0000, 0
        \\f_vals: .word 0x10000, 2100, 0xc0000, 2172, 0
        \\.ltorg
        \\sndt_end:
    );
}

export fn romMain() linksection(".text.romstart") callconv(.c) noreturn {
    const src: [*]const u32 = @ptrCast(@alignCast(&sndt_begin));
    const dst: [*]volatile u32 = @ptrFromInt(0x03000000);
    const n = (@intFromPtr(&sndt_end) - @intFromPtr(&sndt_begin)) / 4;
    for (0..n) |i| dst[i] = src[i];
    asm volatile ("bx %[a]"
        :
        : [a] "r" (@as(u32, 0x03000000)),
    );
    unreachable;
}
