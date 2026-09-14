// SPDX-License-Identifier: MIT
export const _gba_header linksection(".gbaheader") = @import("header.zig").gbaHeader("SNDLOOP", "SLUP");
const WORK: usize = 0x02010000;
const WAVE: usize = 0x02012000;
fn byte(a: usize) *volatile u8 {
    return @ptrFromInt(a);
}
fn word(a: usize) *volatile u32 {
    return @ptrFromInt(a);
}
fn init() void {
    var r0: u32 = WORK;
    asm volatile ("swi 0x1a0000"
        : [r0] "+{r0}" (r0),
        :
        : .{ .memory = true, .r1 = true, .r2 = true, .r3 = true, .r12 = true, .lr = true, .cpsr = true });
}
fn main() void {
    asm volatile ("swi 0x1c0000" ::: .{ .memory = true, .r0 = true, .r1 = true, .r2 = true, .r3 = true, .r12 = true, .lr = true, .cpsr = true });
}
export fn romMain() linksection(".text.romstart") callconv(.c) noreturn {
    for (0..4) |case| {
        init();
        word(0x040000c4).* = 0;
        word(0x040000d0).* = 0;
        byte(WORK + 4).* = 1;
        byte(WORK + 6).* = 1;
        byte(WORK + 7).* = 15;
        word(WORK + 0x10).* = 16;
        word(WORK + 0x14).* = 8192;
        word(WORK + 0x18).* = 1024;
        word(WAVE).* = if (case == 3) 0 else 0x40000000;
        word(WAVE + 8).* = if (case == 2) 7 else 3;
        word(WAVE + 12).* = 8;
        for (0..9) |i| byte(WAVE + 16 + i).* = @intCast(i * 16);
        const ch = WORK + 0x50;
        byte(ch).* = 0x80;
        byte(ch + 1).* = if (case == 0 or case == 3) 8 else 0;
        byte(ch + 2).* = 255;
        byte(ch + 3).* = 255;
        byte(ch + 4).* = 255;
        byte(ch + 6).* = 255;
        word(ch + 0x20).* = 16384;
        word(ch + 0x24).* = WAVE;
        main();
        const out = 0x02000100 + case * 32;
        word(out).* = byte(ch).*;
        word(out + 4).* = word(ch + 0x18).*;
        word(out + 8).* = word(ch + 0x28).* - (WAVE + 16);
        for (0..16) |i| byte(out + 12 + i).* = byte(WORK + 0x350 + i).*;
    }
    byte(0x02000180).* = 0xa5;
    while (true) {}
}
