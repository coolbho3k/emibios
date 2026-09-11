// SPDX-License-Identifier: MIT
//! ArcTan tests for the BIOS fixed-point approximation.
//! The approximation is meaningful through |tan| <= 0x4000. Beyond that, only selected breakpoints are pinned.
const std = @import("std");
const gba = @import("gba");
const opts = @import("test_options");
const testing = @import("testing");

pub const swi = gba.Swi{ .bios_path = opts.bios_path, .target = opts.arc_tan_rom };

fn arctan(tan: i32) gba.Cmd {
    return .{ .r0 = @bitCast(tan) };
}

const RefCase = struct { tan: i32, angle: u32 };
const refs = [_]RefCase{
    .{ .tan = 0, .angle = 0x00000000 },
    .{ .tan = 0x1000, .angle = 0x000009fb },
    .{ .tan = 0x2000, .angle = 0x000012e4 },
    .{ .tan = 0x4000, .angle = 0x00002000 },
    .{ .tan = -0x1000, .angle = 0xfffff604 },
    .{ .tan = -0x2000, .angle = 0xffffed1c },
    .{ .tan = -0x4000, .angle = 0xffffe000 },
};
const breaks = [_]RefCase{
    .{ .tan = 0x00003FFF, .angle = 0x00001fff },
    .{ .tan = 0x00004001, .angle = 0x00001fff }, // turns over just past 0x4000
    .{ .tan = 0x00007FFF, .angle = 0x000016d8 },
    .{ .tan = 0x00008000, .angle = 0x000016a2 },
    .{ .tan = 0x0000BFFF, .angle = 0x00001f64 },
    .{ .tan = @bitCast(@as(u32, 0x0000C000)), .angle = 0xffffc360 }, // discontinuity to large negative
    .{ .tan = @bitCast(@as(u32, 0x0000C001)), .angle = 0xffffd550 },
    .{ .tan = @bitCast(@as(u32, 0x0000FFFF)), .angle = 0xffffa2fe },
    .{ .tan = -1, .angle = 0xffffffff },
};
const TimingCase = struct { tan: i32, cycles: u32 };
const timing = [_]TimingCase{
    .{ .tan = 0, .cycles = 130 },
    .{ .tan = 0x2000, .cycles = 132 },
    .{ .tan = -0x4000, .cycles = 132 },
};

// Monotonic over the documented useful range.
fn sweep(t: anytype, a: std.mem.Allocator) !void {
    var cmds: std.ArrayListUnmanaged(gba.Cmd) = .empty;
    defer cmds.deinit(a);
    var tan: i32 = -0x4000;
    while (tan <= 0x4000) : (tan += 0x100) try cmds.append(a, arctan(tan));
    const res = try swi.run(a, cmds.items);
    defer a.free(res);
    var prev: i32 = std.math.minInt(i32);
    var fails: u32 = 0;
    for (cmds.items, res) |c, r| {
        const angle: i32 = @bitCast(r.r0);
        if (angle <= prev) {
            if (fails == 0) t.info("arctan(0x{X}): {d} does not exceed {d}\n", .{ c.r0, angle, prev });
            fails += 1;
        }
        prev = angle;
    }
    try t.checkEqual("monotonic", @as(u32, 0), fails);
}

// Reference + out-of-range breakpoint angles.
fn angles(t: anytype, a: std.mem.Allocator) !void {
    inline for (refs ++ breaks, 0..) |g, i| {
        const res = try swi.run(a, &.{arctan(g.tan)});
        defer a.free(res);
        try t.checkEqual(std.fmt.comptimePrint("ang[{d}]", .{i}), g.angle, res[0].r0);
    }
}

fn cyc(t: anytype, a: std.mem.Allocator) !void {
    var cmds: [timing.len]gba.Cmd = undefined;
    inline for (timing, 0..) |tc, i| cmds[i] = arctan(tc.tan);
    const res = try swi.run(a, &cmds);
    defer a.free(res);
    inline for (timing, 0..) |tc, i|
        try t.checkEqual(std.fmt.comptimePrint("cyc[{d}]", .{i}), tc.cycles, res[i].cycles);
}

pub fn run(t: anytype, a: std.mem.Allocator) !void {
    try sweep(t, a);
    try angles(t, a);
    try cyc(t, a);
}

test "ArcTan sweep" {
    try testing.host(sweep, std.testing.allocator);
}
test "ArcTan angles" {
    try testing.host(angles, std.testing.allocator);
}
test "ArcTan cyc" {
    try testing.host(cyc, std.testing.allocator);
}
