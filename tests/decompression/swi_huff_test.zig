// SPDX-License-Identifier: MIT
//! HuffUnComp tests for GBATEK type-2 streams.
//! The SWI emits whole 32-bit words, so fixture outputs are multiples of 4.
const std = @import("std");
const gba = @import("gba");
const codec = @import("codec.zig");
const opts = @import("test_options");
const testing = @import("testing");
const h = @import("test_helpers.zig");

pub const swi = gba.Swi{ .bios_path = opts.bios_path, .target = opts.huff_rom };

// codec.huffman is not comptime-evaluable, so its timing source is pre-generated (in cart ROM) and checked
// against the live codec below so it cannot drift.
const huff_timing_data = blk: {
    var d: [256]u8 = undefined;
    for (&d, 0..) |*b, i| b.* = @intCast('A' + (i % 8));
    break :blk d;
};
const comp_timing_bytes align(4) = [_]u8{ 40, 0, 1, 0, 7, 0, 0, 1, 193, 194, 194, 195, 65, 66, 67, 68, 69, 70, 71, 72, 5, 119, 57, 5, 57, 5, 119, 57, 119, 57, 5, 119, 5, 119, 57, 5, 57, 5, 119, 57, 119, 57, 5, 119, 5, 119, 57, 5, 57, 5, 119, 57, 119, 57, 5, 119, 5, 119, 57, 5, 57, 5, 119, 57, 119, 57, 5, 119, 5, 119, 57, 5, 57, 5, 119, 57, 119, 57, 5, 119, 5, 119, 57, 5, 57, 5, 119, 57, 119, 57, 5, 119, 5, 119, 57, 5, 57, 5, 119, 57, 119, 57, 5, 119, 5, 119, 57, 5, 57, 5, 119, 57, 119, 57, 5, 119, 0, 0, 0, 0, 0, 0, 0, 0 };
const comp_timing: []const u8 = &comp_timing_bytes;

const skew = blk: {
    var b: [256]u8 = undefined; // skewed distribution, modest (<=12) alphabet
    for (&b, 0..) |*x, i| x.* = if (i % 7 == 0) @as(u8, @intCast('a' + (i % 12))) else 'a';
    break :blk b;
};

fn roundtrips(t: anytype, a: std.mem.Allocator) !void {
    // The pre-generated timing fixture still matches the codec.
    {
        const ct = try codec.huffman(a, &huff_timing_data);
        defer a.free(ct);
        try t.checkBytes("fixture", comp_timing, ct);
    }
    const cases = .{ "ABCDABCDABCDABCD", "HuffManHuffManHuffMan!!!", &skew };
    inline for (cases, 0..) |d, i|
        try h.roundtrip(t, a, "", i, swi, try codec.huffman(a, d), d);
}

fn cyc(t: anytype, a: std.mem.Allocator) !void {
    try h.timing(t, a, "cyc", swi, comp_timing, 256, 32693);
}

fn guard(t: anytype, a: std.mem.Allocator) !void {
    try h.guard(t, a, "", swi, try codec.huffman(a, "ABCDABCDABCDABCD"), 121);
}

fn malformed(t: anytype, a: std.mem.Allocator) !void {
    const size0 = [_]u8{ 0x28, 0, 0, 0, 0, 0, 0, 0 };
    var d0 = [_]u8{0xAB} ** 8;
    a.free(try swi.runMem(a, &.{.{ .src = &size0, .dest = &d0 }}));
    var n0: u32 = 0;
    for (d0) |b| {
        if (b != 0) n0 += 1;
    }
    try t.checkEqual("size0 nowrite", @as(u32, 0), n0);
}

pub fn run(t: anytype, a: std.mem.Allocator) !void {
    try roundtrips(t, a);
    try cyc(t, a);
    try guard(t, a);
    try malformed(t, a);
}

test "HuffUnComp roundtrips" {
    try testing.host(roundtrips, std.testing.allocator);
}
test "HuffUnComp cyc" {
    try testing.host(cyc, std.testing.allocator);
}
test "HuffUnComp malformed" {
    try testing.host(malformed, std.testing.allocator);
}
test "HuffUnComp guard" {
    try testing.host(guard, std.testing.allocator);
}
