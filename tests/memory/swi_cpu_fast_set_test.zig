// SPDX-License-Identifier: MIT
//! CpuFastSet tests for 32-bit copy/fill in 8-word blocks.
//! Destination memory is the defined output.
const std = @import("std");
const gba = @import("gba");
const opts = @import("test_options");
const testing = @import("testing");
const bytes = std.mem.sliceAsBytes;

pub const swi = gba.Swi{ .bios_path = opts.bios_path, .target = opts.cpu_fast_set_rom };

const FILL: u32 = 1 << 24; // fixed source: repeat one word

const timing_src = [_]u32{0x5A5A5A5A} ** 128; // const -> cart ROM for the pinned cycle counts

fn countNot(slice: []const u32, val: u32) u32 {
    var n: u32 = 0;
    for (slice) |x| {
        if (x != val) n += 1;
    }
    return n;
}

fn copy(t: anytype, a: std.mem.Allocator) !void {
    var src: [64]u32 = undefined;
    for (&src, 0..) |*w, i| w.* = @as(u32, @intCast(i)) *% 0x01010101 +% 0xF00D;
    var copy_dst = [_]u32{0} ** src.len;
    var copy8 = [_]u32{0} ** 8; // the minimum block
    const fill = [_]u32{0x12345678};
    var fill_dst = [_]u32{0} ** 24;
    const cmds = [_]gba.MemCmd{
        .{ .src = bytes(&src), .dest = bytes(&copy_dst), .r2 = src.len }, // copy 64 words
        .{ .src = bytes(&src), .dest = bytes(&copy8), .r2 = 8 }, // copy one 8-word block
        .{ .src = bytes(&fill), .dest = bytes(&fill_dst), .r2 = fill_dst.len | FILL }, // fill 24 words
    };
    a.free(try swi.runMem(a, &cmds));
    try t.checkBytes("copy", bytes(&src), bytes(&copy_dst));
    try t.checkBytes("copy8", bytes(src[0..8]), bytes(&copy8));
    try t.checkEqual("fill", @as(u32, 0), countNot(&fill_dst, 0x12345678));
}

// Counts round up to full 8-word blocks.
fn round(t: anytype, a: std.mem.Allocator) !void {
    var src: [16]u32 = undefined;
    for (&src, 0..) |*w, i| w.* = 0xA0000000 | @as(u32, @intCast(i));
    var d5 = [_]u32{0} ** 16;
    var d12 = [_]u32{0} ** 16;
    const cmds = [_]gba.MemCmd{
        .{ .src = bytes(&src), .dest = bytes(&d5), .r2 = 5 }, // 5 rounds up to 8
        .{ .src = bytes(&src), .dest = bytes(&d12), .r2 = 12 }, // 12 rounds up to 16
    };
    a.free(try swi.runMem(a, &cmds));
    try t.checkBytes("round5", bytes(src[0..8]), bytes(d5[0..8]));
    try t.checkEqual("round5 no overrun", @as(u32, 0), countNot(d5[8..], 0));
    try t.checkBytes("round12", bytes(&src), bytes(&d12));
}

fn cycles(t: anytype, a: std.mem.Allocator) !void {
    var dz = [_]u32{0} ** 1;
    var d0 = [_]u32{0} ** 128;
    var d1 = [_]u32{0} ** 128;
    const want = [_]u32{ 116, 1805, 990 };
    const cmds = [_]gba.MemCmd{
        .{ .src = bytes(timing_src[0..1]), .dest = bytes(&dz), .r2 = 0 },
        .{ .src = bytes(&timing_src), .dest = bytes(&d0), .r2 = 128 }, // copy 128 words
        .{ .src = bytes(timing_src[0..1]), .dest = bytes(&d1), .r2 = 128 | FILL }, // fill 128 words
    };
    const x = try swi.runMem(a, &cmds);
    defer a.free(x);
    inline for (want, 0..) |w, i| try t.checkEqual(std.fmt.comptimePrint("cyc[{d}]", .{i}), w, x[i]);
}

fn guard(t: anytype, a: std.mem.Allocator) !void {
    var dest = [_]u8{0} ** 64;
    const cyc = try swi.runMem(a, &.{.{ .src = bytes(&timing_src), .dest = &dest, .r2 = 16, .src_addr = 0x01000000 }});
    defer a.free(cyc);
    try t.checkEqual("guard nowrite", @as(u32, 0), @as(u32, blk: {
        var n: u32 = 0;
        for (dest) |b| {
            if (b != 0) n += 1;
        }
        break :blk n;
    }));
    try t.checkEqual("guard cyc", @as(u32, 118), cyc[0]);
}

fn degenerate(t: anytype, a: std.mem.Allocator) !void {
    var src: [16]u32 = undefined;
    for (&src, 0..) |*w, i| w.* = 0xB0000000 | @as(u32, @intCast(i));
    var d0 = [_]u32{0xABCD} ** 8;
    var dmask = [_]u32{0xABCD} ** 16;
    const cmds = [_]gba.MemCmd{
        .{ .src = bytes(&src), .dest = bytes(&d0), .r2 = 0 },
        .{ .src = bytes(&src), .dest = bytes(&dmask), .r2 = 8 | (1 << 21) },
    };
    a.free(try swi.runMem(a, &cmds));
    try t.checkEqual("count0 nowrite", @as(u32, 0), countNot(&d0, 0));
    try t.checkBytes("countmask", bytes(src[0..8]), bytes(dmask[0..8]));
    try t.checkEqual("countmask tail", @as(u32, 0), countNot(dmask[8..], 0));
}

pub fn run(t: anytype, a: std.mem.Allocator) !void {
    try copy(t, a);
    try round(t, a);
    try cycles(t, a);
    try guard(t, a);
    try degenerate(t, a);
}

test "CpuFastSet copy" {
    try testing.host(copy, std.testing.allocator);
}
test "CpuFastSet round" {
    try testing.host(round, std.testing.allocator);
}
test "CpuFastSet cycles" {
    try testing.host(cycles, std.testing.allocator);
}
test "CpuFastSet guard" {
    try testing.host(guard, std.testing.allocator);
}
test "CpuFastSet degenerate" {
    try testing.host(degenerate, std.testing.allocator);
}
