// SPDX-License-Identifier: MIT
//! Standalone RAM permutation harness ROM
const gba = @import("gba");
const perm = @import("perm");
const protocol = @import("protocol");

export const _gba_header linksection(".gbaheader") = @import("header.zig").gbaHeader("PERMHARN", "PMHN");

const REG_DISPCNT: *volatile u16 = @ptrFromInt(0x04000000);

export fn romMain() linksection(".text.romstart") callconv(.c) noreturn {
    REG_DISPCNT.* = 0x0080;
    gba.timerInit();
    perm.runMatrix();
    perm.runDiag();
    @as(*volatile u32, @ptrFromInt(0x02000000)).* = protocol.DONE_MAGIC;
    while (true) {}
}
