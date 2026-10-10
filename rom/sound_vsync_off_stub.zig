// SPDX-License-Identifier: MIT
//! SoundDriverVSyncOff (SWI 0x28). A Timer2 IRQ fired at fixed delays into the call samples
//! ident, DMA1/DMA2 control, pcmDmaCounter and the first and last mix buffer words.
//! Timer3 measures the valid and bad ident call costs. Timer0 is stopped so FIFO DMA never runs.
export const _gba_header linksection(".gbaheader") = @import("header.zig").gbaHeader("SNDVSOFF", "SVOF");

const WORK: u32 = 0x03000000;
const RESULT: [*]volatile u32 = @ptrFromInt(0x02000100);
pub const DELAYS = [_]u16{ 40, 58, 59, 65, 66, 67, 68, 69, 70, 119, 120, 5656, 5657, 5679, 5680 };

fn reg16(a: u32) *volatile u16 {
    return @ptrFromInt(a);
}
fn reg32(a: u32) *volatile u32 {
    return @ptrFromInt(a);
}

fn swiInit() void {
    var r0: u32 = WORK;
    asm volatile ("swi 0x1a0000"
        : [r0] "+{r0}" (r0),
        :
        : .{ .memory = true, .r1 = true, .r2 = true, .r3 = true, .r12 = true, .lr = true, .cpsr = true });
}
fn swiOff() void {
    asm volatile ("swi 0x280000" ::: .{ .memory = true, .r0 = true, .r1 = true, .r2 = true, .r3 = true, .r12 = true, .lr = true, .cpsr = true });
}
fn swiOn() void {
    asm volatile ("swi 0x290000" ::: .{ .memory = true, .r0 = true, .r1 = true, .r2 = true, .r3 = true, .r12 = true, .lr = true, .cpsr = true });
}

// IRQ handler (ARM, called by the BIOS dispatcher). r1 = sample slot from SLOT.
fn irq() callconv(.naked) void {
    asm volatile (
        \\ldr r1, =0x020000fc
        \\ldr r1, [r1]
        \\mov r2, #0x03000000
        \\ldr r3, [r2]
        \\str r3, [r1]
        \\ldr r0, =0x040000c6
        \\ldrh r3, [r0]
        \\ldrh r0, [r0, #0x0c]
        \\orr r3, r3, r0, lsl #16
        \\str r3, [r1, #4]
        \\ldrb r3, [r2, #4]
        \\str r3, [r1, #8]
        \\ldr r3, [r2, #0x350]
        \\str r3, [r1, #12]
        \\add r2, r2, #0xf00
        \\ldr r3, [r2, #0xac]
        \\str r3, [r1, #16]
        \\mov r0, #0x04000000
        \\mov r3, #0
        \\add r0, r0, #0x100
        \\strh r3, [r0, #0x0a]
        \\add r0, r0, #0x100
        \\mov r3, #0x20
        \\strh r3, [r0, #2]
        \\bx lr
        \\.ltorg
    );
}

fn cost() u32 {
    reg32(0x0400010C).* = 0;
    reg32(0x0400010C).* = 0x00800000;
    swiOff();
    const c = reg16(0x0400010C).*;
    reg32(0x0400010C).* = 0;
    return c;
}

export fn romMain() linksection(".text.romstart") callconv(.c) noreturn {
    const si: [*]volatile u32 = @ptrFromInt(WORK);
    reg32(0x03007FFC).* = @intFromPtr(&irq);
    swiInit();
    reg16(0x04000102).* = 0;
    RESULT[0] = si[0];
    RESULT[1] = cost();
    RESULT[3] = si[0];
    si[0] = 0;
    RESULT[2] = cost();
    si[0] = 0x68736D53;
    reg16(0x04000200).* = 0x20;
    reg16(0x04000208).* = 1;
    for (DELAYS, 0..) |d, i| {
        @as(*volatile u8, @ptrFromInt(WORK + 4)).* = 0x55;
        for (0x350 / 4..0xFB0 / 4) |k| si[k] = 0xFFFFFFFF;
        swiOn();
        reg32(0x020000FC).* = @intFromPtr(&RESULT[4 + i * 5]);
        reg32(0x04000108).* = 0x00C00000 | @as(u32, 0x10000 - @as(u32, d));
        swiOff();
    }
    RESULT[4 + DELAYS.len * 5] = 0xA5A5;
    while (true) {}
}
