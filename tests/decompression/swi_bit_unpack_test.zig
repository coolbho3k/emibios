// SPDX-License-Identifier: MIT
//! BitUnPack tests for packed bit values and UnPackInfo control fields.
const std = @import("std");
const gba = @import("gba");
const codec = @import("codec.zig");
const opts = @import("test_options");
const testing = @import("testing");

pub const swi = gba.Swi{ .bios_path = opts.bios_path, .target = opts.bit_unpack_rom };

// Timing fixtures (comptime const -> cart ROM, the region the cycle count was measured against).
const timing_src align(4) = blk: {
    var d: [64]u8 = undefined;
    for (&d, 0..) |*b, i| b.* = @intCast((i * 53 + 7) & 0xFF);
    break :blk d;
};
const info_timing: [8]u8 align(4) = codec.bitUnpackInfo(64, 1, 8, 0x10);
const guard_info: [8]u8 align(4) = codec.bitUnpackInfo(8, 1, 8, 0);
const expected_timing = ctBitunpack(&timing_src, 1, 8, 0x10);

fn ctBitunpack(comptime src: []const u8, comptime sw: u8, comptime dw: u8, comptime offset: u32) []const u8 {
    const arr align(4) = comptime blk: {
        @setEvalBranchQuota(4_000_000);
        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const c = codec.bitunpack(fba.allocator(), src, sw, dw, offset) catch unreachable;
        var out: [c.len]u8 align(4) = undefined;
        @memcpy(&out, c);
        break :blk out;
    };
    return &arr;
}

// Decompress live and report whether the SWI output matches the codec (the caller aggregates the matrix).
fn matches(a: std.mem.Allocator, src: []const u8, sw: u8, dw: u8, offset: u32) !bool {
    const expected = try codec.bitunpack(a, src, sw, dw, offset);
    defer a.free(expected);
    const info = codec.bitUnpackInfo(@intCast(src.len), sw, dw, offset);
    const dest = try a.alloc(u8, expected.len);
    defer a.free(dest);
    a.free(try swi.runMem(a, &.{.{ .src = src, .dest = dest, .r2_ptr = &info }}));
    return std.mem.eql(u8, expected, dest);
}

fn checkCase(t: anytype, a: std.mem.Allocator, fails: *u32, src: []const u8, sw: u8, dw: u8, offset: u32) !void {
    if (try matches(a, src, sw, dw, offset)) return;
    if (fails.* == 0) t.info("bitunpack sw={d} dw={d} off=0x{X} len={d}\n", .{ sw, dw, offset, src.len });
    fails.* += 1;
}

