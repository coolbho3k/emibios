// SPDX-License-Identifier: MIT
//! LZ77UnComp tests for WRAM and VRAM destinations.
//! VRAM uses 16-bit writes, so fixtures avoid disp=1 back-references.
const std = @import("std");
const gba = @import("gba");
const codec = @import("codec.zig");
const opts = @import("test_options");
const testing = @import("testing");
const h = @import("test_helpers.zig");

pub const wram = gba.Swi{ .bios_path = opts.bios_path, .target = opts.lz77_wram_rom };
pub const vram = gba.Swi{ .bios_path = opts.bios_path, .target = opts.lz77_vram_rom };

// Timing fixtures, compressed at comptime so they sit in cart ROM (the source region the pinned cycle
// counts were measured against). Roundtrips compress live through the test allocator.
fn ctLz77(comptime data: []const u8, comptime min_disp: usize) []const u8 {
    const arr align(4) = comptime blk: {
        @setEvalBranchQuota(4_000_000);
        var buf: [8192]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const c = codec.lz77(fba.allocator(), data, min_disp) catch unreachable;
        var out: [c.len]u8 align(4) = undefined;
        @memcpy(&out, c);
        break :blk out;
    };
    return &arr;
}
const comp_wram = ctLz77(&[_]u8{0x5A} ** 256, 1);
const comp_vram = ctLz77(&[_]u8{0x5A} ** 256, 2);

// Comptime mixed literal/repeat content; the trailing case in each sweep is odd (wram) / even (vram) size.
fn mixed(comptime n: usize) [n]u8 {
    var b: [n]u8 = undefined;
    for (&b, 0..) |*x, i| x.* = @intCast((i * 7 + (i / 13) * 3) & 0xFF);
    return b;
}

fn roundWram(t: anytype, a: std.mem.Allocator) !void {
    const cases = .{ "A", "Hi", "abc", "Hello, GBA BIOS -- decompress me!", "ABABABABABABABABABAB", &([_]u8{0x5A} ** 100), &mixed(777) };
    inline for (cases, 0..) |d, i|
        try h.roundtrip(t, a, "wram", i, wram, try codec.lz77(a, d, 1), d);
}

fn roundVram(t: anytype, a: std.mem.Allocator) !void {
    const cases = .{ "Hi", "GBA!", "ABABABABABABABABABAB", &([_]u8{0x5A} ** 100), &mixed(778) };
    inline for (cases, 0..) |d, i|
        try h.roundtrip(t, a, "vram", i, vram, try codec.lz77(a, d, 2), d);
}

fn cyc(t: anytype, a: std.mem.Allocator) !void {
    try h.timing(t, a, "wram cyc", wram, comp_wram, 256, 4041);
    try h.timing(t, a, "vram cyc", vram, comp_vram, 256, 7263);
}

fn guard(t: anytype, a: std.mem.Allocator) !void {
    try h.guard(t, a, "wram", wram, try codec.lz77(a, "would be output if not guarded", 1), 113);
    try h.guard(t, a, "vram", vram, try codec.lz77(a, "would be output if not guarded", 1), 123);
}

fn malformed(t: anytype, a: std.mem.Allocator) !void {
    const size0 = [_]u8{ 0x10, 0, 0, 0 };
    var d0 = [_]u8{0xAB} ** 8;
    a.free(try wram.runMem(a, &.{.{ .src = &size0, .dest = &d0 }}));
    try t.checkEqual("size0 nowrite", @as(u32, 0), countNonZero(&d0));
    const trunc = [_]u8{ 0x10, 6, 0, 0, 0x40, 0x41, 0xF0, 0x00 };
    var dt = [_]u8{0xAB} ** 10;
    a.free(try wram.runMem(a, &.{.{ .src = &trunc, .dest = &dt }}));
    try t.checkBytes("final match overshoot", "AAAAAAAAAA", &dt);
}

fn countNonZero(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |b| {
        if (b != 0) n += 1;
    }
    return n;
}

pub fn run(t: anytype, a: std.mem.Allocator) !void {
    try roundWram(t, a);
    try roundVram(t, a);
    try cyc(t, a);
    try guard(t, a);
    try malformed(t, a);
}

test "LZ77UnComp roundWram" {
    try testing.host(roundWram, std.testing.allocator);
}
test "LZ77UnComp roundVram" {
    try testing.host(roundVram, std.testing.allocator);
}
test "LZ77UnComp cyc" {
    try testing.host(cyc, std.testing.allocator);
}
test "LZ77UnComp guard" {
    try testing.host(guard, std.testing.allocator);
}
test "LZ77UnComp malformed" {
    try testing.host(malformed, std.testing.allocator);
}
