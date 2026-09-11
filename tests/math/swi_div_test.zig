// SPDX-License-Identifier: MIT
//! Div tests for signed quotient, remainder, absolute quotient, and timing.
//! Undefined inputs use pinned outputs only where the BIOS returns.
const std = @import("std");
const gba = @import("gba");
const opts = @import("test_options");
const testing = @import("testing");

pub const swi = gba.Swi{ .bios_path = opts.bios_path, .target = opts.div_rom };
const INT_MIN: i32 = std.math.minInt(i32);

pub fn div(num: i32, den: i32) gba.Cmd {
    return .{ .r0 = @bitCast(num), .r1 = @bitCast(den) };
}

const TimingCase = struct { c: gba.Cmd, cycles: u32 };
const timing = [_]TimingCase{
    .{ .c = div(0x12345, 7), .cycles = 270 },
    .{ .c = div(0x7FFFFFFF, 1), .cycles = 491 },
    .{ .c = div(0, 12345), .cycles = 101 },
    .{ .c = div(-1, 1), .cycles = 101 },
};
const ZeroCase = struct { c: gba.Cmd, r0: u32, r1: u32, r3: u32 };
const zero = [_]ZeroCase{
    .{ .c = div(0, 0), .r0 = 1, .r1 = 0, .r3 = 1 },
    .{ .c = div(1, 0), .r0 = 1, .r1 = 1, .r3 = 1 },
    .{ .c = div(-1, 0), .r0 = 0xFFFFFFFF, .r1 = 0xFFFFFFFF, .r3 = 1 },
};

// Well-defined division over a representative sweep: zero, units, both signs, primes, powers of two,
// and 32-bit extremes; checked against Zig integer division.
fn sweep(t: anytype, a: std.mem.Allocator) !void {
    const vals = [_]i32{ 0, 1, -1, 2, -2, 7, -7, 10, -10, 100, -100, 0x12345, -0x12345, 65535, 1 << 16, 0x40000000, 0x7FFFFFFF, INT_MIN, INT_MIN + 1 };
    var cmds: std.ArrayListUnmanaged(gba.Cmd) = .empty;
    defer cmds.deinit(a);
    for (vals) |num| for (vals) |den| {
        if (den == 0 or (num == INT_MIN and den == -1)) continue; // separate edge cases
        try cmds.append(a, div(num, den));
    };
    const res = try swi.run(a, cmds.items);
    defer a.free(res);
    var fails: u32 = 0;
    for (cmds.items, res) |c, r| {
        const num: i32 = @bitCast(c.r0);
        const den: i32 = @bitCast(c.r1);
        const q = @divTrunc(num, den);
        const rem = num -% q *% den; // truncated-division remainder, no second divide
        if (r.r0 != @as(u32, @bitCast(q)) or r.r1 != @as(u32, @bitCast(rem)) or r.r3 != @abs(q)) {
            if (fails == 0) t.info("div {d}/{d}: r0={x} r1={x} r3={x}, want q={x} rem={x} |q|={x}\n", .{
                num, den, r.r0, r.r1, r.r3, @as(u32, @bitCast(q)), @as(u32, @bitCast(rem)), @abs(q),
            });
            fails += 1;
        }
    }
    try t.checkEqual("division", @as(u32, 0), fails);
}

// INT_MIN / -1: the true quotient 2^31 does not fit i32, but the BIOS still returns a pinned tuple.
fn overflow(t: anytype, a: std.mem.Allocator) !void {
    const res = try swi.run(a, &.{div(INT_MIN, -1)});
    defer a.free(res);
    try t.checkEqual("overflow r0", @as(u32, 0x80000000), res[0].r0);
    try t.checkEqual("overflow r1", @as(u32, 0), res[0].r1);
    try t.checkEqual("overflow r3", @as(u32, 0x80000000), res[0].r3);
}

// Denominator-zero cases known to terminate under the harness.
fn zeros(t: anytype, a: std.mem.Allocator) !void {
    var cmds: [zero.len]gba.Cmd = undefined;
    inline for (zero, 0..) |z, i| cmds[i] = z.c;
    const res = try swi.run(a, &cmds);
    defer a.free(res);
    inline for (zero, 0..) |z, i| {
        try t.checkEqual(std.fmt.comptimePrint("zero[{d}] r0", .{i}), z.r0, res[i].r0);
        try t.checkEqual(std.fmt.comptimePrint("zero[{d}] r1", .{i}), z.r1, res[i].r1);
        try t.checkEqual(std.fmt.comptimePrint("zero[{d}] r3", .{i}), z.r3, res[i].r3);
    }
}

// Pinned timing: fixed harness overhead plus the magnitude-dependent division loop.
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
    try overflow(t, a);
    try zeros(t, a);
    try cyc(t, a);
}

test "Div sweep" {
    try testing.host(sweep, std.testing.allocator);
}
test "Div overflow" {
    try testing.host(overflow, std.testing.allocator);
}
test "Div zeros" {
    try testing.host(zeros, std.testing.allocator);
}
test "Div cyc" {
    try testing.host(cyc, std.testing.allocator);
}
