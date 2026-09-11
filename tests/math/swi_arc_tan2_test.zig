// SPDX-License-Identifier: MIT
//! ArcTan2 tests for the full-circle fixed-point angle.
//! Only r0 is a defined output.
const std = @import("std");
const gba = @import("gba");
const opts = @import("test_options");
const testing = @import("testing");

pub const swi = gba.Swi{ .bios_path = opts.bios_path, .target = opts.arc_tan2_rom };

fn arctan2(x: i32, y: i32) gba.Cmd {
    return .{ .r0 = @bitCast(x), .r1 = @bitCast(y) };
}

const CardCase = struct { x: i32, y: i32, angle: u32 };
const cardinal = [_]CardCase{
    .{ .x = 0x4000, .y = 0, .angle = 0x0000 }, // +X -> 0 deg
    .{ .x = 0, .y = 0x4000, .angle = 0x4000 }, // +Y -> 90 deg
    .{ .x = -0x4000, .y = 0, .angle = 0x8000 }, // -X -> 180 deg
    .{ .x = 0, .y = -0x4000, .angle = 0xC000 }, // -Y -> 270 deg
    .{ .x = 0x4000, .y = 0x4000, .angle = 0x2000 }, // Q1 -> 45 deg
    .{ .x = -0x4000, .y = 0x4000, .angle = 0x6000 }, // Q2 -> 135 deg
    .{ .x = -0x4000, .y = -0x4000, .angle = 0xA000 }, // Q3 -> 225 deg
    .{ .x = 0x4000, .y = -0x4000, .angle = 0xE000 }, // Q4 -> 315 deg
};
const edges = [_]CardCase{
    .{ .x = 0, .y = 0, .angle = 0x0000 }, // origin (degenerate)
    .{ .x = 0x7FFF, .y = 1, .angle = 0x0000 }, // hugging +X
    .{ .x = 1, .y = 0x7FFF, .angle = 0x4000 }, // hugging +Y
    .{ .x = 0x8000, .y = 0x8000, .angle = 0x2000 }, // 32-bit positive -> Q1
    .{ .x = 0xC000, .y = 0xC000, .angle = 0x2000 },
};
const TimingCase = struct { x: i32, y: i32, cycles: u32 };
const timing = [_]TimingCase{
    .{ .x = 0x4000, .y = 0, .cycles = 105 },
    .{ .x = 0x4000, .y = 0x4000, .cycles = 393 },
    .{ .x = -0x4000, .y = 0x4000, .cycles = 396 },
};

fn angles(t: anytype, a: std.mem.Allocator) !void {
    inline for (cardinal ++ edges, 0..) |g, i| {
        const res = try swi.run(a, &.{arctan2(g.x, g.y)});
        defer a.free(res);
        try t.checkEqual(std.fmt.comptimePrint("ang[{d}]", .{i}), g.angle, res[0].r0);
    }
}

// Quadrant selection away from the axes (half-open bounds).
fn quadrant(t: anytype, a: std.mem.Allocator) !void {
    var cmds: std.ArrayListUnmanaged(gba.Cmd) = .empty;
    defer cmds.deinit(a);
    const mags = [_]i32{ 0x1000, 0x2000, 0x4000 };
    for ([_]i32{ 1, -1 }) |sx| for ([_]i32{ 1, -1 }) |sy| for (mags) |mx| for (mags) |my|
        try cmds.append(a, arctan2(sx * mx, sy * my));
    const res = try swi.run(a, cmds.items);
    defer a.free(res);
    var fails: u32 = 0;
    for (cmds.items, res) |c, r| {
        const x: i32 = @bitCast(c.r0);
        const y: i32 = @bitCast(c.r1);
        const lo: u32 = if (y > 0) (if (x > 0) 0x0000 else 0x4000) else (if (x < 0) 0x8000 else 0xC000);
        if (!(r.r0 >= lo and r.r0 < lo + 0x4000)) {
            if (fails == 0) t.info("arctan2({d},{d}): got 0x{X}, want quadrant 0x{X}\n", .{ x, y, r.r0, lo });
            fails += 1;
        }
    }
    try t.checkEqual("quadrant", @as(u32, 0), fails);
}

fn cyc(t: anytype, a: std.mem.Allocator) !void {
    var cmds: [timing.len]gba.Cmd = undefined;
    inline for (timing, 0..) |tc, i| cmds[i] = arctan2(tc.x, tc.y);
    const res = try swi.run(a, &cmds);
    defer a.free(res);
    inline for (timing, 0..) |tc, i|
        try t.checkEqual(std.fmt.comptimePrint("cyc[{d}]", .{i}), tc.cycles, res[i].cycles);
}

pub fn run(t: anytype, a: std.mem.Allocator) !void {
    try angles(t, a);
    try quadrant(t, a);
    try cyc(t, a);
}

test "ArcTan2 angles" {
    try testing.host(angles, std.testing.allocator);
}
test "ArcTan2 quadrant" {
    try testing.host(quadrant, std.testing.allocator);
}
test "ArcTan2 cyc" {
    try testing.host(cyc, std.testing.allocator);
}
