// SPDX-License-Identifier: MIT
//! DivArm tests for the Div contract with r0 and r1 operands exchanged.
//! Well-defined cases are checked against Zig integer division.
const std = @import("std");
const gba = @import("gba");
const opts = @import("test_options");
const testing = @import("testing");

pub const swi = gba.Swi{ .bios_path = opts.bios_path, .target = opts.div_arm_rom };
const INT_MIN: i32 = std.math.minInt(i32);

pub fn divArm(num: i32, den: i32) gba.Cmd {
    return .{ .r0 = @bitCast(den), .r1 = @bitCast(num) }; // operands swapped relative to Div
}

const TimingCase = struct { c: gba.Cmd, cycles: u32 };
const timing = [_]TimingCase{
    .{ .c = divArm(0x12345, 7), .cycles = 273 },
    .{ .c = divArm(0x7FFFFFFF, 1), .cycles = 494 },
    .{ .c = divArm(0, 12345), .cycles = 104 },
};

fn sweep(t: anytype, a: std.mem.Allocator) !void {
    const vals = [_]i32{ 0, 1, -1, 2, -2, 7, -7, 100, -100, 0x12345, -0x12345, 0x40000000, 0x7FFFFFFF, INT_MIN, INT_MIN + 1 };
    var cmds: std.ArrayListUnmanaged(gba.Cmd) = .empty;
    defer cmds.deinit(a);
    for (vals) |num| for (vals) |den| {
        if (den == 0 or (num == INT_MIN and den == -1)) continue;
        try cmds.append(a, divArm(num, den));
    };
    const res = try swi.run(a, cmds.items);
    defer a.free(res);
    var fails: u32 = 0;
    for (cmds.items, res) |c, r| {
        const den: i32 = @bitCast(c.r0); // recover the (swapped) operands
        const num: i32 = @bitCast(c.r1);
        const q = @divTrunc(num, den);
        const rem = num -% q *% den; // truncated-division remainder, no second divide
        if (r.r0 != @as(u32, @bitCast(q)) or r.r1 != @as(u32, @bitCast(rem)) or r.r3 != @abs(q)) {
            if (fails == 0) t.info("divarm {d}/{d}: r0={x} r1={x} r3={x}, want q={x} rem={x} |q|={x}\n", .{
                num, den, r.r0, r.r1, r.r3, @as(u32, @bitCast(q)), @as(u32, @bitCast(rem)), @abs(q),
            });
            fails += 1;
        }
    }
    try t.checkEqual("division", @as(u32, 0), fails);
}

fn cyc(t: anytype, a: std.mem.Allocator) !void {
    var cmds: [timing.len]gba.Cmd = undefined;
    inline for (timing, 0..) |tc, i| cmds[i] = tc.c;
    const res = try swi.run(a, &cmds);
    defer a.free(res);
    inline for (timing, 0..) |tc, i|
        try t.checkEqual(std.fmt.comptimePrint("cyc[{d}]", .{i}), tc.cycles, res[i].cycles);
}

pub fn run(t: anytype, a: std.mem.Allocator) !void {
    try sweep(t, a);
    try cyc(t, a);
}

test "DivArm sweep" {
    try testing.host(sweep, std.testing.allocator);
}
test "DivArm cyc" {
    try testing.host(cyc, std.testing.allocator);
}
