// SPDX-License-Identifier: MIT
//! Drives SoundDriverInit + SoundDriverMode so the host test can read back the reverb byte
//! (SoundInfo+0x05).
//! Records: Mode(0x85)->5, Mode(0x80)->0 (apply reverb value 0), Mode(0)->unchanged.
export const _gba_header linksection(".gbaheader") = @import("header.zig").gbaHeader("SNDMODE", "SMDE");

const WORK: u32 = 0x02010000;
const RESULT: [*]volatile u8 = @ptrFromInt(0x02000100);

fn swiInit(work: u32) void {
    var r0 = work;
    asm volatile ("swi %[n]"
        : [r0] "+{r0}" (r0),
        : [n] "i" (@as(u32, 0x1A) << 16),
        : .{ .memory = true, .r1 = true, .r2 = true, .r3 = true, .r12 = true, .lr = true, .cpsr = true });
}
fn swiMode(m: u32) void {
    var r0 = m;
    asm volatile ("swi %[n]"
        : [r0] "+{r0}" (r0),
        : [n] "i" (@as(u32, 0x1B) << 16),
        : .{ .memory = true, .r1 = true, .r2 = true, .r3 = true, .r12 = true, .lr = true, .cpsr = true });
}

export fn romMain() linksection(".text.romstart") callconv(.c) noreturn {
    swiInit(WORK);
    const si: [*]volatile u8 = @ptrFromInt(WORK);
    swiMode(0x85);
    RESULT[0] = si[5];
    swiMode(0x80);
    RESULT[1] = si[5];
    swiMode(0x85);
    swiMode(0x00);
    RESULT[2] = si[5];
    RESULT[4] = 0xA5;
    while (true) {}
}
