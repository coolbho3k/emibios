// SPDX-License-Identifier: MIT
//! Sqrt tests for floor(sqrt(r0)) over unsigned 32-bit inputs.
//! Only r0 is a defined output, so r1 and r3 are left as scratch.
const std = @import("std");
const gba = @import("gba");
const opts = @import("test_options");
const testing = @import("testing");

pub const swi = gba.Swi{ .bios_path = opts.bios_path, .target = opts.sqrt_rom };

const TimingCase = struct { x: u32, cycles: u32 };
const timing = [_]TimingCase{
    .{ .x = 0, .cycles = 130 },
    .{ .x = 0x12345, .cycles = 612 },
    .{ .x = 0xFFFFFFFF, .cycles = 629 },
};

/// Exact floor(sqrt(x)), integer-only (the ROM has no FPU/soft-float): bit-by-bit restoring sqrt.
fn isqrt(x: u32) u32 {
    var root: u32 = 0;
    var rem: u32 = x;
    var bit: u32 = 1 << 30;
    while (bit > rem) bit >>= 2;
    while (bit != 0) {
        if (rem >= root + bit) {
            rem -= root + bit;
            root = (root >> 1) + bit;
        } else {
            root >>= 1;
        }
        bit >>= 2;
    }
    return root;
}

fn sweep(t: anytype, a: std.mem.Allocator) !void {
    var inputs: std.ArrayListUnmanaged(u32) = .empty;
    defer inputs.deinit(a);
    for (0..64) |x| try inputs.append(a, @intCast(x)); // the dense low end
    for ([_]u32{ 100, 255, 256, 1000, 0x8000, 0xFFFF }) |n| { // straddle n^2 (n <= 0xFFFF)
        const sq = n * n;
        try inputs.appendSlice(a, &.{ sq - 1, sq, sq + 1 });
    }
    try inputs.appendSlice(a, &.{ 0x12345, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF }); // mid + extremes
    try inputs.appendSlice(a, &.{ 0xF, 0x10, 0x10000, 0x10001, 0x3FFFFFFF, 0x40000000, 0x40000001, 0xFFFF0000, 0xFFFFFFFE });

    const cmds = try a.alloc(gba.Cmd, inputs.items.len);
    defer a.free(cmds);
    for (cmds, inputs.items) |*c, x| c.* = .{ .r0 = x };
    const res = try swi.run(a, cmds);
    defer a.free(res);
    var fails: u32 = 0;
    for (inputs.items, res) |x, r| {
        if (r.r0 != isqrt(x)) {
            if (fails == 0) t.info("sqrt(0x{X}): got {d}, want {d}\n", .{ x, r.r0, isqrt(x) });
            fails += 1;
        }
    }
    try t.checkEqual("floor result", @as(u32, 0), fails);
}

fn cyc(t: anytype, a: std.mem.Allocator) !void {
    var cmds: [timing.len]gba.Cmd = undefined;
    inline for (timing, 0..) |tc, i| cmds[i] = .{ .r0 = tc.x };
    const res = try swi.run(a, &cmds);
    defer a.free(res);
    inline for (timing, 0..) |tc, i|
        try t.checkEqual(std.fmt.comptimePrint("cyc[{d}]", .{i}), tc.cycles, res[i].cycles);
}

pub fn run(t: anytype, a: std.mem.Allocator) !void {
    try sweep(t, a);
    try cyc(t, a);
}

test "Sqrt sweep" {
    try testing.host(sweep, std.testing.allocator);
}
test "Sqrt cyc" {
    try testing.host(cyc, std.testing.allocator);
}
