// SPDX-License-Identifier: MIT
//! SoundDriverMain re-entrancy lock. ident must read "Smsh"+1 inside the sequencer hook and a
//! nested SWI 0x1C must be a no-op.
//! Records: hook call count, ident during the call, ident after.
export const _gba_header linksection(".gbaheader") = @import("header.zig").gbaHeader("SNDREENT", "SRNT");

const WORK: u32 = 0x02010000;
const RESULT: [*]volatile u32 = @ptrFromInt(0x02000100);

fn swiInit(work: u32) void {
    var r0 = work;
    asm volatile ("swi %[n]"
        : [r0] "+{r0}" (r0),
        : [n] "i" (@as(u32, 0x1A) << 16),
        : .{ .memory = true, .r1 = true, .r2 = true, .r3 = true, .r12 = true, .lr = true, .cpsr = true });
}
fn swiMain() void {
    asm volatile ("swi %[n]"
        :
        : [n] "i" (@as(u32, 0x1C) << 16),
        : .{ .memory = true, .r0 = true, .r1 = true, .r2 = true, .r3 = true, .r12 = true, .lr = true, .cpsr = true });
}

fn secondHook(arg: u32) callconv(.c) void {
    RESULT[8] = arg;
}

fn thumbHook() callconv(.naked) void {
    asm volatile (
        \\.thumb
        \\ldr r1, =0x02000124
        \\str r0, [r1]
        \\bx lr
        \\.ltorg
        \\.arm
    );
}

fn hook(arg: u32) callconv(.c) void {
    RESULT[7] = arg;
    const si: [*]volatile u32 = @ptrFromInt(WORK);
    RESULT[0] += 1;
    if (RESULT[0] == 1) {
        RESULT[1] = si[0];
        swiMain();
    }
}

export fn romMain() linksection(".text.romstart") callconv(.c) noreturn {
    swiInit(WORK);
    const si: [*]volatile u32 = @ptrFromInt(WORK);
    RESULT[5] = 1;
    for (0x28 / 4..0x40 / 4) |i| RESULT[5] &= si[i] & 1;
    si[0x350 / 4] = 0xFFFFFFFF;
    swiMain();
    RESULT[4] = si[0];
    RESULT[6] = si[0x350 / 4];
    RESULT[0] = 0;
    RESULT[1] = 0;
    si[0x20 / 4] = @intFromPtr(&hook);
    si[0x24 / 4] = 0x12345678;
    si[0x28 / 4] = @intFromPtr(&secondHook);
    swiMain();
    RESULT[2] = si[0];
    si[0x20 / 4] = @intFromPtr(&thumbHook) | 1;
    si[0x24 / 4] = 0x87654321;
    swiMain();
    RESULT[10] = si[0];
    RESULT[3] = 0xA5A5;
    while (true) {}
}