fn widths(t: anytype, a: std.mem.Allocator) !void {
    // Width matrix, offsets + zero flag, and larger fixtures.
    var fails: u32 = 0;
    const M = struct { src: []const u8, sw: u8, dw: u8, off: u32 };
    const cases = [_]M{
        .{ .src = &[_]u8{ 0b10110001, 0b00001111 }, .sw = 1, .dw = 2, .off = 0 },
        .{ .src = &[_]u8{0b10110001}, .sw = 1, .dw = 4, .off = 0 },
        .{ .src = &[_]u8{ 0b10110001, 0xF0 }, .sw = 1, .dw = 8, .off = 0 },
        .{ .src = &[_]u8{0b10110001}, .sw = 1, .dw = 16, .off = 0 },
        .{ .src = &[_]u8{0b10110001}, .sw = 1, .dw = 32, .off = 0 },
        .{ .src = &[_]u8{ 0xE4, 0x1B }, .sw = 2, .dw = 4, .off = 0 },
        .{ .src = &[_]u8{0xE4}, .sw = 2, .dw = 8, .off = 0 },
        .{ .src = &[_]u8{0xE4}, .sw = 2, .dw = 16, .off = 0 },
        .{ .src = &[_]u8{ 0x21, 0x43 }, .sw = 4, .dw = 8, .off = 0 },
        .{ .src = &[_]u8{0x21}, .sw = 4, .dw = 16, .off = 0 },
        .{ .src = &[_]u8{0x21}, .sw = 4, .dw = 32, .off = 0 },
        .{ .src = &[_]u8{ 0x11, 0x22, 0x33, 0x44 }, .sw = 8, .dw = 8, .off = 0 },
        .{ .src = &[_]u8{ 0x11, 0x22 }, .sw = 8, .dw = 16, .off = 0 },
        .{ .src = &[_]u8{0x42}, .sw = 8, .dw = 32, .off = 0 },
        .{ .src = &[_]u8{ 0b10110001, 0xF0 }, .sw = 1, .dw = 8, .off = 0x20 },
        .{ .src = &[_]u8{ 0b10110001, 0xF0 }, .sw = 1, .dw = 8, .off = 0x80000020 },
        .{ .src = &[_]u8{ 0x21, 0x40 }, .sw = 4, .dw = 8, .off = 0x10 },
        .{ .src = &[_]u8{ 0x21, 0x40 }, .sw = 4, .dw = 8, .off = 0x80000010 },
        .{ .src = &[_]u8{0xE4}, .sw = 2, .dw = 8, .off = 0x80000005 },
        .{ .src = &[_]u8{ 0x00, 0x05 }, .sw = 8, .dw = 32, .off = 0x100 },
        .{ .src = &[_]u8{ 0x00, 0x05 }, .sw = 8, .dw = 32, .off = 0x80000100 },
    };
    for (cases) |c| {
        try checkCase(t, a, &fails, c.src, c.sw, c.dw, c.off);
    }
    var b16: [16]u8 = undefined;
    for (&b16, 0..) |*b, i| b.* = @intCast((i * 53 + 7) & 0xFF);
    try checkCase(t, a, &fails, &b16, 1, 8, 0x10);
    for (&b16, 0..) |*b, i| b.* = @intCast((i * 29 + 3) & 0xFF);
    try checkCase(t, a, &fails, &b16, 2, 8, 0x04);
    for (&b16, 0..) |*b, i| b.* = @intCast((i * 37 + 1) & 0xFF);
    try checkCase(t, a, &fails, &b16, 4, 16, 0x20);
    var b40: [40]u8 = undefined;
    for (&b40, 0..) |*b, i| b.* = @intCast((i * 17 + 9) & 0xFF);
    try checkCase(t, a, &fails, &b40, 8, 8, 0x01);
    try t.checkEqual("matrix", @as(u32, 0), fails);
}

fn pinned(t: anytype, a: std.mem.Allocator) !void {
    // Pinned timing (const src + info in cart ROM).
    const dest = try a.alloc(u8, expected_timing.len);
    defer a.free(dest);
    const cyc = try swi.runMem(a, &.{.{ .src = timing_src[0..], .dest = dest, .r2_ptr = &info_timing }});
    defer a.free(cyc);
    try t.checkEqual("cyc", @as(u32, 13928), cyc[0]);
}

fn guard(t: anytype, a: std.mem.Allocator) !void {
    // BIOS-region source: the guard fires (dest untouched) on a calibrated skip-path cycle count. The info
    // is a ROM const so the guard's src_len read matches the harness region (a stack local sits in IWRAM).
    var dest = [_]u8{0} ** 64;
    const cyc = try swi.runMem(a, &.{.{ .src = &[_]u8{0xAA} ** 8, .dest = &dest, .src_addr = 0x01000000, .r2_ptr = &guard_info }});
    defer a.free(cyc);
    var touched: u32 = 0;
    for (dest) |b| {
        if (b != 0) touched += 1;
    }
    try t.checkEqual("guard nowrite", @as(u32, 0), touched);
    try t.checkEqual("guard cyc", @as(u32, 128), cyc[0]);
}

fn degenerate(t: anytype, a: std.mem.Allocator) !void {
    const info: [8]u8 align(4) = codec.bitUnpackInfo(0, 1, 8, 0);
    const src = [_]u8{0xFF} ** 4;
    var d0 = [_]u8{0xAB} ** 8;
    a.free(try swi.runMem(a, &.{.{ .src = &src, .dest = &d0, .r2_ptr = &info }}));
    var n: u32 = 0;
    for (d0) |b| {
        if (b != 0) n += 1;
    }
    try t.checkEqual("len0 nowrite", @as(u32, 0), n);
}

pub fn run(t: anytype, a: std.mem.Allocator) !void {
    try widths(t, a);
    try pinned(t, a);
    try guard(t, a);
    try degenerate(t, a);
}

test "BitUnPack degenerate" {
    try testing.host(degenerate, std.testing.allocator);
}
test "BitUnPack widths" {
    try testing.host(widths, std.testing.allocator);
}
test "BitUnPack pinned" {
    try testing.host(pinned, std.testing.allocator);
}
test "BitUnPack guard" {
    try testing.host(guard, std.testing.allocator);
}
