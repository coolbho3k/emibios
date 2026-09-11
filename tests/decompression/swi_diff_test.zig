// SPDX-License-Identifier: MIT
//! DiffUnFilter tests for 8-bit WRAM, 8-bit VRAM, and 16-bit streams.
//! Fixtures encode known running sums and verify output, wraparound, and source guards.
const std = @import("std");
const gba = @import("gba");
const codec = @import("codec.zig");
const opts = @import("test_options");
const testing = @import("testing");
const h = @import("test_helpers.zig");
const bytes = std.mem.sliceAsBytes;

pub const diff8 = gba.Swi{ .bios_path = opts.bios_path, .target = opts.diff8_wram_rom };
pub const diff8v = gba.Swi{ .bios_path = opts.bios_path, .target = opts.diff8_vram_rom };
pub const diff16 = gba.Swi{ .bios_path = opts.bios_path, .target = opts.diff16_rom };

fn ctCodec(comptime f: anytype, comptime data: []const u8) []const u8 {
    const arr align(4) = comptime blk: {
        @setEvalBranchQuota(4_000_000);
        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const c = f(fba.allocator(), data) catch unreachable;
        var out: [c.len]u8 align(4) = undefined;
        @memcpy(&out, c);
        break :blk out;
    };
    return &arr;
}
const ramp8 = blk: {
    var d: [256]u8 = undefined;
    for (&d, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    break :blk d;
};
const ramp16 = blk: {
    var d: [128]u16 = undefined;
    for (&d, 0..) |*w, i| w.* = @intCast(i & 0xFFFF);
    break :blk @as([256]u8, @bitCast(d));
};
const noisy = blk: {
    var b: [400]u8 = undefined; // large deltas that wrap mod 256
    for (&b, 0..) |*x, i| x.* = @intCast((i * 97 + 13) & 0xFF);
    break :blk b;
};
const r16 = blk: {
    var w: [200]u16 = undefined; // large strides that wrap mod 65536
    for (&w, 0..) |*x, i| x.* = @truncate(i *% 0x0789);
    break :blk w;
};
const comp8 = ctCodec(codec.diff8, &ramp8);
const comp16 = ctCodec(codec.diff16, &ramp16);

fn filt8(t: anytype, a: std.mem.Allocator) !void {
    const w8 = .{ &[_]u8{0x42}, &[_]u8{ 1, 3, 6, 10, 15, 21, 28 }, &ramp8, &noisy }; // first byte verbatim; sums; ramp; wrap
    const v8 = .{ &noisy, &ramp8 };
    inline for (w8, 0..) |d, i| try h.roundtrip(t, a, "8w", i, diff8, try codec.diff8(a, d), d);
    inline for (v8, 0..) |d, i| try h.roundtrip(t, a, "8v", i, diff8v, try codec.diff8(a, d), d);
}

fn filt16(t: anytype, a: std.mem.Allocator) !void {
    const w16 = .{ bytes(&[_]u16{0x1234}), bytes(&r16) };
    inline for (w16, 0..) |d, i| try h.roundtrip(t, a, "16", i, diff16, try codec.diff16(a, d), d);
}

// Row tags: 8w = Diff8bit write-8 (WRAM), 8v = Diff8bit write-16 (VRAM), 16 = Diff16bit.
fn cyc(t: anytype, a: std.mem.Allocator) !void {
    try h.timing(t, a, "8w cyc", diff8, comp8, 256, 4983);
    try h.timing(t, a, "8v cyc", diff8v, comp8, 256, 6393);
    try h.timing(t, a, "16 cyc", diff16, comp16, 256, 2551);
}

fn guard(t: anytype, a: std.mem.Allocator) !void {
    try h.guard(t, a, "8w", diff8, try codec.diff8(a, "would be output if not guarded"), 116);
    try h.guard(t, a, "8v", diff8v, try codec.diff8(a, "would be output if not guarded"), 123);
    try h.guard(t, a, "16", diff16, try codec.diff16(a, bytes(&[_]u16{ 0xAAAA, 0xBBBB })), 116);
}

fn malformed(t: anytype, a: std.mem.Allocator) !void {
    const s8 = [_]u8{ 0x81, 0, 0, 0 };
    const s16 = [_]u8{ 0x82, 0, 0, 0 };
    var d8 = [_]u8{0xAB} ** 8;
    var d16 = [_]u8{0xAB} ** 8;
    a.free(try diff8.runMem(a, &.{.{ .src = &s8, .dest = &d8 }}));
    a.free(try diff16.runMem(a, &.{.{ .src = &s16, .dest = &d16 }}));
    var n: u32 = 0;
    for (d8) |b| {
        if (b != 0) n += 1;
    }
    for (d16) |b| {
        if (b != 0) n += 1;
    }
    try t.checkEqual("size0 nowrite", @as(u32, 0), n);
}

pub fn run(t: anytype, a: std.mem.Allocator) !void {
    try filt8(t, a);
    try filt16(t, a);
    try cyc(t, a);
    try guard(t, a);
    try malformed(t, a);
}

test "DiffUnFilter filt8" {
    try testing.host(filt8, std.testing.allocator);
}
test "DiffUnFilter filt16" {
    try testing.host(filt16, std.testing.allocator);
}
test "DiffUnFilter cyc" {
    try testing.host(cyc, std.testing.allocator);
}
test "DiffUnFilter malformed" {
    try testing.host(malformed, std.testing.allocator);
}
test "DiffUnFilter guard" {
    try testing.host(guard, std.testing.allocator);
}
