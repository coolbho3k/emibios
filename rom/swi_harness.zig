// SPDX-License-Identifier: MIT
//! Per-SWI timing harness ROM booted by the host driver (tests/gba.zig). It reads the command table the
//! host patched into cart ROM and runs each command through the shared executor (rom/gba.zig execReg), so
//! the host's cycle goldens and the on-GBA counts come from one timing bracket. `harness_opts.swi` fixes
//! the SWI number per cart at build time. The `swi #n` immediate must be comptime.
//!
//! Protocol (same as tests/gba.zig):
//!   cart ROM 0x08000400: [count u32][r0,r1,r2,r3]...  (patched by the host)
//!   EWRAM    0x02000000: [DONE magic u32]
//!   EWRAM    0x02000004: [r0,r1,r2,r3,cycles]...
const gba = @import("gba");
const opts = @import("harness_opts");
const protocol = @import("protocol");

export const _gba_header linksection(".gbaheader") = @import("header.zig").gbaHeader("SWIHARN", "SWIH");

const CMD: [*]volatile u32 = @ptrFromInt(0x08000000 + protocol.CMD_OFF); // count, then {r0,r1,r2,r3} per command
const RES: [*]volatile u32 = @ptrFromInt(0x02000000 + protocol.RES_OFF); // {r0,r1,r2,r3,cycles} per command
const DONE: *volatile u32 = @ptrFromInt(0x02000000);

export fn romMain() linksection(".text.romstart") callconv(.c) noreturn {
    gba.timerInit();
    const count = CMD[0];
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const c = 1 + i * (protocol.CMD_STRIDE / 4);
        const r = gba.execReg(opts.swi, .{ .r0 = CMD[c], .r1 = CMD[c + 1], .r2 = CMD[c + 2], .r3 = CMD[c + 3] });
        const o = i * (protocol.RES_STRIDE / 4);
        RES[o] = r.r0;
        RES[o + 1] = r.r1;
        RES[o + 2] = r.r2;
        RES[o + 3] = r.r3;
        RES[o + 4] = r.cycles;
    }
    DONE.* = protocol.DONE_MAGIC; // last, after every result is written
    while (true) {}
}
